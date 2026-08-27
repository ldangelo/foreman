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

# Plan workflow phases are long-running (ensemble full PRD/TRD/implementation
# skill invocations can exceed 10 minutes on first run with cold pi skill cache
# and a large implementation surface; implement-trd-beads for the MCP server
# has 48 tasks over ~90h of estimated work). The built-in FailurePolicy default
# timeout is 60_000ms which aborts the phase mid-skill. Phase names come from
# workflow YAML as strings, so keys MUST be strings to match the task_type
# passed by RunExecutor. `default_timeout_ms` covers any phase not named
# below (e.g. resolve, refine-prd, configure-team); the named overrides cover
# the known long-running ensemble skills.
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter],
  default_timeout_ms: 1_800_000,
  failure_policies: %{
    "create-prd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "create-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "refine-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "refine-prd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "implement-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 3_600_000},
    "implement-trd-beads" => %{fallback: false, max_attempts: 1, timeout_ms: 3_600_000}
  }

config :foreman_server, :operator_timeout, enabled: true

# Jido checkpoint store (TRD-2026-4212be7e, JCR-T004) — opt-in. Set
# enabled: true and the Repo url via env to bring up the Ecto.Repo
# under supervision. The wrapper module is safe to load even when
# disabled (calls return {:error, :repo_not_configured}).
config :foreman_server, :jido_ecto, enabled: false
config :foreman_server, ForemanServer.Agents.JidoCheckpointStore.Repo,
  url:
    System.get_env("JIDO_CHECKPOINT_DATABASE_URL",
      "postgres://postgres:postgres@localhost:55432/foreman_dev")

# TRD-036: MCP server (dev only)
config :foreman_server, :mcp,
  enabled: true,
  mount: "/mcp",
  allow_workflow_writes: false,
  allow_insecure_local: true
