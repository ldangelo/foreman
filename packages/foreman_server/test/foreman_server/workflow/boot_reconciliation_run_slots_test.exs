defmodule ForemanServer.Workflow.BootReconciliationRunSlotsTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias EventStore.RecordedEvent
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.{ProjectionStore, Telemetry}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.Workflow.BootReconciliation

  setup_all do
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    # start_boot_reconciliation? is false in test config.
    ensure_started(
      ForemanServer.Workflow.BootReconciliation,
      ForemanServer.Workflow.BootReconciliation
    )

    :ok
  end

  setup do
    # A previous example may have left a scan cast in flight that is still appending; the scan
    # runs inside BootReconciliation, so a call there is a barrier for it.
    _ = :sys.get_state(BootReconciliation)
    RunSlotsReset.reset!()
    cleanup_boot_reconciliation_runs()

    on_exit(fn -> RunSlotsReset.reset!() end)

    # The boot scan reads each registered project's own `run_slots:<project_id>` stream.
    project = H.register_project(System.tmp_dir!(), config: %{})
    {:ok, project: project, stream: RunSlots.stream_id(project)}
  end

  setup do
    {handler_id, ref} =
      ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), Telemetry.all_events())

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, telemetry_ref: ref}
  end

  describe "scan_run_slot_orphans/0" do
    test "no holders or waiters → no dispatches" do
      assert :ok = BootReconciliation.scan_run_slot_orphans()
    end

    test "holder with terminal run → run_slots.release dispatched", %{
      telemetry_ref: ref,
      project: project,
      stream: stream
    } do
      terminal_run_id = unique_id("orphan-holder-run")

      seed_terminal_run!(terminal_run_id, project)
      # Append holder directly to bypass aggregate actor state issues
      append_run_slot_holder!(project, terminal_run_id, 0)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        case Store.read_stream_forward(stream, 0, 20) do
          {:ok, events} ->
            case List.last(events) do
              %RecordedEvent{event_type: "RunSlotReleased", data: data}
              when is_map(data) ->
                run_id_str = Map.get(data, "run_id") || Map.get(data, :run_id)

                if run_id_str == terminal_run_id do
                  :ok
                else
                  {:still_waiting, List.last(events)}
                end

              other ->
                {:still_waiting, other}
            end

          other ->
            {:still_waiting, other}
        end
      end)

      assert_receive {[:foreman_server, :run_slots, :reconciled], ^ref,
                      %{holders_dropped: 1, waiters_dropped: 0}, %{phase: :boot}}
    end

    test "holder with live run → no release dispatched", %{project: project, stream: stream} do
      live_run_id = unique_id("live-holder-run")

      seed_live_run!(live_run_id, project)
      append_run_slot_holder!(project, live_run_id, 0)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      # The scan is a cast handled synchronously inside BootReconciliation, so
      # a call to the same process is a mailbox barrier: it returns only after
      # the scan (and every command it dispatched) has completed.
      _ = :sys.get_state(BootReconciliation)

      assert {:ok, events} = Store.read_stream_forward(stream, 0, 20)
      released_events = Enum.filter(events, &(&1.event_type == "RunSlotReleased"))
      assert released_events == []
    end

    test "waiter with terminal run → run_slots.remove_waiter dispatched", %{
      telemetry_ref: ref,
      project: project,
      stream: stream
    } do
      holder_run_id = unique_id("holder-run-waiter-test")
      orphan_waiter_run_id = unique_id("orphan-waiter-run")

      seed_live_run!(holder_run_id, project)
      seed_terminal_run!(orphan_waiter_run_id, project)
      # Append holder at v0, waiter at v1
      append_run_slot_holder!(project, holder_run_id, 0)
      append_run_slot_waiter!(project, orphan_waiter_run_id, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        case Store.read_stream_forward(stream, 0, 30) do
          {:ok, events} ->
            removed? =
              Enum.any?(events, fn
                %RecordedEvent{
                  event_type: "RunSlotWaiterRemoved",
                  data: data
                } ->
                  Map.get(data, "run_id") == orphan_waiter_run_id or
                    Map.get(data, :run_id) == orphan_waiter_run_id

                _ ->
                  false
              end)

            if removed?, do: :ok, else: {:still_waiting, removed?}

          other ->
            {:still_waiting, other}
        end
      end)

      assert_receive {[:foreman_server, :run_slots, :reconciled], ^ref,
                      %{holders_dropped: 0, waiters_dropped: 1}, %{phase: :boot}}
    end

    test "waiter with live run → no remove_waiter dispatched", %{project: project, stream: stream} do
      holder_run_id = unique_id("live-holder-run-waiter")
      live_waiter_run_id = unique_id("live-waiter-run")

      seed_live_run!(holder_run_id, project)
      seed_live_run!(live_waiter_run_id, project)
      append_run_slot_holder!(project, holder_run_id, 0)
      append_run_slot_waiter!(project, live_waiter_run_id, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      # The scan is a cast handled synchronously inside BootReconciliation, so
      # a call to the same process is a mailbox barrier: it returns only after
      # the scan (and every command it dispatched) has completed.
      _ = :sys.get_state(BootReconciliation)

      assert {:ok, events} = Store.read_stream_forward(stream, 0, 30)
      removed_events = Enum.filter(events, &(&1.event_type == "RunSlotWaiterRemoved"))
      assert removed_events == []
    end

    test "survives force-kill of the project's run_slots actor mid-scan (regression: race with RunSlotsReset.reset!/0)",
         %{project: project, stream: stream} do
      terminal_run_id = unique_id("kill-orphan-run")
      seed_terminal_run!(terminal_run_id, project)
      append_run_slot_holder!(project, terminal_run_id, 0)

      # Force the actor into the same dead state RunSlotsReset.reset!/0
      # creates between test cases — this is the real-world race.
      [{actor_pid, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)
      ref = Process.monitor(actor_pid)
      Process.exit(actor_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^actor_pid, _}, 1_000

      boot_pid = Process.whereis(BootReconciliation)

      _log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Without the try/catch rescue in release_run_slot/3 this scan
          # propagates `(EXIT) killed` up through handle_info and terminates
          # BootReconciliation, which cascades into ForemanServer.Application
          # shutting down and Process.whereis(ForemanServer.EventStore) going
          # nil for the rest of the test file.
          assert :ok = BootReconciliation.scan_run_slot_orphans()

          # Barrier: surfaces an exit if the rescue is missing.
          _ = :sys.get_state(BootReconciliation)
        end)

      assert Process.alive?(boot_pid)
      assert Process.whereis(BootReconciliation) == boot_pid
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_id(prefix) do
    "#{prefix}-slot-orphan-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp cleanup_boot_reconciliation_runs do
    :sys.replace_state(ProjectionStore, fn state ->
      %{
        state
        | runs:
            Map.reject(state.runs, fn {run_id, _run} ->
              String.contains?(run_id, "-slot-orphan-")
            end)
      }
    end)
  end

  defp append_run_slot_holder!(project, run_id, version) do
    ForemanServer.CommandGateway.dispatch_system(%{
      type: "run_slots.acquire",
      aggregate_id: RunSlots.stream_id(project),
      command_id: "seed-holder:#{run_id}:#{version}",
      payload: %{
        run_id: run_id,
        project_id: project,
        capacity: 1,
        acquired_at_ms: System.system_time(:millisecond)
      }
    })
  end

  defp append_run_slot_waiter!(project, run_id, version) do
    ForemanServer.CommandGateway.dispatch_system(%{
      type: "run_slots.acquire",
      aggregate_id: RunSlots.stream_id(project),
      command_id: "seed-waiter:#{run_id}:#{version}",
      payload: %{
        run_id: run_id,
        project_id: project,
        capacity: 0,
        acquired_at_ms: System.system_time(:millisecond)
      }
    })
  end

  defp seed_live_run!(run_id, project) do
    append_and_apply("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique_id("task"),
      project_id: project,
      workflow_snapshot: %{},
      sequence: 0
    })
  end

  defp seed_terminal_run!(run_id, project) do
    append_and_apply("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique_id("task"),
      project_id: project,
      workflow_snapshot: %{},
      sequence: 0
    })

    append_and_apply("run:#{run_id}", 1, "RunCompleted", %{
      run_id: run_id,
      sequence: 1
    })
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end

  defp assert_eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    case fun.() do
      :ok ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("assert_eventually timed out; last value: #{inspect(other)}")
        else
          Process.sleep(20)
          poll_until(fun, deadline)
        end
    end
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
