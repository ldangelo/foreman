defmodule ForemanServer.VcsAdapterTest.Stub do
  @behaviour ForemanServer.VcsAdapter

  alias ForemanServer.EventStore

  @impl true
  def clone(input, _opts), do: invoke(:clone, input)

  @impl true
  def branch(input, _opts), do: invoke(:branch, input)

  @impl true
  def create_pr(input, _opts), do: invoke(:create_pr, input)

  defp invoke(operation, input) do
    operation_id = value(input, :operation_id)

    send(self(), {:adapter_call, operation, operation_id, stream_event_types(operation_id)})

    case Process.get(:vcs_adapter_script, []) do
      [next | rest] ->
        Process.put(:vcs_adapter_script, rest)
        next

      [] ->
        {:error, :missing_script_step}
    end
  end

  defp stream_event_types(operation_id) do
    operation_id
    |> then(&EventStore.stream("vcs:#{&1}"))
    |> Enum.map(& &1.event_type)
  end

  defp value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end

defmodule ForemanServer.VcsAdapterTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, VcsAdapter}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-vcs-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "transient failures retry three times with exponential backoff and complete", %{tmp_dir: tmp_dir} do
    Process.put(:vcs_adapter_script, [
      {:error, {:transport, :timeout}},
      {:error, {:http_status, 429, %{message: "slow down"}}},
      {:error, {:http_status, 503, %{message: "unavailable"}}},
      {:ok, %{clone_url: "https://example.invalid/repo.git", path: Path.join(tmp_dir, "repo")}}
    ])

    test_pid = self()

    assert {:ok, %{event: event, projection: projection, result: result}} =
             VcsAdapter.clone(
               %{operation_id: "op-clone-retry", repo: "acme/widgets", path: Path.join(tmp_dir, "repo")},
               impl: ForemanServer.VcsAdapterTest.Stub,
               base_backoff_ms: 10,
               sleep_fn: fn ms -> send(test_pid, {:sleep, ms}) end
             )

    assert event.event_type == "VcsOperationCompleted"
    assert result.operation_id == "op-clone-retry"
    assert projection.vcs_operations["op-clone-retry"].status == "completed"
    assert projection.vcs_operations["op-clone-retry"].attempt == 4

    assert_receive {:adapter_call, :clone, "op-clone-retry", ["VcsOperationStarted"]}
    assert_receive {:sleep, 10}
    assert_receive {:adapter_call, :clone, "op-clone-retry", ["VcsOperationStarted"]}
    assert_receive {:sleep, 20}
    assert_receive {:adapter_call, :clone, "op-clone-retry", ["VcsOperationStarted"]}
    assert_receive {:sleep, 40}
    assert_receive {:adapter_call, :clone, "op-clone-retry", ["VcsOperationStarted"]}

    assert ["VcsOperationStarted", "VcsOperationCompleted"] ==
             (EventStore.stream("vcs:op-clone-retry") |> Enum.map(& &1.event_type))
  end

  test "non-transient failures are not retried and emit failed event" do
    Process.put(:vcs_adapter_script, [
      {:error, {:http_status, 404, %{message: "Not Found"}}}
    ])

    test_pid = self()

    assert {:error, {:http_status, 404, %{message: "Not Found"}}} =
             VcsAdapter.branch(
               %{operation_id: "op-branch-missing", repo: "acme/widgets", branch: "feature/missing"},
               impl: ForemanServer.VcsAdapterTest.Stub,
               base_backoff_ms: 10,
               sleep_fn: fn ms -> send(test_pid, {:sleep, ms}) end
             )

    assert_receive {:adapter_call, :branch, "op-branch-missing", ["VcsOperationStarted"]}
    refute_receive {:sleep, _}
    refute_receive {:adapter_call, :branch, "op-branch-missing", _}

    assert ["VcsOperationStarted", "VcsOperationFailed"] ==
             (EventStore.stream("vcs:op-branch-missing") |> Enum.map(& &1.event_type))

    failure = ProjectionStore.snapshot().vcs_operations["op-branch-missing"]
    assert failure.status == "failed"
    assert failure.retryable == false
    assert value(failure.error, :code) == 404
  end

  test "successful create_pr emits completed event" do
    Process.put(:vcs_adapter_script, [
      {:ok, %{pr_number: 17, pr_url: "https://github.example/acme/widgets/pull/17", state: "open"}}
    ])

    assert {:ok, %{event: event, result: result}} =
             VcsAdapter.create_pr(
               %{
                 operation_id: "op-pr-success",
                 repo: "acme/widgets",
                 branch: "feature/trd-018",
                 base_branch: "main",
                 title: "TRD-018"
               },
               impl: ForemanServer.VcsAdapterTest.Stub
             )

    assert event.event_type == "VcsOperationCompleted"
    assert result.pr_number == 17
    assert result.operation_id == "op-pr-success"

    completed = ProjectionStore.snapshot().vcs_operations["op-pr-success"]
    assert completed.status == "completed"
    assert value(completed.result, :pr_number) == 17
  end

  test "started event is recorded before adapter execution", %{tmp_dir: tmp_dir} do
    Process.put(:vcs_adapter_script, [
      {:ok, %{clone_url: "https://example.invalid/repo.git", path: Path.join(tmp_dir, "repo")}}
    ])

    assert {:ok, _response} =
             VcsAdapter.clone(
               %{operation_id: "op-start-before-call", repo: "acme/widgets", path: Path.join(tmp_dir, "repo")},
               impl: ForemanServer.VcsAdapterTest.Stub
             )

    assert_receive {:adapter_call, :clone, "op-start-before-call", ["VcsOperationStarted"]}
  end

  defp value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
