defmodule ForemanServer.Application do
  use Commanded.Application,
    otp_app: :foreman_server,
    event_store: [
      adapter: Commanded.EventStore.Adapters.EventStore,
      event_store: ForemanServer.EventStore
    ]

  router(ForemanServer.Router)
end
