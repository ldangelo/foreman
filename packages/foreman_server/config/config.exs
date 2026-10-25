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
# Multi-repository runs (E12). Open since E12-S12 (`scripts/e2e/multi_repo.sh`, 110
# assertions against a real agent, see docs/lessons/multi-repo-e2e-2026-10-21.md).
# `runs: false` is the operator's kill switch: it refuses, at run start, any run whose
# resolved repository set is larger than one repository or whose primary repository is
# not the project's primary (`{:error, :multi_repo_runs_disabled}`). Tests state the
# gate they need with `ForemanServer.MultiRepoRuns.enable!/0` and `disable!/0`.
config :foreman_server, :multi_repo, runs: true
# Anubis MCP server (TRD-036)
config :foreman_server, :mcp,
  enabled: false,
  mount: "/mcp",
  allow_workflow_writes: false,
  allow_insecure_local: false

# JSON `/api` pipeline (ForemanServerWeb.Plugs.BearerAuth). With no
# `:api_bearer_token` configured the API answers 401 unless
# `allow_insecure_local` is exactly `true`. Opt-in for local development only:
# dev.exs/test.exs enable it; production uses FOREMAN_API_TOKEN (or
# FOREMAN_API_ALLOW_INSECURE_LOCAL=true via runtime.exs).
config :foreman_server, :api, allow_insecure_local: false

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

# Prompt-cache lifetime per provider, seconds (ForemanServer.Usage.CacheHint).
# claude: Anthropic's documented 5-minute default [assumption: tune per provider;
# providers without an entry report `likely_cold: null`].
config :foreman_server, :usage, cache_ttl_seconds: %{claude: 300}

# Per-run session archive + automated review (ForemanServer.Review).
# Mid-phase steering (docs/plans/live-steering.md): claude/pi phases are launched with
# streaming input so an operator steer is taken inside the running session. `false`
# restores pause -> resume at the phase boundary for every provider.
config :foreman_server, :live_steering, enabled: true

# `max_concurrent_analyses` bounds how many reviewer agents run at once (the rest queue):
# 32 reviewers started together all failed on a provider 429 (foreman-uxfwb).
# `evaluator_retry_backoff_ms` is how long a reviewer that failed on a provider rate
# limit waits before its one retry.
config :foreman_server, :review,
  capture: true,
  analysis: true,
  archive_root: nil,
  agent: %{provider: :claude, model: nil, effort: nil},
  evaluator: ForemanServer.Review.Evaluator.Agent,
  evaluator_timeout_ms: 900_000,
  evaluator_retry_backoff_ms: 60_000,
  max_concurrent_analyses: 3,
  max_transcript_bytes: 2_000_000,
  max_diff_bytes: 1_000_000,
  max_comment_bytes: 8_000,
  max_gap_beads: 10

# PR watching (E9): ForemanServer.PrWatcher observes the PRs of runs (checks, reviews,
# comments, conflicts) and, when a project opts in, starts fix threads. `enabled: false`
# (env FOREMAN_PR_WATCHER_ENABLED=false) stops it. Polling is a separate opt-in
# (FOREMAN_PR_MONITOR_ENABLED=true -> ForemanServer.PrMonitor). The fix-thread jobsite
# runs `agent` unless the run's own provider session names one; `max_iterations`
# bounds one fix agent invocation; `log_tail_bytes` caps the failing-CI log excerpt.
config :foreman_server, :pr_watcher, enabled: true

config :foreman_server, :pr_fix,
  agent: %{"provider" => "claude"},
  max_iterations: 1,
  log_tail_bytes: 20_000

# Per-project coordinator conversation (ForemanServer.Coordinator).
config :foreman_server, :coordinator,
  enabled: true,
  agent: ForemanServer.Coordinator.Agent.Harness,
  # Spike S1: pi + MiniMax is the provider path verified end to end.
  default_provider: :pi,
  default_model: "minimax/MiniMax-M2.7-highspeed",
  default_effort: nil,
  agent_timeout_ms: 180_000,
  turn_timeout_ms: 300_000,
  retry_backoff_ms: 5_000,
  unhealthy_after: 3,
  max_message_bytes: 16_000,
  max_actions_per_turn: 10,
  max_threads_per_turn: 5,
  # Messages from these sources never carry operator authority (thread agents
  # can call the MCP tool). Remove "mcp" only to let MCP callers start work.
  untrusted_sources: ["mcp"],
  report_turns_per_hour: 6,
  report_backfill_hours: 24,
  # The first-turn setup proposal (Coordinator.SetupProposer): posted once when a project
  # is registered and, at startup, for projects whose conversation has no message yet.
  setup_proposals: true,
  mcp_messages_per_minute: 6,
  context: [max_total_tokens: 12_000]

# Per-project memory (ForemanServer.ProjectMemory): caps and durable-content guard.
config :foreman_server, :project_memory,
  max_topic_bytes: 65_536,
  max_index_lines: 200,
  max_index_bytes: 25_600,
  max_topics: 200,
  max_description_chars: 200,
  max_repeat_ratio: 0.5,
  max_redaction_ratio: 0.5,
  min_guard_bytes: 200

# Scheduled tasks (E11). `ticker_enabled` starts `Schedule.Ticker` (env override:
# FOREMAN_SCHEDULE_TICKER_ENABLED=true|false in runtime.exs; off under test).
# `min_interval_seconds` is the smallest `every` accepted; `max_per_project` caps
# non-deleted schedules per project; `default_misfire_grace_seconds` is how late
# a due slot may still fire before it is recorded as skipped (`missed`).
config :foreman_server, :schedule,
  ticker_enabled: true,
  tick_interval_ms: 30_000,
  min_interval_seconds: 300,
  max_per_project: 50,
  default_misfire_grace_seconds: 600

# Per-project secret VALUES live only here, never in events (E4, spike E4-SP1).
# Default: 0600 files under ~/.foreman/secrets (dir 0700), outside any repo.
config :foreman_server, :secret_store,
  backend: ForemanServer.SecretStore.File,
  dir: Path.join(System.user_home!(), ".foreman/secrets")

# Secret values arrive as `value` in PUT /api/projects/:id/secrets/:name; Phoenix
# must never log them (E4-S6).
config :phoenix, :filter_parameters, ["password", "value"]

# Project library (E5): limits mirror Claude Projects. `folder_*` apply to a folder add;
# `produced_*` bound thread-produced files registered by `Library.Collector`;
# `allow_server_paths` lets an operator add a directory that lives on the server host
# (off by default: it lets the caller read arbitrary server directories).
config :foreman_server, :library,
  max_files_per_add: 100,
  max_file_bytes: 480 * 1024 * 1024,
  folder_max_files: 100,
  folder_max_bytes: 200 * 1024 * 1024,
  folder_skip_file_bytes: 30 * 1024 * 1024,
  upload_max_bytes: 512 * 1024 * 1024,
  allow_server_paths: false,
  collector: true,
  produced_max_bytes_per_run: 50 * 1024 * 1024,
  produced_max_files_per_run: 100

config :foreman_server, :project_context,
  max_bytes: 24_000,
  section_caps: %{instructions: 16_000, repositories: 1_000, memory: 6_000, library: 3_000},
  section_providers: [ForemanServer.ProjectContext.Memory, ForemanServer.ProjectContext.Library]

import_config "#{config_env()}.exs"
