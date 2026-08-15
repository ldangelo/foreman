defmodule ForemanServer.Aggregates.WorkRequestCommandTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.WorkRequest
  alias ForemanServer.Aggregates.WorkRequest.State
  alias ForemanServer.Commands.WorkSubmit
  alias ForemanServer.Events.WorkSubmitted
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

      assert {:error, {:invalid_envelope, :missing_prompt}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects empty binary prompt with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}
      cmd = %WorkSubmit{
        work_id: "work-5",
        project_id: "proj-1",
        prompt: "",
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects non-binary prompt with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}
      cmd = %WorkSubmit{
        work_id: "work-6",
        project_id: "proj-1",
        prompt: 123,
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} = WorkRequest.handle_command(state, cmd)
    end

    test "rejects non-binary prompt (list) with {:error, {:invalid_envelope, :missing_prompt}}" do
      state = %State{}
      cmd = %WorkSubmit{
        work_id: "work-7",
        project_id: "proj-1",
        prompt: ["not", "a", "binary"],
        workflow_snapshot: %{}
      }

      assert {:error, {:invalid_envelope, :missing_prompt}} = WorkRequest.handle_command(state, cmd)
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

    test "emits WorkSubmitted from nil state" do
      state = nil
      cmd = %WorkSubmit{
        work_id: "work-9",
        project_id: "proj-1",
        prompt: "test prompt",
        workflow_snapshot: %{}
      }

      assert {:ok, %WorkSubmitted{} = event} = WorkRequest.handle_command(state, cmd)
      assert event.work_id == "work-9"
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
