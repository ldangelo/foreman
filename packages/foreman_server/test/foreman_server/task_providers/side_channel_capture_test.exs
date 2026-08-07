defmodule ForemanServer.TaskProviders.SideChannelCaptureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Mox

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProvider.Telemetry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError

  @cache_name :foreman_server_json_schema_cache
  @rejected_event [:foreman_server, :task_provider, :transition_comment, :rejected]
  @database_path "/abs/SECRET_DB_PATH_TOKEN_SIDE_CHANNEL.sqlite3"
  @transition_comment String.duplicate("SECRET_TOKEN_", 8)

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    start_supervised!(Registry)

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      stop_schema_cache()
    end)

    :ok
  end

  test "list_ready/2 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-list-ready")

    stderr =
      Jason.encode!(%{
        "code" => "BR_DATABASE_LOCKED",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    raw_argv = ready_argv(@database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:ready, %{database_path: @database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 73}}
    end)

    captured = capture_side_channels(fn -> BeadsAdapter.list_ready(project_config, []) end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "BR_DATABASE_LOCKED"
    assert provider_error.context.command == "br ready"
    assert provider_error.context.exit_code == 73
    refute inspect(provider_error.context) =~ @database_path

    assert_raw_runner_argv_kept(raw_argv, [@database_path])
    assert_side_channels_scrubbed(captured, [@database_path])
  end

  test "get/2 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-get")
    raw_argv = show_argv(@database_path, "bead-get-1")

    stderr =
      Jason.encode!(%{
        "code" => "ISSUE_NOT_FOUND",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:show, %{id: "bead-get-1", database_path: @database_path}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 4}}
    end)

    captured = capture_side_channels(fn -> BeadsAdapter.get("bead-get-1", project_config) end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "ISSUE_NOT_FOUND"
    assert provider_error.context.command == scrubbed_command(raw_argv)
    assert provider_error.context.exit_code == 4
    refute provider_error.context.command =~ @database_path
    assert provider_error.context.command =~ redacted_database_path(@database_path)

    assert_raw_runner_argv_kept(raw_argv, [@database_path])
    assert_side_channels_scrubbed(captured, [@database_path])
  end

  test "claim/3 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-claim")
    raw_argv = claim_argv(@database_path, "bead-claim-1")

    stderr =
      Jason.encode!(%{
        "code" => "NOT_CLAIMABLE",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", "bead-claim-1"]}}
      assert runner_project_config == project_config
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 2}}
    end)

    captured =
      capture_side_channels(fn ->
        BeadsAdapter.claim("bead-claim-1", "operator", project_config)
      end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "NOT_CLAIMABLE"
    assert provider_error.context.command == "br update"
    assert provider_error.context.exit_code == 2
    refute inspect(provider_error.context) =~ @database_path

    assert_raw_runner_argv_kept(raw_argv, [@database_path])
    assert_side_channels_scrubbed(captured, [@database_path])
  end

  test "complete/3 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-complete")
    raw_argv = close_argv(@database_path, "bead-complete-1")

    stderr =
      Jason.encode!(%{
        "code" => "ISSUE_NOT_FOUND",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: "bead-complete-1"}}
      assert runner_project_config == %{database_path: @database_path}
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 3}}
    end)

    captured =
      capture_side_channels(fn ->
        BeadsAdapter.complete(
          "bead-complete-1",
          %{completion_token: "SECRET_TOKEN"},
          project_config
        )
      end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "ISSUE_NOT_FOUND"
    assert provider_error.context.command == "br close"
    assert provider_error.context.exit_code == 3
    refute inspect(provider_error.context) =~ @database_path

    assert_raw_runner_argv_kept(raw_argv, [@database_path])
    assert_side_channels_scrubbed(captured, [@database_path])
  end

  test "fail/3 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-fail")
    raw_argv = reopen_argv(@database_path, "bead-fail-1", @transition_comment)

    stderr =
      Jason.encode!(%{
        "code" => "UNKNOWN_BR_CODE",
        "message" => "raw envelope message",
        "hint" => "raw envelope hint",
        "retryable?" => true
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-fail-1",
                    "--status",
                    "open",
                    "--transition-comment",
                    @transition_comment
                  ],
                  database_path: @database_path
                }}

      assert runner_project_config == %{database_path: @database_path}
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 7}}
    end)

    captured =
      capture_side_channels(fn ->
        BeadsAdapter.fail(
          "bead-fail-1",
          %{transition_comment: @transition_comment, run_id: "run-fail-1"},
          project_config
        )
      end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "BR_ERROR_ENVELOPE"
    assert provider_error.context.command == scrubbed_command(raw_argv)
    assert provider_error.context.exit_code == 7
    refute provider_error.context.command =~ @database_path
    refute provider_error.context.command =~ @transition_comment
    assert provider_error.context.command =~ redacted_database_path(@database_path)
    assert provider_error.context.command =~ redacted_transition_comment(@transition_comment)

    rejected_event =
      Enum.find(captured.telemetry, fn %{event: event} -> event == @rejected_event end)

    assert rejected_event
    assert rejected_event.metadata.raw_code == "UNKNOWN_BR_CODE"
    assert rejected_event.metadata.task_id == "bead-fail-1"
    assert rejected_event.metadata.argv == Telemetry.scrub_argv(raw_argv)

    assert_raw_runner_argv_kept(raw_argv, [@database_path, @transition_comment])
    assert_side_channels_scrubbed(captured, [@database_path, @transition_comment])
    assert captured.log =~ "BR_ERROR_ENVELOPE"
    assert captured.log =~ "UNKNOWN_BR_CODE"
    assert captured.log =~ redacted_database_path(@database_path)
    assert captured.log =~ redacted_transition_comment(@transition_comment)
  end

  test "reopen/3 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-reopen")
    raw_argv = reopen_argv(@database_path, "bead-reopen-1", @transition_comment)

    stderr =
      Jason.encode!(%{
        "code" => "ISSUE_NOT_FOUND",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    "bead-reopen-1",
                    "--status",
                    "open",
                    "--transition-comment",
                    @transition_comment
                  ],
                  database_path: @database_path
                }}

      assert runner_project_config == %{database_path: @database_path}
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 3}}
    end)

    captured =
      capture_side_channels(fn ->
        BeadsAdapter.reopen("bead-reopen-1", @transition_comment, project_config)
      end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "ISSUE_NOT_FOUND"
    assert provider_error.context.command == scrubbed_command(raw_argv)
    assert provider_error.context.exit_code == 3
    refute provider_error.context.command =~ @database_path
    refute provider_error.context.command =~ @transition_comment
    assert provider_error.context.command =~ redacted_database_path(@database_path)
    assert provider_error.context.command =~ redacted_transition_comment(@transition_comment)

    assert_raw_runner_argv_kept(raw_argv, [@database_path, @transition_comment])
    assert_side_channels_scrubbed(captured, [@database_path, @transition_comment])
  end

  test "set_priority/3 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-set-priority")
    raw_argv = set_priority_argv(@database_path, "bead-priority-1", 4)

    stderr =
      Jason.encode!(%{
        "code" => "BR_DATABASE_LOCKED",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:set_priority,
                %{id: "bead-priority-1", priority: 4, database_path: @database_path}}

      assert runner_project_config == %{}
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 73}}
    end)

    captured =
      capture_side_channels(fn ->
        BeadsAdapter.set_priority("bead-priority-1", 4, project_config)
      end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "BR_DATABASE_LOCKED"
    assert provider_error.context.command == "br update"
    assert provider_error.context.exit_code == 73
    refute inspect(provider_error.context) =~ @database_path

    assert_raw_runner_argv_kept(raw_argv, [@database_path])
    assert_side_channels_scrubbed(captured, [@database_path])
  end

  test "add_dependency/3 keeps raw argv in the runner while side channels stay scrubbed" do
    parent = self()
    project_config = register_project!("side-channel-add-dependency")
    raw_argv = add_dependency_argv(@database_path, "bead-dep-1", "opaque:dep-secret")

    stderr =
      Jason.encode!(%{
        "code" => "DEPENDENCY_EXISTS",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:add_dependency,
                %{dependent_id: "bead-dep-1", dependency_id: "opaque:dep-secret"}}

      assert runner_project_config == %{database_path: @database_path}
      assert opts == [timeout_ms: 30_000]
      send(parent, {:runner_argv, raw_argv})
      {:error, %{stdout: "", stderr: stderr, exit_code: 5}}
    end)

    captured =
      capture_side_channels(fn ->
        BeadsAdapter.add_dependency("bead-dep-1", "opaque:dep-secret", project_config)
      end)

    assert_receive {:runner_argv, ^raw_argv}
    assert {:error, %ProviderError{} = provider_error} = captured.result
    assert provider_error.code == "DEPENDENCY_EXISTS"
    assert provider_error.context.command == "br dep add"
    assert provider_error.context.exit_code == 5
    refute inspect(provider_error.context) =~ @database_path

    assert_raw_runner_argv_kept(raw_argv, [@database_path])
    assert_side_channels_scrubbed(captured, [@database_path])
  end

  defp register_project!(suffix) do
    project_id = "#{suffix}-#{System.unique_integer([:positive, :monotonic])}"

    assert :ok =
             Registry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => @database_path
             })

    assert {:active, %{provider_module: BeadsAdapter, config: project_config}} =
             :sys.get_state(Registry).per_project[project_id]

    project_config
  end

  defp capture_side_channels(fun) do
    parent = self()
    ref = :telemetry_test.attach_event_handlers(parent, Map.keys(Telemetry.taxonomy()))

    try do
      log =
        capture_log(fn ->
          stdout =
            capture_io(fn ->
              stderr =
                capture_io(:stderr, fn ->
                  result = fun.()
                  send(parent, {:captured_result, result})
                end)

              send(parent, {:captured_stderr, stderr})
            end)

          send(parent, {:captured_stdout, stdout})
        end)

      %{
        result: receive_tagged_message!(:captured_result),
        stdout: receive_tagged_message!(:captured_stdout),
        stderr: receive_tagged_message!(:captured_stderr),
        log: log,
        telemetry: drain_telemetry(ref, [])
      }
    after
      :telemetry.detach(ref)
    end
  end

  defp receive_tagged_message!(tag) do
    receive do
      {^tag, value} -> value
    after
      1_000 -> flunk("did not receive #{inspect(tag)}")
    end
  end

  defp drain_telemetry(ref, acc) do
    receive do
      {event, ^ref, measurements, metadata} ->
        drain_telemetry(ref, [
          %{event: event, measurements: measurements, metadata: metadata} | acc
        ])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_side_channels_scrubbed(captured, sentinels) do
    Enum.each(sentinels, fn sentinel ->
      refute captured.log =~ sentinel
      refute captured.stdout =~ sentinel
      refute captured.stderr =~ sentinel

      Enum.each(captured.telemetry, fn %{metadata: metadata} ->
        refute inspect(metadata) =~ sentinel
      end)
    end)
  end

  defp assert_raw_runner_argv_kept(raw_argv, sentinels) do
    Enum.each(sentinels, fn sentinel ->
      assert Enum.any?(raw_argv, &(&1 == sentinel or String.contains?(&1, sentinel)))
    end)
  end

  defp ready_argv(database_path), do: ["ready", "--db", database_path, "--json"]
  defp show_argv(database_path, task_id), do: ["show", "--db", database_path, task_id, "--json"]

  defp claim_argv(database_path, task_id),
    do: ["update", "--db", database_path, "--claim", task_id, "--json"]

  defp close_argv(database_path, task_id), do: ["close", "--db", database_path, task_id, "--json"]

  defp reopen_argv(database_path, task_id, transition_comment) do
    [
      "update",
      "--db",
      database_path,
      task_id,
      "--status",
      "open",
      "--transition-comment",
      transition_comment,
      "--json"
    ]
  end

  defp set_priority_argv(database_path, task_id, priority) do
    [
      "update",
      "--db",
      database_path,
      task_id,
      "--priority",
      Integer.to_string(priority),
      "--json"
    ]
  end

  defp add_dependency_argv(database_path, dependent_id, dependency_id) do
    ["dep", "add", dependent_id, dependency_id, "--json", "--db", database_path]
  end

  defp scrubbed_command(argv) do
    argv
    |> Telemetry.scrub_argv()
    |> then(&["br" | &1])
    |> Enum.join(" ")
  end

  defp redacted_database_path(database_path) do
    [_, _, redacted, _] = Telemetry.scrub_argv(ready_argv(database_path))
    redacted
  end

  defp redacted_transition_comment(transition_comment) do
    [_, value] = Telemetry.scrub_argv(["--transition-comment", transition_comment])
    value
  end

  defp stop_schema_cache do
    if pid = Process.whereis(@cache_name) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end
end
