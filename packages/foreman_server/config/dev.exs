import Config

config :foreman_server, ForemanServer.EventStore,
  url: "postgres://postgres:postgres@localhost:55432/foreman_eventstore_dev",
  log: :debug

config :foreman_server, ForemanServer.Repo,
  url: "postgres://postgres:postgres@localhost:55432/foreman_dev"

config :foreman_server, ForemanServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4766],
  debug_errors: true,
  code_reloader: true

config :foreman_server, ForemanServer.Overwatch,
  enabled: true,
  log: :debug

config :foreman_server, ForemanServer.WorkerLauncher,
  enabled: true
