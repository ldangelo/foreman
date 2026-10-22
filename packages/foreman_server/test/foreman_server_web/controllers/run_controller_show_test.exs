defmodule ForemanServerWeb.RunControllerShowTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Events.UsageRecorded
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @endpoint ForemanServerWeb.Endpoint
  @token "run-show-token"

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

  # Found by the live acceptance run: once a worker reported usage, the run
  # projection carried a `%ForemanServer.Usage{}` and `GET /api/runs/:id` (and
  # therefore `foreman run get`) answered 500 (Protocol.UndefinedError).
  test "a run whose worker reported usage is served with its totals" do
    %{run_id: run_id, project_id: project_id} = Support.start_run!()

    event = %UsageRecorded{
      run_id: run_id,
      worker_id: "wkr-1",
      provider: "pi",
      project_id: project_id,
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      cost_usd: 0.25
    }

    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{event_type: "UsageRecorded", payload: Map.from_struct(event)}
      ])

    assert %{"run" => %{"run_id" => ^run_id, "usage" => usage}} =
             get_json("/api/runs/#{run_id}", 200)

    assert %{"total_tokens" => 15, "cost_usd" => 0.25} = usage

    assert %{"runs" => runs} = get_json("/api/runs?project_id=#{project_id}", 200)
    assert Enum.any?(runs, &(&1["run_id"] == run_id))
  end
end
