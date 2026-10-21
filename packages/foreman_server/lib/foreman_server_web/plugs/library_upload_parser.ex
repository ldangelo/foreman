defmodule ForemanServerWeb.Plugs.LibraryUploadParser do
  @moduledoc """
  Parses `multipart/form-data` for the project-library upload routes with a larger
  body limit than the endpoint-wide `Plug.Parsers` default (8 MB).

  Only `POST`/`PUT /api/projects/<id>/library[/<entry_id>]` get the raised limit
  (`config :foreman_server, :library, upload_max_bytes`, default 512 MiB; a whole request, so a
  single add of many large files may need it raised, and an overrun is a JSON 413 `upload_too_large`); every
  other path keeps the default, so the larger limit cannot be used to push big
  bodies at unrelated routes. Uploaded parts are streamed to temp files by
  `Plug.Parsers` (`Plug.Upload`), never held in memory. The endpoint's regular
  `Plug.Parsers` runs after this plug and leaves already-parsed bodies alone.
  """

  @behaviour Plug

  @default_max 512 * 1024 * 1024
  @path ~r{\A/api/projects/[^/]+/library(/[^/]+)?\z}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, request_path: path} = conn, _opts)
      when method in ["POST", "PUT"] do
    if Regex.match?(@path, path) and multipart?(conn) do
      # Authenticate BEFORE reading a byte of the (up to `upload_max_bytes`) body: this
      # plug runs ahead of the router's `:api` pipeline, so an unauthenticated caller
      # would otherwise get a large multipart parse for free.
      # `?token=` is read from the query string only; the body stays untouched.
      case conn |> Plug.Conn.fetch_query_params() |> ForemanServerWeb.Plugs.BearerAuth.call([]) do
        %Plug.Conn{halted: true} = denied -> denied
        authed -> parse(authed)
      end
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp parse(conn) do
    max = Application.get_env(:foreman_server, :library, [])[:upload_max_bytes] || @default_max

    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: [{:multipart, length: max}], pass: ["*/*"])
    )
  rescue
    Plug.Parsers.RequestTooLargeError ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        413,
        Jason.encode!(%{
          error: "upload_too_large",
          message: "upload exceeds the server's request body limit (upload_max_bytes)"
        })
      )
      |> Plug.Conn.halt()
  end

  defp multipart?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "multipart/"))
  end
end
