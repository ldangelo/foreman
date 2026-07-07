import Config

base = Path.expand("../../tmp/test", __DIR__)

config :foreman_server,
  event_store_adapter: :term,
  database_url: nil,
  event_log_path: Path.join(base, "events.term.log"),
  project_store_path: Path.join(base, "projects.term"),
  scheduler: [auto_tick: false, event_triggered_ticks: false]
