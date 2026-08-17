defmodule ForemanServer.Workflow.DispatcherTest do
  @moduledoc """
  Tests for `ForemanServer.Workflow.Dispatcher` terminal-event coverage.

  Verifies that when `ProjectionStore` broadcasts a terminal run event
  (`RunCancelled`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`), the
  Dispatcher forwards it to `BootReconciliation.run_terminated/2` so the
  orphan-task scan and dispatch path mirrors the boot path. Earlier
  builds only reacted to `RunCancelled`; this test pins the full set.

  Tests call `Dispatcher.handle_info({:projection_event, envelope}, ...)`
  directly so they exercise the dispatcher's pattern-matching without
  polluting the shared ProjectionStore with synthetic fixtures.
  """

  use ExUnit.Case, async: false
  alias EventStore.RecordedEvent
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.CommandGateway
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.BootReconciliation
  alias ForemanServer.Workflow.Dispatcher

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(ForemanServer.Workflow.Catalog, ForemanServer.Workflow.Catalog)
    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)
    ensure_started(ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.Dispatcher)

    ensure_started(
      ForemanServer.Workflow.BootReconciliation,
      ForemanServer.Workflow.BootReconciliation
    )

    :ok
  end

  setup do
    parent = self()
    boot_name = ForemanServer.Workflow.BootReconciliation
    real_pid = Process.whereis(boot_name)

    forwarder =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        forward_loop(parent)
      end)

    Process.unregister(boot_name)
    :erlang.register(boot_name, forwarder)

    on_exit(fn ->
      if Process.whereis(boot_name) == forwarder do
        Process.unregister(boot_name)
      end

      if Process.alive?(real_pid) do
        :erlang.register(boot_name, real_pid)
      end

      Process.exit(forwarder, :kill)
    end)

    :ok
  end

  describe "terminal run events fan out to BootReconciliation.run_terminated/2" do
    test "RunCancelled uses default reason 'run_cancelled'" do
      send_envelope(%{event_type: "RunCancelled", data: %{run_id: "run-x", status: "cancelled"}})
      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_cancelled"}}, 500
    end

    test "RunFlaggedStuck uses default reason 'run_flagged_stuck'" do
      send_envelope(%{
        event_type: "RunFlaggedStuck",
        data: %{run_id: "run-x", flagged_at: 1_700_000_000_000}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_flagged_stuck"}}, 500
    end

    test "RunCompleted uses default reason 'run_completed'" do
      send_envelope(%{event_type: "RunCompleted", data: %{run_id: "run-x", status: "completed"}})

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_completed"}}, 500
    end

    test "RunFailed uses default reason 'run_failed'" do
      send_envelope(%{
        event_type: "RunFailed",
        data: %{run_id: "run-x", status: "failed", failure_reason: "boom"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_failed"}}, 500
    end

    test "RunBlocked uses default reason 'run_blocked' (lease cleanup fan-out)" do
      # RunLifecycleReconciler treats RunBlocked as terminal; the
      # Dispatcher must fan out to BootReconciliation so the
      # orphan-task scan runs and the Beads-DB lease is released.
      # Without this clause the lease would leak forever after a
      # blocked run.
      send_envelope(%{
        event_type: "RunBlocked",
        data: %{run_id: "run-x"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_blocked"}}, 500
    end
  end

  describe "reason override and missing run_id" do
    test "payload reason overrides event_type default" do
      send_envelope(%{
        event_type: "RunCancelled",
        data: %{run_id: "run-x", reason: "operator_supplied", status: "cancelled"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "operator_supplied"}}, 500
    end

    test "missing run_id is a no-op (no crash, no dispatch)" do
      send_envelope(%{
        event_type: "RunCancelled",
        data: %{project_id: "project-x", status: "cancelled"}
      })

      refute_receive {:"$gen_cast", {:run_terminated, _, _}}, 100
    end

    test "non-terminal events do not trigger run_terminated" do
      send_envelope(%{event_type: "TaskApproved", data: %{task_id: "task-x"}})
      refute_receive {:"$gen_cast", {:run_terminated, _, _}}, 100
    end

    test "string-keyed envelope is dispatched" do
      send_envelope(%{
        "event_type" => "RunCancelled",
        "data" => %{run_id: "run-x", status: "cancelled"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, "run-x", "run_cancelled"}}, 500
    end
  end

  describe "RunBlocked releases the per-DB Beads lease" do
    test "RunBlocked dispatches lease.release for the run bound to a Beads workflow" do
      run_id = "run-lease-#{System.unique_integer([:positive])}"
      task_id = "task-lease-#{System.unique_integer([:positive])}"
      db_path = "/private/tmp/cg-dispatcher-lease-#{System.unique_integer([:positive])}.db"
      stream = BeadsDbLease.stream_id(db_path)

      on_exit(fn ->
        _ = Store.delete_stream(stream, :any_version, :hard)
      end)

      ms = System.system_time(:millisecond)

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "lease.acquire",
                 command_id: "test:lease-acquire:#{run_id}:#{ms}",
                 aggregate_id: stream,
                 payload: %{
                   db_path: db_path,
                   run_id: run_id,
                   task_id: task_id,
                   acquired_at_ms: ms
                 }
               })

      assert_eventually(fn ->
        {:ok, [%RecordedEvent{event_type: "BeadsDbLeaseAcquired"}]} =
          Store.read_stream_forward(stream, 0, 1)

        :ok
      end)

      seed_task_with_beads_db_path(task_id, run_id, db_path)

      send_envelope(%{
        event_type: "RunBlocked",
        data: %{run_id: run_id, reason: "gate_timeout"}
      })

      assert_receive {:"$gen_cast", {:run_terminated, ^run_id, "gate_timeout"}}, 500

      assert_eventually(fn ->
        {:ok, events} = Store.read_stream_forward(stream, 0, 10)

        case List.last(events) do
          %RecordedEvent{
            event_type: "BeadsDbLeaseReleased",
            data: %{run_id: ^run_id, reason: "gate_timeout"}
          } ->
            :ok

          other ->
            {:still_waiting, other}
        end
      end)
    end
  end

  describe "TaskDispatched enters the run-start path through RunAdmission" do
    test "calls RunAdmission.start/2 and not CommandRouter.dispatch_run_start/3 directly" do
      parent = self()
      task_id = "task-dispatch-#{System.unique_integer([:positive])}"
      run_id = "run-dispatch-#{System.unique_integer([:positive])}"
      project_id = "project-dispatch-#{System.unique_integer([:positive])}"
      approval_id = "approval-dispatch-#{System.unique_integer([:positive])}"
      workflow_snapshot = %{phases: [%{id: "phase-1", kind: "exec"}]}
      phase_specs = [%{id: "phase-1", kind: "exec"}]

      task_proj = %{
        task_id: task_id,
        run_id: run_id,
        project_id: project_id,
        approval_id: approval_id,
        workflow_snapshot: workflow_snapshot,
        phase_specs: phase_specs
      }

      :meck.new(ForemanServer.ProjectionStore, [:no_link])
      :meck.new(ForemanServer.RunAdmission, [:no_link])
      :meck.new(ForemanServer.CommandRouter, [:no_link])
      :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

      :meck.expect(ForemanServer.ProjectionStore, :task_projection, fn ^task_id -> task_proj end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, payload ->
        send(parent, {:run_admission_start, payload})
        {:ok, :queued}
      end)

      :meck.expect(ForemanServer.CommandRouter, :dispatch_run_start, fn _, _, _ ->
        send(parent, :dispatch_run_start_called)
        {:error, :should_not_be_called}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _, _ ->
        send(parent, :start_run_called)
        {:ok, :started}
      end)

      on_exit(fn ->
        for mod <-
              [
                ForemanServer.ProjectionStore,
                ForemanServer.RunAdmission,
                ForemanServer.CommandRouter,
                ForemanServer.Workflow.RunSupervisor
              ] do
          if :meck.validate(mod), do: :meck.unload(mod)
        end
      end)

      send_envelope(%{event_type: "TaskDispatched", data: %{task_id: task_id}})

      assert_receive {:run_admission_start, payload}, 500

      assert payload == %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: workflow_snapshot,
               phase_specs: phase_specs
             }

      assert :meck.called(ForemanServer.RunAdmission, :start, :_)
      refute :meck.called(ForemanServer.CommandRouter, :dispatch_run_start, :_)
      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
      refute_receive :dispatch_run_start_called, 0
      refute_receive :start_run_called, 0
    end
  end


  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp send_envelope(envelope) do
    pid = Process.whereis(Dispatcher)
    # Calling handle_info directly so the dispatcher's pattern-matching runs
    # without going through ProjectionStore (no shared-state pollution).
    {:noreply, _state} = Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})
    _ = pid
  end

  defp forward_loop(parent) do
    receive do
      {:EXIT, _, _} ->
        :ok

      msg ->
        send(parent, msg)
        forward_loop(parent)
    end
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end

  # Drive TaskCreated + TaskApproved through ProjectionStore so the
  # dispatcher's `db_path_for_run/1` (which calls `tasks_by_run_id/1`)
  # finds a task whose `workflow_snapshot.implementation.beads_database_path`
  defp seed_task_with_beads_db_path(task_id, run_id, db_path) do
    task_created = %{
      event_type: "TaskCreated",
      payload: %{
        task_id: task_id,
        project_id: "project-lease-test",
        title: "lease test task",
        status: "open",
        task_type: "implement-trd-beads"
      }
    }

    task_approved = %{
      event_type: "TaskApproved",
      payload: %{
        task_id: task_id,
        approval_id: "approval-#{task_id}",
        approved_by: "operator-test",
        approved_at: DateTime.to_iso8601(DateTime.utc_now()),
        run_id: run_id,
        workflow_snapshot: %{
          implementation: %{
            beads_database_path: db_path
          }
        }
      }
    }

    ProjectionStore.apply_events([task_created, task_approved])

    seeded = ProjectionStore.task_projection(task_id)
    assert seeded != nil
    assert seeded.workflow_snapshot.implementation.beads_database_path == db_path
    assert seeded.run_id == run_id
  end

  # Poll an assertion until it returns `:ok` or a 1s budget elapses.
  # Returns the final value so a failure message can name the last seen state.
  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    poll_until(fun, timeout_ms)
  end

  defp poll_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    case fun.() do
      :ok ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("assert_eventually timed out; last value: #{inspect(fun.())}")
        else
          Process.sleep(20)
          do_poll(fun, deadline)
        end
    end
  end
end
