defmodule ForemanServer.Workflow.DispatcherWorkSubmittedTest do
  @moduledoc """
  Tests for Dispatcher.handle_work_submitted/2 — the handler that reacts
  to WorkSubmitted when a work request is submitted.

  The handler:
    1. Extracts work_id from the event envelope
    2. Looks up the work projection via ProjectionStore.work_projection/1
    3. Builds a RunPayload via Work.RunPayload.from_work_projection/1
    4. Calls RunAdmission.start/3 for the work
    5. Starts RunSupervisor if admission succeeds with a non-queued result
  """

  use ExUnit.Case, async: false

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

    # Default: no work projection; admission returns queued; supervisor returns ok
    :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn _ -> nil end)
    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _, _ -> {:ok, :queued} end)
    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _, _ -> {:ok, :started} end)

    on_exit(fn ->
      for mod <-
            [ForemanServer.ProjectionStore, ForemanServer.RunAdmission, ForemanServer.Workflow.RunSupervisor] do
        if :meck.validate(mod), do: :meck.unload(mod)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests: WorkSubmitted triggers admission
  # ---------------------------------------------------------------------------

  describe "WorkSubmitted triggers admission" do
    test "calls RunAdmission.start/3 with work projection data" do
      work_id = "work-submit-#{unique_id()}"
      project_id = "project-work-submit"
      run_id = "run-work-#{unique_id()}"

      work_proj = %{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: "sub-#{unique_id()}",
        workflow_snapshot: %{
          "phases" => [%{"id" => "phase-1"}]
        }
      }

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> work_proj end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, payload, [] ->
        assert payload.run_id == run_id
        assert payload.project_id == project_id
        {:ok, :queued}
      end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: project_id,
          run_id: run_id,
          submission_id: "sub-123",
          workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      assert :meck.called(ForemanServer.RunAdmission, :start, :_)
    end

    test "returns noreply without crashing when work_id is missing" do
      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          project_id: "proj-1"
          # no work_id
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      refute :meck.called(ForemanServer.RunAdmission, :start, :_)
    end

    test "returns noreply when work projection is nil" do
      work_id = "work-no-proj-#{unique_id()}"

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> nil end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: "proj-1",
          run_id: "run-1",
          submission_id: "sub-1",
          workflow_snapshot: %{}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      # No call to RunAdmission when projection is nil
      refute :meck.called(ForemanServer.RunAdmission, :start, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: WorkSubmitted with admitted starts supervisor
  # ---------------------------------------------------------------------------

  describe "WorkSubmitted with admitted starts supervisor" do
    test "calls RunSupervisor.start_run when admission returns {:ok, map()}" do
      work_id = "work-admit-#{unique_id()}"
      project_id = "project-admit-test"
      run_id = "run-work-admit-#{unique_id()}"

      work_proj = %{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: "sub-#{unique_id()}",
        workflow_snapshot: %{
          "phases" => [%{"id" => "phase-1"}]
        }
      }

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> work_proj end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload, [] ->
        {:ok, %{event_type: "RunStarted"}}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn ^run_id, _proj ->
        {:ok, :child_started}
      end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: project_id,
          run_id: run_id,
          submission_id: "sub-admit",
          workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end

    test "calls RunSupervisor.start_run when admission returns {:ok, nil}" do
      work_id = "work-admit-nil-#{unique_id()}"
      project_id = "project-admit-nil-test"
      run_id = "run-work-admit-nil-#{unique_id()}"

      work_proj = %{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: "sub-#{unique_id()}",
        workflow_snapshot: %{}
      }

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> work_proj end)

      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload, [] ->
        {:ok, nil}
      end)

      :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn ^run_id, _proj ->
        {:ok, :child_started}
      end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: project_id,
          run_id: run_id,
          submission_id: "sub-admit-nil",
          workflow_snapshot: %{}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: WorkSubmitted with :queued does NOT start supervisor
  # ---------------------------------------------------------------------------

  describe "WorkSubmitted with :queued does NOT start supervisor" do
    test "does NOT start supervisor when admission returns {:ok, :queued}" do
      work_id = "work-queued-#{unique_id()}"
      project_id = "project-queued-test"
      run_id = "run-work-queued-#{unique_id()}"

      work_proj = %{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: "sub-#{unique_id()}",
        workflow_snapshot: %{}
      }

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> work_proj end)
      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload, [] -> {:ok, :queued} end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: project_id,
          run_id: run_id,
          submission_id: "sub-queued",
          workflow_snapshot: %{}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: WorkSubmitted with :slot_queued does NOT start supervisor
  # ---------------------------------------------------------------------------

  describe "WorkSubmitted with :slot_queued does NOT start supervisor" do
    test "does NOT start supervisor when admission returns {:ok, :slot_queued}" do
      work_id = "work-slot-queued-#{unique_id()}"
      project_id = "project-slot-queued-test"
      run_id = "run-work-slot-queued-#{unique_id()}"

      work_proj = %{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: "sub-#{unique_id()}",
        workflow_snapshot: %{}
      }

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> work_proj end)
      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload, [] -> {:ok, :slot_queued} end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: project_id,
          run_id: run_id,
          submission_id: "sub-slot-queued",
          workflow_snapshot: %{}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: WorkSubmitted with failed admission logs warning
  # ---------------------------------------------------------------------------

  describe "WorkSubmitted with failed admission logs warning" do
    test "returns noreply when admission returns an error" do
      work_id = "work-fail-#{unique_id()}"
      project_id = "project-fail-test"
      run_id = "run-work-fail-#{unique_id()}"

      work_proj = %{
        work_id: work_id,
        project_id: project_id,
        run_id: run_id,
        submission_id: "sub-#{unique_id()}",
        workflow_snapshot: %{}
      }

      :meck.expect(ForemanServer.ProjectionStore, :work_projection, fn ^work_id -> work_proj end)
      :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload, [] ->
        {:error, {:slot_acquire_failed, :unknown}}
      end)

      envelope = %{
        event_type: "WorkSubmitted",
        data: %{
          work_id: work_id,
          project_id: project_id,
          run_id: run_id,
          submission_id: "sub-fail",
          workflow_snapshot: %{}
        }
      }

      {:noreply, _state} =
        Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

      # Admission was called and failed
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
