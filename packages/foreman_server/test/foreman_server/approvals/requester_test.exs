defmodule ForemanServer.Approvals.RequesterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.Requester
  alias ForemanServer.EventStore
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.{Eventually, SecretStoreDir}

  @db_url "postgres://svc:hunter2pw@db.internal:5432/app"

  defp run_id, do: "run-req-#{System.unique_integer([:positive])}"

  defp events(run_id, id) do
    {:ok, events} = EventStore.read_stream_forward(ToolCall.stream_id(run_id, id), 0, 100)
    events
  end

  defp summary_of([%{data: data}]), do: data["input_summary"] || data[:input_summary]

  test "asking twice for the same tool call appends exactly one ToolCallRequested" do
    run_id = run_id()
    ctx = %{run_id: run_id, project_id: "p", provider: :claude}

    assert {:ok, "perm-1-Write"} =
             Requester.request(ctx, "Write", %{"path" => "a"}, phase_index: 1)

    assert {:ok, "perm-1-Write"} =
             Requester.request(ctx, "Write", %{"path" => "a"}, phase_index: 1)

    assert [%{event_type: "ToolCallRequested"}] = events(run_id, "perm-1-Write")
  end

  test "the request records the provider's delivery mode" do
    run_id = run_id()

    {:ok, id} = Requester.request(%{run_id: run_id, provider: :opencode}, "Bash", "ls", [])
    [%{data: live}] = events(run_id, id)
    assert (live["delivery"] || live[:delivery]) == "live"

    run_id = run_id()
    {:ok, id} = Requester.request(%{run_id: run_id, provider: :pi}, "Bash", "ls", [])
    [%{data: resume}] = events(run_id, id)
    assert (resume["delivery"] || resume[:delivery]) == "resume_with_override"
  end

  test "a secret in the tool input is never stored and the summary is bounded" do
    run_id = run_id()

    input = %{
      "command" => "curl",
      "api_key" => "sk-super-secret-value",
      "pad" => String.duplicate("x", 5_000)
    }

    {:ok, id} = Requester.request(%{run_id: run_id}, "Bash", input, [])

    [%{data: data}] = events(run_id, id)
    summary = data["input_summary"] || data[:input_summary]
    refute summary =~ "sk-super-secret-value"
    assert String.length(summary) <= 500
  end

  test "a gateway refusal is returned, not swallowed" do
    assert {:error, {:missing_or_invalid, :tool_name}} =
             Requester.request(%{run_id: run_id()}, "", "x", tool_call_id: "t")
  end

  # The tool input is the agent's, and a tool call can carry a secret of the project: a
  # connection string on a command line. The aggregate redacts by name pattern only, so the
  # project's stored values are redacted here, before the summary is bounded. `DB_URL` looks
  # like no secret by name.
  describe "a stored project secret in the tool input" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      SecretStoreDir.use_tmp_dir!(tmp)
      project_id = "p-req-#{System.unique_integer([:positive])}"
      SecretStoreDir.put!(project_id, "DB_URL", @db_url)
      {:ok, project_id: project_id}
    end

    test "never reaches ToolCallRequested or the read model, whatever its name",
         %{project_id: project_id} do
      run_id = run_id()
      ctx = %{run_id: run_id, project_id: project_id}

      {:ok, id} =
        Requester.request(ctx, "Bash", %{"command" => "psql #{@db_url} -c 'select 1'"}, [])

      events = events(run_id, id)
      refute inspect(events) =~ @db_url
      assert summary_of(events) =~ "[REDACTED]"
      assert summary_of(events) =~ "select 1"

      assert %{input_summary: projected} =
               Eventually.await(fn ->
                 Enum.find(
                   ProjectionStore.run_approvals(run_id, status: :all),
                   &(&1.tool_call_id == id)
                 )
               end)

      refute projected =~ @db_url
    end

    test "is redacted before the summary is bounded: a long secret cut at either limit leaves no part of itself",
         %{project_id: project_id} do
      secret = String.duplicate("s3cr3t-", 600)
      SecretStoreDir.put!(project_id, "BLOB", secret)
      run_id = run_id()

      {:ok, id} =
        Requester.request(
          %{run_id: run_id, project_id: project_id},
          "Write",
          secret <> " tail",
          []
        )

      assert summary_of(events(run_id, id)) == "[REDACTED] tail"
    end

    test "is not rewritten when the stored value is shorter than the floor",
         %{project_id: project_id} do
      SecretStoreDir.put!(project_id, "SEVEN_CHR", "abcdefg")
      run_id = run_id()

      {:ok, id} =
        Requester.request(%{run_id: run_id, project_id: project_id}, "Bash", "ls abcdefg", [])

      assert summary_of(events(run_id, id)) == "ls abcdefg"
    end

    test "of a project whose environment is refused is recorded with the patterns alone, never raising" do
      project_id = "p-req-refused-#{System.unique_integer([:positive])}"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ProjectRegistered",
            payload: %{
              project_id: project_id,
              path: "/tmp/#{project_id}",
              config: %{env: %{"FOREMAN_RUN_ID" => "sneaky"}}
            }
          }
        ])

      run_id = run_id()
      input = %{"command" => "curl", "api_key" => "sk-super-secret-value"}

      {result, log} =
        with_log(fn ->
          Requester.request(%{run_id: run_id, project_id: project_id}, "Bash", input, [])
        end)

      assert {:ok, id} = result
      assert log =~ "reserved_project_env_keys"
      refute summary_of(events(run_id, id)) =~ "sk-super-secret-value"
    end
  end
end
