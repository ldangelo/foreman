import Config

config :foreman_server,
  ecto_repos: [ForemanServer.Repo]

config :foreman_server, ForemanServer.Repo,
  pool_size: String.to_integer(System.get_env("FOREMAN_SERVER_DB_POOL_SIZE") || "10"),
  migration_source: "foreman_server_schema_migrations"

# Finite, configurable timeout (ms) for projection rebuild operations:
# - EventStore.start_link/1 init/1
# - EventStore.rebuild_projections/0 GenServer.call/3
# - ProjectionStore.Postgres.replace_all/1 Repo.transaction/3
# Default 10 minutes (600_000 ms) covers the observed ~30s rebuild of a
# 157K-event log while still letting the supervisor recover from a stalled
# init/transaction. Override via env: FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS
# (or set :projection_rebuild_timeout_ms in your runtime.exs).
config :foreman_server, :projection_rebuild_timeout_ms,
  String.to_integer(System.get_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS") || "600000")

import_config "#{config_env()}.exs"
