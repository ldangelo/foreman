defmodule ForemanServerWeb.ProjectWorkspaceApprovalsLiveTest do
  # The workspace's Approve / Deny controls for a pending tool-call request, end to end:
  # a claude permission prompt blocks in `PermissionPrompt.decide/3`, the thread card
  # shows the request, and the click is the operator's `tool.approve` / `tool.deny`
  # which wakes the blocked call through the real Deliverer.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.Approvals.{Deliverer, Inflight, PermissionPrompt}
  alias ForemanServer.{ProjectionStore, ProjectStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-workspace-approvals-token"

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

    :ok = ProjectionStore.subscribe(replay_existing: false)
    start_supervised!(Inflight)
    start_supervised!(Deliverer)

    id = "apr-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", name: "Demo #{id}"})
    run = Support.start_run!(project_id: id)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: run.task_id,
            project_id: id,
            title: "Write a file",
            status: "open",
            task_type: "implement"
          }
        }
      ])

    {:ok, id: id, run: run}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp blocked_prompt(run, use_id) do
    args = %{
      "tool_name" => "Write",
      "input" => %{"file_path" => "/w/a.txt"},
      "tool_use_id" => use_id
    }

    run_id = run.run_id
    task = Task.async(fn -> PermissionPrompt.decide(run_id, args, timeout_ms: 30_000) end)
    assert_call_event("ToolCallRequested", run_id, "inflight-" <> use_id)
    task
  end

  # The projection is shared and broadcasts every test's events: wait for THIS run's call.
  defp assert_call_event(event_type, run_id, tool_call_id) do
    assert_receive {:projection_event,
                    %{
                      event_type: ^event_type,
                      data: %{run_id: ^run_id, tool_call_id: ^tool_call_id}
                    }},
                   15_000
  end

  defp mount_view(id) do
    {:ok, view, _html} = live(build_conn(), "/dashboard/projects/#{id}?token=#{@token}")
    view
  end

  defp control(run, use_id), do: "#approval-run\\:#{run.run_id}-inflight-#{use_id}"

  defp await_element(view, selector, tries \\ 100) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("#{selector} never rendered")
      true -> Process.sleep(20) && await_element(view, selector, tries - 1)
    end
  end

  test "Approve on the card lets the blocked call proceed in its session", %{id: id, run: run} do
    task = blocked_prompt(run, "toolu_ui1")
    view = mount_view(id)
    await_element(view, control(run, "toolu_ui1"))

    html = view |> element(control(run, "toolu_ui1")) |> render()
    assert html =~ "Write"
    assert html =~ "the agent is waiting on this call"

    view |> element(control(run, "toolu_ui1") <> " button", "Approve") |> render_click()

    assert %{"behavior" => "allow"} = Task.await(task)
    assert_call_event("ToolCallFinished", run.run_id, "inflight-toolu_ui1")
    assert %{status: "finished"} = ProjectionStore.tool_call(run.run_id, "inflight-toolu_ui1")
  end

  test "Deny on the card refuses the blocked call", %{id: id, run: run} do
    task = blocked_prompt(run, "toolu_ui2")
    view = mount_view(id)
    await_element(view, control(run, "toolu_ui2"))

    view |> element(control(run, "toolu_ui2") <> " button", "Deny") |> render_click()

    assert %{"behavior" => "deny", "message" => message} = Task.await(task)
    assert message =~ "operator denied"

    assert %{status: "denied", decided_by: "dashboard"} =
             ProjectionStore.tool_call(run.run_id, "inflight-toolu_ui2")
  end

  test "a request that is not pending, or not this thread's, is refused and nothing is dispatched",
       %{id: id, run: run} do
    view = mount_view(id)

    html =
      render_click(view, "decide_approval", %{
        "thread-id" => "run:#{run.run_id}",
        "run-id" => run.run_id,
        "tool-call-id" => "inflight-nope",
        "decision" => "approve"
      })

    assert html =~ "That request is no longer pending for this thread."
    assert ProjectionStore.run_approvals(run.run_id, status: :all) == []
  end
end
