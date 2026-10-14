defmodule ForemanServerWeb.Plugs.VerifyGithubSignature do
  @moduledoc """
  Authenticates a GitHub webhook delivery by its `X-Hub-Signature-256` header: the
  HMAC-SHA256 of the raw request body, keyed with the shared secret configured in
  `:foreman_server, :github_webhook_secret` (`FOREMAN_GITHUB_WEBHOOK_SECRET`).

  Fails closed. With no secret configured nothing is accepted, because an endpoint
  that mutates run state on an unauthenticated POST is worse than a webhook that is
  switched off. Each failure has its own response so an operator can tell a
  misconfigured server from a bad delivery:

    * no secret configured          — `503 webhook_secret_not_configured`
    * header absent                 — `401 signature_missing`
    * header not `sha256=<hex>`     — `401 signature_malformed`
    * digest does not match         — `401 signature_mismatch`
    * body was not cached           — `500 raw_body_unavailable`

  Only the SHA-256 header is honoured; the legacy SHA-1 `X-Hub-Signature` is not.
  The digest comparison is constant-time. The body comes from
  `ForemanServerWeb.CacheRawBody`, which must list this route's path.
  """

  import Plug.Conn

  alias ForemanServerWeb.CacheRawBody

  @header "x-hub-signature-256"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    with {:ok, secret} <- secret(),
         {:ok, provided} <- provided_signature(conn),
         :ok <- verify(CacheRawBody.raw_body(conn), secret, provided) do
      conn
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp secret do
    case Application.get_env(:foreman_server, :github_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :secret_not_configured}
    end
  end

  defp provided_signature(conn) do
    case get_req_header(conn, @header) do
      [] -> {:error, :signature_missing}
      ["sha256=" <> hex = value | _] when hex != "" -> {:ok, value}
      _ -> {:error, :signature_malformed}
    end
  end

  defp verify(nil, _secret, _provided), do: {:error, :raw_body_unavailable}

  defp verify(body, secret, provided) do
    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    if Plug.Crypto.secure_compare(expected, provided),
      do: :ok,
      else: {:error, :signature_mismatch}
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status(reason), Jason.encode!(%{status: "error", reason: error_name(reason)}))
    |> halt()
  end

  defp status(:secret_not_configured), do: 503
  defp status(:raw_body_unavailable), do: 500
  defp status(_signature_problem), do: 401

  defp error_name(:secret_not_configured), do: "webhook_secret_not_configured"
  defp error_name(reason), do: Atom.to_string(reason)
end
