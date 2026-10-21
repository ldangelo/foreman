defmodule ForemanServerWeb.Plugs.LibraryUploadParser do
  @moduledoc """
  Parses `multipart/form-data` for the project-library upload routes with a larger
  body limit than the endpoint-wide `Plug.Parsers` default (8 MB).

  Only `POST`/`PUT /api/projects/<id>/library[/<entry_id>]` get the raised limit
  (`config :foreman_server, :library, upload_max_bytes`, default 512 MiB); every
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
      max = Application.get_env(:foreman_server, :library, [])[:upload_max_bytes] || @default_max

      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(parsers: [{:multipart, length: max}], pass: ["*/*"])
      )
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp multipart?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "multipart/"))
  end
end
