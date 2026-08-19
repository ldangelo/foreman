import Config

config :foreman_server,
  event_stores: [ForemanServer.EventStore]

# EventStore — connection from DATABASE_URL env, defaulting to localhost:55432
config :foreman_server, ForemanServer.EventStore,
  url:
    System.get_env(
      "DATABASE_URL",
      "postgres://postgres:postgres@localhost:55432/foreman_eventstore_test"
    ),
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public"

config :foreman_server, ForemanServerWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: ForemanServerWeb.ErrorHTML], layout: false],
  pubsub_server: ForemanServer.PubSub

config :foreman_server, :agent_runtime,
  enabled: true,
  # Default agent backend is now JidoHarnessAdapter (JHA-T002:
  # replaced PiAdapter's Port.open shell-out with the in-process
  # Jido.Harness runtime). Operators wanting to revert to the
  # legacy external `pi` Node CLI can override with
  #   config :foreman_server, :agent_runtime,
  #     adapters: [ForemanServer.AgentRuntime.Adapters.PiAdapter]
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter]

# jido_harness backend — now the default after JHA-T002 (TRD-2026-
# 4212be7e): the in-process Jido.Harness runtime replaced the
# Port.open shell-out to the legacy `pi` Node CLI. The rollout
# switch is now a *kill switch*: setting `:jido_harness, :enabled`
# to false at runtime disables the adapter without changing the
# default. Operators can still fall back to PiAdapter by overriding
# the `:agent_runtime, :adapters` config to a list containing
# PiAdapter instead of JidoHarnessAdapter.
config :foreman_server, :jido_harness,
  # JHA-T002 flipped this from a rollout switch (default false) to a
  # kill switch (default true). Backwards-compat: setting
  # FOREMAN_USE_JIDO_HARNESS=false at boot still disables the adapter
  # so older deployment scripts keep working.
  enabled: System.get_env("FOREMAN_USE_JIDO_HARNESS", "true") == "true"
# foreman_server: task_provider subsystem (TRD-029)
config :foreman_server, :br_runner, ForemanServer.TaskProviders.SystemBrRunner

config :foreman_server, :task_provider,
  actor: nil,
  accepted_contract_versions: ["br.capabilities.v1"],
  providers: [ForemanServer.TaskProviders.BeadsAdapter]

# Per-project Beads JSONL watcher + orphan janitor supervisors (TRD-014).
# Both default `false` — operators opt in for production via
# Application.put_env/3 at boot (or a release config that uses
# REPLACE_OS_VARS / runtime env var substitution). Leave `false` for tests.
config :foreman_server, :start_beads_watcher?, false
# RunSlots: global and per-project concurrent run caps (TRD-005).
# max_concurrent_runs: total runs across all projects (default: 3)
# max_concurrent_runs_per_project: per-project cap (default: 100)
config :foreman_server, :max_concurrent_runs, 3
config :foreman_server, :max_concurrent_runs_per_project, 100
# Anubis MCP server (TRD-036)
config :foreman_server, :mcp,
  enabled: false,
  mount: "/mcp",
  allow_workflow_writes: false,
  allow_insecure_local: false

# TRD-2026-4212be7e JOT-T001: jido_otel OTLP endpoint (Langfuse-compatible).
# Defaults to localhost:4318 for local dev; runtime overrides come from
# prod.exs (env-driven: OTEL_EXPORTER_OTLP_ENDPOINT, LANGFUSE_PUBLIC_KEY).
config :jido_otel,
  otlp_endpoint: "http://localhost:4318",
  service_name: "foreman_server"

# TRD-2026-4212be7e LGL-T001: litellm-langfuse-stack integration.
# LiteLLM runs on port 4000, Langfuse on port 3000. The `model: "auto"`
# value tells LiteLLM to pick the best model for the requested capability
# (code, chat, embeddings, etc.) at request time.
config :litellm,
  endpoint: System.get_env("LITELLM_ENDPOINT", "http://localhost:4000"),
  model: System.get_env("LITELLM_MODEL", "auto")

config :langfuse,
  endpoint: System.get_env("LANGFUSE_ENDPOINT", "http://localhost:3000")

import_config "#{config_env()}.exs"
