import Config

# Test-only overrides. Base config is expected to import this file via
# import_config "#{config_env()}.exs" in config/config.exs (TRD-022).
config :foreman_server, ForemanServer.EventStore,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test"),
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public",
  enable_hard_deletes: true,
  # Default pool_size (10) checks out under load from the full suite's
  # ~36 concurrent async test cases plus many serial aggregate actors all
  # sharing one EventStore connection pool — observed as sporadic
  # DBConnection.Holder.checkout timeouts/shutdowns late in full `mix
  # test` runs. Postgres itself allows up to 100 connections (see
  # `foreman-postgres` container), so there's ample headroom.
  pool_size: 30

config :foreman_server, ForemanServer.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_test")

config :foreman_server,
  worker_launcher_enabled: false

# OperatorTimeout backs ForemanServer.Agents.OperatorQuestionDispatcher's
# operator-response timeout scheduling; production always supervises it
# (see config/dev.exs). Without this, tests that exercise the dispatcher
# only pass by accident when another test file's setup_all happens to
# leak a process under the same registered name earlier in the run.
config :foreman_server, :operator_timeout, enabled: true

# The production default (3, config.exs) is realistic for a single node
# but far too tight for a 2300+ test suite: a single un-released holder
# anywhere in the run (residual cleanup gaps in test files that don't
# own the `run_slots:global` singleton) permanently starves every other
# test's RunAdmission.start/2 for the rest of the process, which is
# indistinguishable from a real capacity-gating bug until you dig in.
# Tests that specifically exercise the capacity-gating behavior already
# override this locally via `Application.put_env/3` (see
# run_admission_slot_gate_test.exs) and are unaffected by this default.
config :foreman_server, :max_concurrent_runs, 50

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
config :foreman_server, :start_boot_reconciliation?, false
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
config :foreman_server, :jido_vfs,
  allowed_roots: ["/tmp", "/Users/ldangelo/Development/Fortium"],
  enforce_allowlist: true

# OpenTelemetry tracer no-op in test (TRD-2026-4212be7e / JOT-T001).
# Default tracer is :otel_tracer_default which records every span and
# ships it through the batch processor. We don't want every test run to
# generate network traffic or batch-processor log noise — opt-in tests
# (e.g. OtelSpanEmitterIntegrationTest) flip the tracer back to
# :otel_tracer_default via Application.put_env/3.
config :opentelemetry, :tracer, :otel_tracer_noop

# MCP server disabled in test env (MCPSupervisorTest asserts get_env returns config)
config :foreman_server, :mcp,
  enabled: false,
  mount: "/mcp",
  allow_workflow_writes: false,
  allow_insecure_local: false
