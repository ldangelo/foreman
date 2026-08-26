defmodule ForemanServerWeb.WebhookController do
  @moduledoc """
  Webhook ingestion endpoints for external triggers
  (TRD-015 for external_trigger, TRD-2026-4212be7e JSI-T007 for
  operator ingestion).

  Routes:
    * `POST /webhooks/external_trigger` — ingest payload via
      `SharedInbox.ingest/2`. Source module is read from application
      config (`:trigger_webhook_source_module`).
    * `POST /webhooks/operator/ingest` — operator question ingest.
      Hands the operator question's data map to
      `OperatorQuestionDispatcher` (which calls `SharedInbox.ingest/2`
      with `OperatorQuestionSource` as the source module).
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Agents.OperatorQuestionDispatcher
  alias ForemanServer.Inbox.SharedInbox

  @default_source_module ForemanServer.TriggerPoller.StubSource

  def external_trigger(conn, params) do
    source_module =
      Application.get_env(
        :foreman_server,
        :trigger_webhook_source_module,
        @default_source_module
      )

    payload = if is_map(params), do: params, else: %{"body" => params}

    case SharedInbox.ingest(source_module, payload) do
      {:ok, :started, _item} ->
        conn
        |> put_status(:accepted)
        |> json(%{status: "started"})

      {:ok, :deduped, _item} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "deduped"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  POST /webhooks/operator/ingest — operator question ingest
  (TRD-2026-4212be7e JSI-T007).

  The wire shape is the operator question's data map:

      {
        "question_id": "q-42",
        "question": "what should I do?",
        "agent_id": "agent-7",
        "options": { ... }
      }

  CloudEvent envelopes (`{"data": { ... }}`) are unwrapped so a Jido
  signal can be POSTed directly as the body. Returns 202 on
  `:started`, 200 on `:deduped`, 422 on `:no_correlation_id`,
  500 on other ingest failures.
  """
  def operator_ingest(conn, params) do
    payload = unwrap_operator_payload(params)

    case OperatorQuestionDispatcher.dispatch(payload) do
      {:ok, :started, item} ->
        conn
        |> put_status(:accepted)
        |> json(%{status: "started", correlation_id: item.correlation_id})

      {:ok, :deduped, item} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "deduped", correlation_id: item.existing.correlation_id})

      {:error, :no_correlation_id} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no_correlation_id", message: "payload must include question_id or agent_id"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "ingest_failed", reason: inspect(reason)})
    end
  end

  defp unwrap_operator_payload(%{"data" => %{} = inner}), do: inner
  defp unwrap_operator_payload(other) when is_map(other), do: other
  defp unwrap_operator_payload(_), do: %{}
end
