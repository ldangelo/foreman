defmodule ForemanServerWeb.ProjectWorkspacePrActionsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-workspace-pr-actions-token"

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

    id = "pra-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", name: "Demo #{id}"})
    {:ok, id: id}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  # A completed run of project `id` with a real task projection, built through
  # the real event store like the E9 tests do.
  defp completed_run!(id, title) do
    run = Support.start_run!(project_id: id)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: run.task_id,
            project_id: id,
            title: title,
            status: "open",
            task_type: "implement"
          }
        }
      ])

    Support.complete_run!(run.run_id, id)
    run
  end

  defp command!(run, type, payload) do
    Support.dispatch!(%{
      type: type,
      command_id: "#{type}:#{run.run_id}:#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{run.run_id}",
      payload: Map.put(payload, :run_id, run.run_id)
    })
  end

  defp with_pr!(run, observed) do
    command!(run, "run.pr.ready", %{
      project_id: run.project_id,
      task_id: run.task_id,
      pr_url: run.pr_url,
      branch_name: "foreman/#{run.run_id}/work",
      head_sha: "sha-1",
      base_branch: "main"
    })

    command!(run, "run.pr.checks", %{
      pr_url: run.pr_url,
      head_sha: "sha-1",
      digest: "d1",
      checks_state: Keyword.get(observed, :checks, "passing"),
      failing: [],
      pr_status: Keyword.get(observed, :status, "open"),
      base_branch: "main",
      branch_name: "foreman/#{run.run_id}/work",
      observation_seq: 1
    })

    if comments = observed[:comments] do
      command!(run, "run.pr.review", %{
        pr_url: run.pr_url,
        head_sha: "sha-1",
        digest: "r1",
        review_decision: "changes_requested",
        comment_ids: comments,
        pr_status: "open"
      })
    end

    run
  end

  defp mount_view(id) do
    {:ok, view, _html} = live(build_conn(), "/dashboard/projects/#{id}?token=#{@token}")
    view
  end

  defp btn(run, kind), do: "#pr-action-run\\:#{run.run_id}-#{kind}"
  defp reason(run, kind), do: "#pr-action-run\\:#{run.run_id}-#{kind}-reason"

  defp run_event_types(run), do: Support.run_event_types(run.run_id)

  defp await_event(run, type, tries \\ 100) do
    cond do
      type in run_event_types(run) ->
        :ok

      tries == 0 ->
        flunk("#{type} never reached the run stream: #{inspect(run_event_types(run))}")

      true ->
        Process.sleep(20)
        await_event(run, type, tries - 1)
    end
  end

  test "failing CI enables Fix CI, which dispatches run.pr.fix_ci for the run", %{id: id} do
    run = id |> completed_run!("Fix me") |> with_pr!(checks: "failing")
    view = mount_view(id)

    assert has_element?(view, "#group-waiting_on_you #thread-run\\:#{run.run_id}")
    refute has_element?(view, "#{btn(run, :fix_ci)}[disabled]")
    assert has_element?(view, "#{btn(run, :address_comments)}[disabled]")
    assert has_element?(view, reason(run, :address_comments), "no unresolved review comments")
    assert has_element?(view, reason(run, :resolve_conflicts), "no merge conflicts")
    assert has_element?(view, reason(run, :create_pr), "already exists")

    view |> element(btn(run, :fix_ci)) |> render_click()

    assert :ok = await_event(run, "PrFixRequested")
    assert has_element?(view, "#notice", "run.pr.fix_ci")
  end

  test "review comments enable Address comments (kind comments)", %{id: id} do
    run = id |> completed_run!("Comments") |> with_pr!(comments: ["c1"])
    view = mount_view(id)

    assert has_element?(view, "#{btn(run, :fix_ci)}[disabled]")
    assert has_element?(view, reason(run, :fix_ci), "CI is not failing")

    view |> element(btn(run, :address_comments)) |> render_click()
    assert :ok = await_event(run, "PrFixRequested")

    [requested] =
      run
      |> Map.fetch!(:run_id)
      |> Support.run_events()
      |> Enum.filter(&(&1.event_type == "PrFixRequested"))

    assert requested.data["kind"] == "comments" or requested.data[:kind] == "comments"
  end

  test "a conflicted PR enables Resolve conflicts (kind conflicts)", %{id: id} do
    run = id |> completed_run!("Conflicted") |> with_pr!(status: "conflicted")
    view = mount_view(id)

    assert has_element?(view, "#thread-run\\:#{run.run_id}")
    refute has_element?(view, "#{btn(run, :resolve_conflicts)}[disabled]")

    view |> element(btn(run, :resolve_conflicts)) |> render_click()
    assert :ok = await_event(run, "PrFixRequested")
  end

  test "a fix already running disables the buttons with the reason", %{id: id} do
    run = id |> completed_run!("Busy") |> with_pr!(checks: "failing")
    command!(run, "run.pr.fix_ci", %{pr_url: run.pr_url, trigger: "operator"})
    view = mount_view(id)

    assert has_element?(view, "#{btn(run, :fix_ci)}[disabled]")
    assert has_element?(view, reason(run, :fix_ci), "already running")
  end

  test "a completed run without a PR offers Create PR and dispatches run.pr.create", %{id: id} do
    run = completed_run!(id, "No PR yet")
    view = mount_view(id)

    refute has_element?(view, "#{btn(run, :create_pr)}[disabled]")
    assert has_element?(view, "#{btn(run, :fix_ci)}[disabled]")
    assert has_element?(view, reason(run, :fix_ci), "No pull request is being watched")

    # The real command opens a GitHub PR; record the dispatch instead of calling out.
    test = self()
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(CommandGateway) end)

    :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
      send(test, {:dispatched, envelope})
      {:error, :not_found, :stub}
    end)

    view |> element(btn(run, :create_pr)) |> render_click()

    assert_receive {:dispatched, %{type: "run.pr.create", aggregate_id: aggregate, payload: p}}
    assert aggregate == "run:" <> run.run_id
    assert p.run_id == run.run_id
  end

  test "there is no merge or approve control anywhere in the PR actions", %{id: id} do
    run = id |> completed_run!("Mergeable") |> with_pr!(checks: "failing", comments: ["c1"])
    view = mount_view(id)

    buttons = view |> element("#thread-run\\:#{run.run_id}") |> render()

    refute buttons =~ ~r/<button[^>]*>\s*[^<]*(merge|approve)/i
    refute buttons =~ ~r/phx-click="[^"]*(merge|approve)/i
  end

  test "pr_action is refused for another project's thread, unknown kinds and unwatched PRs", %{
    id: id
  } do
    run = id |> completed_run!("Mine") |> with_pr!(checks: "failing")
    other = "other-#{System.unique_integer([:positive])}"
    {:ok, _} = ProjectStore.save(%{project_id: other, path: "/tmp/#{other}", name: other})
    foreign = completed_run!(other, "Theirs")
    view = mount_view(id)
    thread = "run:" <> run.run_id

    render_click(view, "pr_action", %{"kind" => "fix_ci", "thread-id" => "run:" <> foreign.run_id})

    assert render(view) =~ "belongs to another project"
    refute "PrFixRequested" in run_event_types(foreign)

    render_click(view, "pr_action", %{"kind" => "merge", "thread-id" => thread})
    assert render(view) =~ "Unknown PR action"

    render_click(view, "pr_action", %{
      "kind" => "fix_ci",
      "thread-id" => thread,
      "pr-url" => "https://github.com/evil/other/pull/1"
    })

    assert render(view) =~ "not watched for this thread"
    refute "PrFixRequested" in run_event_types(run)
  end
end
