defmodule ForemanServerWeb.GithubWebhookController do
  @moduledoc """
  TRD-017: HTTP endpoint that receives GitHub webhook deliveries and
  routes the payload through `ForemanServer.Webhooks.Github`.

  Configure your GitHub webhook to point at `POST /webhooks/github`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Webhooks.Github

  def github(conn, params) do
    case Github.process(params) do
      :ok ->
        conn |> send_resp(202, ~s({"status":"ok"}))

      :ignored ->
        conn |> send_resp(202, ~s({"status":"ignored"}))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", reason: inspect(reason)})
    end
  end
end
