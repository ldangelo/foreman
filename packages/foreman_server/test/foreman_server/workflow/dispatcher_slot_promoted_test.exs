defmodule ForemanServer.Workflow.DispatcherSlotPromotedTest do
  @moduledoc """
  Tests for Dispatcher.handle_slot_promoted/2 — the handler that reacts
  to RunSlotTransferred when a waiter is promoted to holder.

  The handler:
    1. Extracts acquired_run_id from the event envelope
    2. Looks up the task via ProjectionStore.tasks_by_run_id/1
    3. Re-enters RunAdmission.start/2 for the promoted run
    4. Starts RunSupervisor if admission succeeds
  """

  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.MeckScope
  alias ForemanServer.Workflow.Dispatcher

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    {:ok, _} = Application.ensure_all_started(:meck)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)

    # Mocking ProjectionStore copies a 5.5k-line module (~1.3 s): once per module. Passthrough, so
    # the functions this test does not stub stay real between tests and while the Dispatcher is
    # resumed at test exit.
    MeckScope.new_once!(ForemanServer.ProjectionStore)
  end

  setup do
    # The app's real Dispatcher stays subscribed to ProjectionStore and handles
    # terminal/resume events emitted by earlier tests. Unfrozen, it would run
    # against the modules mocked below (calling the mocked RunSupervisor.start_run
    # and RunAdmission.start) and put messages in this test's mailbox. See
    # ForemanServer.DispatcherQuiesce.
    :ok = ForemanServer.DispatcherQuiesce.suspend!()

    :meck.new(ForemanServer.RunAdmission, [:no_link])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

    # Default: no task found; admission returns queued; supervisor returns ok
    :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn _ -> [] end)
    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> {:ok, :queued} end)
    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _, _ -> {:ok, :started} end)

    on_exit(fn ->
      for mod <-
            [
              ForemanServer.RunAdmission,
              ForemanServer.Workflow.RunSupervisor
            ] do
        if :meck.validate(mod), do: :meck.unload(mod)
      end
    end)

    MeckScope.restore_on_exit!(ForemanServer.ProjectionStore)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests: RunSlotTransferred causes admission to be re-entered
  # ---------------------------------------------------------------------------

  describe "RunSlotTransferred re-enters admission" do
    test "calls RunAdmission.start/2 with the promoted run's task data" do
      task_id = "task-slot-#{unique_id()}"
      run_id = "run-promoted-#{unique_id()}"
      project_id = "project-slot-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      # Override ProjectionStore to return the task
      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      # Override RunAdmission: assert it is called with correct payload, return slot_queued
      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, payload ->
        assert payload.run_id == run_id
        assert payload.task_id == task_id
        {:ok, :slot_queued}
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      assert :meck.called(ForemanServer.RunAdmission, :start, :_)
    end

    test "returns noreply without crashing when acquired_run_id is missing" do
      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old"
          # no acquired_run_id
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      # No call to RunAdmission — the guard clause short-circuited
      refute :meck.called(ForemanServer.RunAdmission, :start, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: RunSlotTransferred with successful admission starts supervisor
  # ---------------------------------------------------------------------------

  describe "RunSlotTransferred with successful admission starts supervisor" do
    test "calls RunSupervisor.start_run when admission returns {:ok, _run_started_event}" do
      task_id = "task-admit-#{unique_id()}"
      run_id = "run-admit-#{unique_id()}"
      project_id = "project-admit-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      # Admission succeeds
      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload ->
        {:ok, %{event_type: "RunStarted"}}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn ^run_id, _task ->
        {:ok, :child_started}
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end

    # A promo is an async hand-off: the queue snapshot is taken when the waiter is
    # enqueued, not when the slot frees. The task can be closed or failed in between.
    test "does not start the run when its task is no longer promotable" do
      run_id = "run-stale-#{unique_id()}"

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id ->
        [%{task_id: "task-#{run_id}", status: "closed", project_id: "p1", approval_id: "a1"}]
      end)

      # The dispatch door and the run supervisor must stay untouched: if the guard
      # failed to short-circuit, meck would raise on the unexpected call.
      :meck.expect(ForemanServer.RunAdmission, :start, fn _project_id, _payload ->
        {:ok, %{event_type: "RunStarted"}}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _run_id, _task ->
        {:ok, :child_started}
      end)

      test_pid = self()

      # `terminate_slot/2` hands the slot back through `CommandGateway.dispatch_system/1`.
      mock_command_gateway(test_pid)

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, transferred_envelope(run_id)}, %{})

      refute :meck.called(ForemanServer.RunAdmission, :start, :_)
      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)

      # The slot the dead task held goes back to the queue, and its waiter is dropped.
      assert_receive {:dispatched,
                      %{
                        type: "run_slots.release",
                        payload: %{run_id: ^run_id, reason: "task_closed"}
                      }},
                     1_000

      assert_receive {:dispatched,
                      %{type: "run_slots.remove_waiter", payload: %{run_id: ^run_id}}},
                     1_000
    end

    test "still starts the run when the task is promotable (open or in_progress)" do
      run_id = "run-ok-#{unique_id()}"

      # `status: "open"` plus an approval_id is the shape the guard must let through.
      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id ->
        [
          %{
            task_id: "task-#{run_id}",
            status: "open",
            approval_id: "approval-#{run_id}",
            project_id: "project-admit-test",
            workflow_snapshot: %{implementation: %{}}
          }
        ]
      end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn _project_id, _payload ->
        {:ok, %{event_type: "RunStarted"}}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn ^run_id, _task ->
        {:ok, :child_started}
      end)

      test_pid = self()

      mock_command_gateway(test_pid)

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, transferred_envelope(run_id)}, %{})

      assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)

      refute_receive {:dispatched, %{type: "run_slots.release"}}
      refute_receive {:dispatched, %{type: "run_slots.remove_waiter"}}
    end

    # "blocked" is a recoverable status (`Aggregates.Task` accepts "blocked" -> "open"),
    # so promotion starts the run like any other startable status. Releasing the slot
    # with a non-capacity-freeing reason would drop that run permanently.
    test "still starts the run when its task is blocked" do
      run_id = "run-blocked-#{unique_id()}"

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id ->
        [
          %{
            task_id: "task-#{run_id}",
            status: "blocked",
            approval_id: "approval-#{run_id}",
            project_id: "project-admit-test",
            workflow_snapshot: %{implementation: %{}}
          }
        ]
      end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn _project_id, _payload ->
        {:ok, %{event_type: "RunStarted"}}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn ^run_id, _task ->
        {:ok, :child_started}
      end)

      test_pid = self()

      mock_command_gateway(test_pid)

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, transferred_envelope(run_id)}, %{})

      assert :meck.called(ForemanServer.RunAdmission, :start, :_)
      assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)

      refute_receive {:dispatched, %{type: "run_slots.release"}}
      refute_receive {:dispatched, %{type: "run_slots.remove_waiter"}}
    end

    test "calls RunSupervisor.start_run when admission returns {:ok, nil} (already started)" do
      task_id = "task-admit-nil-#{unique_id()}"
      run_id = "run-admit-nil-#{unique_id()}"
      project_id = "project-admit-nil-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      # Admission succeeds with nil (already started)
      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload ->
        {:ok, nil}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn ^run_id, _task ->
        {:ok, :child_started}
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end

    test "does NOT start supervisor when admission returns :slot_queued" do
      task_id = "task-queued-#{unique_id()}"
      run_id = "run-queued-#{unique_id()}"
      project_id = "project-queued-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload ->
        {:ok, :slot_queued}
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end

    test "does NOT start supervisor when admission returns :queued" do
      task_id = "task-leased-#{unique_id()}"
      run_id = "run-leased-#{unique_id()}"
      project_id = "project-leased-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload ->
        {:ok, :queued}
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: the CommandGateway mock must not shadow the real module or leak
  # ---------------------------------------------------------------------------

  describe "CommandGateway mock hygiene" do
    # Both checks go through `mock_command_gateway/1`, the same helper the promoted-run
    # tests use, so they fail when that helper regresses instead of passing on a
    # private copy of the setup.

    test "an unstubbed CommandGateway function is still callable under the mock" do
      mock_command_gateway(self())

      # Without `:passthrough` the mock exports only the stubbed functions, so an
      # unrelated call raises UndefinedFunctionError in whichever process made it.
      assert function_exported?(ForemanServer.CommandGateway, :dispatch_operator, 1)

      assert {:error, _} =
               ForemanServer.CommandGateway.dispatch_operator(%{
                 type: "not.a.command",
                 command_id: "cmd-#{unique_id()}",
                 payload: %{}
               })
    end

    test "the mock is unloaded even after it was invalidated" do
      # Registered before the mock exists, so it runs AFTER the helper's own teardown:
      # ExUnit runs `on_exit` callbacks in reverse registration order. Asserting here
      # rather than calling `unload_command_gateway/0` by hand is what makes this fail
      # if `mock_command_gateway/1` ever stops registering its cleanup.
      on_exit(fn ->
        # The unload is unconditional, so it also runs on an invalidated mock; gating it
        # on `:meck.validate/1` would leave the module mocked for the rest of the suite.
        refute ForemanServer.CommandGateway in :meck.mocked()

        # The real module is back in place, so an unstubbed call reaches the real code.
        assert {:error, _} =
                 ForemanServer.CommandGateway.dispatch_operator(%{
                   type: "not.a.command",
                   command_id: "cmd-#{unique_id()}",
                   payload: %{}
                 })
      end)

      mock_command_gateway(self())

      # A raising expectation is what invalidates a mock in practice.
      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn _command ->
        raise "invalidate the mock"
      end)

      assert catch_error(ForemanServer.CommandGateway.dispatch_system(%{type: "x"}))
      refute :meck.validate(ForemanServer.CommandGateway)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: RunSlotTransferred with failed admission logs warning
  # ---------------------------------------------------------------------------

  describe "RunSlotTransferred with failed admission logs warning" do
    test "returns noreply when no task is found for the promoted run" do
      run_id = "run-no-task-#{unique_id()}"

      # Override: tasks_by_run_id returns empty list
      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [] end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      # No admission attempted when task not found
      refute :meck.called(ForemanServer.RunAdmission, :start, :_)
      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end

    test "returns noreply when admission returns an error" do
      task_id = "task-fail-#{unique_id()}"
      run_id = "run-fail-#{unique_id()}"
      project_id = "project-fail-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload ->
        {:error, {:slot_acquire_failed, :unknown}}
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{})

      assert :meck.called(ForemanServer.RunAdmission, :start, :_)
      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_id, do: System.unique_integer([:positive])

  # `:passthrough` keeps the functions this test does not stub callable, so a stray
  # call cannot turn into an UndefinedFunctionError in another process.
  defp mock_command_gateway(test_pid) do
    :meck.new(ForemanServer.CommandGateway, [:no_link, :passthrough])

    :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
      send(test_pid, {:dispatched, command})
      {:ok, :dispatched}
    end)

    on_exit(&unload_command_gateway/0)

    :ok
  end

  # Unconditional on purpose: `:meck.validate/1` is false once a mock has been
  # invalidated, and skipping the unload then leaves the module mocked suite-wide.
  defp unload_command_gateway do
    try do
      :meck.unload(ForemanServer.CommandGateway)
    catch
      _, _ -> :ok
    end
  end

  defp transferred_envelope(run_id) do
    %{
      event_type: "RunSlotTransferred",
      data: %{
        released_run_id: "run-old",
        acquired_run_id: run_id,
        acquired_at_ms: System.system_time(:millisecond)
      }
    }
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
