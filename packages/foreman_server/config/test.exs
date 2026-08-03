import Config

# Test-only overrides. Base config is expected to import this file via
# import_config "#{config_env()}.exs" in config/config.exs (TRD-022).
config :foreman_server, ForemanServer.EventStore,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test"),
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public"

config :foreman_server, ForemanServer.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test")

config :foreman_server,
  worker_launcher_enabled: false

config :phoenix, Phoenix.Diagnostics, enabled: false

config :logster,
  capture_log: false
