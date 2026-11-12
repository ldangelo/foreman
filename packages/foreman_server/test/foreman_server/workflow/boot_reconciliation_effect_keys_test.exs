defmodule ForemanServer.Workflow.BootReconciliationEffectKeysTest do
  @moduledoc """
  The effect-recovery step of `BootReconciliation.do_reconcile_ambiguous_keys/2`
  (TRD-012): an ambiguous `effect:` key is routed to its class's reconciler and
  never to `CrashRecovery.reconcile/2`; a verdict that blocks does so through
  `RunRecoveryAttempted`, `run.block` and the `RunControl` cancel, in that
  order, only for a run that is not terminal.

  A `not_done` verdict (TRD-003) decides the key first (`KeyStore.mark_decided/2`) and
  records `effect_retried` after, best effort: a rejected or failed audit command is counted
  `audit_failed` and does not undo the decision, a decision that cannot be written is
  counted `unresolved` and sends no command, and a key that carries the decision is skipped.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, RunControl}
  alias ForemanServer.Idempotency.{Effect, KeyStore, Reconciler}
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{Eventually, KeyStoreReset, MeckScope, UniqueIds}
  alias ForemanServer.Workflow.BootReconciliation

  @terminal_event [:foreman_server, :workflow, :boot_reconciliation, :effect_on_terminal_run]
  @effect_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]
  @ambiguous_event [:foreman_server, :workflow, :boot_reconciliation, :ambiguous_reconciled]

  defmodule Fake do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(%{"fake_verdict" => "raise"}), do: raise("provider down")

    def reconcile(%{"fake_verdict" => "needs_reason", "reason" => "orphaned_started_key"}),
      do: :done

    def reconcile(%{"fake_verdict" => "needs_reason"}), do: :unknown
    def reconcile(%{"fake_verdict" => verdict}), do: String.to_existing_atom(verdict)
  end

  defmodule Probe do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    # A class whose reconciler answers `repeatable?/1` from each key's own metadata.
    @impl true
    def reconcile(%{"fake_verdict" => verdict}), do: String.to_existing_atom(verdict)

    @impl true
    def repeatable?(%{"repeatable" => answer}), do: answer
  end

  defmodule Advisory do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    # What the PR comment class declares: repeating it is harmless and its verdict never
    # decides the fate of a run.
    @impl true
    def reconcile(%{"fake_verdict" => verdict}), do: String.to_existing_atom(verdict)

    @impl true
    def repeatable?(_metadata), do: true

    @impl true
    def blocks_run?(_metadata), do: false
  end

  defmodule Flaky do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    # Answers what the test process scripted (the sweep runs the reconciler in its caller).
    @impl true
    def reconcile(_metadata), do: Process.get(:flaky_verdict, :unknown)
  end

  @project_id "project-effect-keys"
  @classes %{"branch_push" => Fake, "pr_create" => Fake}
  @probe_classes %{"probe" => Probe}
  @advisory_classes %{"advisory" => Advisory}

  setup_all do
    MeckScope.new_once!([Jido.Harness.Run, KeyStore, CommandGateway])

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
    MeckScope.restore_on_exit!([Jido.Harness.Run, KeyStore, CommandGateway])
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

    test "a status that is not one the store writes blocks `effect_outcome_ambiguous`",
         %{run_id: run_id} do
      key = Effect.key("branch_push", run_id, "feature/s")

      :ets.insert(
        :foreman_idempotency_keys,
        {key, :weird, %{"run_id" => run_id, "effect_class" => "branch_push"}}
      )

      list_only_ambiguous(key)

      sweep()

      assert status(run_id) == "blocked"
      assert get(List.last(events(run_id)).payload, :reason) == "effect_outcome_ambiguous"
    end

    for moved_on <- [:started, :completed, :failed] do
      test "a key re-marked #{moved_on} between the listing and the read is skipped, not blocked",
           %{run_id: run_id, ref: ref} do
        key = plant(run_id, "branch_push", "feature/moved", "done")
        :ets.insert(:foreman_idempotency_keys, {key, unquote(moved_on), meta(run_id)})

        list_only_ambiguous(key)

        before_events = events(run_id)

        sweep()

        assert events(run_id) == before_events
        assert RunControl.intent(run_id) == nil

        assert_receive {@effect_event, ^ref, %{skipped: 1, blocked: 0, retried: 0, unresolved: 0},
                        _}

        refute_received {@terminal_event, ^ref, _, _}
        assert {:ok, unquote(moved_on)} = KeyStore.status(key)
      end
    end

    test "a listed key that no longer exists is skipped", %{run_id: run_id, ref: ref} do
      key = Effect.key("branch_push", run_id, "feature/gone")

      list_only_ambiguous(key)

      before_events = events(run_id)

      sweep()

      assert events(run_id) == before_events
      assert_receive {@effect_event, ^ref, %{skipped: 1, blocked: 0}, _}
    end

    test "metadata reaches the reconciler string-keyed whether the reason was written atom-keyed (ETS) or string-keyed (repo)" do
      ets_run = UniqueIds.unique_run_id("effect-ets")
      repo_run = UniqueIds.unique_run_id("effect-repo")
      for run <- [ets_run, repo_run], do: start_run(run)
      on_exit(fn -> Enum.each([ets_run, repo_run], &RunControl.clear/1) end)

      # ETS path: `mark_ambiguous/2` merges an atom-keyed `reason` into the stored map.
      plant(ets_run, "branch_push", "feature/ets", "needs_reason")

      # Repo path: the row comes back from a JSON round trip, every key a string.
      repo_key = Effect.key("branch_push", repo_run, "feature/repo")

      :ets.insert(
        :foreman_idempotency_keys,
        {repo_key, :ambiguous,
         %{
           "run_id" => repo_run,
           "effect_class" => "branch_push",
           "fake_verdict" => "needs_reason",
           "reason" => "orphaned_started_key"
         }}
      )

      sweep()

      for run <- [ets_run, repo_run] do
        assert get(List.last(events(run)).payload, :reason) == "effect_already_done"
      end
    end

    test "a :not_done effect is decided and recorded `effect_retried`: it blocks nothing and the next Effect.run runs",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/n", "not_done")
      meta = push_meta(run_id, "feature/n")

      # nobody has decided the key yet: it is refused
      assert {:error, {:effect_undecided, ^key}} = Effect.preflight(:branch_push, key, meta)

      sweep()

      assert status(run_id) == "awaiting_worker"
      assert %{payload: record} = recovery_record(run_id, "effect_retried")
      assert get(record, :effect_class) == "branch_push"
      assert get(record, :effect_key) == key
      assert get(record, :effect_verdict) == "not_done"
      assert is_integer(get(record, :elapsed_since_boot_ms))
      assert recovery_record(run_id, "effect_blocked") == nil
      assert RunControl.intent(run_id) == nil
      assert_receive {@effect_event, ^ref, %{retried: 1, audit_failed: 0, unresolved: 0}, _}

      # The key stays ambiguous, now with the decision, so the next Effect.run runs and
      # re-marks it.
      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert :ok = Effect.preflight(:branch_push, key, meta)

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

    test "after a reset the sweep does not re-decide the key", %{
      run_id: run_id
    } do
      key = plant(run_id, "branch_push", "feature/reset", "done")
      sweep()
      assert status(run_id) == "blocked"
      assert {:ok, %{metadata: marked}} = KeyStore.get(key)
      assert {:ok, _version} = KeyStore.unresolved_version(marked)

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "run.reset",
                 command_id: "reset-#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 payload: %{"run_id" => run_id}
               })

      start_run(run_id, 2)
      sweep()

      # The marker stays and the run is not blocked again: `Effect.run/4` honours the
      # reset when the run's next attempt reaches the effect.
      assert count(run_id, "RunBlocked") == 1
      assert count(run_id, "RunRecoveryAttempted") == 1
      assert {:ok, %{status: :ambiguous, metadata: ^marked}} = KeyStore.get(key)
    end

    test "a reset that lands right after the block still lifts the key", %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/race", "done")

      :meck.expect(CommandGateway, :dispatch_system, fn
        %{type: "run.block"} = command ->
          result = :meck.passthrough([command])

          {:ok, _} =
            :meck.passthrough([
              %{
                type: "run.reset",
                command_id: "reset-race-#{run_id}",
                aggregate_id: "run:#{run_id}",
                payload: %{"run_id" => run_id}
              }
            ])

          result

        command ->
          :meck.passthrough([command])
      end)

      sweep()

      assert count(run_id, "RunReset") == 1
      meta = %{"run_id" => run_id, "head_branch" => "feature/race", "cwd" => "/w"}
      assert :ran == Effect.run(:branch_push, key, fn -> :ran end, meta)
    end

    test "a failed block dispatch still leaves the key marked, so Effect.run refuses it",
         %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/slow", "done")

      :meck.expect(CommandGateway, :dispatch_system, fn
        %{type: "run.block"} -> {:error, {:dispatch_exit, :timeout}}
        command -> :meck.passthrough([command])
      end)

      sweep()

      refute status(run_id) == "blocked"
      assert count(run_id, "RunBlocked") == 0
      assert {:ok, %{status: :ambiguous, metadata: marked}} = KeyStore.get(key)
      assert {:ok, _version} = KeyStore.unresolved_version(marked)
      assert marked["unresolved_reason"] == "effect_already_done"

      meta = %{"run_id" => run_id, "head_branch" => "feature/slow", "cwd" => "/w"}

      assert {:error, {:effect_unresolved, ^key}} =
               Effect.run(:branch_push, key, fn -> flunk("repeated") end, meta)
    end

    test "a marker that cannot be written leaves the run unblocked and the verdict uncounted",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/nomark", "done")
      :meck.expect(KeyStore, :mark_unresolved, fn _key, _version, _reason -> {:error, :down} end)

      sweep()

      refute status(run_id) == "blocked"
      assert count(run_id, "RunBlocked") == 0
      assert_receive {@effect_event, ^ref, %{blocked: 0, unresolved: 1}, _}
      assert {:ok, %{status: :ambiguous}} = KeyStore.get(key)
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

    for terminal <- ["failed", "completed"] do
      test "a :not_done verdict on a #{terminal} run decides the key first: the audit command is rejected and counted audit_failed",
           %{run_id: run_id, ref: ref} do
        key = plant(run_id, "branch_push", "feature/tn-#{unquote(terminal)}", "not_done")
        meta = push_meta(run_id, "feature/tn-#{unquote(terminal)}")
        end_run(run_id, unquote(terminal))
        before_events = events(run_id)

        sweep()

        # The rejected command appended nothing, and the key is decided all the same.
        assert events(run_id) == before_events

        assert_receive {@terminal_event, ^ref, %{count: 1},
                        %{effect_verdict: "not_done", reason: nil, status: unquote(terminal)}}

        assert_receive {@effect_event, ^ref,
                        %{audit_failed: 1, retried: 0, on_terminal_run: 0, unresolved: 0}, _}

        assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
        assert KeyStore.decision(decided) == :not_done
        assert :ran == Effect.run(:branch_push, key, fn -> :ran end, meta)
        assert {:ok, :completed} = KeyStore.status(key)
      end
    end

    test "a run already blocked by the effect step is not decided again: its marked key is skipped",
         %{run_id: run_id, ref: ref} do
      plant(run_id, "branch_push", "feature/again", "done")
      sweep()
      refute_received {@terminal_event, ^ref, _, _}

      sweep()

      assert count(run_id, "RunBlocked") == 1
      refute_received {@terminal_event, ^ref, _, _}
      assert_received {@effect_event, ^ref, %{skipped: 1, blocked: 0, on_terminal_run: 0}, _}
    end

    test "a run with no stream is counted like a terminal one", %{ref: ref} do
      ghost = UniqueIds.unique_run_id("effect-ghost")
      plant(ghost, "branch_push", "feature/ghost", "done")

      sweep()

      assert_receive {@terminal_event, ^ref, _, %{run_id: ^ghost, status: "absent"}}
    end
  end

  describe "a :not_done verdict decides the key before the audit command is dispatched" do
    test "the key already carries the decision when `effect_retried` is dispatched",
         %{run_id: run_id} do
      key = plant(run_id, "branch_push", "feature/order", "not_done")
      test_pid = self()

      :meck.expect(CommandGateway, :dispatch_system, fn
        %{payload: %{outcome: "effect_retried"}} = command ->
          send(test_pid, {:at_dispatch, KeyStore.get(key)})
          :meck.passthrough([command])

        command ->
          :meck.passthrough([command])
      end)

      sweep()

      assert_received {:at_dispatch, {:ok, %{status: :ambiguous, metadata: at_dispatch}}}
      assert KeyStore.decision(at_dispatch) == :not_done
      assert %{payload: _record} = recovery_record(run_id, "effect_retried")
    end

    test "a decision that cannot be written leaves the key refused, sends no audit command and counts it unresolved",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/nodecide", "not_done")
      meta = push_meta(run_id, "feature/nodecide")
      test_pid = self()
      :meck.expect(KeyStore, :mark_decided, fn _key, _decision -> {:error, :down} end)

      :meck.expect(CommandGateway, :dispatch_system, fn command ->
        send(test_pid, {:dispatched, command.type})
        :meck.passthrough([command])
      end)

      sweep()

      assert_receive {@effect_event, ^ref, %{unresolved: 1, retried: 0, audit_failed: 0}, _}
      refute_received {:dispatched, "run.recovery_attempt"}
      assert recovery_record(run_id, "effect_retried") == nil
      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :none

      assert {:error, {:effect_undecided, ^key}} =
               Effect.run(:branch_push, key, fn -> flunk("repeated") end, meta)
    end

    test "a store that exits while the decision is written is counted unresolved too",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/exit", "not_done")
      :meck.expect(KeyStore, :mark_decided, fn _key, _decision -> exit(:noproc) end)

      sweep()

      assert_receive {@effect_event, ^ref, %{unresolved: 1, retried: 0, audit_failed: 0}, _}
      assert recovery_record(run_id, "effect_retried") == nil
      assert {:ok, %{metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :none
    end

    test "a key that settled before it could be decided is skipped, with no audit command",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/settled", "not_done")
      :meck.expect(KeyStore, :mark_decided, fn _key, _decision -> :not_decidable end)

      sweep()

      assert_receive {@effect_event, ^ref, %{skipped: 1, retried: 0, unresolved: 0}, _}
      assert recovery_record(run_id, "effect_retried") == nil

      # Nothing was written: the key is as the sweep found it.
      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :none
    end

    test "a failed audit command leaves the decision standing; the next scan skips the key and sends no second command",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/audit", "not_done")
      meta = push_meta(run_id, "feature/audit")
      test_pid = self()

      :meck.expect(CommandGateway, :dispatch_system, fn
        %{payload: %{outcome: "effect_retried"}} ->
          send(test_pid, :audit_dispatched)
          {:error, {:dispatch_exit, :timeout}}

        command ->
          :meck.passthrough([command])
      end)

      sweep()

      assert_receive {@effect_event, ^ref, %{audit_failed: 1, retried: 0, unresolved: 0}, _}
      assert_received :audit_dispatched
      assert recovery_record(run_id, "effect_retried") == nil
      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert :ok = Effect.preflight(:branch_push, key, meta)

      sweep()

      assert_receive {@effect_event, ^ref, %{skipped: 1, audit_failed: 0, retried: 0}, _}
      refute_received :audit_dispatched
      assert recovery_record(run_id, "effect_retried") == nil
      assert {:ok, %{metadata: still_decided}} = KeyStore.get(key)
      assert KeyStore.decision(still_decided) == :not_done
    end

    test "a key that already carries the decision is skipped without asking its reconciler",
         %{run_id: run_id, ref: ref} do
      # The reconciler would say `done` and block the run, were it asked.
      key = plant(run_id, "branch_push", "feature/decided", "done")
      :ok = KeyStore.mark_decided(key, :not_done)
      before_events = events(run_id)

      sweep()

      assert events(run_id) == before_events
      assert RunControl.intent(run_id) == nil
      assert_receive {@effect_event, ^ref, %{skipped: 1, blocked: 0, retried: 0}, _}
      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :not_done
    end
  end

  describe "a scan that runs while an effect of a terminal run is in flight" do
    # The operator's Create PR runs on a completed run, which has no executor: a scan orphans
    # the `started` key of the effect while it is still running and, the reconciler saying
    # `not_done`, decides it at once (the audit command is rejected). The effect's own settle
    # overwrites the status, so the key ends in the effect's outcome; a caller that read the
    # flipped key decided starts a second attempt, which is accepted (no grace window).
    for {what, result, ends} <- [
          {"completes", :pushed, :completed},
          {"fails", {:error, :boom}, :failed}
        ] do
      test "an effect that #{what} ends #{ends}, and a second caller that read the decided key ran too",
           %{run_id: run_id} do
        end_run(run_id, "completed")
        key = Effect.key("branch_push", run_id, "feature/inflight-#{unquote(ends)}")

        meta =
          run_id
          |> push_meta("feature/inflight-#{unquote(ends)}")
          |> Map.put("fake_verdict", "not_done")

        test_pid = self()

        assert unquote(result) ==
                 Effect.run(
                   "branch_push",
                   key,
                   fn ->
                     sweep()
                     send(test_pid, {:in_flight, KeyStore.get(key)})
                     second = Effect.run("branch_push", key, fn -> :second end, meta)
                     send(test_pid, {:second_attempt, second})
                     unquote(result)
                   end,
                   meta
                 )

        assert_received {:in_flight, {:ok, %{status: :ambiguous, metadata: flipped}}}
        assert KeyStore.decision(flipped) == :not_done
        assert_received {:second_attempt, :second}
        assert {:ok, %{status: unquote(ends)}} = KeyStore.get(key)
      end
    end
  end

  describe "a started key of a live run" do
    # A workflow-door RunExecutor has no RunExecutorLiveness entry; it is registered in
    # RunExecutorRegistry under its run id, which is what `RunExecutor.pid_for/1` reads.
    defp live_executor(run_id) do
      parent = self()

      pid =
        spawn_link(fn ->
          {:ok, _} = Registry.register(ForemanServer.RunExecutorRegistry, run_id, nil)
          send(parent, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      pid
    end

    defp start_effect(run_id) do
      key = Effect.key("branch_push", run_id, "feature/live")
      :ok = KeyStore.mark_started(key, meta(run_id))
      key
    end

    test "an effect key is not marked ambiguous or blocked while its RunExecutor is registered, and is once it is gone",
         %{run_id: run_id} do
      key = start_effect(run_id)
      pid = live_executor(run_id)

      sweep()

      assert {:ok, :started} = KeyStore.status(key)
      assert status(run_id) == "awaiting_worker"
      assert RunControl.intent(run_id) == nil

      # Not orphaned, so nothing decided it: the effect is still refused.
      meta = %{"run_id" => run_id, "head_branch" => "feature/live", "cwd" => "/w"}

      assert {:error, {:effect_undecided, ^key}} =
               Effect.run(:branch_push, key, fn -> flunk("repeated") end, meta)

      assert {:ok, :started} = KeyStore.status(key)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      Eventually.await(fn -> ForemanServer.Workflow.RunExecutor.pid_for(run_id) == nil end)

      sweep()

      assert {:ok, :ambiguous} = KeyStore.status(key)
      assert status(run_id) == "blocked"
    end

    test "an agent-phase key keeps the old liveness rule: a registered RunExecutor does not protect it",
         %{run_id: run_id} do
      :ok = KeyStore.mark_started("agent-live-key", %{run_id: run_id})
      live_executor(run_id)

      BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end, classes: @classes)

      assert {:ok, :ambiguous} = KeyStore.status("agent-live-key")
    end
  end

  describe "an unknown verdict from an on-demand scan (foreman-ulg5y.3.13)" do
    @flaky %{"branch_push" => Flaky}

    defp scan(origin),
      do:
        BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end,
          classes: @flaky,
          origin: origin
        )

    test "leaves the key undecided and the run running; a later healthy scan decides it",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/blip", "unknown")
      before_events = events(run_id)
      Process.put(:flaky_verdict, :unknown)

      scan(:on_demand)

      assert status(run_id) == "awaiting_worker"
      assert events(run_id) == before_events
      assert RunControl.intent(run_id) == nil
      assert {:ok, :ambiguous} = KeyStore.status(key)
      assert {:ok, %{metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(metadata) == :none
      assert KeyStore.decision(metadata) == :none
      assert_receive {@effect_event, ^ref, %{deferred_unknown: 1, blocked: 0, unresolved: 0}, _}

      # Still refused: nobody decided it.
      assert {:error, {:effect_undecided, ^key}} =
               Effect.run(
                 :branch_push,
                 key,
                 fn -> flunk("repeated") end,
                 push_meta(run_id, "feature/blip")
               )

      Process.put(:flaky_verdict, :not_done)
      scan(:on_demand)

      assert KeyStore.decision(elem(KeyStore.get(key), 1).metadata) == :not_done
      assert status(run_id) == "awaiting_worker"
      assert_receive {@effect_event, ^ref, %{retried: 1, deferred_unknown: 0}, _}
    end

    test "the boot sweep still marks the key and blocks the run on the same verdict",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "branch_push", "feature/blip-boot", "unknown")
      Process.put(:flaky_verdict, :unknown)

      scan(:boot)

      assert status(run_id) == "blocked"
      assert get(List.last(events(run_id)).payload, :reason) == "effect_outcome_ambiguous"
      assert {:ok, %{metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(metadata) != :none
      assert_receive {@effect_event, ^ref, %{blocked: 1, deferred_unknown: 0}, _}
    end

    test "a done verdict from an on-demand scan still blocks", %{run_id: run_id} do
      plant(run_id, "branch_push", "feature/done-od", "done")
      Process.put(:flaky_verdict, :done)

      scan(:on_demand)

      assert status(run_id) == "blocked"
      assert get(List.last(events(run_id)).payload, :reason) == "effect_already_done"
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

  describe "the sweep reads the reconciler's definition of repeatable" do
    for {verdict, reason} <- [
          {"done", "effect_already_done"},
          {"unknown", "effect_outcome_ambiguous"}
        ] do
      test "a #{verdict} verdict of a repeatable key blocks the run but does not mark the key unresolved",
           %{run_id: run_id} do
        key = plant_probe(run_id, unquote(verdict), true)

        sweep_with(@probe_classes)

        assert status(run_id) == "blocked"
        assert get(List.last(events(run_id)).payload, :reason) == unquote(reason)
        assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
        assert KeyStore.unresolved_version(metadata) == :none
      end

      test "a #{verdict} verdict of a key that is not repeatable marks it unresolved, as before",
           %{run_id: run_id} do
        key = plant_probe(run_id, unquote(verdict), false)

        sweep_with(@probe_classes)

        assert status(run_id) == "blocked"
        assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
        assert {:ok, _version} = KeyStore.unresolved_version(metadata)
        assert metadata["unresolved_reason"] == unquote(reason)
      end
    end

    test "the answer is read for each key: of two keys of one class only the repeatable one stays unmarked",
         %{run_id: held_run} do
      repeatable_run = UniqueIds.unique_run_id("effect-repeatable")
      start_run(repeatable_run)
      on_exit(fn -> RunControl.clear(repeatable_run) end)

      repeatable = plant_probe(repeatable_run, "done", true)
      held = plant_probe(held_run, "done", false)

      sweep_with(@probe_classes)

      assert {:ok, %{metadata: repeatable_meta}} = KeyStore.get(repeatable)
      assert KeyStore.unresolved_version(repeatable_meta) == :none
      assert {:ok, %{metadata: held_meta}} = KeyStore.get(held)
      assert {:ok, _version} = KeyStore.unresolved_version(held_meta)
    end
  end

  describe "the sweep reads whether the class may block a run (TRD-039)" do
    setup do
      # `Effect.run/4` reads the configured registry, not the sweep's option.
      original = Application.fetch_env(:foreman_server, Reconciler)

      Application.put_env(:foreman_server, Reconciler,
        classes: Map.put(Reconciler.classes(), "advisory", Advisory)
      )

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:foreman_server, Reconciler, value)
          :error -> Application.delete_env(:foreman_server, Reconciler)
        end
      end)

      :ok
    end

    for verdict <- ["done", "unknown"] do
      test "a #{verdict} verdict of an advisory key on a live run blocks nothing, cancels nothing and marks nothing: it is counted skipped and the effect is not refused",
           %{run_id: run_id, ref: ref} do
        key = plant(run_id, "advisory", "comment", unquote(verdict))
        before_events = events(run_id)

        sweep_with(@advisory_classes)

        assert events(run_id) == before_events
        assert status(run_id) == "awaiting_worker"
        assert RunControl.intent(run_id) == nil

        assert_receive {@effect_event, ^ref,
                        %{
                          skipped: 1,
                          blocked: 0,
                          on_terminal_run: 0,
                          unresolved: 0,
                          retried: 0,
                          audit_failed: 0
                        }, _}

        refute_received {@terminal_event, ^ref, _, _}
        assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
        assert KeyStore.unresolved_version(metadata) == :none
        assert KeyStore.decision(metadata) == :none

        assert :ran == Effect.run("advisory", key, fn -> :ran end, %{run_id: run_id})
        assert {:ok, :completed} = KeyStore.status(key)
      end
    end

    test "a verdict of an advisory key on a run that has ended is skipped too, and is not counted on_terminal_run",
         %{run_id: run_id, ref: ref} do
      end_run(run_id, "completed")
      key = plant(run_id, "advisory", "comment", "done")

      sweep_with(@advisory_classes)

      assert_receive {@effect_event, ^ref, %{skipped: 1, on_terminal_run: 0, blocked: 0}, _}
      refute_received {@terminal_event, ^ref, _, _}
      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(metadata) == :none
    end

    test "a not_done verdict of an advisory key decides it like any other",
         %{run_id: run_id, ref: ref} do
      key = plant(run_id, "advisory", "comment", "not_done")

      sweep_with(@advisory_classes)

      assert_receive {@effect_event, ^ref, %{retried: 1, skipped: 0, blocked: 0}, _}
      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert recovery_record(run_id, "effect_retried") != nil
    end

    test "the answer is the class's: in one sweep the advisory key's run is left running and the run of a push key is blocked",
         %{run_id: push_run, ref: ref} do
      advisory_run = UniqueIds.unique_run_id("effect-advisory")
      start_run(advisory_run)
      on_exit(fn -> RunControl.clear(advisory_run) end)

      plant(advisory_run, "advisory", "comment", "done")
      plant(push_run, "branch_push", "feature/blocks", "done")

      sweep_with(Map.merge(@classes, @advisory_classes))

      assert_receive {@effect_event, ^ref, %{skipped: 1, blocked: 1}, _}
      assert status(advisory_run) == "awaiting_worker"
      assert status(push_run) == "blocked"
    end
  end

  # --- helpers ---

  defp meta(run_id), do: %{"run_id" => run_id, "effect_class" => "branch_push"}

  defp push_meta(run_id, identity),
    do: %{"run_id" => run_id, "head_branch" => identity, "cwd" => System.tmp_dir!()}

  # The sweep's reads, scripted: only `key` is listed `ambiguous` and nothing is `started`.
  defp list_only_ambiguous(key) do
    :meck.expect(KeyStore, :list_records_checked, fn
      :ambiguous -> {:ok, [%{key: key, status: :ambiguous, metadata: %{}}]}
      _status -> {:ok, []}
    end)
  end

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

  defp plant_probe(run_id, verdict, repeatable?) do
    key = Effect.key("probe", run_id, "probe")

    :ok =
      KeyStore.mark_started(key, %{
        "run_id" => run_id,
        "effect_class" => "probe",
        "fake_verdict" => verdict,
        "repeatable" => repeatable?
      })

    :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
    key
  end

  defp sweep_with(classes),
    do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end, classes: classes)

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

  defp end_run(run_id, "completed") do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "run.complete",
        payload: %{run_id: run_id},
        aggregate_id: "run:#{run_id}"
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
