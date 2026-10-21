defmodule ForemanServer.ProjectSettingsReplayTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, ProjectSettings}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    {:ok, id: "settings-replay-#{System.unique_integer([:positive])}"}
  end

  defp dispatch(id, type, payload) do
    CommandGateway.dispatch_operator(%{
      command_id: "#{type}-#{System.unique_integer([:positive])}",
      aggregate_id: "project:#{id}",
      type: type,
      payload: Map.put(payload, :project_id, id)
    })
  end

  defp stream_version(id) do
    {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 1_000)
    {length(events), events}
  end

  test "settings are identical live and after rebuilding the projection from the event log", %{
    id: id
  } do
    assert {:ok, _} = dispatch(id, "project.register", %{path: "/tmp/#{id}"})

    assert {:ok, _} =
             dispatch(id, "project.update", %{
               goal: "ship it",
               instructions: "line1\r\nline2",
               thread_model: "opus",
               max_concurrent_runs: 2
             })

    live = ProjectionStore.project_settings(id)

    assert %ProjectSettings{
             goal: "ship it",
             instructions: "line1\nline2",
             thread_model: "opus",
             max_concurrent_runs: 2,
             daily_thread_cap: nil
           } = live

    {_, events} = stream_version(id)
    :ok = ProjectionStore.rebuild(events)
    assert ProjectionStore.project_settings(id) == live
  end

  test "a partial update keeps other settings; clearing removes only the named key", %{id: id} do
    {:ok, _} = dispatch(id, "project.register", %{path: "/tmp/#{id}"})
    {:ok, _} = dispatch(id, "project.update", %{goal: "g", instructions: "i"})
    {:ok, _} = dispatch(id, "project.update", %{goal: "g2"})
    assert %{goal: "g2", instructions: "i"} = ProjectionStore.project_settings(id)

    {:ok, _} = dispatch(id, "project.update", %{cleared_settings: ["instructions"]})
    {_, events} = stream_version(id)
    :ok = ProjectionStore.rebuild(events)
    assert %{goal: "g2", instructions: nil} = ProjectionStore.project_settings(id)
  end

  test "a rejected update appends nothing", %{id: id} do
    {:ok, _} = dispatch(id, "project.register", %{path: "/tmp/#{id}"})
    {before, _} = stream_version(id)

    assert {:error, _} =
             dispatch(id, "project.update", %{instructions: String.duplicate("x", 16_001)})

    assert {^before, _} = stream_version(id)
  end

  test "string-keyed (JSON-decoded) events fold identically to atom-keyed ones", %{id: id} do
    :ok =
      ProjectionStore.apply_events([
        %{
          "event_type" => "ProjectRegistered",
          "payload" => %{
            "project_id" => id,
            "path" => "/tmp/#{id}",
            "config" => %{"goal" => "old"}
          }
        },
        %{
          "event_type" => "ProjectUpdated",
          "payload" => %{
            "project_id" => id,
            "goal" => "new",
            "daily_thread_cap" => 5,
            "cleared_settings" => ["thread_model"]
          }
        }
      ])

    assert %ProjectSettings{goal: "new", daily_thread_cap: 5, thread_model: nil} =
             ProjectionStore.project_settings(id)
  end

  test "an unknown project has no settings" do
    assert ProjectionStore.project_settings("no-such-project") == nil
  end
end
