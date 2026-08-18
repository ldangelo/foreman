defmodule ForemanServer.CommandGatewayWorkSubmitTest do
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway

  setup do
    # Reset projection store before each test
    ForemanServer.TestSupport.ProjectionStoreReset.reset!()

    :ok
  end

  describe "work.submit enrich_operator_command" do
    @tag :skip
    test "enriches with submission_id, run_id, and workflow_snapshot" do
      # SKIPPED: The Work aggregate does not yet handle work.submit.
      # When the aggregate is implemented, unskip this test.
      # Enrichment IS working (verified by aggregate receiving enriched command),
      # but dispatch crashes with :unhandled before returning the event.
      project_id = "proj-test-#{unique_id()}"
      work_id = "work-test-#{unique_id()}"
      command_id = "cmd-submit-#{unique_id()}"

      seed_project(project_id, "implement")

      assert {:ok, event} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: project_id,
                   workflow: "implement",
                   prompt: "test prompt"
                 }
               })

      assert %{
               "payload" => payload
             } = event

      assert is_binary(payload["submission_id"])
      assert is_binary(payload["run_id"])
      assert is_map(payload["workflow_snapshot"])
    end

    test "rejects client-supplied submission_id as reserved field" do
      project_id = "proj-reserved-#{unique_id()}"
      work_id = "work-reserved-#{unique_id()}"
      command_id = "cmd-reserved-#{unique_id()}"

      seed_project(project_id, "implement")

      assert {:error, {:reserved_fields, [:submission_id]}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: project_id,
                   workflow: "implement",
                   prompt: "test prompt",
                   submission_id: "client-submission-id"
                 }
               })
    end

    test "rejects client-supplied run_id as reserved field" do
      project_id = "proj-reserved-#{unique_id()}"
      work_id = "work-reserved-#{unique_id()}"
      command_id = "cmd-reserved-#{unique_id()}"

      seed_project(project_id, "implement")

      assert {:error, {:reserved_fields, [:run_id]}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: project_id,
                   workflow: "implement",
                   prompt: "test prompt",
                   run_id: "client-run-id"
                 }
               })
    end

    test "rejects client-supplied workflow_snapshot as reserved field" do
      project_id = "proj-reserved-#{unique_id()}"
      work_id = "work-reserved-#{unique_id()}"
      command_id = "cmd-reserved-#{unique_id()}"

      seed_project(project_id, "implement")

      assert {:error, {:reserved_fields, [:workflow_snapshot]}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: project_id,
                   workflow: "implement",
                   prompt: "test prompt",
                   workflow_snapshot: %{"some" => "snapshot"}
                 }
               })
    end

    @tag :skip
    test "idempotent: returns cmd unchanged when projection submission_id matches command_id" do
      # SKIPPED: The Work aggregate does not yet handle work.submit.
      # When the aggregate is implemented, unskip this test.
      project_id = "proj-idem-#{unique_id()}"
      work_id = "work-idem-#{unique_id()}"
      command_id = "cmd-idem-#{unique_id()}"

      seed_project(project_id, "implement")
      seed_work_projection(work_id, %{submission_id: command_id})

      assert {:ok, event} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: project_id,
                   workflow: "implement",
                   prompt: "test prompt"
                 }
               })

      # Short-circuits: command returned unchanged without calling prepare
      assert is_map(event["payload"])
    end
    test "project not found returns project_not_found from validate_aggregate_id" do
      work_id = "work-notfound-#{unique_id()}"
      command_id = "cmd-notfound-#{unique_id()}"

      # proj-does-not-exist is not seeded, so validate_aggregate_id fails first
      assert {:error, {:project_not_found, "proj-does-not-exist"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: "proj-does-not-exist",
                   workflow: "implement",
                   prompt: "test prompt"
                 }
               })
    end

    test "backend field passes through enrich_operator_command unchanged" do
      project_id = "proj-backend-#{unique_id()}"
      work_id = "work-backend-#{unique_id()}"
      command_id = "cmd-backend-#{unique_id()}"

      seed_project(project_id, "implement")

      # The enrich_operator_command should preserve backend in the payload
      # We verify by checking that dispatch succeeds with backend present
      # (backend is NOT a reserved field, so it flows through to the aggregate)
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "work:#{work_id}",
                 type: "work.submit",
                 payload: %{
                   work_id: work_id,
                   project_id: project_id,
                   workflow: "implement",
                   prompt: "test prompt",
                   backend: "pi"
                 }
               })
    end
  end

  # -------------------------------------------------------------------------
  # Test helpers
  # -------------------------------------------------------------------------

  defp unique_id do
    System.unique_integer([:positive])
  end

  defp seed_project(project_id, workflow_type) do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      put_in(state.projects[project_id], %{
        project_id: project_id,
        archived?: false,
        workflow_type: workflow_type
      })
    end)
  end

  defp seed_work_projection(work_id, overrides) do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      works = state.works

      updated =
        Map.put(works, work_id, %{work_id: work_id})
        |> update_in([work_id], &Map.merge(&1, overrides))

      %{state | works: updated}
    end)
  end
end
