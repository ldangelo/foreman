defmodule ForemanServerWeb.OverviewControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "overview-controller-test-token"

  @card_keys ~w(actions branch door failure_reason group hint last_report merge_gate pr_state
                pr_url reason status steering thread_id title updated_at)

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: "p", path: "/tmp/p", task_provider: %{type: "beads"}}
        },
        %{event_type: "RunStarted", payload: %{run_id: "r1", task_id: "t1", project_id: "p"}},
        %{event_type: "RunCompleted", payload: %{run_id: "r1", project_id: "p"}},
        %{
          event_type: "PrAssociated",
          payload: %{run_id: "r1", pr_url: "https://g/p/1", pr_number: 1}
        },
        %{event_type: "PrReady", payload: %{run_id: "r1", pr_url: "https://g/p/1"}},
        %{event_type: "RunStarted", payload: %{run_id: "r2", task_id: "t2", project_id: "p"}},
        %{event_type: "RunFailed", payload: %{run_id: "r2", project_id: "p", reason: "boom"}},
        %{event_type: "RunStarted", payload: %{run_id: "r3", task_id: "t3", project_id: "p"}},
        %{event_type: "RunCompleted", payload: %{run_id: "r3", project_id: "p"}},
        %{event_type: "PrMerged", payload: %{run_id: "r3"}}
      ])

    :ok
  end

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "200 body has exactly the documented keys, six string group keys and whitelisted cards" do
    body = json_response(api_get("/api/projects/p/overview"), 200)

    assert body |> Map.keys() |> Enum.sort() ==
             ~w(attention counts generated_at groups project_id tabs)

    assert body["groups"] |> Map.keys() |> Enum.sort() ==
             ~w(idle landing ready_for_review resolved waiting_on_you working)

    assert body["counts"] == %{
             "ready_for_review" => 1,
             "waiting_on_you" => 1,
             "working" => 0,
             "landing" => 0,
             "idle" => 0,
             "resolved" => 1
           }

    assert body["attention"] == %{
             "needed" => true,
             "count" => 2,
             "reasons" => ["failed", "pr_ready"]
           }

    assert body["groups"]["resolved"] == []

    [card] = body["groups"]["ready_for_review"]
    assert card |> Map.keys() |> Enum.sort() == @card_keys
    assert card["thread_id"] == "run:r1"
    assert card["pr_url"] == "https://g/p/1"
  end

  test "include_resolved and resolved_limit are honoured" do
    body = json_response(api_get("/api/projects/p/overview?include_resolved=true"), 200)
    assert [%{"thread_id" => "run:r3", "reason" => "pr_merged"}] = body["groups"]["resolved"]

    body =
      json_response(
        api_get("/api/projects/p/overview?include_resolved=true&resolved_limit=0"),
        200
      )

    assert body["groups"]["resolved"] == []
    assert body["counts"]["resolved"] == 1
  end

  test "bad query values are 400" do
    for query <- [
          "resolved_limit=-1",
          "resolved_limit=201",
          "resolved_limit=x",
          "include_resolved=maybe"
        ] do
      assert %{"error" => "invalid_params"} =
               json_response(api_get("/api/projects/p/overview?#{query}"), 400)
    end
  end

  test "unknown project is 404 project_not_found" do
    assert %{"error" => "project_not_found", "project_id" => "nope"} =
             json_response(api_get("/api/projects/nope/overview"), 404)
  end

  test "no card exposes a merge or approve action" do
    body = json_response(api_get("/api/projects/p/overview?include_resolved=true"), 200)

    actions =
      body["groups"] |> Map.values() |> List.flatten() |> Enum.flat_map(& &1["actions"])

    refute Enum.any?(actions, &(&1 =~ ~r/merge|approve/i))
  end
end
