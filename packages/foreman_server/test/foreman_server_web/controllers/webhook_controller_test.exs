defmodule ForemanServerWeb.WebhookControllerTest do
  @moduledoc """
  Tests for `ForemanServerWeb.WebhookController.operator_ingest/2` —
  the JSI-T007 webhook/HTTP dispatch adapter for operator questions
  (TRD-2026-4212be7e).

  These tests call the controller function directly with a
  `Plug.Conn` built via `Plug.Test` (no `use Phoenix.ConnTest`),
  so they don't require the Phoenix endpoint to be started. The
  Phoenix.ConnTest-based tests fail under --no-start in this
  environment (see test/foreman_server_web/controllers/command_controller_test.exs
  for the same issue), so this direct-call approach is the
  viable verification path here.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ForemanServer.Agents.{OperatorQuestionSource, OperatorTimeout}
  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Inbox.DedupeTable
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.Eventually
  alias ForemanServerWeb.WebhookController

  setup do
    DedupeTable.clear()
    Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 60)
    :ok
  end

  # Helper: build a Plug.Conn for direct controller function calls.
  defp conn_for(payload) do
    conn(:post, "/webhooks/operator/ingest", payload)
    |> put_req_header("content-type", "application/json")
  end

  describe "operator_ingest/2 (JSI-T007)" do
    test "returns 202 + status=started for a new question" do
      conn =
        WebhookController.operator_ingest(
          conn_for(%{
            "question_id" => "q-100",
            "question" => "what should I do?",
            "agent_id" => "agent-7"
          }),
          %{
            "question_id" => "q-100",
            "question" => "what should I do?",
            "agent_id" => "agent-7"
          }
        )

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "started"
      assert body["correlation_id"] == "q-100"
    end

    test "returns 200 + status=deduped for a repeated question" do
      payload = %{
        "question_id" => "q-101",
        "question" => "another one",
        "agent_id" => "agent-8"
      }

      conn1 = WebhookController.operator_ingest(conn_for(payload), payload)
      assert conn1.status == 202
      assert Jason.decode!(conn1.resp_body)["status"] == "started"

      conn2 = WebhookController.operator_ingest(conn_for(payload), payload)
      assert conn2.status == 200
      body = Jason.decode!(conn2.resp_body)
      assert body["status"] == "deduped"
      assert body["correlation_id"] == "q-101"
    end

    test "returns 422 + no_correlation_id when payload lacks question_id and agent_id" do
      conn = WebhookController.operator_ingest(conn_for(%{"foo" => "bar"}), %{"foo" => "bar"})

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "no_correlation_id"
    end

    test "unwraps CloudEvent-style data envelope" do
      envelope = %{
        "data" => %{
          "question_id" => "q-102",
          "question" => "ce-form",
          "agent_id" => "agent-9"
        }
      }

      conn = WebhookController.operator_ingest(conn_for(envelope), envelope)

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "started"
      assert body["correlation_id"] == "q-102"
    end
  end

  describe "operator_ingest/2 question id limit" do
    defp ingest(question_id, agent_id) do
      payload = %{"question_id" => question_id, "question" => "q?", "agent_id" => agent_id}
      WebhookController.operator_ingest(conn_for(payload), payload)
    end

    defp unique_agent, do: "agent-limit-#{System.unique_integer([:positive])}"

    test "an id over the limit is refused 422 with the aggregate's typed error and nothing is recorded" do
      max = OperatorQuestion.max_question_id_chars()
      id = String.duplicate("x", max + 1)
      agent_id = unique_agent()

      conn = ingest(id, agent_id)

      assert conn.status == 422

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "question_id_too_long",
               "length" => max + 1,
               "max" => max
             }

      assert :miss = DedupeTable.lookup(OperatorQuestionSource, id)

      assert {:error, :stream_not_found} =
               Store.read_stream_forward(OperatorQuestion.stream_id("global", id), 0, 10)

      assert [] = :ets.lookup(:operator_timeout_registry, {id, agent_id})
      assert nil == ProjectionStore.question("global", id)
    end

    test "an id of exactly the limit is accepted (202), opens the question, and dedupes (200) when re-posted" do
      id = String.duplicate("y", OperatorQuestion.max_question_id_chars())
      agent_id = unique_agent()
      on_exit(fn -> OperatorTimeout.cancel(id, agent_id) end)

      assert ingest(id, agent_id).status == 202

      assert %{status: "open"} =
               Eventually.await(fn -> ProjectionStore.question("global", id) end)

      assert ingest(id, agent_id).status == 200
    end

    test "the limit counts characters: the limit in multibyte characters is accepted, one more is refused" do
      max = OperatorQuestion.max_question_id_chars()
      ok_id = String.duplicate("é", max)
      agent_id = unique_agent()
      on_exit(fn -> OperatorTimeout.cancel(ok_id, agent_id) end)

      assert ingest(ok_id, agent_id).status == 202

      conn = ingest(String.duplicate("é", max + 1), unique_agent())
      assert conn.status == 422

      assert %{"error" => "question_id_too_long", "length" => len, "max" => ^max} =
               Jason.decode!(conn.resp_body)

      assert len == max + 1
    end
  end
end
