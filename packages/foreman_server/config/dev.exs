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

config :foreman_server, ForemanServer.Overwatch, enabled: true

config :foreman_server, ForemanServer.WorkerLauncher, enabled: true

# Plan workflow phases are long-running (ensemble full PRD/TRD skill
# invocations can exceed 4 minutes on first run with cold pi skill cache).
# The default FailurePolicy timeout is 60_000ms which aborts the phase
# mid-skill. Phase names come from workflow YAML as strings, so keys
# MUST be strings to match the task_type passed by RunExecutor.
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.PiAdapter],
  default_timeout_ms: 60_000,
  failure_policies: %{
    "create-prd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "create-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000}
  }
