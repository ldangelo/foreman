defmodule ForemanServerWeb.RunControllerPhasesTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Events.{PhaseCompleted, PhaseStarted}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @endpoint ForemanServerWeb.Endpoint
  @token "run-phases-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    :ok
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(status)
  end

  defp apply!(type, event),
    do: :ok = ProjectionStore.apply_events([%{event_type: type, payload: Map.from_struct(event)}])

  test "lists the phases in workflow order with their own status, and only the contract fields" do
    %{run_id: run_id} = Support.start_run!()

    for {index, name} <- [{2, "review"}, {1, "fix"}] do
      apply!("PhaseStarted", %PhaseStarted{
        phase_id: "#{run_id}-p00#{index}",
        run_id: run_id,
        index: index,
        name: name,
        attempt: 1,
        artifact_template: "{task.projectReportsDir}/#{name}.md",
        input_artifacts: [%{"path" => "secret/input.md"}]
      })
    end

    apply!("PhaseCompleted", %PhaseCompleted{
      phase_id: "#{run_id}-p001",
      run_id: run_id,
      index: 1,
      artifact_path: "reports/fix.md",
      artifact_sha256: "abc",
      artifact_bytes: 3
    })

    assert %{"run_id" => ^run_id, "phases" => [fix, review]} =
             get_json("/api/runs/#{run_id}/phases", 200)

    assert %{"name" => "fix", "index" => 1, "status" => "completed", "attempt" => 1} = fix
    assert %{"name" => "review", "index" => 2, "status" => "in_progress"} = review

    assert Enum.sort(Map.keys(fix)) ==
             Enum.sort(
               ~w(phase_id index name attempt status failure_reason started_at_ms last_event_at_ms latest_stall)
             )
  end

  test "a run that has started no phase has an empty list, an unknown run is a 404" do
    %{run_id: run_id} = Support.start_run!()

    assert %{"run_id" => ^run_id, "phases" => []} = get_json("/api/runs/#{run_id}/phases", 200)

    assert %{"error" => "run_not_found", "run_id" => "run-nope"} =
             get_json("/api/runs/run-nope/phases", 404)
  end
end
