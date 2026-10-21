defmodule ForemanServer.Aggregates.ProjectCoordinatorSettingsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, ProjectSettings}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    id = "coord-#{System.unique_integer([:positive])}"
    {:ok, _} = dispatch(id, "project.register", %{path: "/tmp/#{id}"})
    {:ok, id: id}
  end

  defp dispatch(id, type, payload) do
    CommandGateway.dispatch_operator(%{
      command_id: "#{type}-#{System.unique_integer([:positive])}",
      aggregate_id: "project:#{id}",
      type: type,
      payload: Map.put(payload, :project_id, id)
    })
  end

  defp replay(id) do
    {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 1_000)
    :ok = ProjectionStore.rebuild(events)
  end

  test "coordinator and thread settings are stored independently and survive replay", %{id: id} do
    {:ok, _} =
      dispatch(id, "project.update", %{
        coordinator_model: "m1",
        coordinator_effort: "high",
        coordinator_provider: "pi",
        thread_model: "m2",
        thread_effort: "low"
      })

    expected = %{
      coordinator_model: "m1",
      coordinator_effort: "high",
      coordinator_provider: "pi",
      thread_model: "m2",
      thread_effort: "low"
    }

    assert %ProjectSettings{} = live = ProjectionStore.project_settings(id)
    assert Map.take(live, Map.keys(expected)) == expected

    {:ok, _} = dispatch(id, "project.update", %{coordinator_model: "m3"})
    assert %{coordinator_model: "m3", thread_model: "m2"} = ProjectionStore.project_settings(id)

    replay(id)

    assert %{
             coordinator_model: "m3",
             thread_model: "m2",
             coordinator_effort: "high",
             thread_effort: "low"
           } =
             ProjectionStore.project_settings(id)
  end

  test "clearing coordinator_model leaves thread_model", %{id: id} do
    {:ok, _} = dispatch(id, "project.update", %{coordinator_model: "m1", thread_model: "m2"})
    {:ok, _} = dispatch(id, "project.update", %{cleared_settings: ["coordinator_model"]})
    replay(id)

    assert %{coordinator_model: nil, thread_model: "m2"} = ProjectionStore.project_settings(id)
  end

  test "an effort outside the allowed list is rejected naming the list", %{id: id} do
    assert {:error, {:coordinator_effort_invalid, "turbo", ["low", "medium", "high"]}} =
             dispatch(id, "project.update", %{coordinator_effort: "turbo"})
  end

  test "coordinator_provider is a closed set", %{id: id} do
    assert {:error, {:invalid_setting, :coordinator_provider, {:unknown_provider, "kimi"}}} =
             dispatch(id, "project.update", %{coordinator_provider: "kimi"})

    assert {:ok, _} = dispatch(id, "project.update", %{coordinator_provider: "claude"})
    assert %{coordinator_provider: "claude"} = ProjectionStore.project_settings(id)
  end
end
