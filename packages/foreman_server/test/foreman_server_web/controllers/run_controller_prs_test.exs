defmodule ForemanServerWeb.RunControllerPrsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.TestSupport.PrSurfaceSupport
  alias ForemanServer.TestSupport.PrWatchSupport

  @endpoint ForemanServerWeb.Endpoint
  @evidence_keys ~w(eligibility checks findings risk waiver report delivery_issue next_actions)
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

    assert Map.drop(failing, @evidence_keys) == %{
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

    # The seeded project is not in the projection: the policy cannot be read, so the status is
    # `unknown` with its one reason, never `off` and never eligible (AC-005-3).
    assert %{
             "eligibility" => %{
               "status" => "unknown",
               "head_sha" => "sha-fail",
               "reasons" => [%{"code" => "evidence_unreadable"}],
               "waived" => [],
               "policy_version" => nil
             },
             "checks" => nil,
             "findings" => nil,
             "risk" => nil,
             "waiver" => nil,
             "report" => nil,
             "delivery_issue" => nil,
             "next_actions" => []
           } = failing

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

  # TRD-031 (AC-005-3): the projection store not answering (down, restarting after a failed
  # boot read, or a call timeout) is `unknown`, never an empty PR list. The read is replaced
  # at the store's boundary; no global process is suspended.
  for {label, reason} <- [
        down: {:noproc, {GenServer, :call, [ForemanServer.ProjectionStore, :x, 5000]}},
        timeout: {:timeout, {GenServer, :call, [ForemanServer.ProjectionStore, :x, 5000]}}
      ] do
    test "an unanswered projection store (#{label}) is 503 unknown, never an empty list" do
      %{run_id: run_id} = PrSurfaceSupport.seed_two_prs!()
      store_exits!(unquote(Macro.escape(reason)))

      body = get_json("/api/runs/#{run_id}/prs", 503)

      assert %{"error" => "projection_unavailable", "status" => "unknown", "run_id" => ^run_id} =
               body

      assert is_binary(body["cause"]) and body["cause"] != ""
      refute Map.has_key?(body, "prs")
    end
  end

  defp store_exits!(reason) do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(ForemanServer.ProjectionStore, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(ForemanServer.ProjectionStore) end)
    :meck.expect(ForemanServer.ProjectionStore, :run, fn _run_id -> exit(reason) end)
  end

  test "an unauthenticated request is rejected" do
    assert build_conn() |> get("/api/runs/anything/prs") |> json_response(401)
  end
end
