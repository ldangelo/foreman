defmodule ForemanServerWeb.QuestionControllerTest do
  @moduledoc """
  `GET /api/projects/:id/questions`: the project's operator questions, oldest first, open ones
  unless `?status=all`. Sibling of `GET /api/projects/:id/approvals`
  (`ApprovalControllerTest`), behind the same bearer-token pipeline.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "question-controller-test-token"

  @keys ~w(actions agent_id answered_by command_hints decided_at opened_at project_id question_id reason run_id status text undelivered_reason)

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_api = Application.get_env(:foreman_server, :api)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      restore(:api_bearer_token, previous_token)
      restore(:api, previous_api)
    end)

    # Applied newest first, so only the endpoint's own ordering can produce oldest-first.
    :ok =
      ProjectionStore.apply_events([
        registered("qp"),
        registered("qo"),
        run_started("qr1", "qp"),
        run_started("qr-other", "qo"),
        opened("qr1", "late", "2026-10-21T00:05:00Z"),
        opened("qr1", "early", "2026-10-21T00:01:00Z"),
        opened("global", "g1", "2026-10-21T00:03:00Z", %{project_id: "qp"}),
        opened("qr1", "done", "2026-10-21T00:02:00Z"),
        %{
          event_type: "QuestionAnswered",
          payload: %{
            run_id: "qr1",
            question_id: "done",
            text: "the secret answer",
            answered_by: "alice",
            at: "2026-10-21T00:04:00Z"
          }
        },
        opened("qr1", "gone", "2026-10-21T00:02:30Z"),
        %{
          event_type: "QuestionExpired",
          payload: %{
            run_id: "qr1",
            question_id: "gone",
            reason: "timeout",
            at: "2026-10-21T00:07:00Z"
          }
        },
        opened("qr-other", "foreign", "2026-10-21T00:00:30Z")
      ])

    :ok
  end

  defp registered(project_id) do
    %{
      event_type: "ProjectRegistered",
      payload: %{
        project_id: project_id,
        path: "/tmp/" <> project_id,
        task_provider: %{type: "beads"}
      }
    }
  end

  defp run_started(run_id, project_id) do
    %{
      event_type: "RunStarted",
      payload: %{run_id: run_id, task_id: "t-" <> run_id, project_id: project_id}
    }
  end

  defp opened(run_id, id, at, extra \\ %{}) do
    %{
      event_type: "QuestionOpened",
      payload:
        Map.merge(
          %{
            run_id: run_id,
            question_id: id,
            agent_id: "agent-" <> id,
            text: "text of " <> id,
            timeout_ms: 300_000,
            at: at
          },
          extra
        )
    }
  end

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  defp ids(%{"questions" => questions}), do: Enum.map(questions, & &1["question_id"])

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  test "lists the project's open questions oldest first, as the exact whitelisted DTO" do
    body = json_response(api_get("/api/projects/qp/questions"), 200)

    assert ids(body) == ["early", "g1", "late"]
    assert Enum.all?(body["questions"], &(&1 |> Map.keys() |> Enum.sort() == @keys))

    assert [early | _] = body["questions"]

    assert early == %{
             "question_id" => "early",
             "run_id" => "qr1",
             "project_id" => "qp",
             "agent_id" => "agent-early",
             "text" => "text of early",
             "status" => "open",
             "opened_at" => "2026-10-21T00:01:00Z",
             "decided_at" => nil,
             "answered_by" => nil,
             "reason" => nil,
             "undelivered_reason" => nil,
             "actions" => ["question.answer"],
             "command_hints" => %{
               "question.answer" => %{
                 "type" => "question.answer",
                 "payload" => %{"run_id" => "qr1", "question_id" => "early", "text" => ""}
               }
             }
           }

    assert Enum.all?(body["questions"], &(&1["actions"] == ["question.answer"]))
  end

  test "a question that belongs to no run is listed under the project it names" do
    body = json_response(api_get("/api/projects/qp/questions"), 200)

    assert %{"run_id" => "global", "project_id" => "qp", "status" => "open"} =
             Enum.find(body["questions"], &(&1["question_id"] == "g1"))

    assert %{"questions" => [%{"question_id" => "foreign", "run_id" => "qr-other"}]} =
             json_response(api_get("/api/projects/qo/questions"), 200)
  end

  test "?status=pending is the default" do
    assert json_response(api_get("/api/projects/qp/questions?status=pending"), 200) ==
             json_response(api_get("/api/projects/qp/questions"), 200)
  end

  test "?status=all adds answered and expired questions, which carry no actions" do
    body = json_response(api_get("/api/projects/qp/questions?status=all"), 200)

    assert ids(body) == ["early", "done", "gone", "g1", "late"]

    done = Enum.find(body["questions"], &(&1["question_id"] == "done"))

    assert done["status"] == "answered"
    assert done["answered_by"] == "alice"
    assert done["decided_at"] == "2026-10-21T00:04:00Z"
    assert done["reason"] == nil
    assert done["actions"] == [] and done["command_hints"] == %{}

    gone = Enum.find(body["questions"], &(&1["question_id"] == "gone"))

    assert gone["status"] == "expired"
    assert gone["reason"] == "timeout"
    assert gone["decided_at"] == "2026-10-21T00:07:00Z"
    assert gone["answered_by"] == nil
    assert gone["actions"] == [] and gone["command_hints"] == %{}
  end

  test "the answer text is delivered to the agent, never listed" do
    conn = api_get("/api/projects/qp/questions?status=all")

    assert conn.status == 200
    refute conn.resp_body =~ "secret answer"
  end

  test "an unknown project is 404 and a bad status is 400" do
    assert %{"error" => "project_not_found", "id" => "nope"} =
             json_response(api_get("/api/projects/nope/questions"), 404)

    assert %{"error" => "invalid_params", "detail" => "status must be pending or all"} =
             json_response(api_get("/api/projects/qp/questions?status=x"), 400)
  end

  describe "authentication matches the sibling approvals endpoint" do
    @paths ["/api/projects/qp/questions", "/api/projects/qp/approvals"]

    test "a configured token is required, in the Authorization header" do
      for path <- @paths do
        assert %{"error" => "unauthorized"} = json_response(get(build_conn(), path), 401)

        wrong = build_conn() |> put_req_header("authorization", "Bearer nope") |> get(path)
        assert %{"error" => "unauthorized"} = json_response(wrong, 401)

        assert json_response(api_get(path), 200)
      end
    end

    test "with no token configured the API is closed unless explicitly opened for local use" do
      Application.delete_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :api, allow_insecure_local: false)

      for path <- @paths do
        assert %{"error" => "unauthorized", "detail" => detail} =
                 json_response(get(build_conn(), path), 401)

        assert detail =~ "no API token is configured"
      end

      Application.put_env(:foreman_server, :api, allow_insecure_local: true)

      for path <- @paths do
        assert json_response(get(build_conn(), path), 200)
      end
    end
  end
end
