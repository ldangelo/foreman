import Config

# ── EventStore ────────────────────────────────────────────────────────────────
# Read DATABASE_URL from .env (./.envrc → .env → RuntimeInfo); fall back to
# the local dev compose stack (port 55432).  The .env DATABASE_URL is
# authoritative, matching the project convention.
database_url =
  System.get_env("DATABASE_URL") ||
    "postgresql://postgres:postgres@127.0.0.1:55432/foreman_dev"

config :foreman_server,
  event_store_adapter: :postgres,
  database_url: database_url

# ── Repo ──────────────────────────────────────────────────────────────────────
config :foreman_server, ForemanServer.Repo,
  url: database_url,
  pool_size: 10

# ── Phoenix / HTTP ────────────────────────────────────────────────────────────
config :foreman_server,
  http_enabled: true,
  debug_errors: true,
  http_port: 4766

# ── Overwatch / Scheduler ─────────────────────────────────────────────────────
# Recovery.scheduler_env/2 reads :scheduler → :worker_launcher at startup.
config :foreman_server,
  scheduler: [
    worker_launcher: ForemanServer.WorkerLauncher
  ]

# ── Logger ────────────────────────────────────────────────────────────────────
config :logger, level: :debug
