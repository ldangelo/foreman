import Config

config :foreman_server, ForemanServer.EventStore,
  url:
    System.get_env(
      "DATABASE_URL",
      "postgres://postgres:postgres@localhost:55432/foreman_eventstore_dev"
    )
config :foreman_server, ForemanServer.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_dev")

config :foreman_server, ForemanServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4766],
  debug_errors: true,
  code_reloader: true,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "foremandebug"]

config :foreman_server, ForemanServer.Overwatch,
  enabled: true

config :foreman_server, ForemanServer.WorkerLauncher,
  enabled: true
