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

  # A gated project whose PR is ready at the world's head with a clean findings record.
  defp gated_run!(world, required) do
    World.ready_run!(world, World.project!(world, required))
  end

  # The approval is refused with exactly `codes` for `head`; the gate is still pending, nothing
  # was approved, and the operator's merge is refused without any call to GitHub's merge.
  # Returns the refusal's detail.
  defp assert_refused(world, run, codes, opts \\ []) do
    head = Keyword.get_lazy(opts, :head_sha, fn -> World.head(world) end)

    assert {:error, {:evidence_ineligible, ^head, ^codes}, detail} =
             World.approve(world, run, opts)

    assert World.events(run, "MergeGateApproved") == []
    assert World.gate_pending?(run)
    refute World.gate_approved?(run)
    # AC-004-1: nothing was approved, so the merge is refused before any GitHub merge call
    assert {:error, :pr_not_acceptable} = World.merge(run)
    refute Enum.any?(World.calls(world), &match?({"gh", ["pr", "merge" | _]}, &1))
    detail
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
      assert [%{code: :missing, subject: "unit"}] = detail.reasons

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
      assert [%{code: :missing, subject: "unit"}] = detail.reasons
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

    test "at the aggregate, checks of the old head decide nothing for the named head: `other_sha`",
         %{world: world} do
      # What the gateway's forced observation prevents, pinned at the aggregate: an approval of
      # head-two stamped by a caller that skipped the observation, over a record of head-one.
      required = [@unit]
      run = gated_run!(world, required)
      World.add_check!(world, World.check_run("unit"))
      World.observe!(world, run)
      :ok = World.record_findings!(world, run, "head-two")
      checks_ref = checks_ref_of(world, run)

      assert {:error, {:evidence_ineligible, "head-two", codes}, detail} =
               approve_stamped(run, "head-two", GateEvidence.gated(required, checks_ref))

      # the checks are of head-one; the risk record is too; the findings were recorded for head-two
      assert codes == ["other_sha", "risk_other_sha"]
      assert detail.inputs.checks_head_sha == "head-one"
      assert World.events(run, "MergeGateApproved") == []
      assert World.gate_pending?(run)
    end
  end

  # -- AC-001-4: a status context is not a check run --------------------------------------------

  describe "AC-001-4: a result is matched by name AND kind" do
    test "a commit status named like a required check run does not satisfy it", %{world: world} do
      run = gated_run!(world, [@unit])
      World.set_rollup!(world, [World.status_context("unit", "SUCCESS")])

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "unit"}] = detail.reasons

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

  describe "AC-001-4: agent-written output is never evidence" do
    @describetag :tmp_dir

    test "an artifact claiming every test passed, with a clean findings block, is not a check result",
         %{world: world, tmp_dir: tmp_dir} do
      artifact = Path.join(tmp_dir, "review.md")
      claim = "All tests passed. unit: SUCCESS. lint: SUCCESS. Nothing to fix.\n"
      File.write!(artifact, claim)

      run = World.ready_run!(world, World.project!(world, [@unit]), findings: :none)
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
      assert [%{code: :pending, subject: "unit"}] = detail.reasons

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
      assert [%{code: :failing, subject: "unit", detail: "FAILURE"}] = detail.reasons
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
      World.script!(world, :list, fn
        _world, ["pr", "list" | _] -> {:reply, {"[]", 0}}
        _world, _args -> :pass
      end)

      run = World.runner(world)

      assert {"[]", 0} = run.("gh", ["pr", "list", "--head", "x"], [])
      assert {_json, 0} = run.("gh", ["pr", "view", World.pr_url(world), "--json", "state"], [])
      assert World.take_unscripted!(world) == []
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

  # the nonce a caller that never observed the PR would have to invent: no recorded observation
  # carries it
  defp checks_ref_of(_world, _run), do: "stamped-without-an-observation"

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
