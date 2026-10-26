defmodule ForemanServerWeb.ProjectSettingsLifecycleLiveTest do
  # The Lifecycle section of `/dashboard/projects/:id/settings`: archive and reactivate
  # (pause and resume are covered by project_settings_live_test.exs), each behind a
  # confirm step and dispatched as `project.archive` / `project.reactivate` through the
  # operator path. The page is driven through the real LiveView; what counts is the
  # projected project status, the events on the project stream and what the page renders.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, EventStore, ProjectStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-settings-lifecycle-live-token"
  @lifecycle ~s(section[aria-labelledby="lifecycle-h"])

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    previous_ws = Application.get_env(:foreman_server, :workspace)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    Application.put_env(:foreman_server, :workspace, coalesce_ms: 20)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      restore(:api_bearer_token, previous)
      restore(:workspace, previous_ws)
    end)

    id = "life-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ProjectStore.save(%{project_id: id, path: dir, name: "Lifecycle Demo", config: %{}})

    {:ok, id: id}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp mount_view(id) do
    {:ok, view, _html} = live(build_conn(), "/dashboard/projects/#{id}/settings?token=#{@token}")
    view
  end

  # The labels of the buttons in the Lifecycle section, in render order.
  defp lifecycle_buttons(view) do
    view
    |> element(@lifecycle)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp status_text(view) do
    view
    |> element("#{@lifecycle} strong")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  # `{kind, text}` of the notice region the page reports every action in; the page marks
  # an error with the `ws-error` class.
  defp notice(view) do
    node = view |> element("#notice") |> render() |> LazyHTML.from_fragment()
    classes = node |> LazyHTML.query("#notice") |> LazyHTML.attribute("class")
    {if("ws-error" in classes, do: :error, else: :ok), node |> LazyHTML.text() |> String.trim()}
  end

  defp click(view, label), do: view |> element("button", label) |> render_click()

  defp stream_events(id, type) do
    {:ok, events} = EventStore.read_stream_forward("project:" <> id, 0, 99_999)
    for %{event_type: ^type} = event <- events, do: event_data(event)
  end

  defp event_data(%{data: data}), do: data |> Jason.encode!() |> Jason.decode!()

  defp operator!(id, type) do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "#{type}-#{id}-#{System.unique_integer([:positive])}",
               type: type,
               aggregate_id: "project:#{id}",
               payload: %{project_id: id}
             })
  end

  defp reserve_run!(project_id, run_id) do
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "reserve:#{project_id}:#{run_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.reserve_run",
               payload: %{
                 project_id: project_id,
                 run_id: run_id,
                 command_id: "run-start:#{project_id}:#{run_id}",
                 sequence: 1,
                 run_start_payload: %{
                   project_id: project_id,
                   run_id: run_id,
                   task_id: "task-#{run_id}",
                   workflow_snapshot: %{}
                 }
               }
             })
  end

  defp release_run!(project_id, run_id) do
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "release:#{project_id}:#{run_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.release_run_reservation",
               payload: %{project_id: project_id, run_id: run_id, reason: "test"}
             })
  end

  test "archive needs a confirm step; confirming archives the project and swaps the buttons",
       %{id: id} do
    view = mount_view(id)

    assert status_text(view) == "active"
    assert lifecycle_buttons(view) == ["Pause", "Archive"]
    assert notice(view) == {:ok, ""}

    click(view, "Archive")

    # The first click only asks: nothing is dispatched yet.
    assert ProjectStore.get(id).status == "active"
    assert stream_events(id, "ProjectArchived") == []
    assert lifecycle_buttons(view) == ["Pause", "Confirm Archive", "Cancel"]

    click(view, "Confirm Archive")

    assert ProjectStore.get(id).status == "archived"
    assert status_text(view) == "archived"
    assert lifecycle_buttons(view) == ["Reactivate"]
    assert notice(view) == {:ok, "Done: project.archive."}

    # One event, carrying the reason the dashboard dispatches with.
    assert [%{"project_id" => ^id, "reason" => "operator_dashboard"}] =
             stream_events(id, "ProjectArchived")
  end

  test "cancelling the confirm step dispatches nothing and restores the buttons", %{id: id} do
    view = mount_view(id)

    click(view, "Archive")
    assert lifecycle_buttons(view) == ["Pause", "Confirm Archive", "Cancel"]

    click(view, "Cancel")

    assert lifecycle_buttons(view) == ["Pause", "Archive"]
    assert status_text(view) == "active"
    assert ProjectStore.get(id).status == "active"
    assert stream_events(id, "ProjectArchived") == []
  end

  test "an archived project offers Reactivate behind a confirm step and returns to active",
       %{id: id} do
    operator!(id, "project.archive")
    view = mount_view(id)

    assert status_text(view) == "archived"
    assert lifecycle_buttons(view) == ["Reactivate"]

    click(view, "Reactivate")

    assert ProjectStore.get(id).status == "archived"
    assert stream_events(id, "ProjectReactivated") == []
    assert lifecycle_buttons(view) == ["Confirm Reactivate", "Cancel"]

    click(view, "Confirm Reactivate")

    assert ProjectStore.get(id).status == "active"
    assert status_text(view) == "active"
    assert lifecycle_buttons(view) == ["Pause", "Archive"]
    assert notice(view) == {:ok, "Done: project.reactivate."}

    assert [%{"project_id" => ^id, "reason" => "operator_dashboard"}] =
             stream_events(id, "ProjectReactivated")
  end

  test "archive is refused while a workflow run holds a reservation, and works once it ends",
       %{id: id} do
    reserve_run!(id, "run-held-#{id}")
    view = mount_view(id)

    click(view, "Archive")
    click(view, "Confirm Archive")

    # The aggregate refused: the project is unchanged, the confirm step is closed and the
    # notice is an error naming the reason.
    assert ProjectStore.get(id).status == "active"
    assert stream_events(id, "ProjectArchived") == []
    assert status_text(view) == "active"
    assert lifecycle_buttons(view) == ["Pause", "Archive"]

    assert notice(view) ==
             {:error,
              "project.archive failed: the project has active runs; try again when they have finished"}

    release_run!(id, "run-held-#{id}")

    click(view, "Archive")
    click(view, "Confirm Archive")

    assert ProjectStore.get(id).status == "archived"
    assert lifecycle_buttons(view) == ["Reactivate"]
    assert notice(view) == {:ok, "Done: project.archive."}
  end
end
