defmodule ForemanServer.RunPrMergeTest do
  # The operator `merge_approve` / `run.pr.merge` path, end to end through the real
  # gateway, Run aggregate and event store. Only `gh` is stubbed. These pin the
  # properties that make exposing a merge command safe: nothing merges before a
  # human approves, what merges is exactly the head that human named, a push after
  # approval voids the approval instead of being merged (or adopted as the new pin),
  # and a client cannot steer the merge by supplying its own payload.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.CommandGateway
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.ProjectionStore
  alias ForemanServer.RunPrMerge
  alias ForemanServer.Workflow.MergeGate

  # The head the PR is opened at, approved at, and the one a push moves it to.
  @approved_sha "approvedsha111"
  @pushed_sha "pushedsha333"
  @approver "github:ldangelo"

  setup do
    MergeGate.clear()

    run_id = "run-pr-merge-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-pr-merge", task_id: "task-pr-merge"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          project_id: "project-pr-merge",
          task_id: "task-pr-merge",
          pr_url: pr_url,
          branch_name: "foreman/task-pr-merge/run",
          head_sha: @approved_sha,
          base_branch: "main"
        }
      })

    on_exit(&RunPrMerge.clear_command_runner/0)

    %{run_id: run_id, pr_url: pr_url}
  end

  # Stubs `gh`: `pr view` answers with `view` (the PR's head is `headRefOid`), `pr merge`
  # with `merge`. Every call is sent to the test process so tests can assert what was
  # (not) run. Calling it again replaces the stub: that is how a test pushes to the PR.
  defp stub_gh(opts \\ []) do
    view = Keyword.get(opts, :view, %{})
    view_result = Keyword.get(opts, :view_result)
    merge_result = Keyword.get(opts, :merge, {"", 0})
    test_pid = self()

    RunPrMerge.set_command_runner(fn "gh", args, _opts ->
      send(test_pid, {:gh, args})

      case args do
        ["pr", "view" | _] when not is_nil(view_result) ->
          view_result

        ["pr", "view" | _] ->
          body =
            Map.merge(
              %{
                "state" => "OPEN",
                "mergeable" => "MERGEABLE",
                "headRefOid" => @approved_sha,
                "headRefName" => "foreman/task-pr-merge/run",
                "baseRefName" => "main"
              },
              view
            )

          {Jason.encode!(body), 0}

        ["pr", "merge" | _] ->
          merge_result
      end
    end)
  end

  # What an operator sends: the head they reviewed rides along as `head_sha`.
  defp approve(run_id, overrides \\ %{}) do
    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{System.unique_integer([:positive])}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload:
        Map.merge(
          %{
            run_id: run_id,
            approver: "leo",
            approver_identity: @approver,
            head_sha: @approved_sha
          },
          overrides
        )
    })
  end

  defp merge(run_id, payload_overrides \\ %{}) do
    CommandGateway.dispatch_operator(%{
      command_id: "merge-#{System.unique_integer([:positive])}",
      type: "run.pr.merge",
      aggregate_id: "run:#{run_id}",
      payload: Map.merge(%{run_id: run_id}, payload_overrides)
    })
  end

  defp pr_status(head_sha, extra \\ []) do
    struct!(
      %PrStatus{
        status: :open,
        head_sha: head_sha,
        head_branch: "foreman/task-pr-merge/run",
        base_branch: "main"
      },
      extra
    )
  end

  # A head the PR watch recorded after the PR was opened (what a Fix CI push, a conflict
  # resolution or a force-push looks like on the run stream).
  defp record_head(run_id, pr_url, head_sha) do
    # The real builder, so the event carries exactly what PrWatcher/PrMonitor record.
    {:ok, command} = ForemanServer.PrUpdate.command(run_id, pr_url, pr_status(head_sha))
    CommandGateway.dispatch_system(command)
  end

  # The gate of the run's primary PR as the aggregate holds it, with the head it pinned.
  defp gate(run_id) do
    {state, _version} = Aggregate.load(Run, "run:#{run_id}")
    {Run.merge_gate(state), Run.merge_pin(state).head_sha}
  end

  # What the read model (overview, `foreman run prs`) shows of the gate.
  defp shown_gate(run_id), do: ProjectionStore.pr_state(run_id).merge_gate

  defp events(run_id, type) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)

    events
    |> Enum.filter(&(&1.event_type == type))
    |> Enum.map(fn e -> e.data |> Jason.encode!() |> Jason.decode!() end)
  end

  defp gh_merge_calls do
    receive_all([])
    |> Enum.filter(&match?(["pr", "merge" | _], &1))
  end

  defp receive_all(acc) do
    receive do
      {:gh, args} -> receive_all([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "before approval" do
    test "an unapproved run is refused and gh is never called", %{run_id: run_id} do
      stub_gh()

      assert {:error, :pr_not_acceptable} = merge(run_id)

      assert receive_all([]) == [], "nothing may reach GitHub before a human approves"
      assert events(run_id, "PrMerged") == []
    end

    test "an unauthorized approver does not open the gate", %{run_id: run_id} do
      stub_gh()

      assert {:error, :unauthorized_approver} =
               approve(run_id, %{approver_identity: "github:someone-else"})

      assert {:error, :pr_not_acceptable} = merge(run_id)
      assert receive_all([]) == [], "an unauthorized approval is refused before any gh call"
    end

    test "an approval missing the approver is a typed error, not nil", %{run_id: run_id} do
      stub_gh()

      assert {:error, {:missing_or_invalid, :approver}} =
               approve(run_id, %{approver: nil})

      assert {:error, {:missing_or_invalid, :approver_identity}} =
               approve(run_id, %{approver_identity: nil})
    end
  end

  describe "approving names the head the operator reviewed (foreman-ehxy6)" do
    test "the head GitHub shows is accepted, recorded on the event and pinned exactly", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      stub_gh()

      assert {:ok, _} = approve(run_id)

      assert [%{"head_sha" => @approved_sha, "approver_identity" => @approver}] =
               events(run_id, "MergeGateApproved")

      assert {:approved, @approved_sha} = gate(run_id)
      assert :approved = shown_gate(run_id)

      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @approved_sha]] =
               gh_merge_calls()
    end

    test "any other head is refused with both SHAs named, and approves nothing", %{
      run_id: run_id
    } do
      stub_gh()

      assert {:error, {:head_sha_mismatch, "stalesha000", @approved_sha}} =
               approve(run_id, %{head_sha: "stalesha000"})

      assert events(run_id, "MergeGateApproved") == []
      assert {:pending, nil} = gate(run_id)
      assert {:error, :pr_not_acceptable} = merge(run_id)
      assert gh_merge_calls() == []
    end

    test "an abbreviated SHA is a mismatch, never a prefix match", %{run_id: run_id} do
      stub_gh()

      assert {:error, {:head_sha_mismatch, "approved", @approved_sha}} =
               approve(run_id, %{head_sha: "approved"})

      assert {:pending, nil} = gate(run_id)
    end

    test "no head is a typed error naming head_sha, and GitHub is not even asked", %{
      run_id: run_id
    } do
      stub_gh()

      for payload <- [%{head_sha: nil}, %{head_sha: ""}, %{head_sha: 42}] do
        assert {:error, {:missing_or_invalid, :head_sha}} = approve(run_id, payload)
      end

      # an absent key is the same refusal
      assert {:error, {:missing_or_invalid, :head_sha}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "approve-nohead-#{System.unique_integer([:positive])}",
                 type: "merge_approve",
                 aggregate_id: "run:#{run_id}",
                 payload: %{run_id: run_id, approver: "leo", approver_identity: @approver}
               })

      assert receive_all([]) == [], "a malformed approval is refused before any gh call"
      assert {:pending, nil} = gate(run_id)
    end

    test "a head that cannot be read from GitHub is refused, never assumed", %{run_id: run_id} do
      stub_gh(view_result: {"HTTP 502\n", 1})

      assert {:error, {:gh_failed, 1, "HTTP 502"}} = approve(run_id)
      assert events(run_id, "MergeGateApproved") == []
      assert {:pending, nil} = gate(run_id)
    end

    test "the event is built from the validated fields, not from the caller's map", %{
      run_id: run_id
    } do
      stub_gh()

      assert {:ok, _} = approve(run_id, %{pr_url: "https://github.com/evil/repo/pull/1", evil: 1})

      assert [event] = events(run_id, "MergeGateApproved")

      assert Map.keys(event) |> Enum.sort() ==
               ~w(approved_at approver approver_identity head_sha run_id)
    end

    test "the head GitHub shows is the authority, not the one the PR watch last recorded", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      # A push the watch has not seen (polling is opt-in): the PrReady head is stale, the
      # operator reviewed what GitHub shows.
      stub_gh(view: %{"headRefOid" => @pushed_sha})

      assert {:ok, _} = approve(run_id, %{head_sha: @pushed_sha})
      assert {:approved, @pushed_sha} = gate(run_id)

      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @pushed_sha]] =
               gh_merge_calls()
    end

    test "approving an approved gate again is refused, as before", %{run_id: run_id} do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      assert {:error, :merge_gate_already_approved} = approve(run_id)
      assert length(events(run_id, "MergeGateApproved")) == 1
    end
  end

  describe "a head that moved after the PR was opened (foreman-axmni)" do
    test "approving after the move pins the head that was approved, so the PR is mergeable", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      {:ok, _} = record_head(run_id, pr_url, "fixedhead222")
      stub_gh(view: %{"headRefOid" => "fixedhead222"})
      {:ok, _} = approve(run_id, %{head_sha: "fixedhead222"})

      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", "fixedhead222"]] =
               gh_merge_calls()

      assert [_one] = events(run_id, "PrMerged")
    end
  end

  describe "after approval" do
    setup %{run_id: run_id} do
      stub_gh()
      {:ok, _} = approve(run_id)
      :ok
    end

    test "squash-merges the approved head and records PrMerged", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @approved_sha]] =
               gh_merge_calls()

      assert [_one] = events(run_id, "PrMerged")
    end

    test "an already-merged PR is recorded without merging again", %{run_id: run_id} do
      stub_gh(view: %{"state" => "MERGED", "mergeable" => "UNKNOWN"})

      assert {:ok, _} = merge(run_id)

      assert gh_merge_calls() == [], "a retry after gh succeeded must not call gh merge again"
      assert [_one] = events(run_id, "PrMerged")
    end

    test "a PR merged at some other head is not recorded as this approval's merge", %{
      run_id: run_id
    } do
      stub_gh(
        view: %{
          "state" => "MERGED",
          "mergeable" => "UNKNOWN",
          "headRefOid" => @pushed_sha
        }
      )

      assert {:error, {:head_moved_since_approval, @approved_sha, @pushed_sha}} = merge(run_id)

      assert gh_merge_calls() == []
      assert events(run_id, "PrMerged") == []
    end

    test "a closed or conflicted PR is refused with its own reason", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      stub_gh(view: %{"state" => "CLOSED", "mergeable" => "UNKNOWN"})
      assert {:error, {:pr_closed, ^pr_url}} = merge(run_id)

      stub_gh(view: %{"mergeable" => "CONFLICTING"})
      assert {:error, {:pr_conflicted, ^pr_url}} = merge(run_id)

      assert gh_merge_calls() == []
      assert {:approved, @approved_sha} = gate(run_id), "neither is a moved head: no re-hold"
    end

    test "a gh merge failure surfaces gh's message and records nothing", %{run_id: run_id} do
      stub_gh(merge: {"Pull request is not mergeable\n", 1})

      assert {:error, {:gh_merge_failed, 1, "Pull request is not mergeable"}} = merge(run_id)
      assert events(run_id, "PrMerged") == []
      assert {:approved, @approved_sha} = gate(run_id)
    end

    test "the caller's payload cannot retarget the merge", %{run_id: run_id, pr_url: pr_url} do
      assert {:ok, _} =
               merge(run_id, %{
                 pr_url: "https://github.com/evil/repo/pull/1",
                 head_sha: "evilsha",
                 branch_name: "evil"
               })

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @approved_sha]] =
               gh_merge_calls()

      assert [event] = events(run_id, "PrMerged")
      assert event["pr_url"] == pr_url
    end
  end

  describe "a push after approval voids the approval (foreman-ehxy6)" do
    test "approve@sha1, push sha2: merge refused and approval cleared; sha1 is stale; sha2 merges",
         %{run_id: run_id, pr_url: pr_url} do
      stub_gh()
      assert {:ok, _} = approve(run_id)
      assert {:approved, @approved_sha} = gate(run_id)

      # the push, as the PR watch records it
      assert {:ok, _} = record_head(run_id, pr_url, @pushed_sha)
      stub_gh(view: %{"headRefOid" => @pushed_sha})

      # the approval is cleared: the gate is held again and pins nothing ...
      assert {:pending, nil} = gate(run_id)
      assert :pending = shown_gate(run_id)

      assert [
               %{
                 "reason" => "head_moved_since_approval",
                 "approved_head_sha" => @approved_sha,
                 "head_sha" => @pushed_sha,
                 "pr_url" => ^pr_url
               }
             ] = events(run_id, "MergeGatePending")

      # ... so the merge is refused, and the moved head was NOT adopted as the pin
      assert {:error, :pr_not_acceptable} = merge(run_id)
      assert gh_merge_calls() == []
      assert events(run_id, "PrMerged") == []

      # the old approval is stale: it names a head the PR no longer has
      assert {:error, {:head_sha_mismatch, @approved_sha, @pushed_sha}} = approve(run_id)
      assert {:pending, nil} = gate(run_id)

      # only a fresh approval of the new head reopens the merge, and it merges exactly that head
      assert {:ok, _} = approve(run_id, %{head_sha: @pushed_sha})
      assert {:approved, @pushed_sha} = gate(run_id)
      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @pushed_sha]] =
               gh_merge_calls()

      assert [_one] = events(run_id, "PrMerged")
    end

    test "a push the PR watch has not seen: the merge attempt finds it and voids the approval",
         %{run_id: run_id, pr_url: pr_url} do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      # GitHub moved; nothing recorded it (polling is opt-in, webhooks are optional)
      stub_gh(view: %{"headRefOid" => @pushed_sha})
      assert {:approved, @approved_sha} = gate(run_id), "nothing has noticed yet"

      assert {:error, {:head_moved_since_approval, @approved_sha, @pushed_sha}} = merge(run_id)
      assert gh_merge_calls() == []

      # the refusal also cleared the approval, so the PR is not stranded as approved-but-unmergeable
      assert {:pending, nil} = gate(run_id)
      assert :pending = shown_gate(run_id)
      assert {:error, :pr_not_acceptable} = merge(run_id), "the stale approval is not honoured"

      assert {:error, {:head_sha_mismatch, @approved_sha, @pushed_sha}} = approve(run_id)
      assert {:ok, _} = approve(run_id, %{head_sha: @pushed_sha})
      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @pushed_sha]] =
               gh_merge_calls()
    end

    test "the voided approval is never revived, not even when the head comes back", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      assert {:ok, _} = record_head(run_id, pr_url, @pushed_sha)
      assert {:pending, nil} = gate(run_id)

      # the PR returns to the head that had been approved
      assert {:ok, _} = record_head(run_id, pr_url, @approved_sha)
      stub_gh()

      assert {:pending, nil} = gate(run_id)
      assert {:error, :pr_not_acceptable} = merge(run_id)
      assert gh_merge_calls() == []

      # the operator has to decide again
      assert {:ok, _} = approve(run_id)
      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", @approved_sha]] =
               gh_merge_calls()
    end

    test "a head that comes back to one the PR watch recorded before is still caught", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      # Both observations are recorded before the approval ...
      assert {:ok, _} = record_head(run_id, pr_url, @pushed_sha)
      assert {:ok, _} = record_head(run_id, pr_url, "fixedhead222")
      stub_gh(view: %{"headRefOid" => "fixedhead222"})
      assert {:ok, _} = approve(run_id, %{head_sha: "fixedhead222"})
      recorded = length(events(run_id, "PrUpdated"))

      # ... so the PR returning to @pushed_sha repeats an observation whose command id the router
      # has seen: it appends nothing, yet the approval it voids is newer than that record.
      assert {:ok, _} = record_head(run_id, pr_url, @pushed_sha)
      assert length(events(run_id, "PrUpdated")) == recorded

      assert {:pending, nil} = gate(run_id)

      assert [%{"approved_head_sha" => "fixedhead222", "head_sha" => @pushed_sha}] =
               events(run_id, "MergeGatePending")
    end

    test "observing the approved head again leaves the approval standing", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      assert {:ok, _} = record_head(run_id, pr_url, @approved_sha)

      assert {:approved, @approved_sha} = gate(run_id)
      assert events(run_id, "MergeGatePending") == []
      assert {:ok, _} = merge(run_id)
    end

    test "approving again after a re-hold works as many times as the head moves", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      for head <- ["round-one", "round-two", "round-three"] do
        stub_gh(view: %{"headRefOid" => head})
        assert {:ok, _} = approve(run_id, %{head_sha: head})
        assert {:approved, ^head} = gate(run_id)

        assert {:ok, _} = record_head(run_id, pr_url, "moved-after-#{head}")
        assert {:pending, nil} = gate(run_id)
      end

      assert length(events(run_id, "MergeGatePending")) == 3
    end

    test "a pushed head observed through checks voids the approval", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      failing = [
        %{
          name: "ci",
          kind: :check_run,
          state: :failing,
          conclusion: "FAILURE",
          url: nil,
          workflow: nil
        }
      ]

      status = pr_status(@pushed_sha, checks_state: :failing, checks: failing)
      assert {:ok, :dispatched} = dispatch_only(run_id, pr_url, status, "run.pr.checks")

      assert {:pending, nil} = gate(run_id)
      assert [_one] = events(run_id, "PrChecksChanged")
      assert [%{"head_sha" => @pushed_sha}] = events(run_id, "MergeGatePending")
    end

    test "a pushed head observed through a review voids the approval", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      status = pr_status(@pushed_sha, review_decision: :changes_requested)
      assert {:ok, :dispatched} = dispatch_only(run_id, pr_url, status, "run.pr.review")

      assert {:pending, nil} = gate(run_id)
      assert [_one] = events(run_id, "PrReviewChanged")
    end

    test "the PR watcher's own observation of a pushed head voids the approval", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      {:ok, _} = ForemanServer.PrAssociate.store(run_id, pr_url)
      stub_gh()
      assert {:ok, _} = approve(run_id)

      assert {:ok, %{dispatched: ["run.pr.update"]}} =
               Observer.observe(pr_url,
                 fetch_fun: fn ^pr_url -> {:ok, pr_status(@pushed_sha)} end,
                 auto_fix: false
               )

      assert {:pending, nil} = gate(run_id)
      assert :pending = shown_gate(run_id)
    end
  end

  # `MergeGateApproved` events written by an older server carry no `head_sha`; they are
  # appended straight to the stream, as they exist in a live event log.
  defp legacy_run(live_head_updates) do
    run_id = "run-legacy-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/acme/legacy/pull/#{System.unique_integer([:positive])}"
    ids = %{run_id: run_id, project_id: "project-pr-merge", task_id: "task-pr-merge"}

    pr = fn extra -> Map.merge(ids, Map.merge(%{pr_url: pr_url}, extra)) end

    events =
      [
        {"RunStarted", ids},
        {"PrReady", pr.(%{branch_name: "legacy", head_sha: "legacy-ready", base_branch: "main"})}
      ] ++
        Enum.map(live_head_updates, fn head ->
          {"PrUpdated",
           pr.(%{branch_name: "legacy", head_sha: head, base_branch: "main", pr_status: "open"})}
        end) ++
        [
          {"MergeGateApproved",
           %{run_id: run_id, approver: "leo", approver_identity: @approver, approved_at: 1}}
        ]

    :ok =
      ForemanServer.EventStore.append_to_stream(
        "run:#{run_id}",
        0,
        Enum.map(events, fn {type, data} ->
          %EventStore.EventData{event_type: type, data: data, metadata: %{}}
        end)
      )

    %{run_id: run_id, pr_url: pr_url}
  end

  describe "an approval recorded before heads were pinned" do
    test "is pinned to the head the PR watch had recorded then, and merges at it" do
      %{run_id: run_id, pr_url: pr_url} = legacy_run(["legacy-fixed"])
      assert {:approved, "legacy-fixed"} = gate(run_id)

      stub_gh(view: %{"headRefOid" => "legacy-fixed"})
      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", ^pr_url, "--squash", "--match-head-commit", "legacy-fixed"]] =
               gh_merge_calls()
    end

    test "is voided by the merge attempt that finds the head moved, so it can be approved again" do
      %{run_id: run_id} = legacy_run(["legacy-fixed"])

      stub_gh(view: %{"headRefOid" => "legacy-pushed"})

      assert {:error, {:head_moved_since_approval, "legacy-fixed", "legacy-pushed"}} =
               merge(run_id)

      assert {:pending, nil} = gate(run_id)
      assert {:ok, _} = approve(run_id, %{head_sha: "legacy-pushed"})
      assert {:ok, _} = merge(run_id)
    end
  end

  describe "the merge gate stays operator-only" do
    test "run.pr.rehold is a system command: the operator path refuses it", %{run_id: run_id} do
      stub_gh()
      assert {:ok, _} = approve(run_id)

      assert {:error, {:command_not_allowed, "run.pr.rehold"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "rehold-#{System.unique_integer([:positive])}",
                 type: "run.pr.rehold",
                 aggregate_id: "run:#{run_id}",
                 payload: %{run_id: run_id, pr_url: "u", head_sha: "x"}
               })

      assert {:approved, @approved_sha} = gate(run_id)
    end
  end

  # Dispatch only the `type` command PrObservation derives from `status`, so a test can say which
  # observation carried the pushed head.
  defp dispatch_only(run_id, pr_url, status, type) do
    {:ok, commands} = ForemanServer.PrObservation.commands(run_id, pr_url, status, nil)
    command = Enum.find(commands, &(&1.type == type))
    assert command, "PrObservation produced no #{type} for #{inspect(status)}"

    with {:ok, _spec} <- CommandGateway.dispatch_system(command), do: {:ok, :dispatched}
  end
end
