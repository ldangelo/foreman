defmodule ForemanServerWeb.GithubWebhookController do
  @moduledoc """
  TRD-017: HTTP endpoint that receives GitHub webhook deliveries and
  routes the payload through `ForemanServer.Webhooks.Github`.

  Configure your GitHub webhook to point at `POST /webhooks/github`, with content
  type `application/json` and the same secret as `FOREMAN_GITHUB_WEBHOOK_SECRET`.
  Deliveries are authenticated before they reach this controller by
  `ForemanServerWeb.Plugs.VerifyGithubSignature`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Webhooks.Github

  def github(conn, params) do
    case Github.process(params) do
      :ok ->
        conn |> put_status(:accepted) |> json(%{status: "ok"})

      :ignored ->
        conn |> put_status(:accepted) |> json(%{status: "ignored"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", reason: inspect(reason)})
    end
  end
end
