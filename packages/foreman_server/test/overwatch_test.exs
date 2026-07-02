defmodule ForemanServer.OverwatchTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Overwatch, ProjectionStore}

  setup do
    Application.stop(:foreman_server)
    path = Path.join(System.tmp_dir!(), "foreman-overwatch-#{System.unique_integer([:positive])}.term.log")
    Application.put_env(:foreman_server, :event_log_path, path)
    {:ok, _} = Application.ensure_all_started(:foreman_server)

    EventStore.append(%{
      stream_id: "task:task-1",
      event_type: "TaskCreated",
      payload: %{task_id: "task-1", project_id: "proj", title: "Task", status: "ready"},
      metadata: %{correlation_id: "test"}
    })

    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "RunStarted",
      payload: %{run_id: "run-1", task_id: "task-1", status: "in_progress"},
      metadata: %{correlation_id: "test"}
    })

    on_exit(fn ->
      Application.stop(:foreman_server)
      File.rm(path)
    end)

    :ok
  end

  test "denies read tool calls against directories and sends steering mail" do
    assert {:ok, decision} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               task_id: "task-1",
               phase_id: "explorer",
               tool_name: "Read",
               tool_call_id: "tool-1",
               args: %{path: System.tmp_dir!()}
             })

    refute decision.allowed
    assert decision.action == "deny"
    assert decision.reason =~ "directory"

    events = EventStore.stream("run:run-1")
    assert Enum.any?(events, &(&1.event_type == "ToolCallRequested"))
    assert Enum.any?(events, &(&1.event_type == "ToolCallDenied"))

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()
    assert Enum.any?(inbox, &(&1.from == "overwatch" and &1.to == "explorer"))
  end

  test "approves ordinary file reads" do
    file = Path.join(System.tmp_dir!(), "foreman-overwatch-file-#{System.unique_integer([:positive])}.txt")
    File.write!(file, "ok")
    on_exit(fn -> File.rm(file) end)

    assert {:ok, %{allowed: true, action: "approve"}} =
             Overwatch.check_tool(%{
               run_id: "run-1",
               phase_id: "fix",
               tool_name: "Read",
               args: %{path: file}
             })
  end

  test "sends native stale phase nudges from heartbeat events" do
    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "PhaseStarted",
      payload: %{run_id: "run-1", task_id: "task-1", phase_id: "explorer"},
      metadata: %{correlation_id: "test"}
    })

    for seq <- 1..3 do
      EventStore.append(%{
        stream_id: "worker:run-1:worker-1",
        event_type: "WorkerHeartbeat",
        payload: %{run_id: "run-1", task_id: "task-1", phase_id: "explorer", worker_id: "worker-1", sequence: seq},
        metadata: %{correlation_id: "test"}
      })
    end

    Process.sleep(50)

    events = EventStore.stream("run:run-1")
    assert Enum.any?(events, &(&1.event_type == "PhaseNudged" and &1.payload.source == "elixir_overwatch"))

    inbox = ProjectionStore.snapshot().inbox_messages |> Map.values()
    assert Enum.any?(inbox, &(&1.from == "overwatch" and &1.subject == "overwatch nudge: stale phase"))
  end
end
