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
  # JidoHarnessAdapter is the sole agent backend after JHA-T002
  # (TRD-2026-4212be7e). The in-process Jido.Harness runtime replaced
  # the Port.open shell-out to the legacy `pi` Node CLI.
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter],
  # JAI-T001: agent execution strategy.  Options: :react (ReAct reasoning),
  # :cot (chain-of-thought), :manual (JidoHarnessAdapter direct).
  agent_strategy: :react,
  # JAI-T001: model identifier passed to the reasoning strategy.
  # "auto" resolves via the jido_ai model_aliases to LiteLLM (LGL-T001),
  # which selects the best model per capability at request time.
  agent_model: "auto"

# Overwatch worker-runtime supervision tree. Production default enabled so
# the Jido path (RunExecutor → Overwatch.start_phase → LaunchWorker) can
# emit WorkerStarted/WorkerHeartbeat/WorkerExited through CommandRouter
# and flip run.status from awaiting_worker → in_progress. Test mode
# overrides this to false in config/test.exs.
config :foreman_server, ForemanServer.Overwatch, enabled: true
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

# OpenTelemetry SDK resource attributes (TRD-2026-4212be7e / JOT-T001).
# Spans emitted by OtelSpanEmitter carry service.name = "foreman_server"
# and the version below; Langfuse / OTel Collector use this to bucket traces.
config :opentelemetry, :resource,
  service: [
    name: "foreman_server",
    version: "0.1.0"
  ]

# OpenTelemetry OTLP exporter (TRD-2026-4212be7e / JOT-T001).
# Without these keys, the SDK's batch processor logs
# "OTLP exporter module `opentelemetry_exporter` not found" every 5s and
# no spans leave the box — the dep is now in mix.exs so the module loads,
# and these settings tell the exporter where to send spans.
#
# Dev default points at the OTel Collector's standard local port (4318).
# prod.exs overrides otlp_endpoint from OTEL_EXPORTER_OTLP_ENDPOINT and
# adds an Authorization: Basic header built from LANGFUSE_PUBLIC_KEY and
# LANGFUSE_SECRET_KEY when both are set, so Langfuse-compatible ingest
# accepts the traces.
config :opentelemetry_exporter,
  otlp_endpoint: "http://localhost:4318",
  otlp_protocol: :http_protobuf,
  otlp_headers: []

# Wire the OpenTelemetry SDK so spans actually flow:
# - :processors routes spans through the batch processor (the default
#   recommended pipeline for production; in dev it still helps cut
#   per-span HTTP overhead against the collector).
# - :traces_exporter hands completed batches to :otel_exporter_otlp
#   (Erlang module; the Elixir OpentelemetryExporter wrapper does not
#   exist in :opentelemetry_exporter 1.10.0). The exporter's own
#   :opentelemetry_exporter env keys (otlp_endpoint, otlp_protocol,
#   otlp_headers) are read inside otel_exporter_otlp:init/1.
# Without these, `Application.started_applications/0` shows
# :opentelemetry + :opentelemetry_exporter running, but the batch processor
# is never started and no spans leave the box (verified 2026-08-22: collector
# self-metrics showed only 2 self-test spans in 14h).
config :opentelemetry,
  processors: [
    {:otel_batch_processor, %{}}
  ],
  traces_exporter: {:otel_exporter_traces_otlp, %{endpoints: ["http://localhost:4318"]}}

# SigNoz operational logs are opt-in and deliberately separate from the
# Langfuse/Jido trace path above. The bridge preserves console Logger output
# and falls back to no-op when disabled.
#
# All four FOREMAN_SIGNOZ_* env vars are parsed once here so dev/test/prod
# share identical validation — prod.exs previously re-derived `headers` and
# `level` itself, which meant dev silently ignored FOREMAN_SIGNOZ_OTLP_HEADERS
# and FOREMAN_SIGNOZ_LOG_LEVEL (neither config.exs nor dev.exs read them, so
# they were stuck at `[]`/`:debug` in dev regardless of the env vars), and
# test.exs had no override at all — an operator's FOREMAN_SIGNOZ_LOGS_ENABLED
# left set from a dev session would enable the real network exporter under
# `mix test` (see config/test.exs for the explicit test-env disable).
#
# Malformed input fails the boot instead of silently coercing to a default
# (AGENTS.md 5.3, "distinguish absent from malformed"): an unrecognized
# FOREMAN_SIGNOZ_LOG_LEVEL, a malformed FOREMAN_SIGNOZ_OTLP_HEADERS pair, or
# credential headers paired with a non-https FOREMAN_SIGNOZ_OTLP_ENDPOINT all
# raise at config load rather than shipping a plausible-looking default.
signoz_logs_level =
  case System.get_env("FOREMAN_SIGNOZ_LOG_LEVEL", "info") |> String.downcase() do
    "debug" ->
      :debug

    "info" ->
      :info

    "notice" ->
      :notice

    "warning" ->
      :warning

    "error" ->
      :error

    "critical" ->
      :critical

    "alert" ->
      :alert

    "emergency" ->
      :emergency

    other ->
      raise "invalid FOREMAN_SIGNOZ_LOG_LEVEL=#{inspect(other)}; expected one of " <>
              "debug, info, notice, warning, error, critical, alert, emergency"
  end

signoz_logs_headers =
  System.get_env("FOREMAN_SIGNOZ_OTLP_HEADERS", "")
  |> String.split(",", trim: true)
  |> Enum.map(fn pair ->
    case String.split(pair, "=", parts: 2) do
      [key, value] ->
        trimmed_key = String.trim(key)

        if trimmed_key == "" do
          raise "invalid FOREMAN_SIGNOZ_OTLP_HEADERS pair #{inspect(pair)}: header name is blank"
        end

        {trimmed_key, String.trim(value)}

      _ ->
        raise "invalid FOREMAN_SIGNOZ_OTLP_HEADERS pair #{inspect(pair)}: expected key=value"
    end
  end)

signoz_logs_endpoint =
  System.get_env("FOREMAN_SIGNOZ_OTLP_ENDPOINT", "http://localhost:4318/v1/logs")

case URI.parse(signoz_logs_endpoint) do
  %URI{scheme: scheme, host: host}
  when scheme in ["http", "https"] and is_binary(host) and host != "" ->
    :ok

  _ ->
    raise "invalid FOREMAN_SIGNOZ_OTLP_ENDPOINT=#{inspect(signoz_logs_endpoint)}; " <>
            "expected a parseable http:// or https:// URI with a non-empty host"
end

if signoz_logs_headers != [] and not String.starts_with?(signoz_logs_endpoint, "https://") do
  raise "FOREMAN_SIGNOZ_OTLP_HEADERS is set but FOREMAN_SIGNOZ_OTLP_ENDPOINT=" <>
          "#{signoz_logs_endpoint} is not https://; refusing to configure credentialed " <>
          "headers over an insecure endpoint"
end

config :foreman_server, :signoz_logs,
  enabled: System.get_env("FOREMAN_SIGNOZ_LOGS_ENABLED", "false") == "true",
  endpoint: signoz_logs_endpoint,
  headers: signoz_logs_headers,
  level: signoz_logs_level,
  exporter: :otel

# TRD-2026-4212be7e LGL-T001: litellm-langfuse-stack integration.
# LiteLLM runs on port 4000, Langfuse on port 3000. The `model: "auto"`
# (code, chat, embeddings, etc.) at request time.
config :foreman_server, :litellm,
  endpoint: System.get_env("LITELLM_ENDPOINT", "http://localhost:4000"),
  model: System.get_env("LITELLM_MODEL", "auto")

# TRD-2026-4212be7e LGL-T001: wire req_llm through LiteLLM when Jido.AI
# reasoning strategies use the "auto" model alias.  The alias resolves to
# %{provider: :openai, id: "auto", base_url: <liteLLM endpoint>}; req_llm
# uses model.base_url for the HTTP endpoint, so all jido_ai LLM calls
# route through LiteLLM with auto-model selection.
config :jido_ai,
  model_aliases: %{
    auto: %{
      provider: :openai,
      id: "auto",
      base_url: System.get_env("LITELLM_ENDPOINT", "http://localhost:4000")
    }
  }

config :foreman_server, :langfuse,
  endpoint: System.get_env("LANGFUSE_ENDPOINT", "http://localhost:3000")

# TRD-2026-4212be7e JSH-T003: VFS isolation per worktree.
# Each agent is bound to a worktree root; shell commands outside
# that root are denied. Allowed worktree roots are enumerated here
# so the VfsIsolation module can validate new bindings against
# the configured allowlist.
config :foreman_server, :jido_vfs,
  # Worktrees must live under one of these base directories.
  allowed_roots: [
    System.get_env("FOREMAN_VFS_ALLOWED_ROOT", "/Users/ldangelo/Development/Fortium"),
    Path.join([System.get_env("HOME", "/Users/ldangelo"), ".foreman", "worktrees"])
  ],
  # When false, VfsIsolation.allowlist_check/2 returns :ok without
  # inspecting the configured roots (useful in CI where worktrees
  # may be in /tmp). Default true in dev/prod.
  enforce_allowlist: System.get_env("FOREMAN_VFS_ENFORCE_ALLOWLIST", "true") == "true"

import_config "#{config_env()}.exs"
