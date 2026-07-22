import Config

config :foreman_server,
  ecto_repos: [ForemanServer.Repo]

config :foreman_server, ForemanServer.Repo,
  pool_size: String.to_integer(System.get_env("FOREMAN_SERVER_DB_POOL_SIZE") || "10"),
  migration_source: "foreman_server_schema_migrations"

# Finite, configurable default timeout (ms) for projection rebuild operations:
# - EventStore.start_link/1 init/1
# - EventStore.rebuild_projections/0 GenServer.call/3
# - ProjectionStore.Postgres.replace_all/1 Repo.transaction/3
# Default 10 minutes (600_000 ms) covers the observed ~30s rebuild of a
# 157K-event log while still letting the supervisor recover from a stalled
# init/transaction.
#
# Runtime override: env var FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS,
# resolved by ForemanServer.RuntimeInfo.projection_rebuild_timeout_ms/0
# (which reads it at call time and falls back to this config value, then
# to 600_000 ms, on invalid/missing). The EventStore.start_link/1 init
# timeout is captured when the supervisor spawns the GenServer, so a
# new env value affects the next start, not a running process. The
# HTTP-triggered rebuild_projections/0 and Repo.transaction/3 paths
# read the env at call time, so the next request after an env change
# picks up the new value without restart.
config :foreman_server, :projection_rebuild_timeout_ms, 600_000

import_config "#{config_env()}.exs"
