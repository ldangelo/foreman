defmodule ForemanServer.ProjectionStoreBroadcastShapeTest do
  # The contract `ForemanServerWeb.Workspace.Refresh` reads (CodeRabbit PR #591 [9], bead
  # foreman-27ayh): every event the store broadcasts carries an ATOM-keyed `data`, whichever
  # path it took. A project event is re-read from the log as a `%RecordedEvent{}`, any other
  # command's event is the appended `%EventData{}` and a rebuild re-sends recorded events.
  # The event store serializer writes terms, so a key keeps its type; if `data` ever arrived
  # string-keyed, every subscriber that scopes events by project would silently over-refresh,
  # which is why `Refresh` reads one key and this test pins what it relies on.
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok = ProjectionStore.subscribe(replay_existing: false)
    {:ok, id: "broadcast-shape-#{System.unique_integer([:positive])}"}
  end

  defp dispatch(id, type, aggregate_id, payload) do
    CommandGateway.dispatch_system(%{
      command_id: "#{type}-#{System.unique_integer([:positive])}",
      aggregate_id: aggregate_id,
      type: type,
      payload: Map.put(payload, :project_id, id)
    })
  end

  test "a project event arrives as a RecordedEvent with atom-keyed data, even for string-keyed input",
       %{id: id} do
    # what an HTTP/JSON client sends: string keys at the top level and inside `config`
    assert {:ok, _} =
             dispatch(id, "project.register", "project:#{id}", %{
               "path" => "/tmp/#{id}",
               "goal" => "g",
               "config" => %{"name" => "Demo"}
             })

    assert_receive {:projection_event,
                    %EventStore.RecordedEvent{
                      event_type: "ProjectRegistered",
                      data: %{project_id: ^id, goal: "g"}
                    }},
                   5_000
  end

  test "another command's event arrives as EventData with atom-keyed data", %{id: id} do
    task_id = "t-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             dispatch(id, "task.create", "task:#{task_id}", %{
               task_id: task_id,
               title: "A task",
               status: "open",
               source: "coordinator",
               provider_tracked: false
             })

    assert_receive {:projection_event,
                    %EventStore.EventData{
                      event_type: "TaskCreated",
                      data: %{project_id: ^id, task_id: ^task_id}
                    }},
                   5_000
  end

  test "a rebuild re-sends the recorded events with atom-keyed data", %{id: id} do
    assert {:ok, _} = dispatch(id, "project.register", "project:#{id}", %{path: "/tmp/#{id}"})

    assert_receive {:projection_event,
                    %EventStore.RecordedEvent{event_type: "ProjectRegistered"}},
                   5_000

    {:ok, events} = ForemanServer.EventStore.read_stream_forward("project:#{id}", 0, 1_000)
    :ok = ProjectionStore.rebuild(events)

    assert_receive {:projection_event,
                    %EventStore.RecordedEvent{
                      event_type: "ProjectRegistered",
                      data: %{project_id: ^id}
                    }},
                   5_000
  end
end
