defmodule ForemanServerWeb.Endpoint do
  @moduledoc "Phoenix endpoint powering dev-only LiveView debug pages."

  use Phoenix.Endpoint, otp_app: :foreman_server

  @session_options [
    store: :cookie,
    key: "_foreman_server_debug_key",
    signing_salt: "foreman-debug-session"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ForemanServerWeb.Router
end
