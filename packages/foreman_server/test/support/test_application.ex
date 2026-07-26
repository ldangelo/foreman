defmodule ForemanServer.TestSupport.TestApplication do
  use Commanded.Application,
    otp_app: :foreman_server,
    event_store: [
      adapter: Commanded.EventStore.Adapters.InMemory
    ]

  router(ForemanServer.TestSupport.TestRouter)
end
