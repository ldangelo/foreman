defmodule ForemanServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :foreman_server

  @session_options [
    store: :cookie,
    key: "_foreman_server_key",
    signing_salt: "debugpages"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # The workspace LiveViews' client libraries, served straight from the deps
  # (no asset pipeline): exactly these two files, nothing else.
  plug(Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)
  )

  plug(Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {ForemanServerWeb.CacheRawBody, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(ForemanServerWeb.Router)
end
