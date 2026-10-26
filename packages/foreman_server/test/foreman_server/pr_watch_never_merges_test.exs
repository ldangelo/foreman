defmodule ForemanServer.PrWatchNeverMergesTest do
  @moduledoc """
  The merge gate is operator-only, and `CommandGateway.dispatch_system/2` has no allowlist of its
  own: what keeps the automatic PR actors from merging or approving is that none of them issues
  such a command. `pr_merge_gate_invariant_test.exs` proves that by reading their source. This
  drives them.

  One run, one PR, every signal saying "merge now": the auto-fix loop ends with CI green, the
  review is approved, GitHub calls the PR clean. The real `PrWatcher` (with `Observer`, `AutoFix`
  and the fix reactor), the real `PrMonitor` poll and real signed webhook deliveries observe it,
  first with the gate pending and then with the operator's approval standing. Every command handed
  to `CommandGateway` is recorded (`:meck` passthrough, as `command_gateway_run_steer_test.exs`
  does for the router) and the run's stream is read back: no `merge_approve`, `run.pr.merge`,
  `PrMerged` or `MergeGate*` may come from any of them, while the operator's own `merge_approve`
  is accepted, so the window can see exactly what it forbids.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.Approvals.Dispatch, as: ApprovalsDispatch
  alias ForemanServer.Coordinator.Dispatch, as: CoordinatorDispatch
  alias ForemanServer.MCP.Tools
  alias ForemanServer.{CommandGateway, PrMonitor, PrWatcher, ProjectionStore, RunPrMerge}
  alias ForemanServer.TestSupport.{Eventually, PrFixSupport, PrWatchSupport, ProjectionStoreReset}
  alias ForemanServer.Workflow.MergeGate

  @secret "whsec-never-merges"
  @approver "github:ldangelo"
  @pushed_sha "sha-pushed-by-the-fix"
  @settings %{
    thread_model: "sonnet",
    pr_auto_fix: %{"kinds" => ["ci", "comments", "conflicts"], "max_attempts" => 2}
  }

  setup do
    MergeGate.clear()
    ProjectionStoreReset.reset!()
    :persistent_term.erase({PrMonitor, :fetch_fun})
    Eventually.put_env_for_test(:foreman_server, :github_webhook_secret, @secret)
    :ok = ProjectionStore.subscribe(replay_existing: false)
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(CommandGateway)
      :persistent_term.erase({PrMonitor, :fetch_fun})
      RunPrMerge.clear_command_runner()
      MergeGate.clear()
      ProjectionStoreReset.reset!()
    end)
  end

  # -- what GitHub says ---------------------------------------------------------------------------

  defp failing_ci do
    PrWatchSupport.status(
      head_branch: "foreman/impl",
      checks: [PrWatchSupport.failing_check("unit")],
      checks_state: :failing
    )
  end

  # CI green, review approved, GitHub calls it clean, no open threads: merge now.
  defp merge_ready(head_sha) do
    passing = %{PrWatchSupport.failing_check("unit") | state: :passing, conclusion: "SUCCESS"}

    PrWatchSupport.status(
      head_sha: head_sha,
      head_branch: "foreman/impl",
      checks: [passing],
      checks_state: :passing,
      review_decision: :approved,
      merge_state_status: :clean,
      threads: []
    )
  end

  defp start_github(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    fetches = :counters.new(1, [])
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fetch = fn _url ->
      :counters.add(fetches, 1, 1)
      Agent.get(agent, &{:ok, &1})
    end

    {agent, fetch, fetches}
  end

  # -- what the actors did -------------------------------------------------------------------------

  # Every command type handed to the gateway, in order (the gateway is the one door they all use).
  defp dispatched do
    for {_pid, {CommandGateway, fun, [%{type: type} | _]}, _result} <-
          :meck.history(CommandGateway),
        fun in [:dispatch_system, :dispatch_system_approval, :dispatch_operator],
        do: type
  end

  # The commands dispatched and the events appended to the run while `fun` runs.
  defp watch(run_id, fun) do
    commands = length(dispatched())
    events = length(PrWatchSupport.run_event_types(run_id))
    fun.()

    {Enum.drop(dispatched(), commands), Enum.drop(PrWatchSupport.run_event_types(run_id), events)}
  end

  defp assert_nothing_merges({commands, events}) do
    assert Enum.filter(commands, &(&1 in ["merge_approve", "run.pr.merge"] or &1 =~ "merge")) ==
             []

    assert Enum.filter(events, &(&1 == "PrMerged" or String.starts_with?(&1, "MergeGate"))) == []
  end

  defp gate_events(run_id) do
    Enum.filter(PrWatchSupport.run_event_types(run_id), &String.starts_with?(&1, "MergeGate"))
  end

  # -- the operator ----------------------------------------------------------------------------------

  defp stub_gh(head_sha) do
    view = %{
      "state" => "OPEN",
      "mergeable" => "MERGEABLE",
      "headRefOid" => head_sha,
      "headRefName" => "foreman/impl",
      "baseRefName" => "main"
    }

    RunPrMerge.set_command_runner(fn "gh", ["pr", "view" | _], _opts ->
      {Jason.encode!(view), 0}
    end)
  end

  defp operator_approves(run_id, head_sha) do
    stub_gh(head_sha)

    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{run_id}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload: %{
        run_id: run_id,
        approver: "leo",
        approver_identity: @approver,
        head_sha: head_sha
      }
    })
  end

  # -- the signals --------------------------------------------------------------------------------------

  defp deliver(body) do
    raw = Jason.encode!(body)

    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, raw), case: :lower)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post("/webhooks/github", raw)
    |> json_response(202)
  end

  # Every automatic observer, once, against what GitHub says now: the watcher's own refresh, the
  # poll, and the two webhook deliveries that ask the watcher to look again.
  defp observe_everywhere(pr_url, fetches) do
    assert {:ok, %{requested: []}} = PrWatcher.refresh_now(pr_url)
    assert 1 = PrMonitor.poll_now()

    repo = String.replace_suffix(pr_url, "/pull/1", "")
    before = :counters.get(fetches, 1)

    assert %{"status" => "ok"} =
             deliver(%{
               "action" => "completed",
               "check_suite" => %{
                 "conclusion" => "success",
                 "pull_requests" => [%{"number" => 1}]
               },
               "repository" => %{"html_url" => repo}
             })

    assert %{"status" => "ok"} =
             deliver(%{
               "action" => "submitted",
               "review" => %{"state" => "approved"},
               "pull_request" => %{"html_url" => pr_url}
             })

    # The watcher reads a PR once at a time (concurrent requests for it share one read), so two
    # deliveries are one read or two. They were cast from this process, so `stats/1` is served
    # after both; then wait for the reads to end.
    PrWatcher.stats()

    Eventually.await(fn -> :sys.get_state(PrWatcher).inflight == %{} end,
      message: "the watcher never finished reading the PR for the webhook deliveries"
    )

    assert :counters.get(fetches, 1) > before, "the webhook deliveries caused no read of the PR"
  end

  defp await_projection(type, run_id) do
    receive do
      {:projection_event, %{event_type: ^type} = event} ->
        data = Map.get(event, :data) || Map.get(event, :payload)
        if data[:run_id] == run_id, do: data, else: await_projection(type, run_id)

      {:projection_event, _other} ->
        await_projection(type, run_id)
    after
      10_000 -> flunk("no #{type} event for #{run_id}")
    end
  end

  test "no automatic actor merges or approves a PR that every signal says is ready to merge" do
    ctx = PrFixSupport.watched!(settings: @settings, status: failing_ci())
    %{run_id: run_id, pr_url: pr_url} = ctx
    {github, fetch, fetches} = start_github(failing_ci())
    test_pid = self()

    starter = fn opts ->
      id = "js-fix-#{System.unique_integer([:positive])}"
      send(test_pid, {:jobsite_start, id, opts})
      {:ok, id}
    end

    start_supervised!(
      {PrWatcher,
       fetch_fun: fetch,
       jobsite_starter: starter,
       plan_opts: [fetch_fun: fetch, log_fetcher: fn _url, _check -> {:error, :none} end]}
    )

    PrMonitor.set_fetch_fun(fetch)
    start_supervised!(PrMonitor)

    # 1. The auto-fix loop, up to the PR being fixed, green and approved. The actors really work:
    #    they request a fix, start its jobsite and record it finished.
    {commands, events} =
      watch(run_id, fn ->
        assert {:ok, %{requested: ["run.pr.fix_ci"]}} = PrWatcher.refresh_now(pr_url)
        assert_receive {:jobsite_start, jobsite_id, _opts}, 10_000
        await_projection("PrFixStarted", run_id)

        Agent.update(github, fn _ -> merge_ready(@pushed_sha) end)

        :ok =
          ProjectionStore.apply_events([
            %{event_type: "JobsiteCompleted", payload: %{jobsite_id: jobsite_id}}
          ])

        assert %{outcome: "pushed"} = await_projection("PrFixFinished", run_id)

        # The fresh observation was handed back to the policy (it asks for nothing more) once
        # the watcher has no fix task left.
        Eventually.await(fn -> :sys.get_state(PrWatcher).fix_tasks == %{} end,
          message: "the watcher never finished the fix"
        )
      end)

    assert "run.pr.fix_ci" in commands
    assert "run.pr.fix_started" in commands
    assert "run.pr.fix_finished" in commands
    assert "PrFixFinished" in events
    assert_nothing_merges({commands, events})

    # 2. The PR opened; its gate is pending. Every signal says merge now.
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          project_id: ctx.project_id,
          task_id: ctx.task_id,
          pr_url: pr_url,
          branch_name: "foreman/impl",
          head_sha: @pushed_sha,
          base_branch: "main"
        }
      })

    pending_window =
      watch(run_id, fn ->
        observe_everywhere(pr_url, fetches)

        # The doors an agent or a coordinator has: refused before they reach the gateway.
        command = %{
          type: "run.pr.merge",
          command_id: "never",
          aggregate_id: "run:#{run_id}",
          payload: %{run_id: run_id, head_sha: @pushed_sha}
        }

        for type <- ["merge_approve", "run.pr.merge"] do
          command = %{command | type: type}

          assert {:error, {:forbidden_command, ^type}} =
                   CoordinatorDispatch.system(CommandGateway, command)

          assert {:error, {:forbidden_command, ^type}} = ApprovalsDispatch.system(command)
          assert {:error, %{code: "METHOD_NOT_FOUND"}} = Tools.call_tool(type, command.payload)
        end
      end)

    assert_nothing_merges(pending_window)
    refute_received {:jobsite_start, _, _}
    assert gate_events(run_id) == []

    # 3. The operator's approval is the one thing that moves the gate, and the window can see it.
    assert {:ok, _} = operator_approves(run_id, @pushed_sha)
    assert gate_events(run_id) == ["MergeGateApproved"]

    # 4. With the approval standing, `run.pr.merge` would be accepted by the aggregate if anything
    #    sent it. Nothing does, and nothing voids or repeats the approval either.
    approved_window = watch(run_id, fn -> observe_everywhere(pr_url, fetches) end)

    assert_nothing_merges(approved_window)
    refute_received {:jobsite_start, _, _}
    assert gate_events(run_id) == ["MergeGateApproved"]
    refute "PrMerged" in PrWatchSupport.run_event_types(run_id)
    assert ProjectionStore.pr_watch(run_id) |> Enum.all?(& &1.watching)
  end
end
