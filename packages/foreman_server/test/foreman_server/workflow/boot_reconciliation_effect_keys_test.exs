defmodule ForemanServer.Workflow.BootReconciliationEffectKeysTest do
  @moduledoc """
  The effect-recovery step of `BootReconciliation.do_reconcile_ambiguous_keys/2`
  (TRD-012): an ambiguous `effect:` key is routed to its class's reconciler and
  never to `CrashRecovery.reconcile/2`; a verdict that blocks does so through
  `RunRecoveryAttempted`, `run.block` and the `RunControl` cancel, in that
  order, only for a run that is not terminal.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, RunControl}
  alias ForemanServer.Idempotency.{Effect, KeyStore}
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{KeyStoreReset, MeckScope, UniqueIds}
  alias ForemanServer.Workflow.BootReconciliation

  @terminal_event [:foreman_server, :workflow, :boot_reconciliation, :effect_on_terminal_run]
  @effect_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]
  @ambiguous_event [:foreman_server, :workflow, :boot_reconciliation, :ambiguous_reconciled]

  defmodule Fake do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(%{"fake_verdict" => "raise"}), do: raise("provider down")
    def reconcile(%{"fake_verdict" => verdict}), do: String.to_existing_atom(verdict)
  end

  @project_id "project-effect-keys"
  @classes %{"branch_push" => Fake, "pr_create" => Fake}

  setup_all do
    MeckScope.new_once!([Jido.Harness.Run, KeyStore])

    repo = Path.join(System.tmp_dir!(), "effect-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: @project_id, path: repo},
        aggregate_id: "project:#{@project_id}"
      })

    :ok
  end

  setup do
    MeckScope.restore_on_exit!([Jido.Harness.Run, KeyStore])
    KeyStoreReset.reset!()

    {handler_id, ref} =
      Handler.attach_event_handlers(self(), [@terminal_event, @effect_event, @ambiguous_event])

    run_id = UniqueIds.unique_run_id("effect-keys")

    on_exit(fn ->
      :telemetry.detach(handler_id)
      RunControl.clear(run_id)
      KeyStoreReset.reset!()
    end)

    start_run(run_id)
    {:ok, run_id: run_id, ref: ref}
  end

  describe "verdicts for a run that is not terminal" do
    test "an effect that is :done blocks the run `effect_already_done` and the key stays ambiguous",
         %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/a", "done")

      sweep()

      assert status(run_id) == "blocked"
      assert %{payload: blocked} = List.last(events(run_id))
      assert get(blocked, :reason) == "effect_already_done"

      assert %{payload: record} = recovery_record(run_id, "effect_blocked")
      assert get(record, :reason) == "effect_already_done"
      assert get(record, :effect_class) == "branch_push"
      assert get(record, :effect_key) == key
      assert get(record, :effect_verdict) == "done"
      assert is_integer(get(record, :elapsed_since_boot_ms))

      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "an effect that is :unknown, or whose reconciler fails, blocks `effect_outcome_ambiguous`" do
      for verdict <- ["unknown", "raise"] do
        run_id = UniqueIds.unique_run_id("effect-unknown")
        start_run(run_id)
        on_exit(fn -> RunControl.clear(run_id) end)
        plant(run_id, "branch_push", "feature/u", verdict)

        sweep()

        assert status(run_id) == "blocked"
        assert get(List.last(events(run_id)).payload, :reason) == "effect_outcome_ambiguous"

        assert get(recovery_record(run_id, "effect_blocked").payload, :effect_verdict) ==
                 "unknown"
      end
    end

    test "a class with no reconciler blocks `effect_class_unregistered` and nothing is retried",
         %{run_id: run_id} do
      key = plant(run_id, "task_provider", "claim:1", "not_done")

      sweep()

      assert status(run_id) == "blocked"
      assert get(List.last(events(run_id)).payload, :reason) == "effect_class_unregistered"

      assert get(recovery_record(run_id, "effect_blocked").payload, :effect_verdict) ==
               "unregistered"

      assert recovery_record(run_id, "effect_retried") == nil
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "an unexpected store status blocks `effect_outcome_ambiguous`", %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/s", "not_done")
      :ok = KeyStore.mark_completed(key, %{})

      :meck.expect(KeyStore, :list_by_status, fn status ->
        if status == :ambiguous, do: [key], else: []
      end)

      sweep()

      assert status(run_id) == "blocked"
      assert get(List.last(events(run_id)).payload, :reason) == "effect_outcome_ambiguous"
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a :not_done effect records `effect_retried`, blocks nothing and the key stays ambiguous so the next Effect.run re-marks it",
         %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/n", "not_done")

      sweep()

      assert status(run_id) == "awaiting_worker"
      assert %{payload: record} = recovery_record(run_id, "effect_retried")
      assert get(record, :effect_class) == "branch_push"
      assert get(record, :effect_key) == key
      assert get(record, :effect_verdict) == "not_done"
      assert is_integer(get(record, :elapsed_since_boot_ms))
      assert recovery_record(run_id, "effect_blocked") == nil
      assert RunControl.intent(run_id) == nil
      assert {:ok, :ambiguous} = KeyStore.status(key)

      meta = %{"run_id" => run_id, "head_branch" => "feature/n", "cwd" => System.tmp_dir!()}
      ran = self()

      assert :ok =
               Effect.run(
                 "branch_push",
                 key,
                 fn ->
                   send(ran, :pushed)
                   :ok
                 end,
                 meta
               )

      assert_received :pushed
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end

  describe "the block sequence" do
    test "appends the effect_blocked record, then run.block, then cancels the executor and agent",
         %{run_id: run_id} do
      plant(run_id, "branch_push", "feature/order", "done")
      :ok = RunControl.register_agent(run_id, "harness-#{run_id}")
      test_pid = self()

      :meck.expect(Jido.Harness.Run, :cancel, fn harness_id ->
        {state, _} = Aggregate.load(Run, "run:#{run_id}")
        send(test_pid, {:cancelled, harness_id, state.status})
        :ok
      end)

      sweep()

      types = for e <- events(run_id), do: {e.event_type, get(e.payload, :outcome)}

      assert types == [
               {"RunStarted", nil},
               {"RunRecoveryAttempted", "effect_blocked"},
               {"RunBlocked", nil}
             ]

      assert RunControl.intent(run_id) == :cancel
      assert_received {:cancelled, "harness-" <> _, "blocked"}
    end

    test "a verdict handled twice appends exactly one RunBlocked and one record, key still ambiguous",
         %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/twice", "done")

      sweep()
      sweep()

      assert count(run_id, "RunBlocked") == 1
      assert count(run_id, "RunRecoveryAttempted") == 1
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "after an operator run.reset the next effect block records again", %{run_id: run_id} do
      plant(run_id, "branch_push", "feature/reset", "done")
      sweep()
      assert status(run_id) == "blocked"

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "run.reset",
                 command_id: "reset-#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 payload: %{"run_id" => run_id}
               })

      start_run(run_id, 2)
      sweep()

      assert status(run_id) == "blocked"
      assert count(run_id, "RunBlocked") == 2
      assert count(run_id, "RunRecoveryAttempted") == 2
    end
  end

  describe "a run that cannot be blocked" do
    for terminal <- ["failed", "blocked"] do
      test "a #{terminal} run is not blocked or retried: the verdict is logged and counted and the key stays ambiguous",
           %{run_id: run_id, ref: ref} do
        key = plant(run_id, "branch_push", "feature/t", "done")
        end_run(run_id, unquote(terminal))
        before_events = events(run_id)
        intent_before = RunControl.intent(run_id)

        sweep()

        assert events(run_id) == before_events

        assert_receive {@terminal_event, ^ref, %{count: 1}, metadata}
        assert metadata.run_id == run_id
        assert metadata.status == unquote(terminal)
        assert metadata.effect_key == key
        assert metadata.effect_class == "branch_push"
        assert metadata.effect_verdict == "done"
        assert metadata.reason == "effect_already_done"
        assert {:ok, :ambiguous} = KeyStore.status(key)
        assert RunControl.intent(run_id) == intent_before
      end
    end

    test "a :not_done verdict on a terminal run retries nothing", %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/tn", "not_done")
      end_run(run_id, "failed")
      before_events = events(run_id)

      sweep()

      assert events(run_id) == before_events
      assert_receive {@terminal_event, ^ref, _, %{effect_verdict: "not_done", reason: nil}}
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "a run already blocked by the effect step is not blocked again but is still counted",
         %{run_id: run_id, ref: ref} do
      plant(run_id, "branch_push", "feature/again", "done")
      sweep()
      refute_received {@terminal_event, ^ref, _, _}

      sweep()

      assert count(run_id, "RunBlocked") == 1
      assert_receive {@terminal_event, ^ref, %{count: 1}, %{status: "blocked", run_id: ^run_id}}
    end

    test "a run with no stream is counted like a terminal one", %{ref: ref} do
      ghost = UniqueIds.unique_run_id("effect-ghost")
      plant(ghost, "branch_push", "feature/ghost", "done")

      sweep()

      assert_receive {@terminal_event, ^ref, _, %{run_id: ^ghost, status: "absent"}}
    end
  end

  describe "the partition in do_reconcile_ambiguous_keys" do
    test "an agent-phase key still goes through CrashRecovery.reconcile/2 and the effect key never does",
         %{run_id: run_id, ref: ref} do
      :ets.insert(:foreman_idempotency_keys, {"agent-phase-key", :ambiguous, %{run_id: "run-x"}})
      effect = plant(run_id, "branch_push", "feature/mix", "done")

      # "side effects present": CrashRecovery marks the agent key completed. For an effect
      # key that is the opposite of the right answer, so it must not be applied to it.
      BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> false end, classes: @classes)

      assert {:ok, :completed} = KeyStore.status("agent-phase-key")
      assert {:ok, :ambiguous} = KeyStore.status(effect)
      assert_receive {@ambiguous_event, ^ref, %{skipped: 0, retried: 1}, _}
      assert_receive {@effect_event, ^ref, %{blocked: 1, retried: 0, on_terminal_run: 0}, _}
    end

    test "a key that merely contains `effect:` is an agent-phase key", %{ref: ref} do
      :ets.insert(:foreman_idempotency_keys, {"phase:effect:x", :ambiguous, %{}})

      BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end, classes: @classes)

      assert_receive {@ambiguous_event, ^ref, %{skipped: 0, retried: 1}, _}
      refute_received {@effect_event, ^ref, _, _}
    end

    test "an orphaned started effect key is marked ambiguous and then reconciled", %{
      run_id: run_id
    } do
      key = Effect.key("branch_push", run_id, "feature/orphan")

      :ok =
        KeyStore.mark_started(key, %{
          "run_id" => run_id,
          "effect_class" => "branch_push",
          "head_branch" => "feature/orphan",
          "cwd" => System.tmp_dir!(),
          "fake_verdict" => "done"
        })

      sweep()

      assert status(run_id) == "blocked"
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "a key without a run id is left ambiguous and raises nothing", %{ref: ref} do
      :ets.insert(
        :foreman_idempotency_keys,
        {"effect:branch_push:nobody:x", :ambiguous, %{"effect_class" => "branch_push"}}
      )

      sweep()

      assert_receive {@effect_event, ^ref, %{unresolved: 1, blocked: 0}, _}
      assert {:ok, :ambiguous} = KeyStore.status("effect:branch_push:nobody:x")
    end
  end

  # --- helpers ---

  defp sweep,
    do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end, classes: @classes)

  defp plant(run_id, class, identity, fake_verdict) do
    key = Effect.key(class, run_id, identity)

    :ok =
      KeyStore.mark_started(key, %{
        "run_id" => run_id,
        "effect_class" => class,
        "fake_verdict" => fake_verdict
      })

    :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
    key
  end

  # The start command id derives from the workflow snapshot, so a restart after a reset
  # carries a different one: the same snapshot would be replayed, not started again.
  defp start_run(run_id, attempt \\ 1) do
    {:ok, _} =
      CommandRouter.dispatch_run_start(@project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [], attempt: attempt}
      })
  end

  defp end_run(run_id, "failed") do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.fail",
        command_id: "fail-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{"run_id" => run_id, "reason" => "test"}
      })
  end

  defp end_run(run_id, "blocked") do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.block",
        command_id: "block-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{"run_id" => run_id, "reason" => "test"}
      })
  end

  defp events(run_id) do
    {:ok, recorded} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)

    for e <- recorded do
      %{event_type: Aggregate.event_type(e), payload: Aggregate.event_payload(e)}
    end
  end

  defp recovery_record(run_id, outcome) do
    Enum.find(events(run_id), fn e ->
      e.event_type == "RunRecoveryAttempted" and get(e.payload, :outcome) == outcome
    end)
  end

  defp count(run_id, event_type), do: Enum.count(events(run_id), &(&1.event_type == event_type))

  defp status(run_id), do: Aggregate.load(Run, "run:#{run_id}") |> elem(0) |> Map.fetch!(:status)

  defp get(payload, key), do: Aggregate.get(payload, key)
end
