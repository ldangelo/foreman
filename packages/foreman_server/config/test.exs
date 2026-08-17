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

config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: []

config :foreman_server, :stuck_run_check_interval_seconds, 3_600
# foreman_server: br_runner test override (TRD-030)
config :foreman_server, :br_runner, ForemanServer.TaskProviders.BrRunnerMock

config :foreman_server, :start_project_provider_projector?, false

config :foreman_server, :start_json_schema_cache?, false

config :foreman_server, :start_beads_watcher?, false
config :foreman_server, :start_lifecycle_reconciler?, false
config :foreman_server, :start_beads_orphan_janitor?, false
config :phoenix, Phoenix.Diagnostics, enabled: false

config :logster,
  capture_log: false
