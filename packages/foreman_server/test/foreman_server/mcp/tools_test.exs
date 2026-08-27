defmodule ForemanServer.MCP.ToolsTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.ProjectionStore
  alias ForemanServer.EventStore, as: Store

  setup do
    # Capture current state to restore on exit
    original_state = :sys.get_state(ProjectionStore)

    on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _ -> original_state end)
    end)

    :ok
  end

  defp replace_state(overrides) do
    base = %{
      projects: %{},
      runs: %{},
      tasks: %{},
      phases: %{},
      pr_associations: %{},
      run_logs: %{},
      scheduler_intents: %{},
      subscribers: %{},
      project_active_runs: %{},
      worktrees: %{},
      worktree_create_orphans: %{},
      run_slots: %{capacity: 0, holders: %{}, waiters: []},
      works: %{}
    }

    :sys.replace_state(ProjectionStore, fn _ -> Map.merge(base, overrides) end)
  end

  describe "tools/list" do
    test "advertises required tools with valid JSON Schemas" do
      tools = Tools.list_tools()

      assert Enum.map(tools, & &1.name) == [
               "foreman_work_get",
               "foreman_run_get",
               "foreman_queue_status",
               "foreman_project_list",
               "foreman_project_get",
               "foreman_workflow_list",
               "foreman_workflow_get",
               "foreman_workflow_validate",
               "foreman_task_create",
               "foreman_run_cancel",
               "foreman_workflow_put",
               "foreman_workflow_delete",
               "foreman_prompt_put",
               "foreman_prompt_get",
               "foreman_doctor",
               "foreman_run_get_logs",
               "foreman_run_get_events",
               "foreman_run_get_activity"
             ]

      Enum.each(tools, fn tool ->
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert tool.inputSchema.type == "object"
        assert is_map(tool.inputSchema.properties)

        if Map.has_key?(tool.inputSchema, :required) do
          assert is_list(tool.inputSchema.required)
        end
      end)
    end
  end

  describe "foreman_work_get" do
    test "returns work when found" do
      work = %{work_id: "work-1", status: "submitted"}
      replace_state(%{works: %{"work-1" => work}})

      assert Tools.call_tool("foreman_work_get", %{work_id: "work-1"}) == {:ok, work}
    end

    test "returns NOT_FOUND when not found" do
      replace_state(%{works: %{}})

      assert Tools.call_tool("foreman_work_get", %{work_id: "nonexistent"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Work not found"}}
    end
  end

  describe "foreman_run_get" do
    test "returns run when found" do
      run = %{run_id: "run-1", status: "in_progress"}
      replace_state(%{runs: %{"run-1" => run}})

      assert Tools.call_tool("foreman_run_get", %{run_id: "run-1"}) == {:ok, run}
    end

    test "returns NOT_FOUND when not found" do
      replace_state(%{runs: %{}})

      assert Tools.call_tool("foreman_run_get", %{run_id: "nonexistent"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
    end
  end

  describe "foreman_queue_status" do
    test "returns queue status" do
      replace_state(%{})

      assert Tools.call_tool("foreman_queue_status", %{}) ==
               {:ok, ProjectionStore.queue_status()}
    end
  end

  describe "foreman_project_list" do
    test "returns projects list" do
      replace_state(%{})

      assert Tools.call_tool("foreman_project_list", %{}) ==
               {:ok, ProjectionStore.list_projects()}
    end
  end

  describe "foreman_project_get" do
    test "returns project when found" do
      project = %{project_id: "proj-1", name: "Test Project"}
      replace_state(%{projects: %{"proj-1" => project}})

      assert Tools.call_tool("foreman_project_get", %{project_id: "proj-1"}) == {:ok, project}
    end

    test "returns NOT_FOUND when not found" do
      replace_state(%{projects: %{}})

      assert Tools.call_tool("foreman_project_get", %{project_id: "nonexistent"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}
    end
  end

  describe "dispatch error taxonomy" do
    # A single catch-all used to report all three of these as
    # METHOD_NOT_FOUND "Unknown tool", which made argument-shape bugs
    # extremely expensive to diagnose. They are now distinct.
    #
    # Note there is no test for "advertised tool with no implementation":
    # `call_tool/2` is generated from `@tools`, so that case cannot compile.

    test "an unknown tool name is METHOD_NOT_FOUND" do
      assert Tools.call_tool("unknown_tool", %{}) ==
               {:error,
                %ToolError{code: "METHOD_NOT_FOUND", message: "Unknown tool: unknown_tool"}}
    end

    test "a known tool missing a required argument is INVALID_PARAMS, naming the key" do
      assert {:error, %ToolError{code: "INVALID_PARAMS", message: message}} =
               Tools.call_tool("foreman_run_get", %{})

      assert message =~ "foreman_run_get"
      assert message =~ "run_id"
    end

    test "string-keyed arguments raise rather than masquerading as an unknown tool" do
      assert_raise ArgumentError, ~r/string-keyed arguments/, fn ->
        Tools.call_tool("foreman_run_get", %{"run_id" => "r-1"})
      end
    end
  end

  describe "run-detail tools" do
    # `run_events/1` returned raw %EventStore.RecordedEvent{} structs, which
    # have no Jason.Encoder — the tool crashed with Protocol.UndefinedError the
    # first time a run actually had events. It looked fine because the only
    # test covered a run with an empty stream.
    #
    # `run_activity/1` and `run_logs/1` returned [], reporting "no data" for an
    # unimplemented feature — indistinguishable from a real empty result. They
    # are implemented now: activity reads the `worker:<run_id>:<worker_id>`
    # streams the run stream never carries, and logs fail loudly because no
    # producer writes run output anywhere.

    test "events for a run are serializable maps, not RecordedEvent structs" do
      assert {:ok, events} = Tools.call_tool("foreman_run_get_events", %{run_id: "no-such-run"})
      assert events == []

      # The real guard: whatever comes back must survive JSON encoding, which
      # is what the MCP transport does to every tool result.
      assert {:ok, _} = Jason.encode(events)
    end

    test "activity surfaces worker heartbeats the run stream never carries" do
      run_id = unique_run_id()
      worker_id = "wkr-#{System.unique_integer([:positive])}"

      seed_worker_stream(run_id, worker_id, [
        {"WorkerStarted",
         %{
           worker_id: worker_id,
           run_id: run_id,
           sequence: 0,
           session_id: "sess-1",
           adapter: "ForemanServer.Overwatch.Adapters.HeartbeatWorker",
           prompt_path: "/tmp/prompt.md"
         }},
        {"WorkerHeartbeat", %{worker_id: worker_id, run_id: run_id, sequence: 1}},
        {"WorkerHeartbeat", %{worker_id: worker_id, run_id: run_id, sequence: 2}}
      ])

      replace_state(%{runs: %{run_id => %{run_id: run_id, status: "in_progress"}}})

      # The reason this tool has to exist: the run stream carries no worker
      # events, so a live worker is invisible through foreman_run_get_events.
      assert {:ok, []} = Tools.call_tool("foreman_run_get_events", %{run_id: run_id})

      assert {:ok, [activity]} = Tools.call_tool("foreman_run_get_activity", %{run_id: run_id})

      assert activity.worker_id == worker_id
      assert activity.event_count == 3
      assert activity.heartbeat_count == 2
      assert activity.last_sequence == 2
      assert activity.last_event_type == "WorkerHeartbeat"
      assert is_binary(activity.last_heartbeat_at)
      assert activity.last_event_at == activity.last_heartbeat_at

      # The MCP transport JSON-encodes every tool result.
      assert {:ok, _} = Jason.encode([activity])
    end

    test "activity for a known run with no worker stream is an empty list" do
      run_id = unique_run_id()
      replace_state(%{runs: %{run_id => %{run_id: run_id, status: "awaiting_worker"}}})

      assert {:ok, []} = Tools.call_tool("foreman_run_get_activity", %{run_id: run_id})
    end

    test "activity for an unknown run is NOT_FOUND, not an empty list" do
      assert {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}} =
               Tools.call_tool("foreman_run_get_activity", %{run_id: "no-such-run"})
    end

    test "logs for a known run with no worker output are an empty success" do
      run_id = unique_run_id()
      replace_state(%{runs: %{run_id => %{run_id: run_id, status: "in_progress"}}})

      assert {:ok,
              %{
                run_id: ^run_id,
                entries: [],
                count: 0,
                limit: 500,
                truncated: false
              }} = Tools.call_tool("foreman_run_get_logs", %{run_id: run_id})
    end

    test "logs for an unknown run are NOT_FOUND" do
      assert {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}} =
               Tools.call_tool("foreman_run_get_logs", %{run_id: "no-such-run"})
    end

    test "run-detail tools missing run_id are INVALID_PARAMS, naming the key" do
      for tool <- ["foreman_run_get_logs", "foreman_run_get_activity"] do
        assert {:error, %ToolError{code: "INVALID_PARAMS", message: message}} =
                 Tools.call_tool(tool, %{})

        assert message =~ tool
        assert message =~ "run_id"
      end
    end
  end

  # Worker events are appended to `worker:<run_id>:<worker_id>`, never to
  # `run:<run_id>` — the whole reason foreman_run_get_events cannot show them.
  defp seed_worker_stream(run_id, worker_id, events) do
    stream_uuid = "worker:#{run_id}:#{worker_id}"

    :ok =
      Store.append_to_stream(
        stream_uuid,
        0,
        Enum.map(events, fn {event_type, payload} ->
          %EventData{event_type: event_type, data: payload, metadata: %{}}
        end)
      )

    on_exit(fn -> Store.delete_stream(stream_uuid, :any_version, :hard) end)

    stream_uuid
  end

  defp unique_run_id do
    "run-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
