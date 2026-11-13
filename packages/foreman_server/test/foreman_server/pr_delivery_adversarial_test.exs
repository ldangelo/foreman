defmodule ForemanServer.PrDeliveryAdversarialTest do
  # TRD-025: the core evidence scenarios of the Phase 1 adversarial suite (PRD section 5 exit
  # rule). Each scenario is a way for a PR to LOOK mergeable that it is not, driven through the
  # operator path (`CommandGateway.dispatch_operator/1`, what the HTTP controller and the CLI
  # call) over the real gateway, aggregate, evaluator, observer and projection; only `gh` is
  # scripted (`PrDeliveryWorld`, which fails the test naming any call it was not scripted for).
  #
  # Every refusal is asserted as the typed reason list (`{:evidence_ineligible, head, codes}`)
  # AND as the gate still pending, nothing approved and no merge possible; each refused
  # scenario ends with its CONTROL: the one change that makes the PR genuinely eligible, which
  # must then be approved, so a refusal cannot be a harness that refuses everything.
  use ExUnit.Case, async: false

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.TestSupport.GateEvidence
  alias ForemanServer.TestSupport.PrDeliveryWorld, as: World

  @unit %{"name" => "unit", "kind" => "check_run"}
  @lint %{"name" => "lint", "kind" => "check_run"}

  setup do
    %{world: World.start!()}
  end

  # A gated project whose PR is ready at the world's head with a clean findings record (a LOW
  # judgement) and the run's base branch recorded: without either, the rubric level is HIGH and
  # `risk_high` refuses the approval.
  defp gated_run!(world, required) do
    run = World.ready_run!(world, World.project!(world, required))
    World.record_base!(run)
    run
  end

  # The approval is refused with exactly `codes` for `head`, plus `risk_high`: the rubric reads
  # HIGH for a PR whose required checks are not passing or whose findings are unusable, and a HIGH
  # level is a reason (AC-003-2), so it rides on every refusal about a check or the findings (a
  # `codes` that names a risk code itself is pinned as given). The gate is still pending, nothing
  # was approved, and the operator's merge is refused without any call to GitHub's merge.
  # Returns the refusal's detail.
  defp assert_refused(world, run, codes, opts \\ []) do
    head = Keyword.get_lazy(opts, :head_sha, fn -> World.head(world) end)
    codes = with_risk_high(codes)

    assert {:error, {:evidence_ineligible, ^head, ^codes}, detail} =
             World.approve(world, run, opts)

    assert World.events(run, "MergeGateApproved") == []
    assert World.gate_pending?(run)
    refute World.gate_approved?(run)
    # AC-004-1: nothing was approved, so the merge is refused before any GitHub merge call
    assert {:error, :pr_not_acceptable} = World.merge(run)
    assert World.merge_calls(world) == []
    detail
  end

  defp with_risk_high(codes) do
    if Enum.any?(codes, &String.starts_with?(&1, "risk_")),
      do: codes,
      else: codes ++ ["risk_high"]
  end

  defp assert_approved(world, run, opts \\ []) do
    assert {:ok, _} = World.approve(world, run, opts)
    assert [%{} = approved] = World.events(run, "MergeGateApproved")
    assert World.gate_approved?(run)
    approved
  end

  # -- AC-001-2: a required check that is missing -----------------------------------------------

  describe "AC-001-2: a required check that never reported" do
    test "an empty rollup refuses with `missing`; the passing check makes it eligible", %{
      world: world
    } do
      run = gated_run!(world, [@unit])

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "unit"}, %{code: :risk_high}] = detail.reasons

      World.add_check!(world, World.check_run("unit"))
      assert_approved(world, run)
    end

    test "only the checks that did report are not enough: each missing entry is its own reason",
         %{
           world: world
         } do
      run = gated_run!(world, [@unit, @lint])
      World.set_rollup!(world, [World.check_run("lint")])

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "unit"}, %{code: :risk_high}] = detail.reasons
    end
  end

  # -- AC-001-2 / AC-001-7: evidence recorded for another head --------------------------------

  describe "AC-001-2 and AC-001-7: evidence of another head" do
    test "a pass recorded for the old head does not carry to a pushed head: the gateway observes the new one",
         %{world: world} do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))
      World.observe!(world, run)
      assert ["head-one"] = for(e <- World.events(run, "PrChecksChanged"), do: get(e, :head_sha))

      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")
      views_before = length(World.view_calls(world))

      detail = assert_refused(world, run, ["missing"], head_sha: "head-two")

      # AC-001-7: one read of the live PR for this request, one forced observation of the named head
      assert length(World.view_calls(world)) - views_before == 1
      nonce = detail.checks_ref
      assert is_binary(nonce)

      assert [%{} = forced] =
               for(
                 e <- World.events(run, "PrChecksChanged"),
                 get(e, :observation_ref) == nonce,
                 do: e
               )

      assert get(forced, :source) == "gate"
      assert get(forced, :head_sha) == "head-two"
      assert get(forced, :checks) == []
      # the decision used only evidence recorded for the named head
      assert detail.inputs.checks_head_sha == "head-two"
      assert detail.inputs.checks_ref == nonce

      World.add_check!(world, World.check_run("unit"))
      approved = assert_approved(world, run, head_sha: "head-two")
      assert approved.head_sha == "head-two"
      assert approved.evidence.inputs.checks_head_sha == "head-two"
    end

    test "at the aggregate, checks, findings and risk of the old head decide nothing for the named head",
         %{world: world} do
      # What the gateway's forced observation prevents, pinned at the aggregate: an approval of
      # head-two stamped by a caller that skipped the observation, over a record of head-one.
      # It kills a mutant that stops comparing the recorded head with the approved one.
      required = [@unit]
      run = gated_run!(world, required)
      World.add_check!(world, World.check_run("unit"))
      World.observe!(world, run)

      # a ref no recorded observation carries: the head is compared before the ref
      stamp = GateEvidence.gated(required, "stamped-without-an-observation")

      assert {:error, {:evidence_ineligible, "head-two", codes}, detail} =
               approve_stamped(run, "head-two", stamp)

      assert codes == ["other_sha", "findings_other_sha", "risk_other_sha"]
      assert detail.inputs.checks_head_sha == "head-one"
      assert World.events(run, "MergeGateApproved") == []
      assert World.gate_pending?(run)

      # CONTROL: the gateway observes head-two (and is refused only for the findings of
      # head-one): the check and risk reasons disappear; with findings recorded the aggregate
      # accepts the same stamp
      World.push!(world, "head-two")
      World.add_check!(world, World.check_run("unit"))
      refused = assert_refused(world, run, ["findings_other_sha"], head_sha: "head-two")
      stamp = GateEvidence.gated(required, refused.checks_ref)

      assert {:error, {:evidence_ineligible, "head-two", ["findings_other_sha", "risk_high"]},
              detail} =
               approve_stamped(run, "head-two", stamp)

      assert detail.inputs.checks_head_sha == "head-two"
      assert detail.inputs.risk_head_sha == "head-two"

      # a review of its own (one fixed finding, so another findings digest) for head-two
      fixed = %{
        path: "lib/a.ex",
        line: 3,
        description: "the token was logged",
        source: "repo-rules",
        severity: "critical",
        disposition: "fixed"
      }

      :ok = World.record_findings!(world, run, "head-two", findings: [fixed])

      # the risk of head-two was judged without its findings (HIGH: the findings on file were
      # head-one's): the PR's own observation records it again from the findings now on file
      World.observe!(world, run)
      assert {:ok, _} = approve_stamped(run, "head-two", stamp)

      assert [%{head_sha: "head-two"}] =
               Enum.map(World.events(run, "MergeGateApproved"), &atomize/1)
    end
  end

  # -- AC-001-4: a status context is not a check run --------------------------------------------

  describe "AC-001-4: a result is matched by name AND kind" do
    test "a commit status named like a required check run does not satisfy it", %{world: world} do
      run = gated_run!(world, [@unit])
      World.set_rollup!(world, [World.status_context("unit", "SUCCESS")])

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "unit"}, %{code: :risk_high}] = detail.reasons

      World.add_check!(world, World.check_run("unit"))
      assert_approved(world, run)
    end

    test "a check run named like a required commit status does not satisfy it either", %{
      world: world
    } do
      status_entry = %{"name" => "ci/build", "kind" => "status_context"}
      run = gated_run!(world, [status_entry])
      World.set_rollup!(world, [World.check_run("ci/build")])

      assert_refused(world, run, ["missing"])

      World.add_check!(world, World.status_context("ci/build", "SUCCESS"))
      assert_approved(world, run)
    end
  end

  describe "AC-001-4: a result is matched by workflow when the entry names one" do
    test "a passing check of the same name in another workflow does not satisfy it", %{
      world: world
    } do
      entry = %{"name" => "unit", "kind" => "check_run", "workflow" => "release"}
      run = gated_run!(world, [entry])
      World.set_rollup!(world, [World.check_run("unit", workflow: "ci")])

      assert_refused(world, run, ["missing"])

      World.add_check!(world, World.check_run("unit", workflow: "release"))
      assert_approved(world, run)
    end
  end

  # Production never reads the artifact a review wrote: the claim reaches the PR only as the
  # findings record (`run.pr.findings`), which no check rule consults. This scenario cannot tell
  # a guard from the absence of a mechanism; it is kept as a REGRESSION: the day something does
  # read an agent-written file as a result, it fails.
  describe "AC-001-4 (regression): agent-written output is never evidence" do
    @describetag :tmp_dir

    test "an artifact claiming every test passed, with a clean findings block, stays no check result",
         %{world: world, tmp_dir: tmp_dir} do
      artifact = Path.join(tmp_dir, "review.md")
      claim = "All tests passed. unit: SUCCESS. lint: SUCCESS. Nothing to fix.\n"
      File.write!(artifact, claim)

      run = World.ready_run!(world, World.project!(world, [@unit]), findings: :none)
      World.record_base!(run)
      sha = :crypto.hash(:sha256, claim) |> Base.encode16(case: :lower)

      :ok =
        World.record_findings!(world, run, World.head(world),
          artifact_path: artifact,
          artifact_sha256: sha
        )

      assert_refused(world, run, ["missing"])

      World.add_check!(world, World.check_run("unit"))
      assert_approved(world, run)
    end
  end

  # -- AC-001-2: a rollup GitHub cut -------------------------------------------------------------

  describe "AC-001-2: a rollup GitHub cut is not a check that never ran" do
    test "the required check fell off the kept items: `checks_truncated`, never `missing`", %{
      world: world
    } do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))
      World.truncate_rollup!(world, PrStatus.max_list())

      detail = assert_refused(world, run, ["checks_truncated"])
      assert [%{code: :checks_truncated, subject: "unit"}, %{code: :risk_high}] = detail.reasons
      assert [%{} = forced] = gate_observations(run)
      assert get(forced, :checks_truncated) == true
      assert length(get(forced, :checks)) == PrStatus.max_list()
      refute Enum.any?(get(forced, :checks), &(get(&1, :name) == "unit"))
    end

    test "CONTROL: a cut rollup that still lists the required check decides on it", %{
      world: world
    } do
      run = gated_run!(world, [@unit])
      World.truncate_rollup!(world, PrStatus.max_list())
      World.add_check!(world, World.check_run("unit"))

      approved = assert_approved(world, run)
      assert approved.evidence.status == "eligible"
      assert [%{} = forced] = gate_observations(run)
      assert get(forced, :checks_truncated) == true
      assert Enum.any?(get(forced, :checks), &(get(&1, :name) == "unit"))
    end
  end

  # -- AC-004-1: the merge follows the approval --------------------------------------------------

  describe "AC-004-1: a merge needs an approval pinned to the head" do
    test "refused while the gate is pending; after the approval GitHub is asked to merge the pinned head",
         %{world: world} do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))

      assert {:error, :pr_not_acceptable} = World.merge(run)
      assert World.merge_calls(world) == []
      assert World.pr_state(world) == "OPEN"

      assert_approved(world, run)
      assert {:ok, _} = World.merge(run)

      url = World.pr_url(world)

      assert [["pr", "merge", ^url, "--squash", "--match-head-commit", "head-one"]] =
               World.merge_calls(world)

      assert World.pr_state(world) == "MERGED"
      # what a push between the approval and the merge does is TRD-037's (the `gh pr merge` the
      # world scripts refuses a pin that is not the live head)
    end
  end

  # -- AC-001-4: the entry is matched exactly ----------------------------------------------------

  describe "AC-001-4: a required name is matched exactly" do
    for {label, name} <- [
          {"another case", "Unit"},
          {"a longer name that starts with it", "unit-tests"},
          {"a path that ends with it", "lint/unit"}
        ] do
      test "a check run called #{inspect(name)} (#{label}) is not `unit`", %{world: world} do
        run = gated_run!(world, [@unit])
        World.set_rollup!(world, [World.check_run(unquote(name))])

        assert_refused(world, run, ["missing"])

        World.add_check!(world, World.check_run("unit"))
        assert_approved(world, run)
      end
    end

    test "the workflow of an entry is matched exactly: `CI` is not `ci`", %{world: world} do
      entry = %{"name" => "unit", "kind" => "check_run", "workflow" => "CI"}
      run = gated_run!(world, [entry])
      World.set_rollup!(world, [World.check_run("unit", workflow: "ci")])

      assert_refused(world, run, ["missing"])

      World.add_check!(world, World.check_run("unit", workflow: "CI"))
      assert_approved(world, run)
    end
  end

  describe "AC-001-2: two results under one name" do
    for {label, conclusions} <- [
          {"the failure first", ["FAILURE", "SUCCESS"]},
          {"the success first", ["SUCCESS", "FAILURE"]}
        ] do
      test "a failure and a success of `unit` (#{label}) is `failing`, whichever GitHub lists last",
           %{world: world} do
        run = gated_run!(world, [@unit])

        World.set_rollup!(
          world,
          for(c <- unquote(conclusions), do: World.check_run("unit", conclusion: c))
        )

        detail = assert_refused(world, run, ["failing"])

        assert [%{code: :failing, subject: "unit", detail: "FAILURE"}, %{code: :risk_high}] =
                 detail.reasons

        World.set_rollup!(world, [World.check_run("unit"), World.check_run("unit")])
        assert_approved(world, run)
      end
    end
  end

  describe "AC-001-2: a conclusion that is not a pass" do
    for {conclusion, code} <- [
          {"STALE", "stale"},
          {"CANCELLED", "failing"},
          {"TIMED_OUT", "failing"},
          {"ACTION_REQUIRED", "failing"}
        ] do
      test "a check run concluded #{conclusion} is `#{code}`", %{world: world} do
        run = gated_run!(world, [@unit])
        World.add_check!(world, World.check_run("unit", conclusion: unquote(conclusion)))

        detail = assert_refused(world, run, [unquote(code)])
        assert [%{subject: "unit"}, %{code: :risk_high}] = detail.reasons

        World.complete_check!(world, "unit", "SUCCESS")
        assert_approved(world, run)
      end
    end

    test "a commit status in ERROR is `failing`", %{world: world} do
      entry = %{"name" => "ci/build", "kind" => "status_context"}
      run = gated_run!(world, [entry])
      World.add_check!(world, World.status_context("ci/build", "ERROR"))

      detail = assert_refused(world, run, ["failing"])

      assert [%{code: :failing, subject: "ci/build", detail: "ERROR"}, %{code: :risk_high}] =
               detail.reasons

      World.set_rollup!(world, [World.status_context("ci/build", "SUCCESS")])
      assert_approved(world, run)
    end
  end

  # -- a recorded real payload -------------------------------------------------------------------

  # `docs/spikes/S4/pr565-view.json` is `gh pr view --json ...` of a real PR (spike S4), recorded
  # with these fields: statusCheckRollup (three CheckRuns with `workflowName`, and a StatusContext
  # `CodeRabbit` with `targetUrl: ""`), reviewDecision (""), reviews, comments, mergeStateStatus,
  # mergeable, headRefOid (40 hex). NOT in the capture, so the world supplies them: headRefName,
  # baseRefName, files, changedFiles, additions, deletions; the PR was merged when recorded, the
  # test makes it open. The rollup, head, reviews and comments reach the gateway as recorded.
  describe "a recorded real `gh pr view` payload" do
    @recorded Path.expand("../../../../docs/spikes/S4/pr565-view.json", __DIR__)

    test "the parser, the gateway and the evaluator read it as recorded", %{world: world} do
      real = @recorded |> File.read!() |> Jason.decode!()
      head = real["headRefOid"]
      assert head =~ ~r/\A[0-9a-f]{40}\z/

      World.push!(world, head)

      World.set_raw!(
        world,
        real
        |> Map.take(
          ~w(statusCheckRollup reviewDecision reviews comments mergeStateStatus mergeable)
        )
        |> Map.put("state", "OPEN")
      )

      assert {:ok, %PrStatus{head_sha: ^head, review_decision: nil, checks: checks}} =
               PrStatus.fetch(World.pr_url(world), command_runner: World.runner(world))

      assert [
               %{name: "foreman_server", kind: :check_run, workflow: "ci", state: :passing},
               %{name: "jido_harness", kind: :check_run, workflow: "ci"},
               %{name: "foreman_cli", kind: :check_run, workflow: "ci"},
               %{name: "CodeRabbit", kind: :status_context, state: :passing}
             ] = checks

      # a status context that the recorded PR has is not a check run of that name
      spoofed = %{"name" => "CodeRabbit", "kind" => "check_run"}
      refused_run = gated_run!(world, [spoofed])
      assert_refused(world, refused_run, ["missing"])

      entries = [
        %{"name" => "foreman_server", "kind" => "check_run", "workflow" => "ci"},
        %{"name" => "CodeRabbit", "kind" => "status_context"}
      ]

      run = gated_run!(world, entries)
      approved = assert_approved(world, run)
      assert approved.evidence.inputs.checks_head_sha == head
    end
  end

  # -- AC-001-2: a stale result after a fix push ------------------------------------------------

  describe "AC-001-2: the old head's pass does not carry to the fix push" do
    test "the new head's run is in progress: `pending`, until it completes", %{world: world} do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))
      World.observe!(world, run)

      World.push!(world, "head-two")
      World.add_check!(world, World.check_run("unit", status: "IN_PROGRESS"))
      :ok = World.record_findings!(world, run, "head-two")

      detail = assert_refused(world, run, ["pending"], head_sha: "head-two")
      assert [%{code: :pending, subject: "unit"}, %{code: :risk_high}] = detail.reasons

      # the operator's old approval target is not GitHub's head any more
      assert {:error, {:head_sha_mismatch, "head-one", "head-two"}} =
               World.approve(world, run, head_sha: "head-one")

      World.complete_check!(world, "unit", "SUCCESS")
      assert_approved(world, run, head_sha: "head-two")
    end

    test "the new head's run failed: `failing` with the conclusion", %{world: world} do
      run = gated_run!(world, [@unit])
      World.push!(world, "head-two")
      World.add_check!(world, World.check_run("unit", conclusion: "FAILURE"))
      :ok = World.record_findings!(world, run, "head-two")

      detail = assert_refused(world, run, ["failing"], head_sha: "head-two")

      assert [%{code: :failing, subject: "unit", detail: "FAILURE"}, %{code: :risk_high}] =
               detail.reasons
    end
  end

  # -- AC-001-7: what a gated approval does at the gateway --------------------------------------

  describe "AC-001-7: the approval is decided on evidence read for the request" do
    test "one read of the live PR, one forced observation of the named head, recorded with the approval",
         %{world: world} do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))

      assert World.view_calls(world) == []
      approved = assert_approved(world, run)

      assert [["pr", "view", url, "--json", fields]] = World.view_calls(world)
      assert url == World.pr_url(world)
      assert fields =~ "statusCheckRollup"

      assert [%{} = forced] =
               for(e <- World.events(run, "PrChecksChanged"), get(e, :source) == "gate", do: e)

      assert get(forced, :head_sha) == World.head(world)
      assert approved.evidence.checks_ref == get(forced, :observation_ref)
      assert approved.evidence.inputs.checks_head_sha == World.head(world)
      assert approved.evidence.status == "eligible"
    end

    test "evidence of an earlier observation is not the one read for this request", %{
      world: world
    } do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))
      World.observe!(world, run)

      # the PR changes after that observation; the approval does not trust it
      World.rerun_check!(world, "unit")
      assert_refused(world, run, ["pending"])
    end
  end

  # -- the harness itself -----------------------------------------------------------------------

  describe "the harness" do
    test "an unscripted call is answered with a failure, recorded and named", %{world: world} do
      run = World.runner(world)

      assert {output, 1} = run.("gh", ["issue", "list", "--json", "number"], [])
      assert output =~ "unscripted call: gh issue list --json number"
      assert {output, 1} = run.("git", ["push", "origin", "x"], [])
      assert output =~ "unscripted call: git push origin x"

      assert {_, 1} =
               run.(
                 "gh",
                 ["pr", "view", "https://github.com/other/repo/pull/9", "--json", "state"],
                 []
               )

      assert [
               "gh issue list --json number",
               "git push origin x",
               "gh pr view https://github.com/other/repo/pull/9 --json state"
             ] = World.take_unscripted!(world)

      assert World.take_unscripted!(world) == []
    end

    test "a registered handler answers its calls; the core answer is unchanged", %{world: world} do
      World.script!(world, :issues, fn
        _world, ["issue", "list" | _] -> {:reply, {"[]", 0}}
        _world, _args -> :pass
      end)

      run = World.runner(world)

      assert {"[]", 0} = run.("gh", ["issue", "list"], [])
      assert {_json, 0} = run.("gh", ["pr", "view", World.pr_url(world), "--json", "state"], [])
      assert World.take_unscripted!(world) == []
    end

    test "gh pr view returns only the requested fields; an unknown field fails the call", %{
      world: world
    } do
      run = World.runner(world)
      url = World.pr_url(world)

      assert {output, 0} = run.("gh", ["pr", "view", url, "--json", "state,headRefOid"], [])
      assert Jason.decode!(output) == %{"state" => "OPEN", "headRefOid" => "head-one"}

      assert {output, 1} = run.("gh", ["pr", "view", url, "--json", "state,bogusField"], [])
      assert output =~ "Unknown JSON field"

      # the parser needs the branch names: a request without them is a payload it refuses
      assert {output, 0} = run.("gh", ["pr", "view", url, "--json", "state,mergeable"], [])

      assert {:error, {:gh_unexpected_payload, _}} =
               PrStatus.fetch(url, command_runner: fn _cmd, _args, _opts -> {output, 0} end)

      assert World.take_unscripted!(world) == []
    end

    test "another PR of the world has its own record, its own list entry and its own merge", %{
      world: world
    } do
      run = World.runner(world)
      other_url = World.add_pr!(world, branch: "feature/x", head: "sha-x")
      other = World.pr(world, other_url)
      fork_url = World.add_pr!(world, branch: "feature/fork", cross_repository: true)

      assert other_url != World.pr_url(world)
      assert World.head(other) == "sha-x"
      World.push!(other, "sha-y")
      assert {World.head(other), World.head(world)} == {"sha-y", "head-one"}

      list = fn flags ->
        {output, 0} = run.("gh", ["pr", "list"] ++ flags, [])
        Jason.decode!(output)
      end

      assert [%{"url" => ^other_url, "headRefOid" => "sha-y", "isCrossRepository" => false}] =
               list.(["--head", "feature/x", "--json", "url,headRefOid,isCrossRepository"])

      assert [%{"isCrossRepository" => true, "url" => ^fork_url}] =
               list.(["--head", "feature/fork", "--json", "url,isCrossRepository"])

      assert list.(["--head", "feature/x", "--state", "closed", "--json", "url"]) == []
      assert {_, 1} = run.("gh", ["pr", "list", "--json", "bogus"], [])

      # a merge pinned to a head that is not GitHub's is refused; the live head merges
      assert {output, 1} =
               run.(
                 "gh",
                 ["pr", "merge", other_url, "--squash", "--match-head-commit", "sha-x"],
                 []
               )

      assert output =~ "Head branch was modified"
      assert World.pr_state(other) == "OPEN"

      assert {"", 0} =
               run.(
                 "gh",
                 ["pr", "merge", other_url, "--squash", "--match-head-commit", "sha-y"],
                 []
               )

      assert World.pr_state(other) == "MERGED"
      assert World.pr_state(world) == "OPEN"

      assert [%{"url" => ^other_url}] =
               list.(["--head", "feature/x", "--state", "merged", "--json", "url"])

      assert {_, 1} =
               run.(
                 "gh",
                 ["pr", "merge", other_url, "--squash", "--match-head-commit", "sha-y"],
                 []
               )

      # a merge that does not pin the head is not something production may send
      assert {_, 1} = run.("gh", ["pr", "merge", World.pr_url(world), "--squash"], [])
      assert ["gh pr merge " <> _] = World.take_unscripted!(world)
    end

    test "a run of the other PR is ready at that PR's head", %{world: world} do
      other_url = World.add_pr!(world, branch: "feature/x", head: "sha-x")
      project = World.project!(world, [@unit])
      run = World.ready_run!(world, project, pr: other_url)

      assert run.pr_url == other_url
      assert [%{head_sha: "sha-x"}] = Enum.map(World.events(run, "PrReady"), &atomize/1)
    end

    test "a run without a PR, an operator command of any type, an approver that is not allowed",
         %{
           world: world
         } do
      project = World.project!(world, [@unit])
      prless = World.start_run!(world, project)
      assert prless.pr_url == nil
      assert [_] = World.events(prless, "RunStarted")

      # any operator command goes through dispatch_operator
      assert {:ok, _} =
               World.operator("project:#{project}", "project.update", %{
                 project_id: project,
                 max_concurrent_runs: 3
               })

      run = World.ready_run!(world, project)
      World.add_check!(world, World.check_run("unit"))

      assert {:error, _unauthorized} =
               World.approve(world, run, identity: "github:not-an-approver")

      assert World.events(run, "MergeGateApproved") == []
      assert World.gate_pending?(run)
    end

    test "finish_runs! completes the runs that are not terminal and leaves the others alone", %{
      world: world
    } do
      project = World.project!(world, nil)
      done = World.start_run!(world, project)
      open = World.start_run!(world, project)
      ForemanServer.TestSupport.PrWatchSupport.complete_run!(done.run_id, project)

      World.finish_runs!(world)
      World.finish_runs!(world)

      assert [_] = World.events(done, "RunCompleted")
      assert [_] = World.events(open, "RunCompleted")
    end

    test "the PR record reads back through PrStatus as the mutators say", %{world: world} do
      fetch = fn -> PrStatus.fetch(World.pr_url(world), command_runner: World.runner(world)) end

      World.set_rollup!(world, [
        World.check_run("unit"),
        World.status_context("ci/build", "PENDING")
      ])

      assert {:ok, %PrStatus{head_sha: "head-one", checks: [unit, build]}} = fetch.()
      assert %{name: "unit", kind: :check_run, state: :passing, workflow: "ci"} = unit
      assert %{name: "ci/build", kind: :status_context, state: :pending} = build

      World.rerun_check!(world, "unit", started_at: "2026-11-12T16:00:00Z")

      assert {:ok,
              %PrStatus{
                checks: [
                  %{state: :pending, completed_at: nil, started_at: "2026-11-12T16:00:00Z"} | _
                ]
              }} = fetch.()

      World.complete_check!(world, "unit", "FAILURE", completed_at: "2026-11-12T16:05:00Z")

      assert {:ok,
              %PrStatus{
                checks: [
                  %{state: :failing, conclusion: "FAILURE", completed_at: "2026-11-12T16:05:00Z"}
                  | _
                ]
              }} = fetch.()

      World.truncate_rollup!(world, PrStatus.max_list())
      assert {:ok, %PrStatus{checks_truncated: true, checks: checks}} = fetch.()
      assert length(checks) == PrStatus.max_list()
      refute Enum.any?(checks, &(&1.name == "unit"))

      World.push!(world, "head-two")
      assert {:ok, %PrStatus{head_sha: "head-two", checks: [], checks_state: :none}} = fetch.()
      assert World.head(world) == "head-two"
      assert length(World.view_calls(world)) == 5
    end

    test "a check that is not on the PR cannot be mutated", %{world: world} do
      assert_raise ExUnit.AssertionError, ~r/no check run named "unit"/, fn ->
        World.complete_check!(world, "unit", "SUCCESS")
      end
    end

    test "observe! records the observer's batch; observed_at ages the evidence", %{world: world} do
      run = gated_run!(world, [@unit])
      World.add_check!(world, World.check_run("unit"))

      World.observe!(world, run, observed_at: 1_700_000_000_000)

      assert [%{} = checks] = World.events(run, "PrChecksChanged")
      assert get(checks, :source) == "watch"
      assert get(checks, :observed_at) == 1_700_000_000_000
      assert [%{name: "unit"}] = Enum.map(get(checks, :checks), &atomize/1)
    end
  end

  # -- support ----------------------------------------------------------------------------------

  defp get(map, key), do: ForemanServer.Aggregate.get(map, key)

  defp atomize(%{} = map), do: Map.new(map, fn {k, v} -> {to_atom(k), v} end)
  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_existing_atom(key)

  defp gate_observations(run),
    do: for(e <- World.events(run, "PrChecksChanged"), get(e, :source) == "gate", do: e)

  # `merge_approve` to the aggregate with a stamp a test built by hand: how a caller that skipped
  # the gateway's observation would reach the aggregate (`GateEvidence`).
  defp approve_stamped(run, head, evidence) do
    ForemanServer.CommandRouter.dispatch(
      %{
        command_id: "approve-stamped-#{System.unique_integer([:positive])}",
        type: "merge_approve",
        aggregate_id: "run:#{run.run_id}",
        payload:
          GateEvidence.stamp(
            %{
              run_id: run.run_id,
              approver: "leo",
              approver_identity: "github:ldangelo",
              head_sha: head
            },
            evidence
          )
      },
      5_000
    )
  end
end
