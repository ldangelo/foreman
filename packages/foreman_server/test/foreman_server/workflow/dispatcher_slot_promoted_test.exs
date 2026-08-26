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

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.Dispatcher

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    {:ok, _} = Application.ensure_all_started(:meck)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)

    :ok
  end

  setup do
    :meck.new(ForemanServer.ProjectionStore, [:no_link])
    :meck.new(ForemanServer.RunAdmission, [:no_link])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

    # Default: no task found; admission returns queued; supervisor returns ok
    :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn _ -> [] end)
    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> {:ok, :queued} end)
    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _, _ -> {:ok, :started} end)

    on_exit(fn ->
      for mod <-
            [
              ForemanServer.ProjectionStore,
              ForemanServer.RunAdmission,
              ForemanServer.Workflow.RunSupervisor
            ] do
        if :meck.validate(mod), do: :meck.unload(mod)
      end
    end)

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

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
