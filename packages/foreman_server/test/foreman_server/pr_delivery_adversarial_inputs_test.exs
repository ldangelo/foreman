defmodule ForemanServer.PrDeliveryAdversarialInputsTest do
  # TRD-032: the gate-input scenarios of the Phase 1 adversarial suite (PRD section 5 exit rule),
  # over the shared world (`PrDeliveryWorld`, TRD-025): what the approval is decided on. Expired
  # evidence, absent, legacy, duplicated, echoed, quoted and declined findings, skipped and
  # neutral checks, truncated lists, forged evidence commands, a policy that moves between the
  # observation and the approval, a waiver that does not follow it.
  #
  # Like the other files of the suite, every scenario enters through a production entry point
  # (the operator path `CommandGateway.dispatch_operator/1`, the system path, the real observer,
  # the real finalising executor) over the real aggregate, gateway, evaluator and projection;
  # only the `gh` binary is scripted. Every scenario asserts an exact typed reason (or the
  # recorded evidence of an approval) AND that the approval did not happen, and carries a
  # CONTROL: the ONE input flipped, with the opposite outcome. The world fails a test that makes
  # a `gh` call it was not scripted for and completes every run the test left non-terminal.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.CommandGateway
  alias ForemanServer.PrEvidence
  alias ForemanServer.PrReadySignal
  alias ForemanServer.TestSupport.GateEvidence
  alias ForemanServer.TestSupport.PrDeliveryWorld, as: World
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.Workflow.RunExecutor

  @unit %{"name" => "unit", "kind" => "check_run"}
  @lint %{"name" => "lint", "kind" => "check_run"}
  @hour_ms 3_600_000

  @start "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @end_ "<!-- FOREMAN_REVIEW_FINDINGS_END -->"

  # A describe tagged `:git` gets a world whose PR head is the local tip of a real run branch (the
  # commit the finalising executor records the review of), see `artifact_run!/2`.
  setup tags do
    if tags[:git] do
      fixture = git_fixture!()
      world = World.start!(head: fixture.tip)
      PrReadySignal.set_command_runner(World.runner(world))
      on_exit(&PrReadySignal.clear_command_runner/0)
      Map.put(fixture, :world, world)
    else
      %{world: World.start!()}
    end
  end

  # -- helpers ----------------------------------------------------------------------------------

  # A gated project whose PR is ready at the world's head with a clean findings record.
  defp gated_run!(world, required \\ [@unit], opts \\ []) do
    World.ready_run!(world, World.project!(world, required), opts)
  end

  defp passing!(world), do: World.add_check!(world, World.check_run("unit"))

  # The approval is refused with exactly `codes` for `head`; the gate is still pending, nothing was
  # approved and the operator's merge is refused without any call to GitHub's merge. Returns the
  # refusal's detail.
  defp assert_refused(world, run, codes, opts \\ []) do
    head = Keyword.get_lazy(opts, :head_sha, fn -> World.head(world) end)

    assert {:error, {:evidence_ineligible, ^head, ^codes}, detail} =
             World.approve(world, run, opts)

    assert World.events(run, "MergeGateApproved") == []
    assert World.gate_pending?(run)
    refute World.gate_approved?(run)
    assert {:error, :pr_not_acceptable} = World.merge(run)
    assert World.merge_calls(world) == []
    detail
  end

  # The approval is recorded; returns the `MergeGateApproved` event.
  defp assert_approved(world, run, opts \\ []) do
    assert {:ok, _} = World.approve(world, run, opts)
    assert World.gate_approved?(run)
    assert %{} = approved = List.last(World.events(run, "MergeGateApproved"))
    approved
  end

  # `merge_approve` through the operator path with extra payload keys (a forged `evidence`).
  defp approve_with(world, run, extra) do
    World.operator(
      "run:#{run.run_id}",
      "merge_approve",
      Map.merge(
        %{
          run_id: run.run_id,
          approver: "leo",
          approver_identity: "github:ldangelo",
          head_sha: World.head(world)
        },
        extra
      )
    )
  end

  defp waive(world, run, head, codes) do
    World.operator("run:#{run.run_id}", "run.pr.waive_evidence", %{
      run_id: run.run_id,
      approver: "leo",
      approver_identity: "github:ldangelo",
      head_sha: head,
      reasons: codes,
      reason: "the check does not run for this PR",
      pr_url: World.pr_url(world)
    })
  end

  defp get(map, key), do: ForemanServer.Aggregate.get(map, key)

  defp gate_observations(run),
    do: for(e <- World.events(run, "PrChecksChanged"), get(e, :source) == "gate", do: e)

  defp policy_version!(%{project_id: project_id}) do
    assert {:ok, %{version: version}} = PrEvidence.project_policy(project_id)
    version
  end

  defp now_ms, do: System.system_time(:millisecond)

  # -- AC-001-7: expired evidence is a display label, never a reason ----------------------------

  describe "AC-001-7: expired evidence is a label of the display, never a reason" do
    for {label, hours} <- [{"two hours", 2}, {"three hours", 3}, {"a day", 24}] do
      test "a stable green PR last observed #{label} ago is approved on the forced observation",
           %{world: world} do
        run = gated_run!(world)
        passing!(world)
        aged_at = now_ms() - unquote(hours) * @hour_ms
        World.observe!(world, run, observed_at: aged_at)

        # the display says the observation is old and still reads the PR eligible
        dto = World.dto!(run)
        assert dto.checks.old == true
        assert dto.checks.stale == false
        assert dto.checks.observed_at == aged_at
        assert dto.eligibility.status == "eligible"

        approved = assert_approved(world, run)

        # the decision used the observation forced for it, not the old one: no window consulted
        assert [%{} = forced] = gate_observations(run)
        assert get(forced, :observed_at) > aged_at + unquote(hours - 1) * @hour_ms
        assert approved.evidence.status == "eligible"
        assert approved.evidence.checks_ref == get(forced, :observation_ref)
        assert approved.evidence.inputs.checks_observed_at == get(forced, :observed_at)
        assert approved.evidence.policy_version == policy_version!(run)
        assert approved.evidence.now_ms >= get(forced, :observed_at)
      end
    end

    test "CONTROL: a fresh observation carries no `old` label and the same decision", %{
      world: world
    } do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      dto = World.dto!(run)
      assert dto.checks.old == false
      assert dto.eligibility.status == "eligible"
      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "the label does not decide: an old green observation of a PR that is running again is refused `pending`",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run, observed_at: now_ms() - 3 * @hour_ms)

      # the display still says eligible (nobody observed the re-run), labelled old
      World.rerun_check!(world, "unit")
      dto = World.dto!(run)
      assert dto.checks.old == true
      assert dto.eligibility.status == "eligible"

      # the approval reads the PR for the request
      detail = assert_refused(world, run, ["pending"])
      assert [%{code: :pending, subject: "unit"}] = detail.reasons

      World.complete_check!(world, "unit", "SUCCESS")
      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "an old observation of a failing PR does not make it approvable either", %{world: world} do
      run = gated_run!(world)
      World.add_check!(world, World.check_run("unit", conclusion: "FAILURE"))
      World.observe!(world, run, observed_at: now_ms() - 3 * @hour_ms)

      assert World.dto!(run).checks.old == true
      detail = assert_refused(world, run, ["failing"])
      assert [%{code: :failing, subject: "unit"}] = detail.reasons

      World.set_rollup!(world, [World.check_run("unit")])
      assert assert_approved(world, run).evidence.status == "eligible"
    end
  end

  # -- AC-002-2: findings that are absent, legacy or malformed -----------------------------------

  describe "AC-002-2: findings that are absent, legacy or malformed at approval" do
    test "no findings record at all reads `findings_absent`; the clean record is the control", %{
      world: world
    } do
      run = gated_run!(world, [@unit], findings: :none)
      passing!(world)

      detail = assert_refused(world, run, ["findings_absent"])
      assert [%{code: :findings_absent, subject: nil}] = detail.reasons
      assert detail.inputs.findings_head_sha == nil

      :ok = World.record_findings!(world, run, World.head(world))
      approved = assert_approved(world, run)
      assert approved.evidence.status == "eligible"
      assert approved.evidence.inputs.findings_head_sha == World.head(world)
    end

    for {name, record, code, waivable?} <- [
          {"an absent record", [status: "absent"], "findings_absent", true},
          {"a legacy bullet block",
           [status: "malformed", defect: "legacy_format", defect_detail: "bullets"],
           "findings_legacy_format", true},
          {"two blocks",
           [status: "malformed", defect: "multiple_blocks", defect_detail: "two blocks"],
           "findings_malformed", false},
          {"an unterminated block",
           [status: "malformed", defect: "unterminated_block", defect_detail: "no end"],
           "findings_malformed", false}
        ] do
      test "#{name} reads `#{code}`#{if waivable?, do: ", which an operator may waive", else: ", which nobody can waive"}",
           %{world: world} do
        run = gated_run!(world, [@unit], findings: :none)
        passing!(world)
        head = World.head(world)
        :ok = World.record_findings!(world, run, head, unquote(Macro.escape(record)))

        detail = assert_refused(world, run, [unquote(code)])
        assert [%{code: code_atom}] = detail.reasons
        assert Atom.to_string(code_atom) == unquote(code)

        if unquote(waivable?) do
          assert {:ok, _} = waive(world, run, head, [unquote(code)])
          approved = assert_approved(world, run)
          assert approved.evidence.status == "waived"
          assert approved.evidence.waived == [unquote(code)]
        else
          assert {:error, {:reason_not_waivable, unquote(code)}} =
                   waive(world, run, head, [unquote(code)])

          assert World.events(run, "PrEvidenceWaived") == []
          assert_refused(world, run, [unquote(code)])

          # CONTROL: a clean record for the head
          :ok = World.record_findings!(world, run, head)
          assert assert_approved(world, run).evidence.status == "eligible"
        end
      end
    end

    test "a waiver of one findings reason covers no other: `findings_legacy_format` is not `findings_malformed`",
         %{world: world} do
      run = gated_run!(world, [@unit], findings: :none)
      passing!(world)
      head = World.head(world)

      :ok =
        World.record_findings!(world, run, head,
          status: "malformed",
          defect: "multiple_blocks",
          defect_detail: "two"
        )

      assert {:ok, _} = waive(world, run, head, ["findings_legacy_format"])
      assert_refused(world, run, ["findings_malformed"])
    end
  end

  # -- AC-002-3: a declined critical finding is still unresolved ---------------------------------

  describe "AC-002-3: a declined critical finding still counts as unresolved" do
    @critical %{
      severity: "critical",
      path: "lib/a.ex",
      line: 3,
      description: "the token is logged",
      source: "repo-rules"
    }
    @low %{
      status: "recorded",
      level: "LOW",
      rationale: "small change",
      defect: nil,
      defect_detail: nil
    }

    test "declined: risk HIGH with the finding listed, and the level alone does not refuse the approval",
         %{world: world} do
      run = gated_run!(world, [@unit], findings: :none)
      World.record_base!(run)
      passing!(world)

      :ok =
        World.record_findings!(world, run, World.head(world),
          findings: [Map.put(@critical, :disposition, "declined")],
          judgement: @low
        )

      World.observe!(world, run)

      assert %{} = risk = List.last(World.events(run, "PrRiskRecorded"))
      assert get(risk, :level) == "HIGH"
      assert [%{} = listed] = get(risk, :unresolved_findings)
      assert get(listed, :severity) == "critical"
      assert get(listed, :disposition) == "declined"

      dto = World.dto!(run)
      assert dto.risk.level == "HIGH"

      assert dto.findings.unresolved == %{
               "critical" => 1,
               "major" => 0,
               "minor" => 0,
               "nitpick" => 0
             }

      # the level is shown to the approver, it is not a reason: the approver decides (PRD §5)
      approved = assert_approved(world, run)
      assert approved.evidence.status == "eligible"
    end

    test "CONTROL: the same finding fixed leaves the judged level LOW and nothing unresolved", %{
      world: world
    } do
      run = gated_run!(world, [@unit], findings: :none)
      World.record_base!(run)
      passing!(world)

      :ok =
        World.record_findings!(world, run, World.head(world),
          findings: [Map.put(@critical, :disposition, "fixed")],
          judgement: @low
        )

      World.observe!(world, run)

      assert %{} = risk = List.last(World.events(run, "PrRiskRecorded"))
      assert get(risk, :level) == "LOW"
      assert get(risk, :unresolved_findings) == []

      assert World.dto!(run).findings.unresolved == %{
               "critical" => 0,
               "major" => 0,
               "minor" => 0,
               "nitpick" => 0
             }
    end
  end

  # -- AC-002-2 and AC-002-3: the artifact shapes, through the finalising executor --------------

  describe "AC-002-2 and AC-002-3: the shapes of a review artifact, through the finalising executor" do
    @describetag :git

    @echoed %{
      "severity" => "critical",
      "path" => "lib/old.ex",
      "line" => 1,
      "description" => "an earlier review's finding",
      "disposition" => "open",
      "source" => "repo-rules"
    }

    for {name, code, defect} <- [
          {"two marker blocks", "findings_malformed", "multiple_blocks"},
          {"an echoed earlier block followed by the real one", "findings_malformed",
           "multiple_blocks"},
          {"a legacy bullet block", "findings_legacy_format", "legacy_format"},
          {"a block that opens and is never closed", "findings_malformed", "unterminated_block"},
          {"a fence that opens inside the block and hides the end marker", "findings_malformed",
           "unterminated_block"},
          {"a fence that opens first and hides the whole block", "findings_absent", nil}
        ] do
      test "#{name}: `#{code}`, never clean", ctx do
        run = artifact_run!(ctx)
        :ok = finalize!(ctx, run, bad_artifact(unquote(name)))

        assert [%{} = recorded] = World.events(run, "ReviewFindingsRecorded")
        assert get(recorded, :findings) == []
        assert get(recorded, :defect) == unquote(defect)

        assert get(recorded, :status) ==
                 if(unquote(code) == "findings_absent", do: "absent", else: "malformed")

        detail = assert_refused(ctx.world, run, [unquote(code)])
        assert [%{code: code_atom}] = detail.reasons
        assert Atom.to_string(code_atom) == unquote(code)

        # CONTROL: one real block, nothing else, in the same place
        :ok = finalize!(ctx, run, block(doc([])))
        assert assert_approved(ctx.world, run).evidence.status == "eligible"
      end
    end

    test "the later block's content never wins: a clean block after an echoed critical one does not make it clean",
         ctx do
      run = artifact_run!(ctx)
      echoed = block(doc([@echoed]))

      :ok =
        finalize!(
          ctx,
          run,
          "Previous review:\n" <> echoed <> "\nThis review:\n" <> block(doc([]))
        )

      assert [%{} = recorded] = World.events(run, "ReviewFindingsRecorded")
      assert get(recorded, :status) == "malformed"
      assert get(recorded, :defect) == "multiple_blocks"
      assert get(recorded, :findings) == []
      assert_refused(ctx.world, run, ["findings_malformed"])
    end

    for {name, kind} <- [
          {"a code fence", :fence},
          {"a tilde fence", :tilde},
          {"an indented quote", :indent},
          {"a block quote", :quote}
        ] do
      test "marker lines quoted inside #{name} are ignored: the one real block is recorded",
           ctx do
        run = artifact_run!(ctx)
        quoted = quote_text(unquote(kind), block(doc([@echoed])))

        :ok =
          finalize!(ctx, run, "The earlier review said:\n" <> quoted <> "\n" <> block(doc([])))

        assert [%{} = recorded] = World.events(run, "ReviewFindingsRecorded")
        assert get(recorded, :status) == "recorded"
        assert get(recorded, :findings) == []
        assert assert_approved(ctx.world, run).evidence.status == "eligible"
      end
    end

    test "CONTROL: the same text outside any quote is a second block", ctx do
      run = artifact_run!(ctx)

      :ok =
        finalize!(
          ctx,
          run,
          "The earlier review said:\n" <> block(doc([@echoed])) <> "\n" <> block(doc([]))
        )

      assert [%{status: "malformed", defect: "multiple_blocks"}] =
               for(e <- World.events(run, "ReviewFindingsRecorded"), do: Map.new(e))

      assert_refused(ctx.world, run, ["findings_malformed"])
    end

    test "a legacy block is waivable, a malformed one is not", ctx do
      legacy = artifact_run!(ctx)
      :ok = finalize!(ctx, legacy, "#{@start}\n- looks fine\n#{@end_}\n")
      assert_refused(ctx.world, legacy, ["findings_legacy_format"])
      assert {:ok, _} = waive(ctx.world, legacy, ctx.tip, ["findings_legacy_format"])
      approved = assert_approved(ctx.world, legacy)
      assert approved.evidence.status == "waived"
      assert approved.evidence.waived == ["findings_legacy_format"]

      malformed = artifact_run!(ctx)
      :ok = finalize!(ctx, malformed, block(doc([])) <> block(doc([])))
      assert_refused(ctx.world, malformed, ["findings_malformed"])

      assert {:error, {:reason_not_waivable, "findings_malformed"}} =
               waive(ctx.world, malformed, ctx.tip, ["findings_malformed"])
    end
  end

  # -- AC-001-8: skipped and neutral required checks --------------------------------------------

  describe "AC-001-8: a skipped or neutral required check is not passing unless its entry allows it" do
    for conclusion <- ["SKIPPED", "NEUTRAL"] do
      test "a required check concluded #{conclusion} is `skipped`; `allow_skipped` on its own entry is the control",
           %{world: world} do
        run = gated_run!(world)
        World.add_check!(world, World.check_run("unit", conclusion: unquote(conclusion)))
        refused_version = policy_version!(run)

        detail = assert_refused(world, run, ["skipped"])
        assert [%{code: :skipped, subject: "unit", detail: unquote(conclusion)}] = detail.reasons
        assert detail.policy_version == refused_version

        World.set_required!(world, run.project_id, [Map.put(@unit, "allow_skipped", true)])
        allowed_version = policy_version!(run)
        refute allowed_version == refused_version

        approved = assert_approved(world, run)
        assert approved.evidence.status == "eligible"
        assert approved.evidence.policy_version == allowed_version
      end
    end

    test "`allow_skipped` is per entry: it does not cover another entry that was skipped", %{
      world: world
    } do
      run = gated_run!(world, [@unit, Map.put(@lint, "allow_skipped", true)])

      World.set_rollup!(world, [
        World.check_run("unit", conclusion: "SKIPPED"),
        World.check_run("lint", conclusion: "SKIPPED")
      ])

      detail = assert_refused(world, run, ["skipped"])
      assert [%{code: :skipped, subject: "unit"}] = detail.reasons

      # CONTROL: the entry that did not allow it is allowed
      World.set_required!(world, run.project_id, [
        Map.put(@unit, "allow_skipped", true),
        Map.put(@lint, "allow_skipped", true)
      ])

      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "`allow_skipped` is not `allow_failing`: a failed required check is still `failing`", %{
      world: world
    } do
      run = gated_run!(world, [Map.put(@unit, "allow_skipped", true)])
      World.add_check!(world, World.check_run("unit", conclusion: "FAILURE"))

      detail = assert_refused(world, run, ["failing"])
      assert [%{code: :failing, subject: "unit"}] = detail.reasons

      World.complete_check!(world, "unit", "SKIPPED")
      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "a skipped check is waivable (`skipped`) like a missing one, and the waiver is recorded with the approval",
         %{world: world} do
      run = gated_run!(world)
      World.add_check!(world, World.check_run("unit", conclusion: "SKIPPED"))
      assert_refused(world, run, ["skipped"])

      # a waiver of another reason does not cover it
      assert {:ok, _} = waive(world, run, World.head(world), ["missing"])
      assert_refused(world, run, ["skipped"])

      assert {:ok, _} = waive(world, run, World.head(world), ["skipped"])
      approved = assert_approved(world, run)
      assert approved.evidence.status == "waived"
      assert approved.evidence.waived == ["skipped"]
    end
  end

  # -- AC-001-8: a truncated rollup ---------------------------------------------------------------

  describe "AC-001-8: a rollup GitHub cut is not eligible unless every required check was kept" do
    test "of two required checks only the one that fell off is `checks_truncated`, and nobody can waive it",
         %{world: world} do
      run = gated_run!(world, [@unit, @lint])
      World.set_rollup!(world, [World.check_run("unit"), World.check_run("lint")])
      # one more than GitHub lists: the oldest item (`unit`) falls off, `lint` is kept
      World.truncate_rollup!(world, PrStatus.max_list() - 1)

      detail = assert_refused(world, run, ["checks_truncated"])
      assert [%{code: :checks_truncated, subject: "unit"}] = detail.reasons

      assert {:error, {:reason_not_waivable, "checks_truncated"}} =
               waive(world, run, World.head(world), ["checks_truncated"])

      # CONTROL: one filler fewer and nothing is cut: both entries are found
      World.set_rollup!(world, [World.check_run("unit"), World.check_run("lint")])
      World.truncate_rollup!(world, PrStatus.max_list() - 2)

      approved = assert_approved(world, run)
      assert approved.evidence.status == "eligible"
      assert [%{} = forced] = gate_observations(run) |> Enum.take(-1)
      assert get(forced, :checks_truncated) == false
    end
  end

  # -- AC-001-2, AC-001-7: a policy that moves between the observation and the approval ----------

  describe "AC-001-7: the approval reads the project's required checks as they stand at that moment" do
    test "a check required after the observation reads `missing`, and `pending` while it runs", %{
      world: world
    } do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)
      v1 = policy_version!(run)

      World.set_required!(world, run.project_id, [@unit, @lint])
      v2 = policy_version!(run)
      refute v1 == v2

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "lint"}] = detail.reasons
      assert detail.policy_version == v2
      assert is_binary(detail.checks_ref)

      World.add_check!(world, World.check_run("lint", status: "IN_PROGRESS"))
      detail = assert_refused(world, run, ["pending"])
      assert [%{code: :pending, subject: "lint"}] = detail.reasons

      # CONTROL: the new check passes
      World.complete_check!(world, "lint", "SUCCESS")
      approved = assert_approved(world, run)
      assert approved.evidence.policy_version == v2

      assert Enum.map(approved.evidence.required, &get(&1, :name)) |> Enum.sort() == [
               "lint",
               "unit"
             ]

      assert approved.evidence.checks_ref ==
               get(List.last(gate_observations(run)), :observation_ref)
    end

    test "a policy relaxed after the observation is read as it stands: the check that was required no longer is",
         %{world: world} do
      run = gated_run!(world, [@unit, @lint])
      World.add_check!(world, World.check_run("unit"))
      World.observe!(world, run)
      assert_refused(world, run, ["missing"])

      World.set_required!(world, run.project_id, [@unit])
      approved = assert_approved(world, run)
      assert approved.evidence.policy_version == policy_version!(run)
    end
  end

  describe "AC-001-5: a waiver follows the head and the policy version it was recorded under" do
    test "a waiver of V1 covers nothing under V2: the refusal names the reasons for both checks, the display says why, the action is offered again",
         %{world: world} do
      run = gated_run!(world)
      head = World.head(world)
      v1 = policy_version!(run)
      # one observation, so the record carries the risk of the head too: the checks are the only
      # reason, and the waiver can cover it
      World.observe!(world, run)

      assert {:ok, _} = waive(world, run, head, ["missing"])
      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      assert get(waived, :policy_version) == v1

      # under V1 the waiver applies: the display reads the PR waived
      dto = World.dto!(run)
      assert dto.eligibility.status == "waived"
      assert dto.waiver.applies == true

      World.set_required!(world, run.project_id, [@unit, @lint])
      v2 = policy_version!(run)
      refute v1 == v2

      # the display: the waiver is shown, ignored, and offered again
      dto = World.dto!(run)
      assert dto.eligibility.status == "ineligible"
      assert dto.waiver.applies == false
      assert dto.waiver.ignored_because == "policy_changed"
      assert dto.waiver.policy_version == v1
      assert dto.waiver.head_sha == head

      assert [%{action: "waive", codes: ["missing"]}] =
               Enum.filter(dto.next_actions, &(&1.action == "waive"))

      # the decision: both checks are missing and nothing is covered
      # one reason per entry: the list is not deduplicated
      detail = assert_refused(world, run, ["missing", "missing"])
      assert detail.reasons |> Enum.map(& &1.subject) |> Enum.sort() == ["lint", "unit"]
      assert detail.waived == []
      assert %{applies: false, ignored_because: :policy_changed} = detail.waiver
      assert detail.policy_version == v2

      # CONTROL: a waiver for the current head under the current version covers both
      assert {:ok, _} = waive(world, run, head, ["missing"])
      approved = assert_approved(world, run)
      assert approved.evidence.status == "waived"
      assert approved.evidence.waived == ["missing", "missing"]
      assert approved.evidence.policy_version == v2
    end

    test "the waiver stamp is the project's version at that moment: an operator-sent version is replaced",
         %{world: world} do
      run = gated_run!(world)
      head = World.head(world)

      assert {:ok, _} =
               World.operator("run:#{run.run_id}", "run.pr.waive_evidence", %{
                 run_id: run.run_id,
                 approver: "leo",
                 approver_identity: "github:ldangelo",
                 head_sha: head,
                 reasons: ["missing"],
                 reason: "the check does not run for this PR",
                 pr_url: World.pr_url(world),
                 policy_version: "0000000000000000"
               })

      assert [%{} = waived] = World.events(run, "PrEvidenceWaived")
      assert get(waived, :policy_version) == policy_version!(run)

      approved = assert_approved(world, run)
      assert approved.evidence.status == "waived"
    end
  end

  describe "AC-001-5 and AC-001-6: a policy cleared between the observation and the approval" do
    test "the next approval is `off`: it proceeds with no observation and the evidence already folded stays visible",
         %{world: world} do
      run = gated_run!(world)
      World.add_check!(world, World.check_run("unit", conclusion: "FAILURE"))
      World.observe!(world, run)
      assert [%{}] = World.events(run, "PrChecksChanged")

      # with the policy set a failing check is refused
      assert_refused(world, run, ["failing"])
      assert [%{}, %{}] = World.events(run, "PrChecksChanged")

      World.set_required!(world, run.project_id, nil)
      assert World.dto!(run).eligibility.status == "off"

      views = length(World.view_calls(world))
      approved = assert_approved(world, run)

      # off: no forced observation and no checks event, the head was the only read
      assert length(World.view_calls(world)) - views == 1
      assert [%{}, %{}] = World.events(run, "PrChecksChanged")
      assert approved.evidence.status == "off"
      assert approved.evidence.policy_version == nil
      assert approved.evidence.checks_ref == nil

      # the evidence folded earlier is still on the PR record and in the display
      dto = World.dto!(run)
      assert dto.eligibility.status == "off"
      assert [%{name: "unit", conclusion: "FAILURE"}] = dto.checks.items
      assert dto.findings.status == "recorded"
    end

    test "CONTROL: with the policy set again the same PR is refused", %{world: world} do
      run = gated_run!(world)
      World.add_check!(world, World.check_run("unit", conclusion: "FAILURE"))
      World.set_required!(world, run.project_id, nil)
      World.set_required!(world, run.project_id, [@unit])

      assert_refused(world, run, ["failing"])
    end
  end

  # -- AC-001-4, AC-004-1: forged evidence -------------------------------------------------------

  describe "AC-001-4: an `evidence` map supplied on merge_approve is dropped" do
    for {label, key} <- [{"atom", :evidence}, {"string", "evidence"}] do
      test "a #{label}-keyed gate-off stamp does not turn the gate off for a failing PR", %{
        world: world
      } do
        run = gated_run!(world)
        World.add_check!(world, World.check_run("unit", conclusion: "FAILURE"))

        forged = %{unquote(key) => %{policy: nil, checks_ref: nil, now_ms: 1}}

        assert {:error, {:evidence_ineligible, head, ["failing"]}, _detail} =
                 approve_with(world, run, forged)

        assert head == World.head(world)
        assert World.events(run, "MergeGateApproved") == []
        assert World.gate_pending?(run)

        # CONTROL: the check passes and the same forged stamp is dropped: the record holds the
        # gateway's values only
        World.set_rollup!(world, [World.check_run("unit")])
        assert {:ok, _} = approve_with(world, run, forged)
        assert [%{} = approved] = World.events(run, "MergeGateApproved")
        assert approved.evidence.policy_version == policy_version!(run)
        refute approved.evidence.now_ms == 1
        assert is_binary(approved.evidence.checks_ref)

        assert approved.evidence.checks_ref ==
                 get(List.last(gate_observations(run)), :observation_ref)
      end
    end

    test "a forged policy does not make a gate-off project gated: the approval is `off` with the gateway's stamp",
         %{world: world} do
      run = gated_run!(world, nil)

      forged = %{
        evidence: %{
          policy: %{required: [@lint], version: "forged"},
          checks_ref: "forged",
          now_ms: 1
        }
      }

      assert {:ok, _} = approve_with(world, run, forged)
      assert [%{} = approved] = World.events(run, "MergeGateApproved")
      assert approved.evidence.status == "off"
      refute approved.evidence.now_ms == 1
      assert approved.evidence.policy_version == nil
      assert approved.evidence.checks_ref == nil
      assert gate_observations(run) == []
    end
  end

  describe "AC-001-4 and AC-004-1: a forged `run.pr.checks`" do
    test "an all-green record injected into the aggregate while GitHub shows a failure is overwritten by the forced observation",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)

      # the genuine green batch of this head, built before the PR goes red
      [green] = Enum.filter(World.observation_batch!(world, run), &(&1.type == "run.pr.checks"))
      World.set_rollup!(world, [World.check_run("unit", conclusion: "FAILURE")])

      # the operator path refuses the type, the system path (in-process code) accepts it
      assert {:error, {:command_not_allowed, "run.pr.checks"}} =
               World.operator("run:#{run.run_id}", "run.pr.checks", green.payload)

      forged = %{
        green
        | command_id: "forged-green",
          payload: %{green.payload | observation_ref: "forged-ref", source: "gate"}
      }

      assert {:ok, _} = ForemanServer.CommandGateway.dispatch_system(forged)
      assert %{checks: %{observation_ref: "forged-ref"}} = World.watch_record(run).evidence

      # the approval forces its own observation over the forged record and reads the failure
      detail = assert_refused(world, run, ["failing"])
      assert [%{code: :failing, subject: "unit"}] = detail.reasons
      refute detail.checks_ref == "forged-ref"
      assert %{observation_ref: ref} = World.watch_record(run).evidence.checks
      assert ref == detail.checks_ref

      # CONTROL: the check really passes; the same approval is decided
      World.set_rollup!(world, [World.check_run("unit")])
      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "a record whose observation_ref is not the gateway's checks_ref is not counted", %{
      world: world
    } do
      run = gated_run!(world)
      passing!(world)
      batch = World.observation_batch!(world, run)
      [green] = Enum.filter(batch, &(&1.type == "run.pr.checks"))
      # the head's genuine risk record is on file, so only the checks decide
      World.dispatch_all!(Enum.filter(batch, &(&1.type == "run.pr.risk")))
      World.set_rollup!(world, [World.check_run("unit", conclusion: "FAILURE")])

      forged = %{
        green
        | command_id: "forged-ref-green",
          payload: %{green.payload | observation_ref: "forged-ref"}
      }

      assert {:ok, _} = ForemanServer.CommandGateway.dispatch_system(forged)

      # a decision that names any other ref reads the record as not the observation it decided on
      stamp = GateEvidence.gated([@unit], "the-gateways-nonce")

      assert {:error, {:evidence_ineligible, head, ["stale"]}, _} =
               World.approve_direct(run, World.head(world), stamp)

      assert head == World.head(world)
      assert World.events(run, "MergeGateApproved") == []

      # CONTROL: the ref the record carries is counted (the forger cannot know the gateway's nonce)
      assert {:ok, _} =
               World.approve_direct(
                 run,
                 World.head(world),
                 GateEvidence.gated([@unit], "forged-ref")
               )
    end
  end

  describe "AC-003-5 and AC-004-1: forged findings and risk commands, through every path that refuses them" do
    test "a findings command of another project is refused; one for another PR or another head never makes this PR's head clean",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      head = World.head(world)
      genuine = World.watch_record(run).evidence.findings
      before = length(World.events(run, "ReviewFindingsRecorded"))

      base = %{
        run_id: run.run_id,
        project_id: run.project_id,
        task_id: run.task_id,
        pr_url: run.pr_url,
        head_sha: head,
        status: "recorded",
        findings: [],
        defect: nil,
        defect_detail: nil,
        artifact_path: "/w/forged.md",
        artifact_sha256: String.duplicate("c", 64),
        recorded_at: now_ms()
      }

      findings_command = fn name, payload ->
        %{
          type: "run.pr.findings",
          command_id: "forged-findings-#{String.replace(name, " ", "-")}",
          aggregate_id: "run:#{run.run_id}",
          payload: payload
        }
      end

      other_pr = "https://github.com/acme/other/pull/9"

      assert {:error, _reason} =
               CommandGateway.dispatch_system(
                 findings_command.("another project", %{base | project_id: "project-forged"})
               )

      assert length(World.events(run, "ReviewFindingsRecorded")) == before

      # a record for ANOTHER PR is that PR's: it leaves the record of this PR as it was
      assert {:ok, _} =
               CommandGateway.dispatch_system(
                 findings_command.("another pr", %{base | pr_url: other_pr})
               )

      assert World.watch_record(run).evidence.findings == genuine

      # a record for ANOTHER head is a record, bound to that head: it does not clean this one
      assert {:ok, _} =
               CommandGateway.dispatch_system(
                 findings_command.("another head", %{base | head_sha: "head-forged"})
               )

      detail = assert_refused(world, run, ["findings_other_sha"])
      assert detail.inputs.findings_head_sha == "head-forged"
      assert World.dto!(run).findings.current == false

      # CONTROL: the genuine record of the PR's head is decided
      assert {:ok, _} =
               CommandGateway.dispatch_system(
                 findings_command.("genuine", %{base | recorded_at: base.recorded_at + 1})
               )

      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "a forged risk command for another PR or project is refused and the rubric's record stands",
         %{world: world} do
      World.set_files!(world, [{".env.production", 1, 0}])
      run = gated_run!(world)
      passing!(world)
      batch = World.observation_batch!(world, run)
      risk = Enum.find(batch, &(&1.type == "run.pr.risk"))
      World.dispatch_all!(Enum.reject(batch, &(&1.type == "run.pr.risk")))

      for {name, key, value} <- [
            {"another pr", :pr_url, "https://github.com/acme/other/pull/9"},
            {"another project", :project_id, "project-forged"}
          ] do
        forged = %{
          risk
          | command_id: "forged-risk-#{String.replace(name, " ", "-")}",
            payload: Map.put(risk.payload, key, value)
        }

        assert {:error, _reason} = ForemanServer.CommandGateway.dispatch_system(forged),
               "a risk command for #{name} was accepted"
      end

      assert World.events(run, "PrRiskRecorded") == []

      # CONTROL: the genuine command records the rubric's HIGH for a secret-named file
      assert {:ok, _} = ForemanServer.CommandGateway.dispatch_system(risk)
      assert [%{} = recorded] = World.events(run, "PrRiskRecorded")
      assert get(recorded, :level) == "HIGH"
    end
  end

  # -- AC-001-7: the interleave of a push and the approval ---------------------------------------

  describe "AC-001-7 and AC-004-2: a push between the gateway's read and the pin" do
    test "the approval is for the head that was read; run.pr.merge then refuses the head that moved",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      head_one = World.head(world)

      # the push lands right after the gateway's read of head-one: the approval is decided on it
      World.push_after_next_view!(world, "head-two")
      approved = assert_approved(world, run, head_sha: head_one)

      assert approved.head_sha == head_one
      assert approved.evidence.inputs.checks_head_sha == head_one
      assert approved.evidence.status == "eligible"
      assert World.head(world) == "head-two"

      # the approval is for head-one ONLY: the merge reads head-two and is refused, GitHub is never asked
      assert {:error, {:head_moved_since_approval, ^head_one, "head-two"}} = World.merge(run)
      assert World.merge_calls(world) == []
      assert World.pr_state(world) == "OPEN"

      # CONTROL: no push, the same approval merges
      other = gated_run!(world)
      World.set_rollup!(world, [])
      World.push!(world, "head-three")
      :ok = World.record_findings!(world, other, "head-three")
      passing!(world)
      assert assert_approved(world, other, head_sha: "head-three").head_sha == "head-three"
      assert {:ok, _} = World.merge(other)
      assert [[_, _, _, _, _, "head-three"]] = World.merge_calls(world)
    end

    test "evidence of an observed head cannot approve the pushed one: the gateway observes the new head itself",
         %{world: world} do
      run = gated_run!(world)
      passing!(world)
      World.observe!(world, run)

      World.push!(world, "head-two")
      :ok = World.record_findings!(world, run, "head-two")

      # head-one's pass does not carry; the new head's own observation reads `missing`
      detail = assert_refused(world, run, ["missing"], head_sha: "head-two")
      assert detail.inputs.checks_head_sha == "head-two"

      passing!(world)
      approved = assert_approved(world, run, head_sha: "head-two")
      assert approved.evidence.inputs.checks_head_sha == "head-two"
    end
  end

  # -- AC-001-4: evidence of another workflow -----------------------------------------------------

  describe "AC-001-4: a check of another workflow is not the entry's check" do
    test "the same name in another workflow reads `missing` when the entry names its workflow; naming it is the control",
         %{world: world} do
      entry = Map.put(@unit, "workflow", "ci")
      run = gated_run!(world, [entry])
      World.add_check!(world, World.check_run("unit", workflow: "nightly"))

      detail = assert_refused(world, run, ["missing"])
      assert [%{code: :missing, subject: "unit"}] = detail.reasons

      World.add_check!(world, World.check_run("unit", workflow: "ci"))
      assert assert_approved(world, run).evidence.status == "eligible"
    end

    test "a failing check of another workflow does not fail an entry that names its own workflow",
         %{world: world} do
      entry = Map.put(@unit, "workflow", "ci")
      run = gated_run!(world, [entry])

      World.set_rollup!(world, [
        World.check_run("unit", workflow: "nightly", conclusion: "FAILURE"),
        World.check_run("unit", workflow: "ci")
      ])

      assert assert_approved(world, run).evidence.status == "eligible"

      # CONTROL: an entry that names no workflow sees both, and the failing one counts
      other = gated_run!(world, [@unit])
      assert_refused(world, other, ["failing"])
    end
  end

  # -- the finalising executor, for the artifact scenarios ---------------------------------------

  defp artifact_run!(%{world: world}) do
    run = World.start_run!(world, World.project!(world, [@unit]))
    World.add_check!(world, World.check_run("unit"))

    ForemanServer.ProjectionStore.apply_events([
      %{
        event_type: "PhasePrRecorded",
        payload: %{
          run_id: run.run_id,
          phase_id: "#{run.run_id}-p001",
          phase_index: 1,
          phase_name: "review",
          status: "existing",
          pr_url: World.pr_url(world),
          pr_number: 1,
          base_branch: "main",
          head_branch: "foreman/run-branch",
          provider: "github",
          recorded_at: "2026-01-01T00:00:01Z"
        }
      }
    ])

    %{run | pr_url: World.pr_url(world)}
  end

  # The real finalisation of a run (`RunExecutor`): the artifact is read once and the typed outcome
  # reaches the aggregate through `run.pr.findings`.
  defp finalize!(ctx, run, contents) do
    path = Path.join(ctx.repo, "artifact-#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)

    state = %{
      run_id: run.run_id,
      task: %{task_id: run.task_id, project_id: run.project_id},
      plan_context: %{"project_root" => ctx.repo},
      run_base_branch: {:ok, "main"},
      last_worktree: %{branch: "foreman/run-branch"},
      current_phase: 0,
      phase_specs: [%{artifact_template: path}]
    }

    assert [{_repo, {:ok, url}}] = RunExecutor.__finalize_repo_prs_for_test__(state)
    assert url == World.pr_url(ctx.world)
    :ok
  end

  defp git_fixture! do
    repo = Path.join(System.tmp_dir!(), "adv-inputs-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    git!(repo, ["checkout", "--quiet", "-b", "foreman/run-branch"])
    File.write!(Path.join(repo, "work.txt"), "work")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "work", "--quiet"])
    tip = git!(repo, ["rev-parse", "foreman/run-branch"])
    git!(repo, ["checkout", "--quiet", "main"])
    on_exit(fn -> File.rm_rf(repo) end)
    %{repo: repo, tip: tip}
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp doc(findings) do
    %{"schema" => "foreman.review_findings/1", "reviewed" => true, "findings" => findings}
  end

  defp block(json) when is_map(json), do: block(Jason.encode!(json))
  defp block(text), do: "#{@start}\n#{text}\n#{@end_}\n"

  defp bad_artifact("two marker blocks"), do: block(doc([@echoed])) <> block(doc([]))

  defp bad_artifact("an echoed earlier block followed by the real one"),
    do: "Earlier:\n" <> block(doc([@echoed])) <> "\nNow:\n" <> block(doc([]))

  defp bad_artifact("a legacy bullet block"), do: "#{@start}\n- looks fine\n* nothing\n#{@end_}\n"

  defp bad_artifact("a block that opens and is never closed"),
    do: "#{@start}\n" <> Jason.encode!(doc([])) <> "\n"

  defp bad_artifact("a fence that opens inside the block and hides the end marker"),
    do: "#{@start}\n" <> Jason.encode!(doc([])) <> "\n```\n#{@end_}\n"

  defp bad_artifact("a fence that opens first and hides the whole block"),
    do: "```\n" <> block(doc([]))

  defp quote_text(:fence, text), do: "```\n#{text}\n```\n"
  defp quote_text(:tilde, text), do: "~~~markdown\n#{text}\n~~~\n"

  defp quote_text(:indent, text),
    do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  defp quote_text(:quote, text),
    do: text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
end
