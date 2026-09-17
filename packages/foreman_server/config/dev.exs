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

config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter]

config :foreman_server, :operator_timeout, enabled: true

# Jido checkpoint store (TRD-2026-4212be7e, JCR-T004) — opt-in. Set
# enabled: true and the Repo url via env to bring up the Ecto.Repo
# under supervision. The wrapper module is safe to load even when
# disabled (calls return {:error, :repo_not_configured}).
config :foreman_server, :jido_ecto, enabled: false

config :foreman_server, ForemanServer.Agents.JidoCheckpointStore.Repo,
  url:
    System.get_env(
      "JIDO_CHECKPOINT_DATABASE_URL",
      "postgres://postgres:postgres@localhost:55432/foreman_dev"
    )

# TRD-036: MCP server (dev only)
config :foreman_server, :mcp,
  enabled: true,
  mount: "/mcp",
  # Enables the write tools (foreman_work_submit / work_cancel / workflow_put /
  # workflow_delete / prompt_put). Required to dispatch work through MCP; the
  # gate stays off in config.exs and test.exs.
  allow_workflow_writes: true,
  allow_insecure_local: true

# BeadsWatcher auto-dispatch enabled (dev opt-in feature, TRD-005)
config :foreman_server, :start_beads_watcher?, true
