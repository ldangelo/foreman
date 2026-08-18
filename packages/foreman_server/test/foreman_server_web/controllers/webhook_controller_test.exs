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

  use Plug.Test

  alias ForemanServer.Inbox.{DedupeTable, Poller}
  alias ForemanServerWeb.WebhookController

  setup_all do
    # Poller + DedupeTable bootstrap (poller_test.exs pattern).
    case Process.whereis(DedupeTable) do
      nil -> {:ok, _} = DedupeTable.start_link([])
      _ -> :ok
    end

    case Process.whereis(Poller) do
      nil -> {:ok, _} = Poller.start_link([])
      _ -> :ok
    end

    :ok
  end

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
end
