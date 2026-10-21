defmodule ForemanServerWeb.RunControllerPrsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.TestSupport.PrSurfaceSupport
  alias ForemanServer.TestSupport.PrWatchSupport

  @endpoint ForemanServerWeb.Endpoint
  @token "run-prs-token"

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

  test "returns one full DTO per PR, ordered by url" do
    %{run_id: run_id, failing_url: failing_url, merged_url: merged_url} =
      PrSurfaceSupport.seed_two_prs!()

    assert %{"run_id" => ^run_id, "prs" => [failing, merged]} =
             get_json("/api/runs/#{run_id}/prs", 200)

    assert failing == %{
             "pr_url" => failing_url,
             "repo_id" => nil,
             "status" => "open",
             "head_sha" => "sha-fail",
             "base_branch" => "main",
             "branch_name" => "foreman/#{run_id}/work",
             "checks_state" => "failing",
             "failing" => ["unit", "lint"],
             "review_decision" => "changes_requested",
             "comment_count" => 2,
             "watching" => true,
             "stop_reason" => nil,
             "fixes" => %{
               "attempts" => %{"ci" => 1, "comments" => 0, "conflicts" => 0},
               "in_flight" => %{
                 "state" => "requested",
                 "kind" => "ci",
                 "attempt" => 1,
                 "jobsite_id" => nil
               },
               "last_outcome" => %{},
               "exhausted" => %{}
             },
             "agent_review" => nil,
             "merge_gate" => "pending"
           }

    assert %{
             "pr_url" => ^merged_url,
             "status" => "merged",
             "checks_state" => "passing",
             "failing" => [],
             "comment_count" => 0,
             "fixes" => %{"in_flight" => nil, "attempts" => %{"ci" => 0}}
           } = merged

    refute Map.has_key?(merged, "merge_gate")
  end

  test "a stopped watch is reported with its reason" do
    %{run_id: run_id, failing_url: failing_url} = PrSurfaceSupport.seed_two_prs!()

    PrWatchSupport.dispatch!(%{
      type: "run.pr.watch_stop",
      command_id: "stop:#{run_id}",
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id, pr_url: failing_url, reason: "operator"}
    })

    assert %{"prs" => [%{"watching" => false, "stop_reason" => "operator"}, _merged]} =
             get_json("/api/runs/#{run_id}/prs", 200)
  end

  test "a run without PRs returns an empty list and an unknown run is 404" do
    %{run_id: run_id} = PrWatchSupport.start_run!(complete: true)

    assert %{"run_id" => ^run_id, "prs" => []} = get_json("/api/runs/#{run_id}/prs", 200)

    assert %{"error" => "run_not_found", "run_id" => "run-nope"} =
             get_json("/api/runs/run-nope/prs", 404)
  end

  test "an unauthenticated request is rejected" do
    assert build_conn() |> get("/api/runs/anything/prs") |> json_response(401)
  end
end
