defmodule ForemanServerWeb.ApprovalControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: "ap", path: "/tmp/ap", task_provider: %{type: "beads"}}
        },
        %{event_type: "RunStarted", payload: %{run_id: "ar1", task_id: "t", project_id: "ap"}},
        req("open", "2026-10-21T00:01:00Z"),
        req("done", "2026-10-21T00:02:00Z"),
        %{
          event_type: "ToolCallDenied",
          payload: %{
            run_id: "ar1",
            tool_call_id: "done",
            decided_at: "2026-10-21T00:03:00Z",
            decided_by: "me"
          }
        }
      ])

    :ok
  end

  defp req(id, at) do
    %{
      event_type: "ToolCallRequested",
      payload: %{
        run_id: "ar1",
        tool_call_id: id,
        tool_name: "Write",
        input_summary: "write x",
        delivery: "resume_with_override",
        requested_at: at
      }
    }
  end

  @keys ~w(actions approval_delivery command_hints decided_at decided_by input_summary outcome project_id reason requested_at run_id status tool_call_id tool_name)

  test "project list returns only pending requests with the whitelisted fields and action hints" do
    conn = get(build_conn(), "/api/projects/ap/approvals")
    assert %{"approvals" => [call]} = json_response(conn, 200)
    assert call |> Map.keys() |> Enum.sort() == @keys
    assert call["tool_call_id"] == "open"
    assert call["actions"] == ["tool.approve", "tool.deny"]
    assert call["approval_delivery"] == "resume_with_override"

    assert call["command_hints"]["tool.approve"] == %{
             "type" => "tool.approve",
             "payload" => %{"run_id" => "ar1", "tool_call_id" => "open"}
           }
  end

  test "?status=all includes decided calls, which carry no actions" do
    conn = get(build_conn(), "/api/projects/ap/approvals?status=all")
    assert %{"approvals" => calls} = json_response(conn, 200)
    assert Enum.map(calls, & &1["tool_call_id"]) == ["open", "done"]
    done = Enum.find(calls, &(&1["tool_call_id"] == "done"))
    assert done["status"] == "denied"
    assert done["actions"] == [] and done["command_hints"] == %{}
  end

  test "an expired call says why and a finished one says how it ended (foreman-u0646)" do
    :ok =
      ProjectionStore.apply_events([
        req("gone", "2026-10-21T00:04:00Z"),
        %{
          event_type: "ToolCallExpired",
          payload: %{
            run_id: "ar1",
            tool_call_id: "gone",
            reason: "server_restart",
            at: "2026-10-21T00:05:00Z"
          }
        },
        req("lost", "2026-10-21T00:06:00Z"),
        %{
          event_type: "ToolCallApproved",
          payload: %{run_id: "ar1", tool_call_id: "lost", decided_at: "2026-10-21T00:07:00Z"}
        },
        %{
          event_type: "ToolCallFinished",
          payload: %{
            worker_id: "approvals",
            run_id: "ar1",
            tool_call_id: "lost",
            outcome: "delivery_failed: :no_live_request"
          }
        }
      ])

    assert %{"approvals" => calls} =
             build_conn() |> get("/api/runs/ar1/approvals?status=all") |> json_response(200)

    gone = Enum.find(calls, &(&1["tool_call_id"] == "gone"))
    assert %{"status" => "expired", "reason" => "server_restart", "outcome" => nil} = gone
    assert gone["actions"] == []

    lost = Enum.find(calls, &(&1["tool_call_id"] == "lost"))
    assert %{"status" => "finished", "outcome" => "delivery_failed: :no_live_request"} = lost
  end

  test "run endpoint matches the project endpoint for the same call" do
    assert %{"approvals" => [from_run]} =
             build_conn() |> get("/api/runs/ar1/approvals") |> json_response(200)

    assert %{"approvals" => [from_project]} =
             build_conn() |> get("/api/projects/ap/approvals") |> json_response(200)

    assert from_run == from_project
  end

  test "unknown project/run are 404 and a bad status is 400" do
    assert %{"error" => "project_not_found"} =
             build_conn() |> get("/api/projects/nope/approvals") |> json_response(404)

    assert %{"error" => "run_not_found"} =
             build_conn() |> get("/api/runs/nope/approvals") |> json_response(404)

    assert %{"error" => "invalid_params"} =
             build_conn() |> get("/api/projects/ap/approvals?status=x") |> json_response(400)
  end
end
