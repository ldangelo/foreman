defmodule ForemanServer.ProjectionStorePhasePrTest do
  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServer.ProjectionStore

  @phase_pr_url "https://github.com/ldangelo/foreman/pull/501"

  setup do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)

    on_exit(fn ->
      ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
    end)

    :ok
  end

  test "PhasePrRecorded projects phase_prs without overwriting final pr_url" do
    run_id = unique_run_id()
    phase_id = "#{run_id}-phase-1"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: "task-1",
                   project_id: "project-1",
                   workflow_snapshot: %{}
                 }
               },
               %{
                 event_type: "PhaseStarted",
                 payload: %{
                   run_id: run_id,
                   phase_id: phase_id,
                   index: 1,
                   name: "implement",
                   attempt: 1
                 }
               },
               phase_pr_event(run_id, phase_id, "created", @phase_pr_url)
             ])

    run = ProjectionStore.run(run_id)
    assert run.pr_url == nil
    assert [%{phase_id: ^phase_id, status: "created", pr_url: @phase_pr_url}] = run.phase_prs
  end

  test "created/reused phase PR payloads must carry usable URLs" do
    run_id = unique_run_id()
    phase_id = "#{run_id}-phase-1"

    assert_raise ArgumentError, ~r/PhasePrRecorded created missing usable pr_url/, fn ->
      ProjectionStore.apply_events([phase_pr_event(run_id, phase_id, "created", nil)])
    end
  end

  test "GET /api/runs/:id includes phase_prs in JSON" do
    run_id = unique_run_id()
    phase_id = "#{run_id}-phase-1"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: "task-1",
                   project_id: "project-1",
                   workflow_snapshot: %{}
                 }
               },
               phase_pr_event(run_id, phase_id, "reused", @phase_pr_url)
             ])

    run_json =
      build_conn()
      |> get("/api/runs/#{run_id}")
      |> json_response(200)
      |> Map.fetch!("run")

    assert [%{"phase_id" => ^phase_id, "status" => "reused", "pr_url" => @phase_pr_url}] =
             run_json["phase_prs"]
  end

  defp unique_run_id, do: "run-phase-pr-#{System.unique_integer([:positive])}"

  defp phase_pr_event(run_id, phase_id, status, pr_url) do
    %{
      event_type: "PhasePrRecorded",
      payload: %{
        run_id: run_id,
        phase_id: phase_id,
        phase_index: 1,
        phase_name: "implement",
        status: status,
        pr_url: pr_url,
        pr_number: 501,
        base_branch: "main",
        head_branch: "foreman/#{run_id}",
        provider: "github",
        recorded_at: "2026-09-01T00:00:00Z"
      }
    }
  end
end
