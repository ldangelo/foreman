defmodule ForemanServerWeb.Plugs.DebugOnly do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:foreman_server, :debug_live_views_enabled, false) do
      conn
    else
      conn
      |> send_resp(:not_found, "Not Found")
      |> halt()
    end
  end
end
