defmodule ForemanServer.Workflow.BootReconciliationTerminalKeysTest do
  @moduledoc """
  The effect keys of a run that has ended (TRD-039, P-1 part 3).

  An ended run takes neither `run.recovery_attempt` nor `run.block`, and a `completed` or
  `cancelled` run cannot be reset either (`run.reset` is accepted from `failed`, `stuck`,
  `blocked` and `paused` only), so the sweep's verdict cannot reach the run: it reaches the key.

    * `done` and `unknown` mark the key unresolved at the run stream's version and count the
      rejected block `on_terminal_run`; `Effect.run/4` then refuses the key `effect_unresolved`,
      for good on a `completed` or `cancelled` run and until an operator `run.reset` on a
      `failed` one. A `branch_push` key is refused the same way (limitation (xix) of the
      decision record: no command clears it).
    * before any scan has looked at a key the refusal is `effect_undecided`, and that refusal
      casts the scan: the real `BootReconciliation` process answers it.
    * `not_done` decides the key first and counts the rejected audit command `audit_failed`.

  The operator's Create PR over these keys, against the scripted GitHub of `EffectWorld`, is in
  `pr_create_test.exs`; a class that never blocks a run is in
  `boot_reconciliation_effect_keys_test.exs`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, RunControl}
  alias ForemanServer.Idempotency.{Effect, KeyStore, Reconciler}
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{KeyStoreReset, UniqueIds}
  alias ForemanServer.Workflow.BootReconciliation

  @terminal_event [:foreman_server, :workflow, :boot_reconciliation, :effect_on_terminal_run]
  @effect_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]

  defmodule Verdict do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    # Each key says what its reconciler answers.
    @impl true
    def reconcile(%{"fake_verdict" => verdict}), do: String.to_existing_atom(verdict)
  end

  @project_id "project-terminal-keys"
  @classes %{"pr_create" => Verdict, "branch_push" => Verdict}

  setup_all do
    repo = Path.join(System.tmp_dir!(), "terminal-keys-#{System.unique_integer([:positive])}")
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
    KeyStoreReset.reset!()

    {handler_id, ref} =
      Handler.attach_event_handlers(self(), [@terminal_event, @effect_event])

    run_id = UniqueIds.unique_run_id("terminal-keys")

    on_exit(fn ->
      :telemetry.detach(handler_id)
      RunControl.clear(run_id)
      KeyStoreReset.reset!()
    end)

    start_run(run_id)
    {:ok, run_id: run_id, ref: ref}
  end

  describe "a done or unknown verdict of a key whose run has ended" do
    for terminal <- ["completed", "cancelled", "failed"],
        {verdict, reason} <- [
          {"done", "effect_already_done"},
          {"unknown", "effect_outcome_ambiguous"}
        ] do
      test "#{verdict} on a #{terminal} run marks the key unresolved at the stream version, counts the rejected block on_terminal_run and refuses the effect",
           %{run_id: run_id, ref: ref} do
        end_run(run_id, unquote(terminal))
        key = plant(run_id, "pr_create", "feature/t:main", unquote(verdict))
        {_state, version} = Aggregate.load(Run, "run:#{run_id}")
        before_events = events(run_id)
        intent_before = RunControl.intent(run_id)

        # Nobody has looked at the key yet: it is refused as undecided, and not as unresolved.
        assert {:error, {:effect_undecided, ^key}} =
                 Effect.preflight(:pr_create, key, %{"run_id" => run_id})

        sweep()

        # The block was rejected: no record, and nothing asked the run's executor to cancel.
        assert events(run_id) == before_events
        assert RunControl.intent(run_id) == intent_before

        assert_receive {@terminal_event, ^ref, %{count: 1},
                        %{
                          run_id: ^run_id,
                          status: unquote(terminal),
                          effect_key: ^key,
                          effect_class: "pr_create",
                          effect_verdict: unquote(verdict),
                          reason: unquote(reason)
                        }}

        assert_receive {@effect_event, ^ref,
                        %{
                          on_terminal_run: 1,
                          blocked: 0,
                          audit_failed: 0,
                          retried: 0,
                          skipped: 0,
                          unresolved: 0
                        }, _}

        assert {:ok, %{status: :ambiguous, metadata: marked}} = KeyStore.get(key)
        assert KeyStore.unresolved_version(marked) == {:ok, version}
        assert marked["unresolved_reason"] == unquote(reason)
        assert KeyStore.decision(marked) == :none

        assert {:error, {:effect_unresolved, ^key}} =
                 Effect.run(:pr_create, key, fn -> flunk("repeated") end, create_meta(run_id))

        assert {:ok, %{status: :ambiguous, metadata: ^marked}} = KeyStore.get(key)
      end
    end

    for terminal <- ["completed", "cancelled"] do
      test "a #{terminal} run cannot be reset, so its marked key stays refused", %{run_id: run_id} do
        end_run(run_id, unquote(terminal))
        key = plant(run_id, "pr_create", "feature/t:main", "done")
        sweep()

        assert {:error, {:run_not_resettable, unquote(terminal)}} = reset(run_id)

        assert {:error, {:effect_unresolved, ^key}} =
                 Effect.run(:pr_create, key, fn -> flunk("repeated") end, create_meta(run_id))
      end
    end

    test "a failed run can be reset, and the reset lifts the key", %{run_id: run_id} do
      end_run(run_id, "failed")
      key = plant(run_id, "pr_create", "feature/t:main", "unknown")
      sweep()

      assert {:error, {:effect_unresolved, ^key}} =
               Effect.run(:pr_create, key, fn -> flunk("repeated") end, create_meta(run_id))

      assert {:ok, _} = reset(run_id)

      assert :ran == Effect.run(:pr_create, key, fn -> :ran end, create_meta(run_id))
      assert {:ok, :completed} = KeyStore.status(key)
    end

    for {verdict, reason} <- [
          {"done", "effect_already_done"},
          {"unknown", "effect_outcome_ambiguous"}
        ] do
      test "a branch_push key that is #{verdict} on a completed run stays refused: no command clears it",
           %{run_id: run_id, ref: ref} do
        end_run(run_id, "completed")
        key = plant(run_id, "branch_push", "feature/t", unquote(verdict))

        sweep()

        assert_receive {@effect_event, ^ref, %{on_terminal_run: 1, unresolved: 0}, _}
        assert {:ok, %{status: :ambiguous, metadata: marked}} = KeyStore.get(key)
        assert marked["unresolved_reason"] == unquote(reason)

        assert {:error, {:effect_unresolved, ^key}} =
                 Effect.run(:branch_push, key, fn -> flunk("repeated") end, push_meta(run_id))

        assert {:error, {:run_not_resettable, "completed"}} = reset(run_id)
      end
    end
  end

  describe "a not_done verdict of a key whose run has ended" do
    test "a cancelled run's key is decided first: the audit command is rejected and counted audit_failed, and the effect runs",
         %{run_id: run_id, ref: ref} do
      end_run(run_id, "cancelled")
      key = plant(run_id, "pr_create", "feature/t:main", "not_done")
      before_events = events(run_id)

      assert {:error, {:effect_undecided, ^key}} =
               Effect.preflight(:pr_create, key, %{"run_id" => run_id})

      sweep()

      assert events(run_id) == before_events

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{effect_verdict: "not_done", reason: nil, status: "cancelled"}}

      assert_receive {@effect_event, ^ref,
                      %{audit_failed: 1, on_terminal_run: 0, retried: 0, unresolved: 0}, _}

      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert KeyStore.unresolved_version(decided) == :none

      assert :ran == Effect.run(:pr_create, key, fn -> :ran end, create_meta(run_id))
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end

  describe "the scan that an undecided refusal casts, answered by the real process" do
    setup do
      original = Application.fetch_env(:foreman_server, Reconciler)

      Application.put_env(:foreman_server, Reconciler,
        classes: Map.put(Reconciler.classes(), "terminal_probe", Verdict)
      )

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:foreman_server, Reconciler, value)
          :error -> Application.delete_env(:foreman_server, Reconciler)
        end
      end)

      start_supervised!({BootReconciliation, []})

      # The process has finished its boot pass once it answers a system message.
      _ = :sys.get_state(BootReconciliation, 15_000)
      :ok
    end

    test "a completed run's key is refused undecided until the scan has looked at it, and unresolved after",
         %{run_id: run_id, ref: ref} do
      end_run(run_id, "completed")
      key = plant(run_id, "terminal_probe", "x", "done")
      meta = %{"run_id" => run_id}

      assert {:error, {:effect_undecided, ^key}} = Effect.preflight("terminal_probe", key, meta)

      # The refusal cast the scan, which reconciled the key at once: the verdict could not
      # block the completed run, so it is counted and the key is marked.
      assert_receive {@effect_event, ^ref, %{on_terminal_run: 1}, _}, 5_000
      assert {:error, {:effect_unresolved, ^key}} = Effect.preflight("terminal_probe", key, meta)
    end
  end

  # --- helpers ---

  defp create_meta(run_id),
    do: %{
      "run_id" => run_id,
      "head_branch" => "feature/t",
      "base_branch" => "main",
      "cwd" => "/w"
    }

  defp push_meta(run_id),
    do: %{"run_id" => run_id, "head_branch" => "feature/t", "cwd" => "/w"}

  defp sweep,
    do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end, classes: @classes)

  # An effect key as the sweep sees one a crash left behind: `ambiguous`, its reconciler's
  # answer in the metadata.
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

  defp start_run(run_id) do
    {:ok, _} =
      CommandRouter.dispatch_run_start(@project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [], attempt: 1}
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

  defp end_run(run_id, "cancelled") do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.cancel",
        command_id: "cancel-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{"run_id" => run_id}
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

  defp reset(run_id) do
    CommandGateway.dispatch_system(%{
      type: "run.reset",
      command_id: "reset-#{run_id}",
      aggregate_id: "run:#{run_id}",
      payload: %{"run_id" => run_id}
    })
  end

  defp events(run_id) do
    {:ok, recorded} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)

    for e <- recorded do
      %{event_type: Aggregate.event_type(e), payload: Aggregate.event_payload(e)}
    end
  end
end
