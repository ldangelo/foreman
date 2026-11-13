defmodule ForemanServer.Idempotency.EffectUndecidedTest do
  @moduledoc """
  An effect key nobody has decided is never repeated (P-1, `foreman-by6nl`): a `started`
  key (the process that began the effect died, or is still in it) and an `ambiguous` key
  with no unresolved marker and no decision are refused by `Effect.run/4` and
  `Effect.preflight/3` with `{:error, {:effect_undecided, key}}`, `fun` not called and the
  key untouched. A key is decided when it is not found, `completed` or `failed`,
  `ambiguous` with the decision `not_done` the boot sweep wrote, or of a class whose
  reconciler declares `repeatable?/1`. Re-marking a key `started` clears its decision, and
  of two callers that read the same decision only one runs the effect.

  Each such refusal asks the boot sweep to run (`BootReconciliation.scan_ambiguous_keys/0`),
  once, whether or not a sweep is running; no other refusal does. A scan that flips the key
  of an effect still in flight is overwritten by the effect's own outcome.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.{Effect, KeyStore, Reconciler}
  alias ForemanServer.TestSupport.KeyStoreReset
  alias ForemanServer.Workflow.BootReconciliation

  @run_id "run-undecided"

  defmodule Repeatable do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :unknown

    @impl true
    def repeatable?(_metadata), do: true
  end

  defmodule NotRepeatable do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :unknown

    @impl true
    def repeatable?(_metadata), do: false
  end

  defmodule NoCallbacks do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :unknown
  end

  defmodule RaisingCallback do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :unknown

    @impl true
    def repeatable?(_metadata), do: raise("callback down")
  end

  defmodule NotDone do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :not_done
  end

  setup do
    KeyStoreReset.reset!()
    original_classes = Application.get_env(:foreman_server, Reconciler)
    original_effect = Application.get_env(:foreman_server, Effect)

    Application.put_env(:foreman_server, Reconciler,
      classes:
        Map.merge(Reconciler.classes(), %{
          "probe_repeatable" => Repeatable,
          "probe_not_repeatable" => NotRepeatable,
          "probe_no_callbacks" => NoCallbacks,
          "probe_raising" => RaisingCallback,
          "probe_not_done" => NotDone
        })
    )

    on_exit(fn ->
      restore_env(Reconciler, original_classes)
      restore_env(Effect, original_effect)
      KeyStoreReset.reset!()
    end)

    :ok
  end

  defp restore_env(module, nil), do: Application.delete_env(:foreman_server, module)
  defp restore_env(module, value), do: Application.put_env(:foreman_server, module, value)

  # The refusal check reads the run stream through this seam: a reset after the marker.
  defp stream_reader!(fun),
    do: Application.put_env(:foreman_server, Effect, run_stream_reader: fun)

  defp push_meta, do: %{run_id: @run_id, head_branch: "feature/x", cwd: "/work/tree"}
  defp push_key, do: Effect.key(:branch_push, @run_id, "feature/x")

  defp create_meta,
    do: %{run_id: @run_id, head_branch: "feature/x", base_branch: "main", cwd: "/work/tree"}

  defp create_key, do: Effect.key(:pr_create, @run_id, "feature/x:main")

  defp subject(:branch_push), do: {push_key(), push_meta()}
  defp subject(:pr_create), do: {create_key(), create_meta()}

  defp probe_meta, do: %{run_id: @run_id}
  defp probe_key(class), do: Effect.key(class, @run_id, "probe")

  # `Effect.run/4` with a function that reports itself to `reporter` and returns `:ran`.
  defp attempt(class, key, meta, reporter \\ self()) do
    Effect.run(
      class,
      key,
      fn ->
        send(reporter, :ran)
        :ran
      end,
      meta
    )
  end

  # The process that began the effect dies inside it: the key stays `started`.
  defp crash_mid_effect!(class, key, meta) do
    test_pid = self()

    pid =
      spawn(fn ->
        Effect.run(
          class,
          key,
          fn ->
            send(test_pid, :in_effect)
            Process.sleep(:infinity)
          end,
          meta
        )
      end)

    monitor = Process.monitor(pid)
    assert_receive :in_effect
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, :started} = KeyStore.status(key)
  end

  # What the boot sweep does to the `started` key of a run with no live executor.
  defp orphan!(key), do: :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")

  describe "a key nobody has decided is refused" do
    for class <- [:branch_push, :pr_create] do
      test "#{class}: a started key (the process died mid-effect), by run/4 and preflight/3" do
        class = unquote(class)
        {key, meta} = subject(class)
        crash_mid_effect!(class, key, meta)
        {:ok, before_key} = KeyStore.get(key)

        assert {:error, {:effect_undecided, ^key}} = attempt(class, key, meta)
        refute_received :ran
        assert {:error, {:effect_undecided, ^key}} = Effect.preflight(class, key, meta)
        assert {:ok, ^before_key} = KeyStore.get(key)
      end

      test "#{class}: an ambiguous key with no marker and no decision, by run/4 and preflight/3" do
        class = unquote(class)
        {key, meta} = subject(class)
        crash_mid_effect!(class, key, meta)
        orphan!(key)
        {:ok, %{status: :ambiguous, metadata: metadata} = before_key} = KeyStore.get(key)
        assert KeyStore.unresolved_version(metadata) == :none
        assert KeyStore.decision(metadata) == :none

        assert {:error, {:effect_undecided, ^key}} = attempt(class, key, meta)
        refute_received :ran
        assert {:error, {:effect_undecided, ^key}} = Effect.preflight(class, key, meta)
        assert {:ok, ^before_key} = KeyStore.get(key)
      end
    end

    test "a decision other than not_done decides nothing" do
      key = push_key()
      :ok = KeyStore.mark_started(key, Map.put(%{"run_id" => @run_id}, "decision", "done"))
      orphan!(key)
      {:ok, before_key} = KeyStore.get(key)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      refute_received :ran
      assert {:ok, ^before_key} = KeyStore.get(key)
    end

    test "a started key that carries a decision is still undecided: only an ambiguous key is decided" do
      key = push_key()
      :ok = KeyStore.mark_started(key, %{"run_id" => @run_id, "decision" => "not_done"})
      {:ok, before_key} = KeyStore.get(key)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      refute_received :ran
      assert {:ok, ^before_key} = KeyStore.get(key)
    end

    test "a started record whose metadata is not a map is its own refusal, never a repeat" do
      key = push_key()
      :ets.insert(:foreman_idempotency_keys, {key, :started, "garbage"})

      assert {:error, {:effect_check_failed, {:metadata_not_a_map, "garbage"}}} =
               attempt(:branch_push, key, push_meta())

      refute_received :ran
    end

    test "an unresolved marker still wins over a decision: refused as unresolved" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)
      :ok = KeyStore.mark_unresolved(key, 4, "effect_outcome_ambiguous")
      {:ok, before_key} = KeyStore.get(key)

      assert {:error, {:effect_unresolved, ^key}} = attempt(:branch_push, key, push_meta())
      refute_received :ran
      assert {:ok, ^before_key} = KeyStore.get(key)
    end
  end

  describe "a key that is decided runs" do
    test "a key that was never written" do
      assert :ran == attempt(:branch_push, push_key(), push_meta())
      assert {:ok, %{status: :completed}} = KeyStore.get(push_key())
    end

    test "a completed key runs again: behaviour is unchanged" do
      key = push_key()
      assert :ran == attempt(:branch_push, key, push_meta())
      assert {:ok, %{status: :completed}} = KeyStore.get(key)

      assert :ran == attempt(:branch_push, key, push_meta())
      assert_received :ran
      assert_received :ran
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
      assert :ok = Effect.preflight(:branch_push, key, push_meta())
    end

    test "a failed key runs again: behaviour is unchanged" do
      key = create_key()

      assert {:error, :rejected} ==
               Effect.run(:pr_create, key, fn -> {:error, :rejected} end, create_meta())

      assert {:ok, %{status: :failed}} = KeyStore.get(key)

      assert :ran == attempt(:pr_create, key, create_meta())
      assert_received :ran
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end

    test "an ambiguous key with the decision not_done runs and is re-marked started with the decision cleared" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)
      {:ok, decided} = KeyStore.get(key)

      # preflight only reads: the decision is still on the key afterwards
      assert :ok = Effect.preflight(:branch_push, key, push_meta())
      assert {:ok, ^decided} = KeyStore.get(key)

      test_pid = self()

      assert :ran ==
               Effect.run(
                 :branch_push,
                 key,
                 fn ->
                   send(test_pid, {:inside, KeyStore.get(key)})
                   :ran
                 end,
                 push_meta()
               )

      assert_received {:inside, {:ok, %{status: :started, metadata: started}}}
      assert KeyStore.decision(started) == :none
      assert started["decision"] == nil
      assert started["run_id"] == @run_id
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end
  end

  describe "the decision does not outlive the re-mark: a second crash is undecided again" do
    test "a decided key that crashes again (the decided re-mark)" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)

      # The decided attempt starts, which consumes the decision, and its process dies too.
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      refute_received :ran
    end

    test "a settled key that still carries a decision (the clear re-mark)" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)

      # The scan flipped the key while its effect was in flight, decided it, and the
      # effect then settled: the merge keeps the decision on the completed key.
      :ok = KeyStore.mark_completed(key)
      assert {:ok, %{status: :completed, metadata: stale}} = KeyStore.get(key)
      assert KeyStore.decision(stale) == :not_done

      # A settled key may run again, and that attempt crashes too.
      crash_mid_effect!(:branch_push, key, push_meta())
      assert {:ok, %{status: :started, metadata: started}} = KeyStore.get(key)
      assert KeyStore.decision(started) == :none
      orphan!(key)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      refute_received :ran
    end

    test "a lifted key that carries a decision (the lifted re-mark)" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)
      :ok = KeyStore.mark_unresolved(key, 1, "effect_outcome_ambiguous")
      assert {:ok, %{metadata: both}} = KeyStore.get(key)
      assert KeyStore.decision(both) == :not_done
      assert KeyStore.unresolved_version(both) == {:ok, 1}

      # The operator's reset follows the marker, so the next attempt lifts the key and
      # starts; that attempt crashes too.
      stream_reader!(fn _stream, _from -> {:ok, [%{event_type: "RunReset"}]} end)
      crash_mid_effect!(:branch_push, key, push_meta())
      assert {:ok, %{status: :started, metadata: started}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(started) == :none
      assert KeyStore.decision(started) == :none
      orphan!(key)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      refute_received :ran
    end
  end

  describe "the decision is consumed by compare-and-set" do
    test "two callers that both read the decision: exactly one runs the effect" do
      key = push_key()
      test_pid = self()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)

      # Both callers' reads wait in the suspended store's mailbox, so both see the
      # decision before either one writes.
      server = Process.whereis(KeyStore)
      :ok = :sys.suspend(server)

      callers =
        try do
          callers =
            for _caller <- 1..2 do
              Task.async(fn -> attempt(:branch_push, key, push_meta(), test_pid) end)
            end

          await_reads(server, key, 2)
          callers
        after
          :ok = :sys.resume(server)
        end

      results = Task.await_many(callers)

      assert Enum.count(results, &(&1 == :ran)) == 1
      assert Enum.count(results, &(&1 == {:error, {:effect_undecided, key}})) == 1
      assert_received :ran
      refute_received :ran
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end
  end

  # Wait until `count` reads of `key` are queued in the suspended store.
  defp await_reads(server, key, count) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_reads(server, key, count, deadline)
  end

  defp await_reads(server, key, count, deadline) do
    {:messages, messages} = Process.info(server, :messages)
    queued = Enum.count(messages, &match?({:"$gen_call", _from, {:get, ^key}}, &1))

    cond do
      queued >= count ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{queued} of #{count} reads of #{key} reached the store")

      true ->
        Process.sleep(5)
        await_reads(server, key, count, deadline)
    end
  end

  describe "a class whose reconciler declares repeatable?/1 true is never undecided" do
    test "its started key runs" do
      key = probe_key(:probe_repeatable)
      crash_mid_effect!(:probe_repeatable, key, probe_meta())

      assert :ok = Effect.preflight(:probe_repeatable, key, probe_meta())
      assert :ran == attempt(:probe_repeatable, key, probe_meta())
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end

    test "its ambiguous key with no decision runs" do
      key = probe_key(:probe_repeatable)
      crash_mid_effect!(:probe_repeatable, key, probe_meta())
      orphan!(key)

      assert :ok = Effect.preflight(:probe_repeatable, key, probe_meta())
      assert :ran == attempt(:probe_repeatable, key, probe_meta())
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end

    test "its decided key runs without competing for the decision, and the decision is cleared" do
      key = probe_key(:probe_repeatable)
      crash_mid_effect!(:probe_repeatable, key, probe_meta())
      orphan!(key)
      :ok = KeyStore.mark_decided(key, :not_done)

      test_pid = self()

      assert :ran ==
               Effect.run(
                 :probe_repeatable,
                 key,
                 fn ->
                   send(test_pid, {:inside, KeyStore.get(key)})
                   :ran
                 end,
                 probe_meta()
               )

      assert_received {:inside, {:ok, %{status: :started, metadata: started}}}
      assert KeyStore.decision(started) == :none
    end

    test "an unresolved marker still refuses it" do
      key = probe_key(:probe_repeatable)
      crash_mid_effect!(:probe_repeatable, key, probe_meta())
      orphan!(key)
      :ok = KeyStore.mark_unresolved(key, 3, "effect_already_done")

      assert {:error, {:effect_unresolved, ^key}} = attempt(:probe_repeatable, key, probe_meta())
      refute_received :ran
    end
  end

  describe "a class that is not declared repeatable stays refused" do
    for class <- [
          :probe_not_repeatable,
          :probe_no_callbacks,
          :probe_raising,
          :probe_unregistered
        ] do
      test "#{class}: started and ambiguous keys" do
        class = unquote(class)
        key = probe_key(class)
        crash_mid_effect!(class, key, probe_meta())

        assert {:error, {:effect_undecided, ^key}} = attempt(class, key, probe_meta())
        assert {:error, {:effect_undecided, ^key}} = Effect.preflight(class, key, probe_meta())

        orphan!(key)
        assert {:error, {:effect_undecided, ^key}} = attempt(class, key, probe_meta())
        assert {:error, {:effect_undecided, ^key}} = Effect.preflight(class, key, probe_meta())
        refute_received :ran
      end
    end
  end

  describe "an undecided refusal asks the boot sweep to run" do
    # No BootReconciliation runs in the test environment, so this process stands in for it:
    # the request production sends to the sweep's name arrives in this mailbox.
    setup do
      true = Process.register(self(), BootReconciliation)
      :ok
    end

    for class <- [:branch_push, :pr_create] do
      test "#{class}: run/4 and preflight/3 each cast one scan request for a started key" do
        class = unquote(class)
        {key, meta} = subject(class)
        crash_mid_effect!(class, key, meta)
        refute_received {:"$gen_cast", :scan_ambiguous_keys}

        assert {:error, {:effect_undecided, ^key}} = attempt(class, key, meta)
        assert_received {:"$gen_cast", :scan_ambiguous_keys}
        refute_received {:"$gen_cast", :scan_ambiguous_keys}

        assert {:error, {:effect_undecided, ^key}} = Effect.preflight(class, key, meta)
        assert_received {:"$gen_cast", :scan_ambiguous_keys}
        refute_received {:"$gen_cast", :scan_ambiguous_keys}
      end
    end

    test "an ambiguous key with no marker and no decision casts too" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      orphan!(key)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      assert_received {:"$gen_cast", :scan_ambiguous_keys}
    end

    test "every refusal casts: coalescing is the sweep's work, not the caller's" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())

      for _refusal <- 1..3 do
        assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())
      end

      for _request <- 1..3, do: assert_received({:"$gen_cast", :scan_ambiguous_keys})
      refute_received {:"$gen_cast", :scan_ambiguous_keys}
    end

    test "the other refusals ask for nothing" do
      # unresolved
      unresolved = push_key()
      crash_mid_effect!(:branch_push, unresolved, push_meta())
      orphan!(unresolved)
      :ok = KeyStore.mark_unresolved(unresolved, 4, "effect_outcome_ambiguous")

      assert {:error, {:effect_unresolved, ^unresolved}} =
               attempt(:branch_push, unresolved, push_meta())

      # a marker that is not a version
      malformed = Effect.key(:branch_push, @run_id, "feature/malformed")
      :ok = KeyStore.mark_started(malformed, %{"unresolved_at_run_version" => "garbage"})
      :ok = KeyStore.mark_ambiguous(malformed, "orphaned_started_key")

      assert {:error, {:effect_marker_malformed, ^malformed}} =
               attempt(:branch_push, malformed, %{push_meta() | head_branch: "feature/malformed"})

      # a record that cannot be read
      garbage = Effect.key(:branch_push, @run_id, "feature/garbage")
      :ets.insert(:foreman_idempotency_keys, {garbage, :started, "garbage"})

      assert {:error, {:effect_check_failed, {:metadata_not_a_map, "garbage"}}} =
               attempt(:branch_push, garbage, %{push_meta() | head_branch: "feature/garbage"})

      # an intent that cannot be recorded
      assert {:error, {:intent_not_recorded, :cwd_missing}} =
               attempt(:branch_push, push_key(), Map.delete(push_meta(), :cwd))

      refute_received {:"$gen_cast", :scan_ambiguous_keys}
    end

    test "a key that is decided, or repeatable, is not refused and asks for nothing" do
      decided = push_key()
      crash_mid_effect!(:branch_push, decided, push_meta())
      orphan!(decided)
      :ok = KeyStore.mark_decided(decided, :not_done)
      assert :ran == attempt(:branch_push, decided, push_meta())

      repeatable = probe_key(:probe_repeatable)
      crash_mid_effect!(:probe_repeatable, repeatable, probe_meta())
      assert :ran == attempt(:probe_repeatable, repeatable, probe_meta())

      refute_received {:"$gen_cast", :scan_ambiguous_keys}
    end

    test "the refusal is the same when no sweep is running" do
      key = push_key()
      crash_mid_effect!(:branch_push, key, push_meta())
      Process.unregister(BootReconciliation)
      refute Process.whereis(BootReconciliation)

      assert {:error, {:effect_undecided, ^key}} = attempt(:branch_push, key, push_meta())

      assert {:error, {:effect_undecided, ^key}} =
               Effect.preflight(:branch_push, key, push_meta())

      refute_received :ran
      refute_received {:"$gen_cast", :scan_ambiguous_keys}
    end
  end

  describe "a scan that flips the key of an effect in flight" do
    # A `started` key with no writer stamp (written before the stamp existed) of a run with no
    # live executor is orphaned by the sweep, so it can be flipped to `ambiguous` while its
    # effect is still running, and the same scan reconciles the flipped key at once. The
    # effect's own settle then overwrites the status: the key ends in the effect's outcome.
    # (A stamped key with a live writer is not flipped: see the writer-stamp tests.)
    defp scan, do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

    for {what, result, ends} <- [
          {"completes", :ran, :completed},
          {"fails", {:error, :boom}, :failed}
        ] do
      test "an effect that #{what} ends #{ends}, whatever the scan did to its key meanwhile" do
        key = probe_key(:probe_not_done)
        test_pid = self()

        assert unquote(result) ==
                 Effect.run(
                   :probe_not_done,
                   key,
                   fn ->
                     # Make it a pre-stamp key.
                     :ok = KeyStore.mark_started(key, KeyStore.recovery_fields_cleared())
                     scan()
                     send(test_pid, {:in_flight, KeyStore.get(key)})
                     unquote(result)
                   end,
                   probe_meta()
                 )

        # Flipped while the effect was running, and decided by the same scan ...
        assert_received {:in_flight, {:ok, %{status: :ambiguous, metadata: flipped}}}
        assert KeyStore.decision(flipped) == :not_done

        # ... and then the effect's own outcome overwrote both.
        assert {:ok, %{status: unquote(ends)}} = KeyStore.get(key)
        assert :ok = Effect.preflight(:probe_not_done, key, probe_meta())
      end

      test "an effect that #{what} leaves neither the decision nor the unresolved marker the scan wrote" do
        key = probe_key(:probe_not_done)

        assert unquote(result) ==
                 Effect.run(
                   :probe_not_done,
                   key,
                   fn ->
                     scan()
                     :ok = KeyStore.mark_unresolved(key, 7, "effect_already_done")
                     unquote(result)
                   end,
                   probe_meta()
                 )

        assert {:ok, %{status: unquote(ends), metadata: settled}} = KeyStore.get(key)
        assert KeyStore.decision(settled) == :none
        assert KeyStore.unresolved_version(settled) == :none
      end
    end

    test "a re-mark of a settled key that carries a marker clears it" do
      key = probe_key(:probe_not_done)
      :ok = KeyStore.mark_started(key, probe_meta())
      :ok = KeyStore.mark_unresolved(key, 7, "effect_already_done")
      # The scan marked the key while its effect was in flight; the settle left the marker.
      :ok = KeyStore.mark_completed(key)
      assert {:ok, %{metadata: stale}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(stale) == {:ok, 7}

      test_pid = self()

      assert :ran ==
               Effect.run(
                 :probe_not_done,
                 key,
                 fn ->
                   send(test_pid, {:in_flight, KeyStore.get(key)})
                   :ran
                 end,
                 probe_meta()
               )

      assert_received {:in_flight, {:ok, %{status: :started, metadata: started}}}
      assert KeyStore.unresolved_version(started) == :none
    end
  end
end
