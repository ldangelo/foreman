import Config

base = Path.expand("../../tmp/test", __DIR__)

config :foreman_server,
  event_store_adapter: :memory,
  database_url: nil,
  event_log_path: Path.join(base, "events.term.log"),
  project_store_path: Path.join(base, "projects.term"),
  debug_live_views_enabled: false,
  scheduler: [auto_tick: false, event_triggered_ticks: false]
