defmodule ForemanServer.Workflow.BootReconciliationAmbiguousKeysTest do
  @moduledoc """
  Tests for `BootReconciliation`'s ambiguous-key reconciliation (TRD-077).

  Covers:
    - `do_reconcile_ambiguous_keys/1` emits telemetry with accurate skipped/retried
      counts derived from actual `CrashRecovery.reconcile/2` outcomes
    - `reconcile_ambiguous_keys/1` defers when CommandRouter is not ready
    - `scan_ambiguous_keys/0` public cast API is wired to `handle_cast`

  The full boot-scan path (`handle_continue(:reconcile, ...)`) requires the
  EventStore/CommandRouter/BootReconciliation supervision tree and is
  verified in CI where the full app boots.

  TRD-003 (P-1, part 2): an undecided refusal of `Effect` casts `scan_ambiguous_keys/0`,
  and the real process answers it (coalesced, whatever the number of refusals queued behind
  a running scan); a failed read of the stored keys is told from a store with no such keys.

  TRD-2026-4212be7e / RTE-T003 / TRD-077.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias ForemanServer.Idempotency.{Effect, IdempotencyKey, KeyStore, Reconciler}
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{Eventually, KeyStoreReset}
  alias ForemanServer.Workflow.BootReconciliation

  @ambiguous_event [:foreman_server, :workflow, :boot_reconciliation, :ambiguous_reconciled]
  @effect_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]
  @config ForemanServer.Agents.JidoCheckpointStore
  @rows :ambiguous_keys_fake_repo

  setup do
    Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])
    Application.ensure_all_started(:telemetry)

    if :ets.info(:foreman_idempotency_keys) != :undefined do
      :ets.delete_all_objects(:foreman_idempotency_keys)
    end

    {handler_id, ref} =
      ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), [@ambiguous_event])

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if :ets.info(:foreman_idempotency_keys) != :undefined do
        :ets.delete_all_objects(:foreman_idempotency_keys)
      end
    end)

    {:ok, telemetry_ref: ref}
  end

  describe "do_reconcile_ambiguous_keys/1" do
    test "empty ambiguous key list → telemetry fires with zero counts" do
      BootReconciliation.do_reconcile_ambiguous_keys()

      assert_receive {@ambiguous_event, _, measurements, _},
                     5_000,
                     "scan must emit ambiguous_reconciled telemetry"

      assert measurements == %{skipped: 0, retried: 0}
    end

    test "ambiguous key with no side effects → retried = 1 (key remediated, not skipped)" do
      # No run_id: has_no_side_effects?/1 safely returns true → no ProjectionStore hit.
      # CrashRecovery.reconcile returns {:retry, :no_side_effects} for :ambiguous status.
      :ets.insert(:foreman_idempotency_keys, {"ambig-no-effects", :ambiguous, %{}})

      BootReconciliation.do_reconcile_ambiguous_keys()

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: retried}, _}, 5_000
      assert retried == 1
    end

    test "ambiguous key with side effects → retried = 1, key remediated to :completed" do
      # side_effects_check always returns false → "has side effects" → mark_completed
      # then {:retry, :side_effects_present}.
      :ets.insert(
        :foreman_idempotency_keys,
        {"ambig-has-effects", :ambiguous, %{run_id: "run-x"}}
      )

      side_effects_check = fn _key -> false end
      BootReconciliation.do_reconcile_ambiguous_keys(side_effects_check)

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: retried}, _}, 5_000
      assert retried == 1, "ambiguous key with side effects must be retried after remediation"

      # Verify the key was remediated to :completed.
      assert KeyStore.status("ambig-has-effects") == {:ok, :completed}
    end

    test "mixed ambiguous keys → counts sum correctly" do
      # 2 no-effects + 1 has-effects
      :ets.insert(:foreman_idempotency_keys, {"ambig-mix-1", :ambiguous, %{}})
      :ets.insert(:foreman_idempotency_keys, {"ambig-mix-2", :ambiguous, %{}})
      :ets.insert(:foreman_idempotency_keys, {"ambig-mix-3", :ambiguous, %{run_id: "run-z"}})

      side_effects_check = fn _key -> false end
      BootReconciliation.do_reconcile_ambiguous_keys(side_effects_check)

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: retried}, _}, 5_000
      assert retried == 3, "all 3 ambiguous keys must be retried (2 no-effects + 1 has-effects)"
    end
  end

  describe "do_reconcile_ambiguous_keys/1 orphaned started keys (foreman-dyppr)" do
    alias ForemanServer.RunExecutorLiveness

    setup do
      RunExecutorLiveness.clear_all()
      on_exit(fn -> RunExecutorLiveness.clear_all() end)
      :ok
    end

    defp no_effects(_key), do: true

    test "a started key whose run is not live becomes ambiguous and is then reconciled" do
      :ets.insert(
        :foreman_idempotency_keys,
        {"orphan-1", :started, %{run_id: "run-dead", task_id: "t1"}}
      )

      BootReconciliation.do_reconcile_ambiguous_keys(&no_effects/1)

      # Marked ambiguous by the orphan step, then picked up by the existing
      # reconcile path in the same scan (no side effects -> retry, which
      # leaves the key ambiguous for the retried dispatch to resolve).
      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: 1}, _}, 5_000
      assert KeyStore.status("orphan-1") == {:ok, :ambiguous}
      assert {:ok, %{metadata: %{reason: "orphaned_started_key"}}} = KeyStore.get("orphan-1")
    end

    test "a started key whose run is live stays started" do
      :ok = RunExecutorLiveness.record("run-live", self(), :infinity)

      :ets.insert(
        :foreman_idempotency_keys,
        {"live-1", :started, %{run_id: "run-live", task_id: "t2"}}
      )

      BootReconciliation.do_reconcile_ambiguous_keys(&no_effects/1)

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: 0}, _}, 5_000
      assert KeyStore.status("live-1") == {:ok, :started}
    end

    test "a started key without a run_id is left started" do
      :ets.insert(:foreman_idempotency_keys, {"norun-1", :started, %{}})

      BootReconciliation.do_reconcile_ambiguous_keys(&no_effects/1)

      assert_receive {@ambiguous_event, _, %{retried: 0}, _}, 5_000
      assert KeyStore.status("norun-1") == {:ok, :started}
    end

    test "keys of other statuses are untouched by the orphan step" do
      for {key, status} <- [{"done-1", :completed}, {"fail-1", :failed}] do
        :ets.insert(:foreman_idempotency_keys, {key, status, %{run_id: "run-dead"}})
      end

      BootReconciliation.do_reconcile_ambiguous_keys(&no_effects/1)

      assert_receive {@ambiguous_event, _, %{skipped: 0, retried: 0}, _}, 5_000
      assert KeyStore.status("done-1") == {:ok, :completed}
      assert KeyStore.status("fail-1") == {:ok, :failed}
    end
  end

  describe "reconcile_ambiguous_keys/1 (deferral when CommandRouter absent)" do
    test "defers when command_router_ready? returns false" do
      # CommandRouter is a real supervised singleton that the full app
      # boots unconditionally, so scan_branch/0 only returns
      # :schedule_not_ready while the router is genuinely absent. Stop it
      # under its own supervisor (mirrors boot_reconciliation_test.exs's
      # "run_terminated/2 defers dispatch when CommandRouter is not
      # registered") and restart it before the test ends so later tests
      # in this run still see a live router.
      app_sup = Process.whereis(ForemanServer.Application)
      assert is_pid(app_sup)

      :ok = Supervisor.terminate_child(app_sup, ForemanServer.CommandRouter)
      assert is_nil(Process.whereis(ForemanServer.CommandRouter))

      on_exit(fn ->
        case Process.whereis(ForemanServer.CommandRouter) do
          nil -> Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)
          _pid -> :ok
        end
      end)

      state = %{
        reconciled?: false,
        scanned?: false,
        vcs_scan_pid: nil,
        vcs_scan_ref: nil,
        ambiguous_reconciled?: false
      }

      result_state = BootReconciliation.reconcile_ambiguous_keys(state)

      assert result_state.ambiguous_reconciled? == false,
             "ambiguous_reconciled? must remain false when scan is deferred"

      refute_receive {@ambiguous_event, _, _, _},
                     100,
                     "no telemetry synchronously when scan is deferred"

      {:ok, _} = Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)
    end
  end

  describe "scan_ambiguous_keys/0 (GenServer cast API)" do
    test "cast returns :ok without error when GenServer is not running" do
      # Without the full app boot, BootReconciliation GenServer is absent.
      # The cast is silently dropped (same behaviour as production with a dead process).
      assert :ok = BootReconciliation.scan_ambiguous_keys()

      refute_receive {@ambiguous_event, _, _, _},
                     200,
                     "no telemetry when GenServer is not running"
    end
  end

  defmodule Verdicts do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    # Every effect did not happen. A key whose metadata says `hold` keeps the scan inside
    # this call until the test sends `:release` to the scan's own process: that is how a scan
    # is made to be running while refusals arrive.
    @impl true
    def reconcile(metadata) do
      if metadata["hold"] do
        send(
          Application.fetch_env!(:foreman_server, :ambiguous_scan_probe),
          {:reconciling, self()}
        )

        receive do
          :release -> :ok
        end
      end

      :not_done
    end
  end

  defmodule FakeRepo do
    @moduledoc false
    # Rows live in a public ETS table the test owns, metadata makes a JSON round trip
    # (string keys, as from Postgres), and the statuses named under `:raise_for` raise when
    # they are listed, as a database that is down does. The `KeyStore` that wrote the keys
    # keeps its ETS copy, which is what `list_by_status/1` falls back to.
    @rows :ambiguous_keys_fake_repo

    # `:fail_insert` makes every write answer an error, as a database that went away does.
    def insert(changeset, _opts) do
      if :ets.lookup(@rows, :fail_insert) == [],
        do: write(changeset),
        else: {:error, :db_down}
    end

    defp write(changeset) do
      key = Ecto.Changeset.get_field(changeset, :key)
      status = Ecto.Changeset.get_field(changeset, :status)

      metadata =
        changeset |> Ecto.Changeset.get_field(:metadata) |> Jason.encode!() |> Jason.decode!()

      :ets.insert(@rows, {key, status, metadata})
      {:ok, %IdempotencyKey{key: key, status: status, metadata: metadata}}
    end

    def get(IdempotencyKey, key) do
      # `:raise_get` makes a read of a key the `KeyStore` has no ETS copy of raise.
      if :ets.lookup(@rows, :raise_get) != [],
        do: raise(DBConnection.ConnectionError, "connection refused")

      case :ets.lookup(@rows, key) do
        [{^key, status, metadata}] ->
          %IdempotencyKey{key: key, status: status, metadata: metadata}

        [] ->
          nil
      end
    end

    def all(%{wheres: [%{params: [{status, _type}]}]} = query) do
      raising = with [{:raise_for, statuses}] <- :ets.lookup(@rows, :raise_for), do: statuses

      if is_list(raising) and status in raising do
        raise DBConnection.ConnectionError, "connection refused"
      else
        for {key, ^status, metadata} <- :ets.tab2list(@rows), is_binary(key) do
          if query.select,
            do: key,
            else: %IdempotencyKey{key: key, status: status, metadata: metadata}
        end
      end
    end
  end

  defp put_scan_probe_class do
    original = Application.get_env(:foreman_server, Reconciler)

    Application.put_env(:foreman_server, Reconciler,
      classes: Map.put(Reconciler.classes(), "scan_probe", Verdicts)
    )

    on_exit(fn ->
      if original,
        do: Application.put_env(:foreman_server, Reconciler, original),
        else: Application.delete_env(:foreman_server, Reconciler)
    end)
  end

  defp unique_run(label), do: "run-#{label}-#{System.unique_integer([:positive])}"

  # An effect key of the probe class, as the boot sweep sees the one a crash left behind.
  defp plant_ambiguous(run_id, extra \\ %{}) do
    key = Effect.key("scan_probe", run_id, "probe")

    :ok =
      KeyStore.mark_started(
        key,
        Map.merge(%{"run_id" => run_id, "effect_class" => "scan_probe"}, extra)
      )

    :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
    key
  end

  # A `started` effect key: the process that began the effect died, or is still in it.
  defp plant_started(run_id) do
    key = Effect.key("scan_probe", run_id, "probe")
    :ok = KeyStore.mark_started(key, %{"run_id" => run_id, "effect_class" => "scan_probe"})
    key
  end

  # A workflow-door RunExecutor is registered in RunExecutorRegistry under its run id, which
  # is what `RunExecutor.pid_for/1` reads: the sweep takes the run to be live.
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

  describe "an undecided refusal asks the sweep to run, and the real process answers" do
    @describetag :capture_log

    setup %{telemetry_ref: ref} do
      put_scan_probe_class()
      start_supervised!({BootReconciliation, []})

      # The new process has finished its boot pass once it answers a system message; the
      # boot pass's own telemetry is not one of the scans these tests count.
      _ = :sys.get_state(BootReconciliation, 15_000)
      flush_scans(ref)
      :ok
    end

    defp flush_scans(ref) do
      receive do
        {@ambiguous_event, ^ref, _measurements, _metadata} -> flush_scans(ref)
      after
        0 -> :ok
      end
    end

    test "the refusal casts a scan that decides the key, and the next Effect.run runs" do
      run_id = unique_run("scan-decides")
      key = plant_ambiguous(run_id)
      meta = %{run_id: run_id}

      assert {:error, {:effect_undecided, ^key}} =
               Effect.run("scan_probe", key, fn -> flunk("repeated") end, meta)

      Eventually.await(
        fn ->
          match?({:ok, %{metadata: %{"decision" => "not_done"}}}, KeyStore.get(key))
        end,
        message: "the scan the refusal cast never decided the key"
      )

      assert {:ok, %{status: :ambiguous}} = KeyStore.get(key)
      assert :ran == Effect.run("scan_probe", key, fn -> :ran end, meta)
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "fifty refusals while a scan runs are answered by one further scan, not fifty",
         %{telemetry_ref: ref} do
      Application.put_env(:foreman_server, :ambiguous_scan_probe, self())
      on_exit(fn -> Application.delete_env(:foreman_server, :ambiguous_scan_probe) end)

      held_run = unique_run("scan-held")
      burst_run = unique_run("scan-burst")
      _held = plant_ambiguous(held_run, %{"hold" => true})

      # The burst's key stays undecided whatever a scan does: its run has a live executor, so
      # the scan does not orphan it, and every refusal of it is real.
      live_executor(burst_run)
      undecided = plant_started(burst_run)
      meta = %{run_id: burst_run}

      assert :ok = BootReconciliation.scan_ambiguous_keys()
      assert_receive {:reconciling, scan}, 5_000

      for _refusal <- 1..50 do
        assert {:error, {:effect_undecided, ^undecided}} =
                 Effect.run("scan_probe", undecided, fn -> flunk("repeated") end, meta)
      end

      send(scan, :release)

      # The scan that was running, and one further scan for all fifty refusals.
      assert_receive {@ambiguous_event, ^ref, _, _}, 5_000
      assert_receive {@ambiguous_event, ^ref, _, _}, 5_000
      refute_receive {@ambiguous_event, ^ref, _, _}, 500
      assert {:ok, :started} = KeyStore.status(undecided)
    end
  end

  describe "the boot pass of the real process" do
    @describetag :capture_log

    test "decides the ambiguous key a crash left, so the first Effect.run after boot runs" do
      put_scan_probe_class()
      run_id = unique_run("boot-decides")
      key = plant_ambiguous(run_id)
      meta = %{run_id: run_id}

      assert {:error, {:effect_undecided, ^key}} = Effect.preflight("scan_probe", key, meta)

      # `init/1` continues into the boot pass; the process answers once it is done.
      start_supervised!({BootReconciliation, []})
      _ = :sys.get_state(BootReconciliation, 15_000)

      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert :ran == Effect.run("scan_probe", key, fn -> :ran end, meta)
    end
  end

  describe "a failed read of the stored keys is not read as no keys" do
    @describetag :capture_log

    setup do
      original = Application.get_env(:foreman_server, @config, [])
      if :ets.whereis(@rows) == :undefined, do: :ets.new(@rows, [:set, :public, :named_table])
      :ets.delete_all_objects(@rows)

      on_exit(fn ->
        Application.put_env(:foreman_server, @config, original)
        restart_key_store()
        KeyStoreReset.reset!()
      end)

      put_scan_probe_class()
      Application.put_env(:foreman_server, @config, repo: FakeRepo)
      restart_key_store()

      {handler_id, ref} = Handler.attach_event_handlers(self(), [@effect_event])
      on_exit(fn -> :telemetry.detach(handler_id) end)
      {:ok, effect_ref: ref}
    end

    defp restart_key_store do
      Supervisor.terminate_child(ForemanServer.Application, KeyStore)
      {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
      :ok
    end

    defp fail_listing(statuses), do: :ets.insert(@rows, {:raise_for, List.wrap(statuses)})

    defp sweep, do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

    test "the ambiguous keys cannot be listed: nothing is decided, it is counted unresolved and the key stays refused",
         %{effect_ref: ref} do
      run_id = unique_run("read-ambiguous")
      key = plant_ambiguous(run_id)
      fail_listing(:ambiguous)

      sweep()

      assert_receive {@effect_event, ^ref,
                      %{unresolved: 1, retried: 0, audit_failed: 0, skipped: 0, blocked: 0}, _}

      assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :none

      assert {:error, {:effect_undecided, ^key}} =
               Effect.preflight("scan_probe", key, %{run_id: run_id})
    end

    test "the started keys cannot be listed: no key is marked, it is counted unresolved and the key stays refused",
         %{effect_ref: ref} do
      run_id = unique_run("read-started")
      key = plant_started(run_id)
      fail_listing(:started)

      sweep()

      assert_receive {@effect_event, ^ref, %{unresolved: 1, retried: 0, audit_failed: 0}, _}
      assert {:ok, :started} = KeyStore.status(key)

      assert {:error, {:effect_undecided, ^key}} =
               Effect.preflight("scan_probe", key, %{run_id: run_id})
    end

    test "a started key that cannot be marked is logged and counted unresolved: the sweep does not crash and the key stays started",
         %{effect_ref: ref} do
      run_id = unique_run("mark-fails")
      key = plant_started(run_id)
      :ets.insert(@rows, {:fail_insert, true})

      log = capture_log(fn -> sweep() end)

      assert log =~ "could not be read or marked"
      assert log =~ key
      assert_receive {@effect_event, ^ref, %{unresolved: 1, retried: 0, audit_failed: 0}, _}
      assert {:ok, :started} = KeyStore.status(key)

      :ets.delete(@rows, :fail_insert)
      sweep()
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "a started key whose read exits is logged and counted unresolved: the sweep does not crash",
         %{effect_ref: ref} do
      run_id = unique_run("get-exits")
      key = Effect.key("scan_probe", run_id, "probe")

      # Listed by the database, unknown to the store's ETS copy: judging it reads the database.
      :ets.insert(
        @rows,
        {key, :started, %{"run_id" => run_id, "effect_class" => "scan_probe"}}
      )

      :ets.insert(@rows, {:raise_get, true})

      log = capture_log(fn -> sweep() end)
      :ets.delete(@rows, :raise_get)

      assert log =~ "could not be read or marked"
      assert_receive {@effect_event, ^ref, %{unresolved: 1, retried: 0, audit_failed: 0}, _}
    end

    test "both reads failing count twice, and the next sweep decides the key once the database answers",
         %{effect_ref: ref} do
      run_id = unique_run("read-both")
      key = plant_ambiguous(run_id)
      fail_listing([:started, :ambiguous])

      sweep()

      assert_receive {@effect_event, ^ref, %{unresolved: 2, retried: 0, audit_failed: 0}, _}
      assert {:ok, %{metadata: metadata}} = KeyStore.get(key)
      assert KeyStore.decision(metadata) == :none

      fail_listing([])
      sweep()

      assert {:ok, %{metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert :ok = Effect.preflight("scan_probe", key, %{run_id: run_id})
    end
  end
end
