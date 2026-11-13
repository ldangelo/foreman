defmodule ForemanServer.PrDeliveryAdversarialApprovalTest do
  # TRD-037: the approval, interleave, waiver and publication scenarios of the Phase 1
  # adversarial suite (PRD section 5 exit rule), over the shared world (`PrDeliveryWorld`, TRD-025).
  # Like the core evidence file, every scenario enters through a production entry point (the
  # operator path `CommandGateway.dispatch_operator/1`, the system path `dispatch_system/1`, the
  # webhook adapter, the real `PrWatcher.Observer`, the real `PrReport.Publisher`) over the real
  # aggregate, gateway, evaluator, observer and projection; only the `gh` binary is scripted.
  #
  # Every scenario asserts an exact typed reason or a count AND that the approval, merge or
  # publication it targets did not happen, and carries a CONTROL: the one input flipped, with the
  # opposite outcome, so a refusal cannot be a harness that refuses everything. Each describe names
  # the PRD acceptance criterion it exercises. The world fails a test that makes a `gh` call it was
  # not scripted for, and completes every run the test left non-terminal.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]

  @moduletag :capture_log
  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.Notifier.{Mapping, Rule}
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.TestSupport.{GateEvidence, SecretStoreDir}
  alias ForemanServer.TestSupport.PrDeliveryWorld, as: World
  alias ForemanServer.TestSupport.PrWatchSupport

  alias ForemanServer.{
    CommandGateway,
    CommandRouter,
    PrObservation,
    PrReport,
    PrReport.Publisher,
    ProjectionStore
  }

  @unit %{"name" => "unit", "kind" => "check_run"}

  setup do
    %{world: World.start!()}
  end

  # -- helpers ----------------------------------------------------------------------------------

  # A gated project whose PR is ready at the world's head with a clean findings record (a LOW
  # judgement) and the run's base branch recorded: without either, the rubric level is HIGH and
  # `risk_high` refuses the approval.
  defp gated_run!(world, opts \\ []) do
    ready_run!(world, World.project!(world, [@unit]), opts)
  end

  defp ready_run!(world, project_id, opts \\ []) do
    run = World.ready_run!(world, project_id, opts)
    World.record_base!(run)
    run
  end

  defp passing!(world), do: World.add_check!(world, World.check_run("unit"))

  # The approval is refused with exactly `codes` for `head`, plus `risk_high`: the rubric reads
  # HIGH for a PR whose required checks are not passing or whose findings are unusable, and a HIGH
  # level is a reason (AC-003-2), so it rides on every refusal about a check or the findings (a
  # `codes` that names a risk code itself is pinned as given). The gate is still pending, nothing
  # was approved and the operator's merge is refused without any call to GitHub's merge. Every
  # merge refusal of this file goes through the operator path, whose gateway reads the gate first;
  # the aggregate's own guard (`ensure_pr_gate_ok`) is exercised only by the direct dispatch in
  # "without an approval nothing reaches GitHub's merge".
  defp assert_refused(world, run, codes, opts \\ []) do
    head = Keyword.get_lazy(opts, :head_sha, fn -> World.head(world) end)
    codes = with_risk_high(codes)

    assert {:error, {:evidence_ineligible, ^head, ^codes}, detail} =
             World.approve(world, run, opts)

    assert World.gate_pending?(run)
    refute World.gate_approved?(run)
    assert {:error, :pr_not_acceptable} = World.merge(run)
    detail
  end

  defp with_risk_high(codes) do
    if Enum.any?(codes, &String.starts_with?(&1, "risk_")),
      do: codes,
      else: codes ++ ["risk_high"]
  end

  defp assert_approved(world, run, opts \\ []) do
    assert {:ok, _} = World.approve(world, run, opts)
    assert World.gate_approved?(run)
    List.last(World.events(run, "MergeGateApproved"))
  end

  # The approval typed-refused before any evidence is decided: nothing is approved, the gate is
  # still pending and the world saw no merge.
  defp assert_not_approvable(world, run, error, opts) do
    assert ^error = World.approve(world, run, opts)
    assert World.events(run, "MergeGateApproved") == []
    assert World.gate_pending?(run)
    refute World.gate_approved?(run)
    assert World.merge_calls(world) == []
  end

  # The default waives a missing check and the HIGH level the rubric gives a PR whose checks do
  # not pass (a waived check is HIGH too): both are reasons of the approval.
  defp waive(world, run, head, codes \\ ["missing", "risk_high"], opts \\ []) do
    World.operator("run:#{run.run_id}", "run.pr.waive_evidence", %{
      run_id: run.run_id,
      approver: "leo",
      approver_identity: Keyword.get(opts, :identity, "github:ldangelo"),
      head_sha: head,
      reasons: codes,
      reason: "the check does not run for this PR",
      pr_url: World.pr_url(world)
    })
  end

  defp watch_record(run) do
    run.run_id |> ProjectionStore.pr_watch() |> Enum.find(&(&1.pr_url == run.pr_url))
  end

  defp get(map, key), do: ForemanServer.Aggregate.get(map, key)

  # `merge_approve` to the aggregate with a stamp a test built by hand: how a caller that skipped
  # the gateway's observation reaches the aggregate. `evidence: :none` sends none at all.
  defp approve_direct(run, head, evidence) do
    payload = %{
      run_id: run.run_id,
      approver: "leo",
      approver_identity: "github:ldangelo",
      head_sha: head
    }

    payload = if evidence == :none, do: payload, else: GateEvidence.stamp(payload, evidence)

    CommandRouter.dispatch(
      %{
        command_id: "approve-direct-#{System.unique_integer([:positive])}",
        type: "merge_approve",
        aggregate_id: "run:#{run.run_id}",
        payload: payload
      },
      5_000
    )
  end

  # The batch the observer would build for the PR as GitHub shows it now (the real builder over a
  # real read through the world's `gh`), optionally with the gate's forced observation.
  defp observation_batch!(world, run, opts \\ []) do
    assert {:ok, status} = PrStatus.fetch(run.pr_url, command_runner: World.runner(world))

    assert {:ok, batch} =
             PrObservation.commands(
               run.run_id,
               run.pr_url,
               status,
               watch_record(run),
               nil,
               [policy: Observer.observation_policy(run.run_id)] ++ opts
             )

    batch
  end

  defp dispatch_all!(commands) do
    for command <- commands do
      assert {:ok, _} = CommandGateway.dispatch_system(command)
    end

    :ok
  end

  # CONTROL of the head-change scenarios: a second PR of the world that nobody pushes to is
  # approved and merged through the same operator path, pinned to its own head.
  defp assert_unmoved_pr_merges!(world) do
    url = World.add_pr!(world, head: "head-steady")
    other = World.pr(world, url)
    World.add_check!(other, World.check_run("unit"))
    run = ready_run!(world, World.project!(world, [@unit]), pr: url)

    assert_approved(world, run)
    assert {:ok, _} = World.merge(run)

    assert ["pr", "merge", ^url, "--squash", "--match-head-commit", "head-steady"] =
             List.last(World.merge_calls(world))

    assert World.pr_state(other) == "MERGED"
  end

  # A gated run whose findings record holds one open finding that quotes `secret`, observed with a
  # running publisher (`publisher_opts` as `World.publisher!/2`): the run, the outcome the
  # publisher recorded and the bodies of the comments on the PR.
  defp publish_leaky_finding!(world, project_id, secret, publisher_opts \\ []) do
    publisher = World.publisher!(world, publisher_opts)
    run = World.ready_run!(world, project_id, findings: :none)

    finding = %{
      "severity" => "major",
      "path" => "lib/a.ex",
      "line" => 3,
      "description" => "the deploy token #{secret} is committed",
      "disposition" => "open",
      "source" => "review"
    }

    :ok = World.record_findings!(world, run, "head-one", findings: [finding])
    passing!(world)
    World.observe!(world, run)

    assert [outcome] = World.await_publications!(run, 1)
    World.settle_publisher!(publisher)
    {run, outcome, Enum.map(World.comments(world), & &1["body"])}
  end

  # -- AC-004-2: the head changes after approval ------------------------------------------------

  describe "AC-004-2: the head changes after approval, by three paths, each with its own outcome" do
    test "the observation of the new head re-holds the gate: it reads pending and nothing merges",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      assert_approved(world, run)

      World.push!(world, "head-two")
      World.observe!(world, run)

      # the approval of head-one is void: the gate is pending again, for a typed reason
      refute World.gate_approved?(run)
      assert World.gate_pending?(run)

      assert [held] = World.events(run, "MergeGatePending")
      assert get(held, :reason) == "head_moved_since_approval"
      assert get(held, :approved_head_sha) == "head-one"
      assert get(held, :head_sha) == "head-two"

      assert {:error, :pr_not_acceptable} = World.merge(run)
      assert World.merge_calls(world) == []
      assert World.pr_state(world) == "OPEN"

      # the new head needs its own evidence: the findings of the old head do not carry, and while
      # its check runs the approval is refused `pending`
      :ok = World.record_findings!(world, run, "head-two")
      World.set_rollup!(world, [World.check_run("unit", status: "IN_PROGRESS")])
      detail = assert_refused(world, run, ["pending"])
      assert [%{code: :pending, subject: "unit"}, %{code: :risk_high}] = detail.reasons
      assert World.merge_calls(world) == []

      # CONTROL: the new head's check passes; the approval is for head-two and so is the merge
      World.complete_check!(world, "unit", "SUCCESS")
      approved = assert_approved(world, run)
      assert get(approved, :head_sha) == "head-two"
      assert {:ok, _} = World.merge(run)
      url = World.pr_url(world)

      assert [["pr", "merge", ^url, "--squash", "--match-head-commit", "head-two"]] =
               World.merge_calls(world)

      assert World.pr_state(world) == "MERGED"
    end

    test "with no observation, run.pr.merge compares the live head with the approved head",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      assert_approved(world, run)

      # a push nobody observed: the gate still reads approved for head-one
      World.push!(world, "head-two")
      assert World.gate_approved?(run)

      assert {:error, {:head_moved_since_approval, "head-one", "head-two"}} = World.merge(run)

      # the refusal came from the live comparison: GitHub's merge was never asked
      assert World.merge_calls(world) == []
      assert World.pr_state(world) == "OPEN"

      # and the refused merge voided the approval, so the operator must decide the new head
      assert World.gate_pending?(run)
      assert [held] = World.events(run, "MergeGatePending")
      assert get(held, :reason) == "head_moved_since_approval"
      assert {:error, :pr_not_acceptable} = World.merge(run)
      assert World.merge_calls(world) == []

      # CONTROL: a PR nobody pushed to merges through the same path
      assert_unmoved_pr_merges!(world)
    end

    test "a push between the live read and the merge call is refused by GitHub's own pin",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      assert_approved(world, run)

      # the live read still shows head-one; the push lands before `gh pr merge` runs
      World.push_after_next_view!(world, "head-two")

      # the world's paraphrase of GitHub's refusal of a stale `--match-head-commit` (the real
      # `gh` text is unverified): what is pinned is the exit code and that GitHub, not Foreman's
      # own comparison, refused it
      assert {:error, {:gh_merge_failed, 1, message}} = World.merge(run)
      assert message =~ "Head branch was modified"

      url = World.pr_url(world)

      assert [["pr", "merge", ^url, "--squash", "--match-head-commit", "head-one"]] =
               World.merge_calls(world)

      assert World.head(world) == "head-two"
      assert World.pr_state(world) == "OPEN"

      # nothing re-held it (the head moved after the read the merge was decided on) and the pin is
      # still the approved head: the next attempt reads head-two and is refused by the comparison
      assert World.gate_approved?(run)

      assert {:error, {:head_moved_since_approval, "head-one", "head-two"}} = World.merge(run)
      assert length(World.merge_calls(world)) == 1
      assert World.pr_state(world) == "OPEN"

      # CONTROL: a PR nobody pushes to merges through the same path
      assert_unmoved_pr_merges!(world)
    end

    test "CONTROL: with no push the same approval merges the pinned head", %{world: world} do
      run = gated_run!(world)
      passing!(world)
      assert_approved(world, run)

      assert {:ok, _} = World.merge(run)
      url = World.pr_url(world)

      assert [["pr", "merge", ^url, "--squash", "--match-head-commit", "head-one"]] =
               World.merge_calls(world)

      assert World.pr_state(world) == "MERGED"
      assert World.events(run, "MergeGatePending") == []
    end
  end

  # -- AC-004-1: a merge needs an approval pinned to the current head ---------------------------

  describe "AC-004-1: merge_approve and run.pr.merge refuse without an approval pinned to the head" do
    test "without an approval nothing reaches GitHub's merge, by the operator path and at the aggregate",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)

      # the operator path: the gateway reads the aggregate's gate before any `gh` call
      assert {:error, :pr_not_acceptable} = World.merge(run)
      assert World.merge_calls(world) == []

      # the aggregate itself: a `run.pr.merge` that reaches it records no merge for a gate that is
      # not approved
      direct = %{
        command_id: "merge-direct-#{System.unique_integer([:positive])}",
        type: "run.pr.merge",
        aggregate_id: "run:#{run.run_id}",
        payload: %{
          run_id: run.run_id,
          project_id: run.project_id,
          task_id: run.task_id,
          pr_url: run.pr_url,
          branch_name: "foreman/task-world/run"
        }
      }

      assert {:error, :pr_not_acceptable} = CommandRouter.dispatch(direct, 5_000)
      assert World.events(run, "PrMerged") == []
      assert World.gate_pending?(run)

      # CONTROL: the same two merges after the approval
      assert_approved(world, run)

      assert {:ok, _} =
               CommandRouter.dispatch(%{direct | command_id: direct.command_id <> "-2"}, 5_000)

      assert [_merged] = World.events(run, "PrMerged")
      assert {:ok, _} = World.merge(run)
      assert [[_pr, _merge, _url, _squash, _match, "head-one"]] = World.merge_calls(world)
    end

    test "a head that is not GitHub's, or the old head after a push, is refused and approves nothing",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)

      assert_not_approvable(
        world,
        run,
        {:error, {:head_sha_mismatch, "head-bogus", "head-one"}},
        head_sha: "head-bogus"
      )

      # the operator reviewed head-one; the PR moved before the approval reached the server
      World.push!(world, "head-two")

      assert_not_approvable(
        world,
        run,
        {:error, {:head_sha_mismatch, "head-one", "head-two"}},
        head_sha: "head-one"
      )

      assert {:error, :pr_not_acceptable} = World.merge(run)

      # CONTROL: naming the head GitHub shows is decided on evidence (head-two has no findings
      # yet), then approved once it is eligible
      assert_refused(world, run, ["missing", "findings_other_sha"], head_sha: "head-two")
      :ok = World.record_findings!(world, run, "head-two")
      passing!(world)
      approved = assert_approved(world, run, head_sha: "head-two")
      assert get(approved, :head_sha) == "head-two"
    end

    test "an approval without the evidence the gateway stamps is refused at the aggregate",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      assert {:error, {:missing_or_invalid, :evidence}} = approve_direct(run, "head-one", :none)
      assert World.events(run, "MergeGateApproved") == []
      assert World.gate_pending?(run)
      refute World.gate_approved?(run)

      # CONTROL: the gateway's own stamp for the same head is decided and approves
      assert_approved(world, run)
    end

    test "a stamp whose observation is not the one recorded for the head is stale, not eligible",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      stamp = GateEvidence.gated([@unit], "an-observation-nobody-recorded")

      assert {:error, {:evidence_ineligible, "head-one", ["stale"]}, _detail} =
               approve_direct(run, "head-one", stamp)

      assert World.events(run, "MergeGateApproved") == []
      assert World.gate_pending?(run)

      # CONTROL: the same stamp naming the observation the gate recorded for this head (a forced
      # observation of it, `checks_ref` its nonce) is eligible and approves
      nonce = "nonce-recorded-for-head-one"

      dispatch_all!(
        observation_batch!(world, run, force: %{nonce: nonce, now_ms: 1_800_000_000_000})
      )

      assert {:ok, _} = approve_direct(run, "head-one", GateEvidence.gated([@unit], nonce))
      assert World.gate_approved?(run)
    end
  end

  # -- AC-001-5: a waiver is pinned to one head and one policy ------------------------------------

  describe "AC-001-5: a waiver for head H1 never covers H2" do
    test "CONTROL: the waiver for the head the approval names covers the missing check",
         %{world: world} do
      run = gated_run!(world)

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "unit"}, %{code: :risk_high}] = detail.reasons

      assert {:ok, _} = waive(world, run, "head-one")
      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      assert get(waived, :head_sha) == "head-one"
      assert get(waived, :reasons) == ["missing", "risk_high"]

      approved = assert_approved(world, run)
      assert get(get(approved, :evidence), :status) == "waived"
      assert get(get(approved, :evidence), :waived) == ["missing", "risk_high"]
    end

    test "a waiver of head-one is voided by the head move and covers nothing of head-two",
         %{world: world} do
      run = gated_run!(world)
      assert {:ok, _} = waive(world, run, "head-one")

      assert %{head_sha: "head-one", codes: ["missing", "risk_high"]} =
               watch_record(run).evidence.waiver

      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")

      # the gateway's forced observation of head-two moves the record's head: the waiver is gone
      detail = assert_refused(world, run, ["missing"], head_sha: "head-two")
      assert [%{code: :missing, subject: "unit"}, %{code: :risk_high}] = detail.reasons
      assert detail.waiver == nil
      assert watch_record(run).evidence.waiver == nil

      # CONTROL: a waiver that names head-two covers it
      assert {:ok, _} = waive(world, run, "head-two")
      approved = assert_approved(world, run, head_sha: "head-two")
      assert get(get(approved, :evidence), :status) == "waived"
      assert get(approved, :head_sha) == "head-two"
    end

    test "a waiver that names a head that is not GitHub's is refused and records nothing",
         %{world: world} do
      run = gated_run!(world)

      assert {:error, {:head_sha_mismatch, "head-bogus", "head-one"}} =
               waive(world, run, "head-bogus")

      World.push!(world, "head-two")

      assert {:error, {:head_sha_mismatch, "head-one", "head-two"}} =
               waive(world, run, "head-one")

      assert World.events(run, "PrEvidenceWaived") == []
      assert watch_record(run).evidence.waiver == nil
      :ok = World.record_findings!(world, run, "head-two")
      assert_refused(world, run, ["missing"], head_sha: "head-two")

      # CONTROL: the live head can be waived
      assert {:ok, _} = waive(world, run, "head-two")
      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      assert get(waived, :head_sha) == "head-two"
    end

    test "a waiver covers only the reasons it lists, and never a failure, a risk reason or a stale check",
         %{world: world} do
      run = gated_run!(world)
      World.set_rollup!(world, [World.check_run("unit", conclusion: "FAILURE")])

      for code <- ["failing", "stale", "pending", "risk_missing", "risk_other_sha", "other_sha"] do
        assert {:error, {:reason_not_waivable, ^code}} = waive(world, run, "head-one", [code])
      end

      assert World.events(run, "PrEvidenceWaived") == []

      # a waiver of `missing` does not cover the failing check that is there
      assert {:ok, _} = waive(world, run, "head-one", ["missing"])
      detail = assert_refused(world, run, ["failing"])
      assert [%{code: :failing, subject: "unit"}, %{code: :risk_high}] = detail.reasons
      assert detail.waived == []

      # CONTROL: the check passes: nothing was missing, the waiver is simply unused
      World.set_rollup!(world, [World.check_run("unit")])
      assert get(get(assert_approved(world, run), :evidence), :status) == "eligible"
    end

    test "a waiver recorded under one policy version covers nothing under another", %{
      world: world
    } do
      run = gated_run!(world)
      assert {:ok, _} = waive(world, run, "head-one")
      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      v1 = get(waived, :policy_version)

      # the project now requires one more check: another policy version, the same head
      lint = %{"name" => "lint", "kind" => "check_run"}
      World.set_required!(world, run.project_id, [@unit, lint])

      detail = assert_refused(world, run, ["missing", "missing"])
      assert Enum.sort(Enum.map(detail.reasons, & &1.subject)) == [nil, "lint", "unit"]
      assert detail.policy_version != v1
      assert detail.waived == []
      assert %{applies: false, ignored_because: :policy_changed} = detail.waiver

      assert {:ok, %{prs: [dto]}} = ForemanServer.PrWatch.DTO.fetch(run.run_id)
      assert %{applies: false} = dto.waiver
      assert to_string(dto.waiver.ignored_because) == "policy_changed"

      # CONTROL: waived again under the current version, the same two reasons are covered
      assert {:ok, _} = waive(world, run, "head-one")
      approved = assert_approved(world, run)
      assert get(get(approved, :evidence), :status) == "waived"
      assert get(get(approved, :evidence), :policy_version) == detail.policy_version
    end

    test "a waiver names its approver: no identity and an unauthorized one are refused",
         %{world: world} do
      run = gated_run!(world)

      for {identity, error} <- [
            {nil, {:missing_or_invalid, :approver_identity}},
            {"", {:missing_or_invalid, :approver_identity}},
            {"github:intruder", :unauthorized_approver}
          ] do
        assert {:error, ^error} = waive(world, run, "head-one", ["missing"], identity: identity)
      end

      assert World.events(run, "PrEvidenceWaived") == []
      assert watch_record(run).evidence.waiver == nil

      # CONTROL: the authorized identity waives
      assert {:ok, _} = waive(world, run, "head-one")
      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      assert get(waived, :approver_identity) == "github:ldangelo"
    end
  end

  # -- AC-003-2: a recorded HIGH risk level refuses the approval, and an operator may waive it ---

  describe "AC-003-2: a recorded HIGH level refuses the approval; the operator waives it with a reason" do
    # A secret-named file is HIGH by the rubric whatever else is true: the checks pass, the
    # findings are clean (a LOW judgement) and the base branch is recorded, so the level is the
    # one reason.
    defp high_run!(world) do
      World.set_files!(world, [{".env.production", 1, 0}])
      run = gated_run!(world)
      passing!(world)
      run
    end

    test "HIGH on a gated project is refused `risk_high`, and the display reads it the same way",
         %{world: world} do
      run = high_run!(world)

      detail = assert_refused(world, run, ["risk_high"])
      assert [%{code: :risk_high, subject: nil}] = detail.reasons
      assert detail.waived == []

      assert %{level: "HIGH", head_sha: "head-one"} = watch_record(run).evidence.risk
      assert World.events(run, "MergeGateApproved") == []
      assert {:error, :pr_not_acceptable} = World.merge(run)
      assert World.merge_calls(world) == []

      dto = World.dto!(run)
      assert dto.eligibility.status == "ineligible"
      assert Enum.map(dto.eligibility.reasons, & &1.code) == ["risk_high"]

      assert [%{codes: ["risk_high"]}] = Enum.filter(dto.next_actions, &(&1.action == "waive"))

      # CONTROL: the one input flipped, the path is not sensitive: LOW, approved
      World.set_files!(world, [{"lib/a.ex", 1, 0}])
      clean = gated_run!(world)
      assert assert_approved(world, clean).evidence.status == "eligible"
    end

    test "a waiver naming `risk_high`, with its reason, makes it approvable and is recorded", %{
      world: world
    } do
      run = high_run!(world)
      assert_refused(world, run, ["risk_high"])

      assert {:ok, _} = waive(world, run, "head-one", ["risk_high"])
      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      assert get(waived, :reasons) == ["risk_high"]
      assert get(waived, :reason) == "the check does not run for this PR"

      approved = assert_approved(world, run)
      assert get(get(approved, :evidence), :status) == "waived"
      assert get(get(approved, :evidence), :waived) == ["risk_high"]
    end

    test "a head change voids the waiver: the new head is refused `risk_high` again", %{
      world: world
    } do
      run = high_run!(world)
      assert {:ok, _} = waive(world, run, "head-one", ["risk_high"])
      assert %{head_sha: "head-one", codes: ["risk_high"]} = watch_record(run).evidence.waiver

      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")
      passing!(world)

      detail = assert_refused(world, run, ["risk_high"], head_sha: "head-two")
      assert detail.waiver == nil
      assert watch_record(run).evidence.waiver == nil

      # CONTROL: a waiver that names head-two covers it
      assert {:ok, _} = waive(world, run, "head-two", ["risk_high"])
      approved = assert_approved(world, run, head_sha: "head-two")
      assert get(get(approved, :evidence), :status) == "waived"
    end

    test "a waiver of `risk_high` does not cover a failing check; `risk_missing` and `risk_other_sha` stay never waivable",
         %{world: world} do
      run = high_run!(world)
      World.set_rollup!(world, [World.check_run("unit", conclusion: "FAILURE")])

      assert {:ok, _} = waive(world, run, "head-one", ["risk_high"])

      assert {:error, {:evidence_ineligible, "head-one", ["failing"]}, detail} =
               World.approve(world, run)

      assert [%{code: :failing}] = detail.reasons
      assert ["risk_high"] = detail.waived

      for code <- ["risk_missing", "risk_other_sha"] do
        assert {:error, {:reason_not_waivable, ^code}} = waive(world, run, "head-one", [code])
      end
    end
  end

  # -- a re-run per head --------------------------------------------------------------------------

  describe "AC-001-1 and AC-001-2: a re-run of a check is a new result for the same head" do
    test "the same check re-run changes its completion time and the evidence digest, not the notification digest",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      World.rerun_check!(world, "unit")
      World.complete_check!(world, "unit", "SUCCESS", completed_at: "2026-11-12T16:00:00Z")
      World.observe!(world, run)

      assert [first, second] = World.events(run, "PrChecksChanged")
      assert get(first, :head_sha) == get(second, :head_sha)
      assert get(first, :evidence_digest) != get(second, :evidence_digest)
      assert get(first, :digest) == get(second, :digest)
      assert [%{} = a] = get(first, :checks)
      assert [%{} = b] = get(second, :checks)
      assert get(a, :completed_at) != get(b, :completed_at)

      # a re-run that changes nothing is recorded as nothing
      World.observe!(world, run)
      assert length(World.events(run, "PrChecksChanged")) == 2
    end

    test "a pass then a failing re-run is failing; a failing run then a passing re-run is eligible",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      World.rerun_check!(world, "unit")
      World.complete_check!(world, "unit", "FAILURE", completed_at: "2026-11-12T16:00:00Z")
      detail = assert_refused(world, run, ["failing"])

      assert [%{code: :failing, subject: "unit", detail: "FAILURE"}, %{code: :risk_high}] =
               detail.reasons

      World.rerun_check!(world, "unit", started_at: "2026-11-12T16:30:00Z")
      World.complete_check!(world, "unit", "SUCCESS", completed_at: "2026-11-12T16:40:00Z")
      approved = assert_approved(world, run)
      assert get(get(approved, :evidence), :status) == "eligible"
    end

    test "the same failing names raise one CI-failed notification, and a gate observation never raises one",
         %{world: world} do
      run = gated_run!(world)
      World.set_rollup!(world, [World.check_run("unit", conclusion: "FAILURE")])
      World.observe!(world, run)

      World.rerun_check!(world, "unit")
      World.complete_check!(world, "unit", "FAILURE", completed_at: "2026-11-12T16:00:00Z")
      World.observe!(world, run)

      assert [first, second] = World.events(run, "PrChecksChanged")
      assert get(first, :digest) == get(second, :digest)
      assert get(first, :evidence_digest) != get(second, :evidence_digest)
      assert get(first, :source) == "watch" and get(second, :source) == "watch"

      # the Notifier's rule: the first sighting of the failure matches, with its dedupe key; the
      # re-run of the same failing names is evidence only and matches nothing
      rules = Mapping.rules()
      assert {:ok, rule} = lookup(rules, first)
      assert rule.subject == "CI failed"
      assert key(rule, first) == key(rule, second)
      assert lookup(rules, second) == :ignore

      # approving the failing PR repeatedly: every forced observation is a gate event
      for _attempt <- 1..2 do
        assert {:error, {:evidence_ineligible, "head-one", ["failing", "risk_high"]}, _} =
                 World.approve(world, run)
      end

      gate = for e <- World.events(run, "PrChecksChanged"), get(e, :source) == "gate", do: e
      assert length(gate) == 2

      for event <- gate do
        assert get(event, :checks_state) == "failing"
        assert get(event, :digest) == get(first, :digest)
        assert lookup(rules, event) == :ignore
      end

      # CONTROL: a NEW failing set from the PR's own observation is a new notification
      World.add_check!(world, World.check_run("lint", conclusion: "FAILURE"))
      World.observe!(world, run)

      assert [third] =
               for(
                 e <- World.events(run, "PrChecksChanged"),
                 get(e, :digest) != get(first, :digest),
                 do: e
               )

      assert {:ok, _} = lookup(rules, third)
      assert key(rule, third) != key(rule, first)
    end

    defp lookup(rules, event),
      do: Mapping.lookup(rules, "PrChecksChanged", Rule.normalize_payload!(event))

    defp key(rule, event) do
      payload = Rule.normalize_payload!(event)
      Enum.map(rule.key_fields, &Rule.field_value(payload, &1))
    end
  end

  # -- AC-003-5 and AC-003-2: the risk level is derived, never supplied ---------------------------

  describe "AC-003-5: a forged risk record is refused and appends nothing" do
    # Every content field of the risk event is derived by the handler (the identity fields name the
    # PR and the head); `sensitive_hits` is a derived rubric input the event does not carry as
    # such. Read from the event struct, so a field added to the event is tried here too.
    @identity ~w(run_id project_id task_id pr_url repo_id head_sha)a
    @derived (Map.keys(ForemanServer.Events.PrRiskRecorded.__struct__()) --
                [:__struct__ | @identity]) ++ [:sensitive_hits]

    test "a payload that names any derived field is refused; the rubric's HIGH stands", %{
      world: world
    } do
      World.set_files!(world, [{".env.production", 1, 0}])
      run = gated_run!(world)
      passing!(world)

      batch = observation_batch!(world, run)
      assert %{type: "run.pr.risk"} = risk = Enum.find(batch, &(&1.type == "run.pr.risk"))
      dispatch_all!(Enum.reject(batch, &(&1.type == "run.pr.risk")))

      for key <- @derived do
        value = if key == :level, do: "LOW", else: "forged"

        forged = %{
          risk
          | command_id: "forged-#{key}",
            payload: Map.put(risk.payload, key, value)
        }

        assert {:error, {:derived_field, ^key}} = CommandGateway.dispatch_system(forged)
      end

      assert World.events(run, "PrRiskRecorded") == []

      # CONTROL: the genuine command, the same facts without the derived fields, is classified by
      # the rubric: a secret-named file is HIGH whatever a worker would like it to be
      assert {:ok, _} = CommandGateway.dispatch_system(risk)
      assert [%{} = recorded] = World.events(run, "PrRiskRecorded")
      assert get(recorded, :level) == "HIGH"
      assert get(recorded, :head_sha) == "head-one"

      # a forgery after the record is refused too, and the record stays
      forged = %{risk | command_id: "forged-after", payload: Map.put(risk.payload, :level, "LOW")}
      assert {:error, {:derived_field, :level}} = CommandGateway.dispatch_system(forged)
      assert [%{}] = World.events(run, "PrRiskRecorded")
      assert %{level: "HIGH", head_sha: "head-one"} = watch_record(run).evidence.risk
    end

    test "a risk record for another head than the PR's is refused", %{world: world} do
      run = gated_run!(world)
      passing!(world)
      batch = observation_batch!(world, run)
      risk = Enum.find(batch, &(&1.type == "run.pr.risk"))
      dispatch_all!(Enum.reject(batch, &(&1.type == "run.pr.risk")))

      forged = %{
        risk
        | command_id: "forged-head",
          payload: %{risk.payload | head_sha: "head-forged"}
      }

      assert {:error, {:head_mismatch, "head-forged", "head-one"}} =
               CommandGateway.dispatch_system(forged)

      assert World.events(run, "PrRiskRecorded") == []

      assert {:ok, _} = CommandGateway.dispatch_system(risk)
      assert [%{head_sha: "head-one"}] = Enum.map(World.events(run, "PrRiskRecorded"), &Map.new/1)
    end

    test "a risk record for another head reads risk_other_sha, and neither it nor a missing one can be waived",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)
      assert [%{head_sha: "head-one"}] = Enum.map(World.events(run, "PrRiskRecorded"), &Map.new/1)

      # the PR moves; head-two's checks are recorded (the gate's forced observation) but its risk
      # record never arrives: what is on file is head-one's
      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")
      passing!(world)

      nonce = "nonce-risk-other-sha"
      batch = observation_batch!(world, run, force: %{nonce: nonce, now_ms: 1_800_000_000_000})
      assert Enum.any?(batch, &(&1.type == "run.pr.risk"))
      dispatch_all!(Enum.reject(batch, &(&1.type == "run.pr.risk")))

      stamp = GateEvidence.gated([@unit], nonce)

      assert {:error, {:evidence_ineligible, "head-two", ["risk_other_sha"]}, detail} =
               approve_direct(run, "head-two", stamp)

      assert detail.inputs.risk_head_sha == "head-one"
      assert World.events(run, "MergeGateApproved") == []

      assert {:error, {:reason_not_waivable, "risk_other_sha"}} =
               waive(world, run, "head-two", ["risk_other_sha"])

      # CONTROL: head-two's own risk record arrives; the same stamp is now eligible
      dispatch_all!(Enum.filter(batch, &(&1.type == "run.pr.risk")))
      assert {:ok, _} = approve_direct(run, "head-two", stamp)

      assert [%{head_sha: "head-two"}] =
               Enum.map(World.events(run, "MergeGateApproved"), &Map.new/1)
    end

    test "no risk record at all reads risk_missing", %{world: world} do
      run = gated_run!(world)
      passing!(world)
      nonce = "nonce-risk-missing"
      batch = observation_batch!(world, run, force: %{nonce: nonce, now_ms: 1_800_000_000_000})
      dispatch_all!(Enum.reject(batch, &(&1.type == "run.pr.risk")))

      stamp = GateEvidence.gated([@unit], nonce)

      assert {:error, {:evidence_ineligible, "head-one", ["risk_missing"]}, _} =
               approve_direct(run, "head-one", stamp)

      assert {:error, {:reason_not_waivable, "risk_missing"}} =
               waive(world, run, "head-one", ["risk_missing"])

      dispatch_all!(Enum.filter(batch, &(&1.type == "run.pr.risk")))
      assert {:ok, _} = approve_direct(run, "head-one", stamp)
    end
  end

  describe "AC-003-5 and AC-004-1: the evidence commands are system-only" do
    # Derived from the aggregate's own lists: every PR-watch command that is not an operator
    # command (the observation, findings, risk, fix and report-outcome records) and the system
    # commands of the PR lifecycle that no operator envelope accepts.
    @system_only (ForemanServer.Aggregates.Run.PrWatch.command_types() --
                    ForemanServer.Aggregates.Run.PrWatch.operator_types()) ++
                   ~w(run.pr.rehold run.pr.update run.pr.ready run.pr.retarget run.pr.reset)

    test "the operator path and POST /api/commands refuse every one, and the run's stream is unchanged",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)
      before = length(PrWatchSupport.run_events(run.run_id))

      payload = %{
        run_id: run.run_id,
        project_id: run.project_id,
        task_id: run.task_id,
        pr_url: run.pr_url,
        head_sha: "head-one",
        level: "LOW"
      }

      assert "run.pr.risk" in @system_only and "run.pr.fix_started" in @system_only

      for type <- @system_only do
        refute type in CommandGateway.operator_types()

        assert {:error, {:command_not_allowed, ^type}} =
                 World.operator("run:#{run.run_id}", type, payload)

        conn = post(build_conn(), "/api/commands", %{"type" => type, "payload" => payload})
        assert %{"error" => "invalid_envelope"} = json_response(conn, 400)
      end

      assert length(PrWatchSupport.run_events(run.run_id)) == before
      assert World.gate_pending?(run)

      # CONTROL: the operator's own PR command, POSTed to the same endpoint, is accepted and recorded
      request = %{
        run_id: run.run_id,
        project_id: run.project_id,
        task_id: run.task_id,
        pr_url: run.pr_url
      }

      conn =
        post(build_conn(), "/api/commands", %{
          "type" => "run.pr.publish_report",
          "payload" => request
        })

      assert %{"status" => "accepted"} = json_response(conn, 201)
      assert [_requested] = World.events(run, "PrReportRequested")
    end

    test "the merge decisions cannot be dispatched by the system path at all", %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      for type <- ["merge_approve", "run.pr.waive_evidence"] do
        assert {:error, {:operator_only, ^type}} =
                 CommandGateway.dispatch_system(%{
                   command_id: "forged-#{type}",
                   type: type,
                   aggregate_id: "run:#{run.run_id}",
                   payload: %{
                     run_id: run.run_id,
                     approver: "leo",
                     approver_identity: "github:ldangelo",
                     head_sha: "head-one",
                     reasons: ["missing"],
                     reason: "forged",
                     evidence: %{policy: nil, checks_ref: nil, now_ms: 1}
                   }
                 })
      end

      assert World.events(run, "MergeGateApproved") == []
      assert World.events(run, "PrEvidenceWaived") == []
      assert World.gate_pending?(run)

      # CONTROL: the operator path decides the same run
      assert_approved(world, run)
    end
  end

  # -- AC-003-3: the report is published once, bound to the head ----------------------------------

  describe "AC-003-3: a changed head invalidates the old report and the new head's report replaces it" do
    test "the old report stays recorded for the old head and is shown stale; the new head's report edits the same comment",
         %{world: world} do
      publisher = World.publisher!(world)
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      assert [first] = World.await_publications!(run, 1)
      assert get(first, :status) == "published"
      assert get(first, :head_sha) == "head-one"
      assert get(first, :superseded) == nil
      assert [%{"body" => body}] = World.comments(world)
      assert {:ok, %{run_id: run_id, head_sha: "head-one"}} = PrReport.parse_marker(body)
      assert run_id == run.run_id
      assert [["api", "repos/" <> _, "-f", "body=" <> ^body]] = World.comment_writes(world)

      # an unchanged PR publishes nothing more
      World.observe!(world, run)
      World.settle_publisher!(publisher)
      assert length(World.publications(run)) == 1
      assert length(World.comment_writes(world)) == 1

      # the head moves while no publisher is up: the new risk record exists, its report does not
      World.stop_publisher!(publisher)
      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")
      passing!(world)
      World.observe!(world, run)

      assert %{head_sha: "head-two"} = Map.new(List.last(World.events(run, "PrRiskRecorded")))
      assert %{head_sha: "head-one", status: "published"} = watch_record(run).evidence.report
      assert {:ok, %{prs: [dto]}} = ForemanServer.PrWatch.DTO.fetch(run.run_id)
      assert %{head_sha: "head-one", current: false, stale: true} = dto.report
      assert [%{"body" => ^body}] = World.comments(world)

      # the operator asks for the current record's report: the same comment is edited
      publisher = World.publisher!(world)

      assert {:ok, _} =
               World.operator("run:#{run.run_id}", "run.pr.publish_report", %{
                 run_id: run.run_id,
                 project_id: run.project_id,
                 task_id: run.task_id,
                 pr_url: run.pr_url
               })

      assert [^first, second] = World.await_publications!(run, 2)
      World.settle_publisher!(publisher)
      assert get(second, :status) == "published"
      assert get(second, :head_sha) == "head-two"
      assert get(second, :superseded) == "head-one"
      assert get(second, :comment_id) == get(first, :comment_id)

      # exactly one Foreman comment exists and it names the new head
      assert [%{"body" => new_body}] = World.comments(world)
      assert new_body != body
      assert {:ok, %{head_sha: "head-two"}} = PrReport.parse_marker(new_body)

      assert [["api", "repos/" <> _, "-f", _], ["api", "-X", "PATCH" | _]] =
               World.comment_writes(world)

      assert %{head_sha: "head-two", status: "published"} = watch_record(run).evidence.report
      assert {:ok, %{prs: [dto]}} = ForemanServer.PrWatch.DTO.fetch(run.run_id)
      assert %{head_sha: "head-two", current: true, stale: false} = dto.report
    end

    test "with the publisher running across the push, the new head's report edits the same comment on its own",
         %{world: world} do
      publisher = World.publisher!(world)
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      assert [first] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert [%{"body" => body}] = World.comments(world)

      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")
      passing!(world)
      World.observe!(world, run)

      assert [^first, second] = World.await_publications!(run, 2)
      World.settle_publisher!(publisher)
      assert get(second, :status) == "published"
      assert get(second, :head_sha) == "head-two"
      assert get(second, :superseded) == "head-one"
      assert get(second, :comment_id) == get(first, :comment_id)

      # one comment, edited in place: a create, then a PATCH of the same comment
      assert [%{"body" => new_body}] = World.comments(world)
      assert new_body != body
      assert {:ok, %{head_sha: "head-two"}} = PrReport.parse_marker(new_body)

      assert [["api", "repos/" <> _, "-f", _], ["api", "-X", "PATCH", "repos/" <> path | _]] =
               World.comment_writes(world)

      assert String.ends_with?(path, "/issues/comments/#{get(first, :comment_id)}")

      # CONTROL: an unchanged head writes nothing more
      World.observe!(world, run)
      World.settle_publisher!(publisher)
      assert length(World.publications(run)) == 2
      assert length(World.comment_writes(world)) == 2
    end
  end

  describe "AC-003-3: the publisher's own comment is not feedback" do
    test "its webhook delivery moves no review digest, emits no run.pr.review and publishes nothing; another user's marker comment is counted",
         %{world: world} do
      publisher = World.publisher!(world)
      run = gated_run!(world)
      passing!(world)
      World.watcher!(world)
      World.observe!(world, run)

      assert [_published] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert [%{"body" => own_body, "viewerDidAuthor" => true}] = World.comments(world)

      digest = watch_record(run).review_digest
      reviews = length(World.events(run, "PrReviewChanged"))
      writes = length(World.comment_writes(world))
      views = length(World.view_calls(world))

      # GitHub tells the watcher about the comment Foreman wrote
      assert :ok = World.webhook!(world, World.issue_comment_payload(world, own_body))
      World.settle_publisher!(publisher)

      # the delivery reached the observer (it read the PR again) and found no new feedback
      assert length(World.view_calls(world)) > views
      assert watch_record(run).review_digest == digest
      assert length(World.events(run, "PrReviewChanged")) == reviews
      assert length(World.publications(run)) == 1
      assert length(World.comment_writes(world)) == writes

      # CONTROL: a person's comment that merely starts like a marker is feedback
      marker = PrReport.marker(run.run_id, "head-one", "0123456789abcdef")
      World.add_comment!(world, marker <> "\n\nlooks like a report, is not", own: false)
      assert :ok = World.webhook!(world, World.issue_comment_payload(world, marker))
      World.settle_publisher!(publisher)

      assert watch_record(run).review_digest != digest
      assert length(World.events(run, "PrReviewChanged")) == reviews + 1
      assert length(World.publications(run)) == 1
      assert length(World.comment_writes(world)) == writes
    end
  end

  describe "the harness: settling the publisher is a barrier, not a hope" do
    # Every negative assertion of this file ("nothing more was published") reads after
    # `World.settle_publisher!/1`. If it returned before the publisher handled the event the last
    # observation appended, those assertions would pass on an empty window: so after each
    # observation, with no wait of its own, the outcome it triggered must already be recorded.
    test "returns only after the publication the last observation triggered is recorded",
         %{world: world} do
      publisher = World.publisher!(world)
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)
      World.settle_publisher!(publisher)
      assert [%{} = first] = World.publications(run)
      assert get(first, :head_sha) == "head-one"

      for n <- 2..6 do
        head = "head-#{n}"
        World.push!(world, head)
        passing!(world)
        World.observe!(world, run)
        World.settle_publisher!(publisher)

        assert length(World.publications(run)) == n
        assert head == get(List.last(World.publications(run)), :head_sha)
      end

      # CONTROL: nothing changed, so nothing more is published
      World.observe!(world, run)
      World.settle_publisher!(publisher)
      assert length(World.publications(run)) == 6
      assert length(World.comments(world)) == 1
    end
  end

  # -- AC-003-4: redaction ------------------------------------------------------------------------

  describe "AC-003-4: a project secret that survives the render blocks the publication" do
    test "the comment is refused with redaction_failed, nothing is written and none is published",
         %{world: world} do
      # the head is in the marker line, which is never redacted: a project whose secret is that
      # text cannot be published
      publisher = World.publisher!(world, secrets: ["head-one"])
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      assert [refused] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert get(refused, :status) == "refused"
      assert get(refused, :reason) == "redaction_failed"
      refute get(refused, :detail) =~ "head-one"
      assert get(refused, :comment_id) == nil

      assert World.comments(world) == []
      assert World.comment_writes(world) == []
      assert for(e <- World.publications(run), get(e, :status) == "published", do: e) == []
      assert %{status: "refused", reason: "redaction_failed"} = watch_record(run).evidence.report

      # a refusal is not retried on its own
      World.observe!(world, run)
      World.settle_publisher!(publisher)
      assert length(World.publications(run)) == 1
    end

    test "CONTROL: a secret that is not in the report does not block it", %{world: world} do
      publisher = World.publisher!(world, secrets: ["ghp_NOT-IN-THE-REPORT-0123456789"])
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      assert [published] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert get(published, :status) == "published"
      assert [%{"body" => body}] = World.comments(world)
      assert {:ok, %{head_sha: "head-one"}} = PrReport.parse_marker(body)
    end

    test "a secret inside a finding the agent wrote is replaced, and the rest of the finding is published",
         %{world: world} do
      secret = "zk-finding-secret-0123456789"
      project_id = World.project!(world, [@unit])

      {_run, outcome, [body]} =
        publish_leaky_finding!(world, project_id, secret, secrets: [secret])

      assert get(outcome, :status) == "published"
      refute body =~ secret
      assert body =~ "the deploy token"
      assert body =~ "is committed"
    end

    test "CONTROL: the same finding with an empty redaction list is published verbatim, so the replacement above is the list's doing",
         %{world: world} do
      secret = "zk-finding-secret-0123456789"
      project_id = World.project!(world, [@unit])

      {_run, outcome, [body]} = publish_leaky_finding!(world, project_id, secret, secrets: [])

      assert get(outcome, :status) == "published"
      assert body =~ secret
    end

    @tag :tmp_dir
    test "a secret in the project's secret store is replaced through the real redaction list",
         %{world: world, tmp_dir: tmp_dir} do
      SecretStoreDir.use_tmp_dir!(tmp_dir)
      secret = "zk-store-secret-0123456789"
      project_id = World.project!(world, [@unit])
      SecretStoreDir.put!(project_id, "DEPLOY_KEY", secret)

      # no `secrets:` here: the publisher resolves the list as production does
      {_run, outcome, [body]} = publish_leaky_finding!(world, project_id, secret)

      assert get(outcome, :status) == "published"
      refute body =~ secret
      assert body =~ "the deploy token"
    end

    @tag :tmp_dir
    test "CONTROL: without the store entry the same finding is published verbatim",
         %{world: world, tmp_dir: tmp_dir} do
      SecretStoreDir.use_tmp_dir!(tmp_dir)
      secret = "zk-store-secret-0123456789"
      project_id = World.project!(world, [@unit])

      {_run, outcome, [body]} = publish_leaky_finding!(world, project_id, secret)

      assert get(outcome, :status) == "published"
      assert body =~ secret
    end

    @tag :tmp_dir
    test "a stored project secret that is in a closed field of the report refuses the publication",
         %{world: world, tmp_dir: tmp_dir} do
      SecretStoreDir.use_tmp_dir!(tmp_dir)
      project_id = World.project!(world, [@unit])
      # eight characters: stored values shorter than that are not redacted; the marker line
      # carries the head, and nothing may hide it
      SecretStoreDir.put!(project_id, "DEPLOY_KEY", "head-one")

      publisher = World.publisher!(world)
      run = World.ready_run!(world, project_id)
      passing!(world)
      World.observe!(world, run)

      assert [refused] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert get(refused, :status) == "refused"
      assert get(refused, :reason) == "redaction_failed"
      assert World.comments(world) == []
      assert World.comment_writes(world) == []
    end

    test "a redaction list that cannot be resolved refuses the publication and writes nothing",
         %{world: world} do
      publisher = :"pr_world_publisher_boom_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Publisher,
         name: publisher,
         scan: false,
         command_runner: World.runner(world),
         secrets_fun: fn _project_id -> {:error, :boom} end}
      )

      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      assert [refused] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert get(refused, :status) == "refused"
      assert get(refused, :reason) == "redaction_failed"
      assert get(refused, :detail) == "the redaction list could not be resolved: boom"
      assert World.comments(world) == []
      assert World.comment_writes(world) == []
      assert for(e <- World.publications(run), get(e, :status) == "published", do: e) == []
    end
  end
end
