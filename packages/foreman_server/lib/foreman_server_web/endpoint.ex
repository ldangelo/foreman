defmodule ForemanServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :foreman_server

  @session_options [
    store: :cookie,
    key: "_foreman_server_key",
    signing_salt: "debugpages"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ForemanServerWeb.Router
end
