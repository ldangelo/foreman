defmodule ForemanServer.Aggregates.WorkRequestCommandTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.WorkRequest
  alias ForemanServer.Aggregates.WorkRequest.State
  alias ForemanServer.Commands.WorkSubmit

  alias ForemanServer.Events.{
    WorkCancelled,
    WorkExecutionCompleted,
    WorkExecutionFailed,
    WorkSubmitted
  }

  alias ForemanServer.Identity

  defp uuid, do: EventStore.UUID.uuid4()

  describe "handle_command/2 — work.submit" do
    test "emits WorkSubmitted with all required fields from empty state" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-1",
        project_id: "proj-1",
        prompt: "Please summarize the code",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
      }

      assert {:ok, %WorkSubmitted{} = event} = WorkRequest.handle_command(state, cmd)
      assert event.work_id == "work-1"
      assert event.project_id == "proj-1"
      assert event.workflow_snapshot == %{"phases" => [%{"id" => "phase-1"}]}
      assert is_binary(event.submission_id)
      assert is_binary(event.run_id)
    end

    test "uses provided submission_id and run_id when given" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-2",
        project_id: "proj-1",
        prompt: "Summarize",
        workflow_snapshot: %{},
        submission_id: "sub-2",
        run_id: "run-2"
      }

      assert {:ok, %WorkSubmitted{} = event} = WorkRequest.handle_command(state, cmd)
      assert event.submission_id == "sub-2"
      assert event.run_id == "run-2"
    end

    test "generates deterministic run_id from work_id and submission_id when run_id not provided" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-3",
        project_id: "proj-1",
        prompt: "Hello",
        workflow_snapshot: %{},
        submission_id: "sub-3"
      }

      assert {:ok, %WorkSubmitted{} = event} = WorkRequest.handle_command(state, cmd)
      assert event.run_id == Identity.run_id("work-3", "sub-3")
    end

    test "rejects nil prompt with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-4",
        project_id: "proj-1",
        prompt: nil,
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} =
               WorkRequest.handle_command(state, cmd)
    end

    test "rejects empty binary prompt with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-5",
        project_id: "proj-1",
        prompt: "",
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} =
               WorkRequest.handle_command(state, cmd)
    end

    test "rejects non-binary prompt with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-6",
        project_id: "proj-1",
        prompt: 123,
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} =
               WorkRequest.handle_command(state, cmd)
    end

    test "rejects non-binary prompt (list) with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-7",
        project_id: "proj-1",
        prompt: ["not", "a", "binary"],
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} =
               WorkRequest.handle_command(state, cmd)
    end

    test "accepts valid non-empty binary prompt" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-8",
        project_id: "proj-1",
        prompt: "valid prompt",
        workflow_snapshot: %{}
      }

      assert {:ok, %WorkSubmitted{}} = WorkRequest.handle_command(state, cmd)
    end

    test "emits WorkSubmitted with backend from struct path" do
      state = %State{}

      cmd = %WorkSubmit{
        work_id: "work-9",
        project_id: "proj-1",
        prompt: "test prompt",
        workflow_snapshot: %{},
        backend: "pi"
      }

      assert {:ok, %WorkSubmitted{} = event} = WorkRequest.handle_command(state, cmd)
      assert event.backend == "pi"
    end

    test "emits WorkSubmitted from nil state" do
      state = nil

      cmd = %WorkSubmit{
        work_id: "work-10",
        project_id: "proj-1",
        prompt: "test prompt",
        workflow_snapshot: %{}
      }

      assert {:ok, %WorkSubmitted{} = event} = WorkRequest.handle_command(state, cmd)
      assert event.work_id == "work-10"
    end
  end

  describe "handle_command/2 — map-type work.submit" do
    test "emits WorkSubmitted with backend from nil state map-type" do
      cmd = %{
        type: "work.submit",
        payload: %{
          work_id: "work-map-1",
          project_id: "proj-1",
          prompt: "test prompt",
          workflow_snapshot: %{},
          backend: "pi"
        }
      }

      assert {:ok, %WorkSubmitted{} = event} =
               WorkRequest.handle_command(nil, cmd)

      assert event.work_id == "work-map-1"
      assert event.backend == "pi"
    end

    test "emits WorkSubmitted from State{status: nil} map-type" do
      state = %State{}

      cmd = %{
        type: "work.submit",
        payload: %{
          work_id: "work-map-2",
          project_id: "proj-1",
          prompt: "another prompt",
          workflow_snapshot: %{}
        }
      }

      assert {:ok, %WorkSubmitted{} = event} =
               WorkRequest.handle_command(state, cmd)

      assert event.work_id == "work-map-2"
      assert event.backend == nil
    end

    test "idempotent — already submitted returns {:ok, nil}" do
      state = %State{
        work_id: "work-map-3",
        status: :submitted,
        project_id: "proj-1"
      }

      cmd = %{
        type: "work.submit",
        payload: %{
          work_id: "work-map-3",
          project_id: "proj-1",
          prompt: "duplicate",
          workflow_snapshot: %{}
        }
      }

      assert {:ok, nil} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects already submitted with different work_id" do
      state = %State{
        work_id: "work-map-4-existing",
        status: :submitted,
        project_id: "proj-1"
      }

      cmd = %{
        type: "work.submit",
        payload: %{
          work_id: "work-map-4-different",
          project_id: "proj-1",
          prompt: "wrong work_id",
          workflow_snapshot: %{}
        }
      }

      assert {:error, {:already_submitted, "work-map-4-existing"}} =
               WorkRequest.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — work.execution_complete" do
    test "transitions from running to succeeded" do
      state = %State{
        work_id: "work-1",
        status: :running,
        bound_run_id: "run-1"
      }

      cmd = %{
        type: "work.execution_complete",
        payload: %{work_id: "work-1", run_id: "run-1"}
      }

      assert {:ok, %WorkExecutionCompleted{work_id: "work-1", run_id: "run-1"} = event} =
               WorkRequest.handle_command(state, cmd)

      assert event.work_id == "work-1"
      assert event.run_id == "run-1"
    end

    test "returns error with mismatched run_id" do
      state = %State{
        work_id: "work-1",
        status: :running,
        bound_run_id: "run-bound"
      }

      cmd = %{
        type: "work.execution_complete",
        payload: %{work_id: "work-1", run_id: "run-wrong"}
      }

      assert {:error, {:run_id_mismatch, "run-bound", "run-wrong"}} =
               WorkRequest.handle_command(state, cmd)
    end

    test "allows nil bound_run_id (forward-compat, work not yet bound)" do
      state = %State{
        work_id: "work-1",
        status: :running,
        bound_run_id: nil
      }

      cmd = %{
        type: "work.execution_complete",
        payload: %{work_id: "work-1", run_id: "run-1"}
      }

      assert {:ok, %WorkExecutionCompleted{}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects on already-succeeded status" do
      state = %State{work_id: "work-1", status: :succeeded, bound_run_id: "run-1"}

      cmd = %{
        type: "work.execution_complete",
        payload: %{work_id: "work-1", run_id: "run-1"}
      }

      assert {:error, {:work_terminal, :succeeded}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects on already-failed status" do
      state = %State{work_id: "work-1", status: :failed, bound_run_id: "run-1"}

      cmd = %{
        type: "work.execution_complete",
        payload: %{work_id: "work-1", run_id: "run-1"}
      }

      assert {:error, {:work_terminal, :failed}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects when run_id is missing from payload" do
      state = %State{work_id: "work-1", status: :running, bound_run_id: "run-1"}

      cmd = %{type: "work.execution_complete", payload: %{work_id: "work-1"}}

      assert {:error, {:missing_or_invalid, :run_id}} =
               WorkRequest.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — work.execution_fail" do
    test "transitions to terminal with matching run_id" do
      state = %State{
        work_id: "work-1",
        status: :running,
        bound_run_id: "run-1"
      }

      cmd = %{
        type: "work.execution_fail",
        payload: %{work_id: "work-1", run_id: "run-1"}
      }

      assert {:ok, %WorkExecutionFailed{work_id: "work-1", run_id: "run-1"} = event} =
               WorkRequest.handle_command(state, cmd)

      assert event.work_id == "work-1"
      assert event.run_id == "run-1"
    end

    test "returns error with mismatched run_id" do
      state = %State{
        work_id: "work-1",
        status: :running,
        bound_run_id: "run-bound"
      }

      cmd = %{
        type: "work.execution_fail",
        payload: %{work_id: "work-1", run_id: "run-wrong"}
      }

      assert {:error, {:run_id_mismatch, "run-bound", "run-wrong"}} =
               WorkRequest.handle_command(state, cmd)
    end

    test "allows nil bound_run_id (forward-compat, work not yet bound)" do
      state = %State{
        work_id: "work-1",
        status: :running,
        bound_run_id: nil
      }

      cmd = %{
        type: "work.execution_fail",
        payload: %{work_id: "work-1", run_id: "run-1"}
      }

      assert {:ok, %WorkExecutionFailed{}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects on already-succeeded status" do
      state = %State{work_id: "work-1", status: :succeeded, bound_run_id: "run-1"}

      cmd = %{type: "work.execution_fail", payload: %{work_id: "work-1", run_id: "run-1"}}

      assert {:error, {:work_terminal, :succeeded}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects on already-failed status" do
      state = %State{work_id: "work-1", status: :failed, bound_run_id: "run-1"}

      cmd = %{type: "work.execution_fail", payload: %{work_id: "work-1", run_id: "run-1"}}

      assert {:error, {:work_terminal, :failed}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects when run_id is missing from payload" do
      state = %State{work_id: "work-1", status: :running, bound_run_id: "run-1"}

      cmd = %{type: "work.execution_fail", payload: %{work_id: "work-1"}}

      assert {:error, {:missing_or_invalid, :run_id}} =
               WorkRequest.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — work.cancel" do
    test "transitions non-terminal work to cancelled" do
      state = %State{work_id: "work-1", status: :running}

      cmd = %{type: "work.cancel", payload: %{work_id: "work-1"}}

      assert {:ok, %WorkCancelled{work_id: "work-1"} = event} =
               WorkRequest.handle_command(state, cmd)

      assert event.work_id == "work-1"
    end

    test "transitions queued work to cancelled" do
      state = %State{work_id: "work-1", status: :queued}

      cmd = %{type: "work.cancel", payload: %{work_id: "work-1"}}

      assert {:ok, %WorkCancelled{}} = WorkRequest.handle_command(state, cmd)
    end

    test "transitions submitted work to cancelled" do
      state = %State{work_id: "work-1", status: :submitted}

      cmd = %{type: "work.cancel", payload: %{work_id: "work-1"}}

      assert {:ok, %WorkCancelled{}} = WorkRequest.handle_command(state, cmd)
    end

    test "idempotent no-op on already-succeeded work" do
      state = %State{work_id: "work-1", status: :succeeded}

      cmd = %{type: "work.cancel", payload: %{work_id: "work-1"}}

      assert {:ok, nil} = WorkRequest.handle_command(state, cmd)
    end

    test "idempotent no-op on already-failed work" do
      state = %State{work_id: "work-1", status: :failed}

      cmd = %{type: "work.cancel", payload: %{work_id: "work-1"}}

      assert {:ok, nil} = WorkRequest.handle_command(state, cmd)
    end

    test "idempotent no-op on already-cancelled work" do
      state = %State{work_id: "work-1", status: :cancelled}

      cmd = %{type: "work.cancel", payload: %{work_id: "work-1"}}

      assert {:ok, nil} = WorkRequest.handle_command(state, cmd)
    end
  end

  describe "handle_command/2 — unknown command" do
    test "returns :unhandled for unknown commands on nil state" do
      assert :unhandled = WorkRequest.handle_command(nil, %{type: "unknown", payload: %{}})
    end

    test "returns :unhandled for unknown commands on existing state" do
      state = %State{}
      assert :unhandled = WorkRequest.handle_command(state, %{type: "unknown", payload: %{}})
    end
  end
end
