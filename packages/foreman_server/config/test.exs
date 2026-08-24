import Config

# Test-only overrides. Base config is expected to import this file via
# import_config "#{config_env()}.exs" in config/config.exs (TRD-022).
config :foreman_server, ForemanServer.EventStore,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test"),
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public",
  enable_hard_deletes: true

config :foreman_server, ForemanServer.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test")

config :foreman_server, ForemanServerWeb.Endpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "foremandebug"]

config :foreman_server,
  worker_launcher_enabled: false

# Overwatch stays off in test env. The infrastructure is exercised by
# dedicated overwatch_test.exs; flipping it on here would require every
# test that appends events to also stand up the WorkerSupervisor tree.
config :foreman_server, ForemanServer.Overwatch, enabled: false

config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: []

config :foreman_server, :stuck_run_check_interval_seconds, 3_600
# foreman_server: br_runner test override (TRD-030)
config :foreman_server, :br_runner, ForemanServer.TaskProviders.BrRunnerMock

config :foreman_server, :start_project_provider_projector?, false

config :foreman_server, :start_json_schema_cache?, false

config :foreman_server, :start_beads_watcher?, false
config :foreman_server, :start_lifecycle_reconciler?, false
config :foreman_server, :start_beads_orphan_janitor?, false
# JHA-T002: the in-process JidoHarnessAdapter is the production
# default after the JHA migration, but tests that exercise adapter
# routing assert the empty catalog from `adapters: []` above, so
# disable the jido_harness rollout switch here. Individual tests
# that need the adapter re-enable it via Application.put_env/3.
config :foreman_server, :jido_harness, enabled: false
config :phoenix, Phoenix.Diagnostics, enabled: false

config :logster,
  capture_log: false

# Jido checkpoint store (TRD-2026-4212be7e, JCR-T004) — off by default
# in tests because most test cases don't need Postgres persistence;
# opt in per-test via Application.put_env(:foreman_server, :jido_ecto,
# enabled: true).
config :foreman_server, :jido_ecto, enabled: false

config :foreman_server, ForemanServer.Agents.JidoCheckpointStore.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test")

# JSH-T003: VFS isolation per worktree — allow /tmp for test worktrees.
# `/var/folders/.../T/...` is macOS's per-user tmpdir; include the
# resolved-prefix paths in case so the tests in either environment
# bind worktrees without tripping the allowlist.
config :foreman_server, :jido_vfs,
  allowed_roots: ["/tmp", "/private/tmp", "/var/folders", "/Users/ldangelo/Development/Fortium"],
  enforce_allowlist: true
# OpenTelemetry tracer no-op in test (TRD-2026-4212be7e / JOT-T001).
# Default tracer is :otel_tracer_default which records every span and
# ships it through the batch processor. We don't want every test run to
# generate network traffic or batch-processor log noise — opt-in tests
# (e.g. OtelSpanEmitterIntegrationTest) flip the tracer back to
# :otel_tracer_default via Application.put_env/3.
config :opentelemetry, :tracer, :otel_tracer_noop
