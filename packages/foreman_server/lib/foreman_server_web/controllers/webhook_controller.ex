defmodule ForemanServerWeb.WebhookController do
  @moduledoc """
  TRD-015: Webhook ingestion endpoint for external triggers.

  Routes:
    * `POST /webhooks/external_trigger` — ingest payload via
      `SharedInbox.ingest/2`. Source module is read from application
      config (`:trigger_webhook_source_module`).
  """

  use ForemanServerWeb, :controller

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
end
