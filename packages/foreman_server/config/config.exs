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
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter],
  # JAI-T001: agent execution strategy.  Options: :react (ReAct reasoning),
  # :cot (chain-of-thought), :manual (JidoHarnessAdapter direct).
  agent_strategy: :react,
  # JAI-T001: model identifier passed to the reasoning strategy.
  # "auto" resolves via the jido_ai model_aliases to LiteLLM (LGL-T001),
  # which selects the best model per capability at request time.
  agent_model: "auto"

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

# TRD-2026-4212be7e LGL-T001: wire req_llm through LiteLLM when Jido.AI
# reasoning strategies use the "auto" model alias.  The alias resolves to
# %{provider: :openai, id: "auto", base_url: <liteLLM endpoint>}; req_llm
# uses model.base_url for the HTTP endpoint, so all jido_ai LLM calls
# route through LiteLLM with auto-model selection.
config :jido_ai,
  model_aliases: %{
    "auto" => %{
      provider: :openai,
      id: "auto",
      base_url: System.get_env("LITELLM_ENDPOINT", "http://localhost:4000")
    }
  }
config :langfuse,
  endpoint: System.get_env("LANGFUSE_ENDPOINT", "http://localhost:3000")
# TRD-2026-4212be7e JSH-T003: VFS isolation per worktree.
# Each agent is bound to a worktree root; shell commands outside
# that root are denied. Allowed worktree roots are enumerated here
# so the VfsIsolation module can validate new bindings against
# the configured allowlist.
config :foreman_server, :jido_vfs,
  # Worktrees must live under one of these base directories.
  allowed_roots: [
    System.get_env("FOREMAN_VFS_ALLOWED_ROOT", "/Users/ldangelo/Development/Fortium")
  ],
  # When false, VfsIsolation.allowlist_check/2 returns :ok without
  # inspecting the configured roots (useful in CI where worktrees
  # may be in /tmp). Default true in dev/prod.
  enforce_allowlist: System.get_env("FOREMAN_VFS_ENFORCE_ALLOWLIST", "true") == "true"

import_config "#{config_env()}.exs"
