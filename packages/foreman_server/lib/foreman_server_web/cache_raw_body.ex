defmodule ForemanServerWeb.CacheRawBody do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the exact request bytes for the routes that
  must verify a signature over them.

  `Plug.Parsers` consumes the body before the router runs, and a signature is
  computed over the bytes GitHub sent, not over a re-encoding of the parsed JSON.
  Caching is limited to `@cached_paths` so every other request is read as usual and
  no other body is held in memory a second time.

  The bytes are stored under `conn.private[:raw_body]`; read them with `raw_body/1`.
  """

  @cached_paths ["/webhooks/github"]

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: path} = conn, opts) when path in @cached_paths do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        {status, body, Plug.Conn.put_private(conn, :raw_body, (raw_body(conn) || "") <> body)}

      {:error, _reason} = error ->
        error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @doc "The cached request body, or `nil` when this path is not cached."
  @spec raw_body(Plug.Conn.t()) :: binary() | nil
  def raw_body(%Plug.Conn{private: private}), do: Map.get(private, :raw_body)
end
