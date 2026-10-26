defmodule ForemanServerWeb.ProjectWorkspaceAttentionLiveTest do
  # foreman-q9zzo C6: the attention dot next to the workspace's "Overview" heading
  # (`Components.overview_pane/1`). It shows when `Overview.attention.needed` (a thread is
  # `waiting_on_you` or `ready_for_review`), names the real count of such threads in its
  # label, and goes away live once the cause is resolved.
  #
  # Attention is driven by real state, never by a poked assign: runs that really fail
  # (`run.fail`), a real tool-approval request (`tool.request`) and a real open pull
  # request (`run.pr.ready`), cleared by the operator's own commands (`thread.resolve`
  # from the card's button or the API, `tool.approve` from the card's button).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.Approvals.Requester
  alias ForemanServer.{CommandGateway, ProjectStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset}

  @endpoint ForemanServerWeb.Endpoint
  @token "workspace-attention-live-token"
  @dot ~s(#overview-heading [role="img"])

  setup do
    Eventually.put_env_for_test(:foreman_server, :api_bearer_token, @token)
    Eventually.put_env_for_test(:foreman_server, :workspace, coalesce_ms: 20)
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    id = "wsattn-#{System.unique_integer([:positive])}"
    other = "wsattn-other-#{System.unique_integer([:positive])}"

    for project_id <- [id, other] do
      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 name: "Demo #{project_id}"
               })
    end

    {:ok, id: id, other: other}
  end

  defp mount_view(id) do
    {:ok, view, _html} = live(build_conn(), "/dashboard/projects/#{id}?token=#{@token}")
    view
  end

  # The dot whose label starts with `count` ("2 threads need attention"). The label is
  # matched by its number only: it is the count that must be real.
  defp dot_with_count(view, count), do: has_element?(view, ~s(#{@dot}[aria-label^="#{count} "]))

  defp card(run), do: "#thread-run\\:#{run.run_id}"

  defp command!(run, type, payload) do
    Support.dispatch!(%{
      type: type,
      command_id: "#{type}:#{run.run_id}",
      aggregate_id: "run:#{run.run_id}",
      payload: Map.put(payload, :run_id, run.run_id)
    })
  end

  defp failed_run!(project_id) do
    run = Support.start_run!(project_id: project_id)
    command!(run, "run.fail", %{reason: "tests are red"})
    run
  end

  # A completed run with an open pull request awaiting review (merge gate pending).
  defp pr_ready_run!(project_id) do
    run = Support.start_run!(project_id: project_id)
    Support.complete_run!(run.run_id, project_id)

    command!(run, "run.pr.ready", %{
      project_id: project_id,
      task_id: run.task_id,
      pr_url: run.pr_url,
      branch_name: "foreman/#{run.run_id}/work",
      head_sha: "sha-1",
      base_branch: "main"
    })

    run
  end

  # `thread.resolve` as the CLI and `POST /api/commands` send it.
  defp resolve_thread!(project_id, run) do
    thread_id = "run:#{run.run_id}"

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "resolve:#{thread_id}",
               type: "thread.resolve",
               aggregate_id: "thread:#{thread_id}",
               payload: %{
                 thread_id: thread_id,
                 project_id: project_id,
                 resolved_by: "test",
                 source: "operator"
               }
             })
  end

  describe "the attention dot" do
    test "is absent while no thread needs the operator, whatever another project has going on",
         %{id: id, other: other} do
      working = Support.start_run!(project_id: id)
      foreign = failed_run!(other)

      view = mount_view(id)

      # The Overview lists the project's thread; nothing of it needs attention.
      assert has_element?(view, "#group-working #{card(working)}")
      refute has_element?(view, card(foreign))
      refute has_element?(view, @dot)
    end

    test "carries the number of threads needing attention and follows it as they are resolved",
         %{id: id} do
      failed = failed_run!(id)
      in_review = pr_ready_run!(id)

      view = mount_view(id)

      # One thread waits on the operator, one has a pull request to review: two.
      assert has_element?(view, "#group-waiting_on_you #{card(failed)}")
      assert has_element?(view, "#group-ready_for_review #{card(in_review)}")
      assert dot_with_count(view, 2)

      # Resolving the failed thread from its card leaves the review.
      view |> element("#{card(failed)} button[phx-value-action=resolve]") |> render_click()
      Eventually.await(fn -> dot_with_count(view, 1) end)

      # Resolving the other one elsewhere (the API / CLI path) puts the dot out live.
      resolve_thread!(id, in_review)
      Eventually.await(fn -> not has_element?(view, @dot) end)
      assert has_element?(view, "#group-resolved #{card(failed)}")
      assert has_element?(view, "#group-resolved #{card(in_review)}")
    end

    test "lights while the page is open when a running thread fails", %{id: id} do
      run = Support.start_run!(project_id: id)
      view = mount_view(id)
      assert has_element?(view, "#group-working #{card(run)}")
      refute has_element?(view, @dot)

      command!(run, "run.fail", %{reason: "the build broke"})

      Eventually.await(fn -> dot_with_count(view, 1) end)
      assert has_element?(view, "#group-waiting_on_you #{card(run)}")
      refute has_element?(view, "#group-working #{card(run)}")
    end

    test "a pending tool approval lights it until the operator decides the request", %{id: id} do
      run = Support.start_run!(project_id: id)
      view = mount_view(id)
      refute has_element?(view, @dot)

      assert {:ok, tool_call_id} =
               Requester.request(%{run_id: run.run_id, project_id: id}, "Write", %{
                 "file_path" => "/w/a.txt"
               })

      Eventually.await(fn -> dot_with_count(view, 1) end)
      assert has_element?(view, "#group-waiting_on_you #{card(run)}")

      view
      |> element("#approval-run\\:#{run.run_id}-#{tool_call_id} button", "Approve")
      |> render_click()

      Eventually.await(fn -> not has_element?(view, @dot) end)
      assert has_element?(view, "#group-working #{card(run)}")
    end
  end
end
