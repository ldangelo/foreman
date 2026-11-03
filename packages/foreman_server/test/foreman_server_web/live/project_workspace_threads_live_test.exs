defmodule ForemanServerWeb.ProjectWorkspaceThreadsLiveTest do
  # The thread sidebar and the open thread's pane (`/dashboard/projects/:id/threads/:thread_id`),
  # through the real router, LiveView and projections.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{ProjectionStore, ProjectStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServerWeb.Workspace.Components

  @endpoint ForemanServerWeb.Endpoint
  @token "project-workspace-threads-token"

  setup do
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

    id = "thr-#{System.unique_integer([:positive])}"
    other = "thr-other-#{System.unique_integer([:positive])}"

    for p <- [id, other] do
      assert {:ok, _} = ProjectStore.save(%{project_id: p, path: "/tmp/#{p}", name: "Demo #{p}"})
    end

    :ok =
      ProjectionStore.apply_events([
        task("t-work", id, "In flight"),
        run("r-work", "t-work", id)
      ])

    {:ok, id: id, other: other}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp task(task_id, project_id, title),
    do: %{
      event_type: "TaskCreated",
      payload: %{
        task_id: task_id,
        project_id: project_id,
        title: title,
        status: "open",
        task_type: "implement"
      }
    }

  defp run(run_id, task_id, project_id),
    do: %{
      event_type: "RunStarted",
      payload: %{run_id: run_id, task_id: task_id, project_id: project_id}
    }

  # The page of a thread, the way a browser asks for it: the token rides the query.
  defp thread_url(id, thread_id),
    do: Components.thread_path(id, thread_id) <> "?token=#{@token}"

  defp row(thread_id), do: "#thread-#{String.replace(thread_id, ":", "\\:")}"

  test "a thread's URL shows its pane, its sidebar row selected and the chat unselected", %{id: id} do
    {:ok, view, html} = live(build_conn(), thread_url(id, "run:r-work"))

    assert html =~ "In flight"
    assert has_element?(view, "section#thread-pane[aria-label='Thread: In flight']")
    assert has_element?(view, "#thread-pane h2", "In flight")
    assert has_element?(view, "#thread-log[role=log]")
    assert has_element?(view, "#{row("run:r-work")}[aria-current=page]")
    refute has_element?(view, "#thread-list-chat[aria-current]")
    refute has_element?(view, "#conversation-pane")
  end
end
