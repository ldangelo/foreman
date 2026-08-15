defmodule ForemanServer.MCP.Auth do
  @moduledoc """
  Shared bearer-token verifier for both MCP transports (HTTP and stdio).

  Verifies bearer tokens from the `Authorization: Bearer <token>` header
  using constant-time comparison (`Plug.Crypto.secure_compare/2`) to resist
  timing attacks.

  ## Behaviour

  - **Token absent, `allow_insecure_local: false`** → `{:error, :no_token_configured}`
  - **Token absent, `allow_insecure_local: true`** → `:ok` (local dev mode)
  - **Token present, matches** → `:ok`
  - **Token present, does not match** → `{:error, :invalid_token}`

  ## Security guarantees

  - Token comparison is constant-time (`secure_compare`) to resist timing attacks.
  - Neither the bearer token nor tool-call arguments are ever emitted to
    `Logger` or `Telemetry` metadata, protecting them from log injection
    and log-file exposure.
  """

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Verify a raw bearer token string (e.g. from an `Authorization` header).

  Returns `:ok` if the token is valid (or local-insecure mode is enabled
  and no token is configured), or `{:error, reason}` otherwise.
  """
  @spec verify_token(String.t() | nil) :: :ok | {:error, :invalid_token | :no_token_configured}
  def verify_token(nil) do
    if insecure_local?() do
      :ok
    else
      {:error, :no_token_configured}
    end
  end

  def verify_token(token) when is_binary(token) do
    expected = Application.get_env(:foreman_server, :api_bearer_token)

    cond do
      is_nil(expected) or expected == "" ->
        if insecure_local?() do
          :ok
        else
          {:error, :no_token_configured}
        end

      Plug.Crypto.secure_compare(token, expected) ->
        :ok

      true ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Verify a bearer token and log the tool name on failure.

  The tool name is logged at `:debug` level on auth failure.  Neither the
  bearer token nor the `args` map are ever included in any log or telemetry
  event.
  """
  @spec verify_request(String.t() | nil, String.t(), map()) ::
          :ok | {:error, :invalid_token | :no_token_configured}
  def verify_request(token, tool_name, args)
      when is_binary(tool_name) and is_map(args) do
    case verify_token(token) do
      :ok ->
        :ok

      {:error, _} = error ->
        require Logger
        Logger.debug(fn -> "MCP.Auth: authentication failed for tool #{tool_name}" end)
        error
    end
  end

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    token = bearer_token(conn)

    case verify_token(token) do
      :ok ->
        conn

      {:error, _reason} ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> Plug.Conn.halt()
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp insecure_local? do
    Keyword.get(
      Application.get_env(:foreman_server, :mcp, []),
      :allow_insecure_local,
      false
    )
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
