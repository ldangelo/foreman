defmodule ForemanServer.PrDeliveryAdversarialKeysTest do
  # TRD-040: the fork-PR adoption and the keyed-effect scenarios of the Phase 1 adversarial suite
  # (PRD section 5, preconditions P-1 and P-2, design rule P-4), over the shared world
  # (`PrDeliveryWorld`, TRD-025) with its real `git`, the `gh pr create` and crash points of
  # `EffectWorld` and the boot sweep over the world's GitHub.
  #
  # Every scenario enters through a production entry point (the operator's Create PR through
  # `CommandGateway.dispatch_operator/1`, `PrCreate.execute/1`, `PhasePR.maybe_create/1`, the real
  # `PrReport.Publisher`, the real boot sweep with the real reconcilers) and asserts the exact typed
  # outcome, the evidence it recorded and the number of `gh pr create` or comment-write calls the
  # world received. Each carries a CONTROL: one input flipped (the PR is this repository's, the head
  # is the tip, the list call answers, the crash is on the other side of the effect) with the
  # opposite outcome, so a refusal cannot be a harness that refuses everything.
  #
  # "calls" count what reached the world, parked or refused calls included; "executed" counts what
  # reached GitHub and made something (`EffectWorld.executed/2`).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.{Aggregate, CommandGateway, PrCreate, ProjectionStore, RunControl}
  alias ForemanServer.Idempotency.{Effect, KeyStore}
  alias ForemanServer.Idempotency.Reconcilers.{BranchPush, PrComment}
  alias ForemanServer.Idempotency.Reconcilers.PrCreate, as: CreateEffect
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{EffectWorld, PrWatchSupport}
  alias ForemanServer.TestSupport.PrDeliveryWorld, as: World
  alias ForemanServer.Workflow.{BootReconciliation, PhasePR}
  alias ForemanServerWeb.MCP.Tools.Doctor

  @terminal_event [:foreman_server, :workflow, :boot_reconciliation, :effect_on_terminal_run]
  @effect_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]
  @unit %{"name" => "unit", "kind" => "check_run"}
  @other_head String.duplicate("b", 40)

  setup do
    world = World.start!()
    World.effects!(world)
    {handler_id, ref} = Handler.attach_event_handlers(self(), [@terminal_event, @effect_event])
    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{world: world, ref: ref}
  end

  # -- helpers ----------------------------------------------------------------------------------

  defp create_key(run), do: CreateEffect.key(run.run_id, run.branch, run.base)
  defp push_key(run), do: BranchPush.key(run.run_id, run.branch)

  # The `gh pr create` calls the world received for this run's branch.
  defp creates_for(world, run) do
    Enum.filter(World.create_calls(world), &(["--head", run.branch] in pairs(&1)))
  end

  defp pairs(args), do: Enum.chunk_every(args, 2, 1, :discard)

  # Every PR url an event of the run names.
  defp urls_named(run) do
    for event <- PrWatchSupport.run_events(run.run_id),
        url = Aggregate.get(Aggregate.event_payload(event), :pr_url),
        is_binary(url),
        uniq: true,
        do: url
  end

  defp event_types(run), do: PrWatchSupport.run_event_types(run.run_id)

  # A completed run whose `gh pr create` window crashed on `side` of the create: the key is
  # `started` and nobody has looked at it.
  defp crash_create!(world, run, side) do
    World.crash!(world, :create, side, fn -> PrCreate.execute(run.run_id) end)
    assert {:ok, :started} = KeyStore.status(create_key(run))
  end

  # What the sweep reports for a key of a run that ended: the verdict and why a block was not
  # possible, and the counters of the sweep (`deferred_unknown` is 0 unless the counters say).
  defp assert_terminal_verdict(ref, run, verdict, reason, counters, class \\ "pr_create") do
    assert_receive {@terminal_event, ^ref, %{count: 1},
                    %{
                      run_id: run_id,
                      status: "completed",
                      effect_class: ^class,
                      effect_verdict: ^verdict,
                      reason: ^reason
                    }}

    assert run_id == run.run_id

    counters = Map.put_new(counters, :deferred_unknown, 0)
    assert_receive {@effect_event, ^ref, ^counters, _}
  end

  # -- the lookup adopts only this repository's PR with the pushed tip (P-2) ----------------------

  describe "Create PR: a PR is the run's only when it is this repository's and has the pushed tip" do
    test "a fork's PR of the same branch name and tip is never adopted: the run opens its own PR",
         %{world: world} do
      run = World.delivery_run!(world)
      fork = World.open_by_hand!(world, run, cross_repository: true)
      assert World.head(World.pr(world, fork)) == World.tip(run)

      assert {:ok, _} = World.create_pr(run)

      own = World.created_url!(run)
      refute own == fork
      assert World.created_prs(world) == [own]
      assert {:ok, %{pr_url: ^own}} = ProjectionStore.pr_association(run.run_id)

      # one push, one create: the fork's PR was not a PR for the run
      assert length(World.push_calls(world)) == 1
      assert length(creates_for(world, run)) == 1
      assert World.executed(world, :create) == 1

      # nothing the run recorded names the fork, and no gate is held for it
      assert urls_named(run) == [own]
      assert World.pr_state(World.pr(world, fork)) == "OPEN"

      # CONTROL: the same PR, this repository's: adopted, nothing pushed or created for the run
      other = World.delivery_run!(world)
      mine = World.open_by_hand!(world, other)

      assert {:ok, _} = World.create_pr(other)

      assert World.created_url!(other) == mine
      assert {:ok, %{pr_url: ^mine}} = ProjectionStore.pr_association(other.run_id)
      assert creates_for(world, other) == []
      assert World.remote_tip(other) == nil
      assert length(World.push_calls(world)) == 1
      assert World.executed(world, :create) == 1
    end

    test "a PR of the branch with another head is refused with both heads and nothing is associated or gated",
         %{world: world} do
      run = World.delivery_run!(world)
      other = World.open_by_hand!(world, run, head: @other_head)
      tip = World.tip(run)

      assert {:error, {:pr_lookup_mismatch, ^other, ^tip, @other_head}} = World.create_pr(run)

      assert {:error, :not_found} = ProjectionStore.pr_association(run.run_id)
      assert urls_named(run) == []
      assert Enum.all?(~w(PrCreated PrAssociated PrReady), &(&1 not in event_types(run)))
      refute World.gate_pending?(run)

      # GitHub refused the create (the PR exists) and made nothing; the run's branch was pushed
      assert length(creates_for(world, run)) == 1
      assert World.executed(world, :create) == 0
      assert World.created_prs(world) == []
      assert World.remote_tip(run) == tip

      # CONTROL: the same PR with the pushed tip is the run's
      control = World.delivery_run!(world)
      mine = World.open_by_hand!(world, control)

      assert {:ok, _} = World.create_pr(control)

      assert World.created_url!(control) == mine
      assert {:ok, %{pr_url: ^mine}} = ProjectionStore.pr_association(control.run_id)
      assert creates_for(world, control) == []
    end
  end

  describe "the phase PR: the same adoption rules" do
    test "a fork's PR is not reused and the phase opens its own; a PR with another head is the typed mismatch",
         %{world: world} do
      run = World.phase_run!(world)
      fork = World.open_by_hand!(world, run, cross_repository: true)

      assert {:ok, %PhasePR.Record{status: "created", pr_url: own}} =
               PhasePR.maybe_create(run.request)

      refute own == fork
      assert World.created_prs(world) == [own]
      assert World.executed(world, :create) == 1

      # a second phase run: this repository's PR with another head
      other_run = World.phase_run!(world)
      other = World.open_by_hand!(world, other_run, head: @other_head)
      tip = World.tip(other_run)

      assert {:error,
              %PhasePR.Error{
                reason: :pr_lookup_mismatch,
                details: %{url: ^other, expected_head: ^tip, actual_head: @other_head}
              }} = PhasePR.maybe_create(other_run.request)

      assert World.created_prs(world) == [own]
      assert World.executed(world, :create) == 1

      # CONTROL: with the tip it is this repository's PR and is reused
      control = World.phase_run!(world)
      mine = World.open_by_hand!(world, control)

      assert {:ok, %PhasePR.Record{status: "existing", pr_url: ^mine}} =
               PhasePR.maybe_create(control.request)

      assert World.executed(world, :create) == 1
    end
  end

  # -- a completed run whose keys the sweep cannot act on (TRD-039) --------------------------------

  describe "a completed run whose gh pr create crashed" do
    test "not_done: the key is decided, the audit event is rejected (audit_failed) and Create PR opens the PR once",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = create_key(run)
      crash_create!(world, run, :before)
      assert World.executed(world, :create) == 0
      assert length(creates_for(world, run)) == 1

      # nobody has looked at the key: it is undecided, and it is refused as such
      assert {:error, {:effect_undecided, ^key}} = World.create_pr(run)

      World.sweep!(world)

      assert_terminal_verdict(ref, run, "not_done", nil, %{
        audit_failed: 1,
        on_terminal_run: 0,
        retried: 0,
        blocked: 0,
        unresolved: 0,
        skipped: 0
      })

      # the rejected audit command appended nothing, and the decision stands
      refute "RunRecoveryAttempted" in event_types(run)
      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert KeyStore.unresolved_version(decided) == :none

      assert {:ok, _} = World.create_pr(run)

      own = World.created_url!(run)
      assert World.created_prs(world) == [own]
      assert World.executed(world, :create) == 1
      # the parked call and the retry: two calls, one PR
      assert length(creates_for(world, run)) == 2
      assert {:ok, :completed} = KeyStore.status(key)

      # once: the run has its PR, a repeated Create PR is refused and makes no call
      assert {:error, {:pr_already_associated, ^own}} = PrCreate.execute(run.run_id)
      assert length(creates_for(world, run)) == 2

      # CONTROL: the crash on the other side of the create is a different verdict
      after_run = World.delivery_run!(world)
      crash_create!(world, after_run, :after)
      assert World.executed(world, :create) == 2

      World.sweep!(world)

      assert_terminal_verdict(ref, after_run, "done", "effect_already_done", %{
        on_terminal_run: 1,
        audit_failed: 0,
        retried: 0,
        blocked: 0,
        unresolved: 0,
        skipped: 0
      })
    end

    test "done: marked unresolved, the block is rejected (on_terminal_run) and Create PR returns GitHub's PR with no gh pr create",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = create_key(run)
      crash_create!(world, run, :after)
      assert [made] = World.created_prs(world)
      assert World.executed(world, :create) == 1
      {_state, version} = Aggregate.load(ForemanServer.Aggregates.Run, "run:#{run.run_id}")
      before_types = event_types(run)

      World.sweep!(world)

      assert_terminal_verdict(ref, run, "done", "effect_already_done", %{
        on_terminal_run: 1,
        blocked: 0,
        audit_failed: 0,
        retried: 0,
        unresolved: 0,
        skipped: 0
      })

      # the rejected block appended nothing and cancelled nothing
      assert event_types(run) == before_types
      assert RunControl.intent(run.run_id) == nil
      assert {:ok, %{status: :ambiguous, metadata: marked}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(marked) == {:ok, version}
      assert marked["unresolved_reason"] == "effect_already_done"

      # the effect is refused ...
      meta = CreateEffect.intent(run.run_id, run.branch, run.base, run.repo)

      assert {:error, {:effect_unresolved, ^key}} =
               Effect.run(:pr_create, key, fn -> flunk("repeated") end, meta)

      # ... and Create PR returns the PR GitHub has: the lookup, before the effect's preflight
      assert {:ok, _} = World.create_pr(run)

      assert World.created_url!(run) == made
      assert World.created_prs(world) == [made]
      assert World.executed(world, :create) == 1
      assert length(creates_for(world, run)) == 1
      assert {:ok, %{status: :completed, metadata: settled}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(settled) == :none

      # CONTROL: a create that did not happen leaves nothing to return, and Create PR makes it
      control = World.delivery_run!(world)
      crash_create!(world, control, :before)
      World.sweep!(world)
      assert {:ok, _} = World.create_pr(control)
      assert length(creates_for(world, control)) == 2
      assert World.executed(world, :create) == 2
    end

    test "done but merged since: the lookup cannot adopt it, Create PR stays refused effect_unresolved and creates nothing",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = create_key(run)
      crash_create!(world, run, :after)
      assert [made] = World.created_prs(world)
      World.set_state!(World.pr(world, made), "MERGED")

      World.sweep!(world)

      assert_terminal_verdict(ref, run, "done", "effect_already_done", %{
        on_terminal_run: 1,
        blocked: 0,
        audit_failed: 0,
        retried: 0,
        unresolved: 0,
        skipped: 0
      })

      assert {:error, {:effect_unresolved, ^key}} = World.create_pr(run)

      assert World.executed(world, :create) == 1
      assert length(creates_for(world, run)) == 1
      assert {:error, :not_found} = ProjectionStore.pr_association(run.run_id)
      assert {:ok, %{status: :ambiguous}} = KeyStore.get(key)

      # the key is listed for the operator, who finds the PR on GitHub
      assert {:ok, entries} = Doctor.unresolved_effect_keys()
      assert %{class: "pr_create", status: "completed"} = Enum.find(entries, &(&1.key == key))

      # CONTROL: the same PR still open is returned
      control = World.delivery_run!(world)
      crash_create!(world, control, :after)
      World.sweep!(world)
      assert {:ok, _} = World.create_pr(control)
      assert [_merged, open] = World.created_prs(world)
      assert World.created_url!(control) == open
    end

    test "unknown: effect_undecided, then effect_unresolved after any sweep, listed by the doctor; a PR opened by hand is adopted",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = create_key(run)
      crash_create!(world, run, :before)
      World.fail_gh!(world, :list)

      # the sweep has not looked at the key, and GitHub cannot say more
      assert {:error, {:effect_undecided, ^key}} = World.create_pr(run)

      World.sweep!(world)

      assert_terminal_verdict(ref, run, "unknown", "effect_outcome_ambiguous", %{
        on_terminal_run: 1,
        unresolved: 0,
        blocked: 0,
        audit_failed: 0,
        retried: 0,
        skipped: 0
      })

      # undecided only applies before the sweep: from now on the key is unresolved, for good
      assert {:error, {:effect_unresolved, ^key}} = World.create_pr(run)
      World.sweep!(world)
      assert {:error, {:effect_unresolved, ^key}} = World.create_pr(run)

      assert {:ok, entries} = Doctor.unresolved_effect_keys()
      run_id = run.run_id

      assert %{
               class: "pr_create",
               run_id: ^run_id,
               status: "completed",
               key_status: "ambiguous",
               decision: "none"
             } = Enum.find(entries, &(&1.key == key))

      assert World.executed(world, :create) == 0
      assert length(creates_for(world, run)) == 1

      # the operator opens the PR by hand; GitHub answers again and the lookup adopts it
      by_hand = World.open_by_hand!(world, run)
      World.heal_gh!(world, :list)

      assert {:ok, _} = World.create_pr(run)

      assert World.created_url!(run) == by_hand
      assert World.executed(world, :create) == 0
      assert length(creates_for(world, run)) == 1
      assert {:ok, :completed} = KeyStore.status(key)

      # CONTROL: the same crash with GitHub answering is decided not_done, and Create PR creates
      control = World.delivery_run!(world)
      crash_create!(world, control, :before)
      World.sweep!(world)

      assert_terminal_verdict(ref, control, "not_done", nil, %{
        audit_failed: 1,
        on_terminal_run: 0,
        retried: 0,
        blocked: 0,
        unresolved: 0,
        skipped: 0
      })

      assert {:ok, _} = World.create_pr(control)
      assert World.executed(world, :create) == 1
    end
  end

  describe "a completed run whose branch push crashed" do
    test "done: the push key stays refused, Create PR names it and creates nothing; a PR opened by hand is returned",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = push_key(run)

      World.crash!(world, :push, :after, fn -> PrCreate.execute(run.run_id) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert World.remote_tip(run) == World.tip(run)

      World.sweep!(world)

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        status: "completed",
                        effect_class: "branch_push",
                        effect_verdict: "done",
                        reason: "effect_already_done"
                      }}

      assert {:error, {:effect_unresolved, ^key}} = World.create_pr(run)
      assert {:error, {:run_not_resettable, "completed"}} = reset(run)
      assert World.executed(world, :push) == 1
      assert World.executed(world, :create) == 0
      assert creates_for(world, run) == []

      by_hand = World.open_by_hand!(world, run)

      assert {:ok, _} = World.create_pr(run)

      assert World.created_url!(run) == by_hand
      assert World.executed(world, :push) == 1
      assert creates_for(world, run) == []

      # CONTROL: a push that never reached the remote is decided not_done and is pushed once
      control = World.delivery_run!(world)
      World.crash!(world, :push, :before, fn -> PrCreate.execute(control.run_id) end)
      assert World.remote_tip(control) == nil
      World.sweep!(world)
      assert {:ok, _} = World.create_pr(control)
      assert World.remote_tip(control) == World.tip(control)
      assert World.executed(world, :push) == 2
    end
  end

  describe "a running run's phase PR keys" do
    test "a push that reached the remote blocks the run and is not pushed again; one that did not is retried and pushed once",
         %{world: world} do
      run = World.phase_run!(world)
      World.crash!(world, :push, :after, fn -> PhasePR.maybe_create(run.request) end)
      key = push_key(run)
      assert {:ok, :started} = KeyStore.status(key)

      World.sweep!(world)

      assert EffectWorld.status(run.run_id) == "blocked"
      assert EffectWorld.block_reason(run.run_id) == "effect_already_done"
      assert World.executed(world, :push) == 1
      assert World.executed(world, :create) == 0
      assert {:ok, :ambiguous} = KeyStore.status(key)

      # CONTROL: the push that did not reach the remote is retried, not blocked
      control = World.phase_run!(world)
      World.crash!(world, :push, :before, fn -> PhasePR.maybe_create(control.request) end)
      assert World.remote_tip(control) == nil

      World.sweep!(world)

      assert EffectWorld.status(control.run_id) != "blocked"
      assert EffectWorld.recovery_outcomes(control.run_id) == ["effect_retried"]
      assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(control.request)
      assert World.remote_tip(control) == World.tip(control)
      assert World.executed(world, :push) == 2
      assert World.executed(world, :create) == 1
    end

    test "a create GitHub made blocks the run and no second PR is created; one that never ran is retried and creates once",
         %{world: world} do
      run = World.phase_run!(world)
      World.crash!(world, :create, :after, fn -> PhasePR.maybe_create(run.request) end)
      assert World.executed(world, :create) == 1

      World.sweep!(world)

      assert EffectWorld.status(run.run_id) == "blocked"
      assert EffectWorld.block_reason(run.run_id) == "effect_already_done"
      assert length(World.created_prs(world)) == 1
      assert {:ok, :ambiguous} = KeyStore.status(create_key(run))

      # CONTROL
      control = World.phase_run!(world)
      World.crash!(world, :create, :before, fn -> PhasePR.maybe_create(control.request) end)
      World.sweep!(world)

      assert EffectWorld.status(control.run_id) != "blocked"
      assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(control.request)
      assert length(World.created_prs(world)) == 2
      assert World.executed(world, :create) == 2
    end
  end

  # -- the pr_comment key never decides the fate of a run (TRD-002, TRD-039) -----------------------

  describe "a pr_comment key a crash left behind" do
    # A gated run on a world with a publisher; the publisher's post parks on `side` of the comment
    # write and the publisher's task is killed there. Returns the run and the comment's key.
    defp crashed_post!(world, publisher, side) do
      pr = World.add_pr!(world, head: "head-" <> Base.encode16(:crypto.strong_rand_bytes(3)))
      World.add_check!(World.pr(world, pr), World.check_run("unit"))
      run = World.ready_run!(world, World.project!(world, [@unit]), pr: pr)

      World.park_next_comment_write!(world, side)
      World.observe!(world, run)
      World.kill_parked!(World.await_parked!(side))
      World.settle_publisher!(publisher)

      digest = run |> World.events("PrRiskRecorded") |> List.last() |> Aggregate.get(:digest)
      key = PrComment.key(run.run_id, World.head(World.pr(world, pr)), digest)
      assert {:ok, :started} = KeyStore.status(key)
      {run, key}
    end

    defp live?(run), do: match?(%{terminal?: false}, ProjectionStore.run(run.run_id))

    test "done: the sweep counts the key skipped, the run keeps running and the publisher is not refused",
         %{world: world, ref: ref} do
      publisher = World.publisher!(world)
      {run, key} = crashed_post!(world, publisher, :after)
      assert length(World.comment_writes(world)) == 1
      before_types = event_types(run)

      World.sweep!(world)

      assert_receive {@effect_event, ^ref,
                      %{
                        skipped: 1,
                        deferred_unknown: 0,
                        on_terminal_run: 0,
                        blocked: 0,
                        retried: 0,
                        audit_failed: 0,
                        unresolved: 0
                      }, _}

      refute_received {@terminal_event, ^ref, _, _}
      assert event_types(run) == before_types
      assert RunControl.intent(run.run_id) == nil
      assert live?(run)
      # orphaned (its writer is dead), never marked unresolved or decided
      assert {:ok, %{status: :ambiguous, metadata: left}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(left) == :none
      assert KeyStore.decision(left) == :none

      # the operator asks for the report again: the publisher adopts the comment it finds
      assert {:ok, _} = request_report(run)
      assert [published] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert Aggregate.get(published, :status) == "published"
      assert length(World.comment_writes(world)) == 1
      assert length(World.comments(World.pr(world, run.pr_url))) == 1
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "unknown: GitHub cannot be read, the key is skipped and the publisher writes the report afterwards",
         %{world: world, ref: ref} do
      publisher = World.publisher!(world)
      {run, key} = crashed_post!(world, publisher, :before)
      assert World.comments(world) == []
      before_types = event_types(run)
      pr = World.pr(world, run.pr_url)

      World.fail_gh!(world, :view)
      World.sweep!(world)
      World.heal_gh!(world, :view)

      assert_receive {@effect_event, ^ref,
                      %{skipped: 1, on_terminal_run: 0, blocked: 0, deferred_unknown: 0}, _}

      refute_received {@terminal_event, ^ref, _, _}
      assert event_types(run) == before_types
      assert RunControl.intent(run.run_id) == nil
      assert live?(run)
      assert {:ok, %{status: :ambiguous, metadata: left}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(left) == :none
      assert KeyStore.decision(left) == :none

      assert {:ok, _} = request_report(run)
      assert [published] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert Aggregate.get(published, :status) == "published"
      assert [%{"body" => body}] = World.comments(pr)
      assert {:ok, %{run_id: run_id}} = ForemanServer.PrReport.parse_marker(body)
      assert run_id == run.run_id
      # the parked write and the one that wrote
      assert length(World.comment_writes(world)) == 2
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "CONTROL: not_done decides the key like any other class and the next post writes", %{
      world: world,
      ref: ref
    } do
      publisher = World.publisher!(world)
      {run, key} = crashed_post!(world, publisher, :before)

      World.sweep!(world)

      assert_receive {@effect_event, ^ref, %{retried: 1, skipped: 0, unresolved: 0}, _}
      assert "RunRecoveryAttempted" in event_types(run)
      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert live?(run)

      assert {:ok, _} = request_report(run)
      assert [published] = World.await_publications!(run, 1)
      World.settle_publisher!(publisher)
      assert Aggregate.get(published, :status) == "published"
      assert length(World.comments(World.pr(world, run.pr_url))) == 1
    end

    defp request_report(run) do
      World.operator("run:#{run.run_id}", "run.pr.publish_report", %{
        run_id: run.run_id,
        project_id: run.project_id,
        task_id: run.task_id,
        pr_url: run.pr_url
      })
    end
  end

  describe "a pr_comment key on a run that has ended" do
    # The run ended while the comment's key was `started`: the sweep never marks, blocks or cancels
    # for a class that never blocks a run, so a terminal run is left exactly as it is.
    defp ended_after_crash!(world, publisher, side) do
      {run, key} = crashed_post!(world, publisher, side)
      PrWatchSupport.complete_run!(run.run_id, run.project_id)
      assert %{terminal?: true} = ProjectionStore.run(run.run_id)
      {run, key}
    end

    for {side, verdict} <- [after: "done", before: "unknown"] do
      test "#{verdict}: the key is skipped, the ended run is untouched and the report can still be published",
           %{world: world, ref: ref} do
        publisher = World.publisher!(world)
        {run, key} = ended_after_crash!(world, publisher, unquote(side))
        before_types = event_types(run)
        if unquote(verdict) == "unknown", do: World.fail_gh!(world, :view)

        World.sweep!(world)
        World.heal_gh!(world, :view)

        assert_receive {@effect_event, ^ref,
                        %{
                          skipped: 1,
                          on_terminal_run: 0,
                          audit_failed: 0,
                          retried: 0,
                          blocked: 0,
                          unresolved: 0,
                          deferred_unknown: 0
                        }, _}

        refute_received {@terminal_event, ^ref, _, _}
        assert event_types(run) == before_types
        assert RunControl.intent(run.run_id) == nil
        assert %{terminal?: true} = ProjectionStore.run(run.run_id)
        assert {:ok, %{status: :ambiguous, metadata: left}} = KeyStore.get(key)
        assert KeyStore.unresolved_version(left) == :none
        assert KeyStore.decision(left) == :none

        assert {:ok, _} = request_report(run)
        assert [published] = World.await_publications!(run, 1)
        World.settle_publisher!(publisher)
        assert Aggregate.get(published, :status) == "published"
        assert length(World.comments(World.pr(world, run.pr_url))) == 1
        assert {:ok, :completed} = KeyStore.status(key)
      end
    end

    test "CONTROL: not_done of the same key is decided and the audit event rejected: the ended run is still untouched",
         %{world: world, ref: ref} do
      publisher = World.publisher!(world)
      {run, key} = ended_after_crash!(world, publisher, :before)
      before_types = event_types(run)

      World.sweep!(world)

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        run_id: run_id,
                        status: "completed",
                        effect_class: "pr_comment",
                        effect_verdict: "not_done",
                        reason: nil
                      }}

      assert run_id == run.run_id
      assert_receive {@effect_event, ^ref, %{audit_failed: 1, skipped: 0, on_terminal_run: 0}, _}
      assert event_types(run) == before_types
      assert {:ok, %{metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
    end
  end

  describe "a branch push whose remote already holds the branch: the verdict follows the remote" do
    test "not_done at the earlier tip, done at the pushed tip and unknown when another commit landed",
         %{world: world, ref: ref} do
      # not_done: origin holds the run's earlier tip and the push never reached it
      run = World.delivery_run!(world)
      :ok = EffectWorld.publish!(run.fx)
      earlier = World.remote_tip(run)
      later = EffectWorld.commit_on_head!(run.fx, "more.txt")
      refute earlier == later
      World.crash!(world, :push, :before, fn -> PrCreate.execute(run.run_id) end)
      assert World.remote_tip(run) == earlier

      World.sweep!(world)

      assert_terminal_verdict(
        ref,
        run,
        "not_done",
        nil,
        %{audit_failed: 1, on_terminal_run: 0, retried: 0, blocked: 0, unresolved: 0, skipped: 0},
        "branch_push"
      )

      assert {:ok, _} = World.create_pr(run)
      assert World.remote_tip(run) == later
      assert World.executed(world, :push) == 1

      # CONTROL: the same crash after the push reached origin is done
      pushed = World.delivery_run!(world)
      :ok = EffectWorld.publish!(pushed.fx)
      pushed_tip = EffectWorld.commit_on_head!(pushed.fx, "more.txt")
      World.crash!(world, :push, :after, fn -> PrCreate.execute(pushed.run_id) end)
      assert World.remote_tip(pushed) == pushed_tip

      World.sweep!(world)

      assert_terminal_verdict(
        ref,
        pushed,
        "done",
        "effect_already_done",
        %{on_terminal_run: 1, audit_failed: 0, retried: 0, blocked: 0, unresolved: 0, skipped: 0},
        "branch_push"
      )

      # unknown: origin's branch moved to a commit that is neither the earlier nor the pushed tip
      moved = World.delivery_run!(world)
      World.crash!(world, :push, :before, fn -> PrCreate.execute(moved.run_id) end)
      stranger = EffectWorld.land_other_commit!(moved.fx)
      assert World.remote_tip(moved) == stranger
      refute stranger == World.tip(moved)

      World.sweep!(world)

      assert_terminal_verdict(
        ref,
        moved,
        "unknown",
        "effect_outcome_ambiguous",
        # the done key above is already marked: the sweep skips it
        %{on_terminal_run: 1, audit_failed: 0, retried: 0, blocked: 0, unresolved: 0, skipped: 1},
        "branch_push"
      )

      assert {:error, {:effect_unresolved, _push_key}} = World.create_pr(moved)
      assert World.remote_tip(moved) == stranger
      assert World.executed(world, :push) == 2
    end
  end

  describe "Create PR: the list holds a fork's PR and this repository's" do
    test "this repository's PR is adopted wherever it is listed, a fork's never",
         %{world: world} do
      forked_first = World.delivery_run!(world)
      fork = World.open_by_hand!(world, forked_first, cross_repository: true)
      own = World.open_by_hand!(world, forked_first)

      assert {:ok, _} = World.create_pr(forked_first)

      assert World.created_url!(forked_first) == own
      refute own == fork
      assert creates_for(world, forked_first) == []
      assert World.remote_tip(forked_first) == nil

      own_first = World.delivery_run!(world)
      own2 = World.open_by_hand!(world, own_first)
      _fork2 = World.open_by_hand!(world, own_first, cross_repository: true)

      assert {:ok, _} = World.create_pr(own_first)

      assert World.created_url!(own_first) == own2
      assert creates_for(world, own_first) == []

      # CONTROL: when the first PR listed is this repository's too, it is the one adopted
      both = World.delivery_run!(world)
      first = World.open_by_hand!(world, both)
      _second = World.open_by_hand!(world, both)

      assert {:ok, _} = World.create_pr(both)

      assert World.created_url!(both) == first
      assert World.executed(world, :create) == 0
    end
  end

  describe "a running run's phase PR create key the sweep cannot read" do
    test "unknown blocks the run effect_outcome_ambiguous and cancels its executor; the same crash with GitHub answering is retried",
         %{world: world, ref: ref} do
      run = World.phase_run!(world)
      World.crash!(world, :create, :before, fn -> PhasePR.maybe_create(run.request) end)
      World.fail_gh!(world, :list)

      World.sweep!(world)

      assert_receive {@effect_event, ^ref,
                      %{
                        blocked: 1,
                        on_terminal_run: 0,
                        retried: 0,
                        audit_failed: 0,
                        unresolved: 0,
                        skipped: 0,
                        deferred_unknown: 0
                      }, _}

      assert EffectWorld.status(run.run_id) == "blocked"
      assert EffectWorld.block_reason(run.run_id) == "effect_outcome_ambiguous"
      assert RunControl.intent(run.run_id) == :cancel
      assert World.executed(world, :create) == 0

      # CONTROL: GitHub answers, the PR was never made: retried, not blocked
      control = World.phase_run!(world)
      World.heal_gh!(world, :list)
      World.crash!(world, :create, :before, fn -> PhasePR.maybe_create(control.request) end)

      World.sweep!(world)

      assert_receive {@effect_event, ^ref,
                      %{retried: 1, blocked: 0, skipped: 1, deferred_unknown: 0}, _}

      assert EffectWorld.status(control.run_id) != "blocked"
      assert RunControl.intent(control.run_id) == nil
      assert {:ok, %PhasePR.Record{status: "created"}} = PhasePR.maybe_create(control.request)
    end
  end

  describe "the scan an undecided refusal casts (the production BootReconciliation process)" do
    test "an unknown verdict on that scan is deferred: nothing is marked and the run is untouched; once GitHub answers the key is decided",
         %{world: world, ref: ref} do
      start_supervised!({BootReconciliation, []})
      _booted = :sys.get_state(BootReconciliation, 15_000)

      run = World.delivery_run!(world)
      key = create_key(run)
      crash_create!(world, run, :before)
      World.fail_gh!(world, :list)
      before_types = event_types(run)

      assert {:error, {:effect_undecided, ^key}} = World.create_pr(run)

      assert_receive {@effect_event, ^ref, %{deferred_unknown: 1, on_terminal_run: 0, blocked: 0},
                      _},
                     5_000

      refute_received {@terminal_event, ^ref, _, _}
      assert {:ok, %{status: :ambiguous, metadata: left}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(left) == :none
      assert KeyStore.decision(left) == :none
      assert event_types(run) == before_types
      assert RunControl.intent(run.run_id) == nil

      # still undecided (not unresolved): the next refusal casts the next scan
      assert {:error, {:effect_undecided, ^key}} = World.create_pr(run)
      assert_receive {@effect_event, ^ref, %{deferred_unknown: 1}, _}, 5_000

      # CONTROL: GitHub answers: the scan decides the key not_done and Create PR runs
      World.heal_gh!(world, :list)
      assert {:error, {:effect_undecided, ^key}} = World.create_pr(run)

      assert_receive {@effect_event, ^ref, %{audit_failed: 1, deferred_unknown: 0}, _}, 5_000
      assert {:ok, %{metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert {:ok, _} = World.create_pr(run)
      assert World.executed(world, :create) == 1
    end
  end

  describe "a key whose writer is alive" do
    test "the sweep leaves it started; once the writer is dead it is reconciled",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = create_key(run)
      writer = World.hold!(world, :create, :after, fn -> PrCreate.execute(run.run_id) end)

      assert {:ok, %{status: :started, metadata: meta}} = KeyStore.get(key)
      assert Effect.writer_state(meta) == :alive

      World.sweep!(world)

      assert {:ok, :started} = KeyStore.status(key)
      refute_received {@effect_event, ^ref, _, _}
      refute_received {@terminal_event, ^ref, _, _}

      # CONTROL: the writer is gone: the key is an orphan and the sweep decides it
      World.kill_parked!(writer)
      assert Effect.writer_state(meta) == :dead

      World.sweep!(world)

      assert_terminal_verdict(ref, run, "done", "effect_already_done", %{
        on_terminal_run: 1,
        audit_failed: 0,
        retried: 0,
        blocked: 0,
        unresolved: 0,
        skipped: 0
      })
    end
  end

  describe "the sweep's pr_create verdict follows the lookup's rule about forks" do
    test "a fork's PR of the same branch and tip is not proof the create ran: not_done, the run is not blocked and Create PR opens its own PR once",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world, complete: false)
      key = create_key(run)
      crash_create!(world, run, :before)
      fork = World.open_by_hand!(world, run, cross_repository: true)
      assert World.executed(world, :create) == 0

      World.sweep!(world)

      assert_receive {@effect_event, ^ref,
                      %{
                        retried: 1,
                        blocked: 0,
                        on_terminal_run: 0,
                        audit_failed: 0,
                        unresolved: 0,
                        skipped: 0,
                        deferred_unknown: 0
                      }, _}

      assert %{terminal?: false} = ProjectionStore.run(run.run_id)
      refute "RunBlocked" in event_types(run)
      assert RunControl.intent(run.run_id) == nil
      assert {:ok, %{metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done

      assert {:ok, _} = World.create_pr(run)

      own = World.created_url!(run)
      refute own == fork
      assert World.created_prs(world) == [own]
      assert World.executed(world, :create) == 1
      assert length(creates_for(world, run)) == 2

      # CONTROL: the same PR of this repository proves the create ran: done, the run is blocked
      control = World.delivery_run!(world, complete: false)
      crash_create!(world, control, :before)
      _mine = World.open_by_hand!(world, control)

      World.sweep!(world)

      assert_receive {@effect_event, ^ref, %{blocked: 1, retried: 0}, _}
      assert EffectWorld.status(control.run_id) == "blocked"
      assert EffectWorld.block_reason(control.run_id) == "effect_already_done"
    end

    # DELIBERATE: the reconciler does not compare heads (the key's intent holds no tip). A PR of
    # this repository for the run's branch proves the create ran, so the verdict is `done` even
    # though its head is not the tip; Create PR then adopts nothing (the lookup refuses the other
    # head) and the unresolved key refuses the effect: fail-closed, nothing is created.
    test "a PR of this repository with another head is done by decision: Create PR creates nothing",
         %{world: world, ref: ref} do
      run = World.delivery_run!(world)
      key = create_key(run)
      crash_create!(world, run, :before)
      _other = World.open_by_hand!(world, run, head: @other_head)

      World.sweep!(world)

      assert_terminal_verdict(ref, run, "done", "effect_already_done", %{
        on_terminal_run: 1,
        audit_failed: 0,
        retried: 0,
        blocked: 0,
        unresolved: 0,
        skipped: 0
      })

      assert {:error, {:effect_unresolved, ^key}} = World.create_pr(run)
      assert length(creates_for(world, run)) == 1
      assert World.executed(world, :create) == 0
      assert World.created_prs(world) == []
      assert {:error, :not_found} = ProjectionStore.pr_association(run.run_id)
    end
  end

  defp reset(run) do
    CommandGateway.dispatch_system(%{
      type: "run.reset",
      command_id: "reset-#{run.run_id}",
      aggregate_id: "run:#{run.run_id}",
      payload: %{"run_id" => run.run_id}
    })
  end
end
