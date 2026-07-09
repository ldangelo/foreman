---
name: foreman-elixir-backend
description: "Use when changing Foreman's Elixir/OTP backend under packages/foreman_server: event store, projections, scheduler, run/phase actors, worker protocol, PR/VCS reconciliation, operations, auth, or storage/test isolation."
---

# Foreman Elixir Backend

## When to Use

Use this skill for any change under `packages/foreman_server/lib/**` or `packages/foreman_server/test/**` involving events, projections, scheduler/runs/phases, workers, PR/VCS, integrations, operations, auth, or storage.

## Core Model

- Events are the durable source of truth; projections are rebuildable read models.
- Commands validate through `ForemanServer.AggregateRouter` and aggregate modules where command families exist.
- Events append through `ForemanServer.EventStore.append/1`; do not mutate `ForemanServer.ProjectionStore` directly as source of truth.
- Use `expected_stream_version` for optimistic concurrency and `metadata.idempotency_key` for duplicate protection.
- Debug state anomalies by checking event existence first, then projection lag/rebuilds.

## Scheduler and Run Ownership

- Elixir scheduler is the active scheduler after cutover; do not reintroduce Node daemon scheduling.
- Scheduler claims ready tasks, enforces capacity, appends `TaskUpdated` and `RunStarted`, and delegates to `WorkerLauncher`; scheduler claim does not synthesize `PhaseStarted`.
- Preserve run/phase actor lifecycle events and terminal-state guards.

## Worker Protocol

- `/worker/v1/phases/:phase_id/start` records `WorkerStarted` with sequence `0` and redacted environment metadata.
- `/worker/v1/heartbeat` and `/worker/v1/events` require run/phase/worker identity and monotonic sequence where applicable.
- Out-of-order worker events must fail before projection mutation.
- `WorkerEnvironment.prepare/1` strips forbidden secrets (`AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, `DATABASE_*`, `FOREMAN_SERVER_AUTH_TOKEN`, etc.) before durable append.

## PR and VCS Reconciliation

- External PR/GitHub/worktree state is observed and recorded; never silently overwrite projections.
- `PrMonitor` marks tasks `merged` only after GitHub reports merged and `run.pr.merge` succeeds; closed/open/draft observations do not mean merged.
- `PrGate.merge/1` revalidates ready state immediately before merge and records `MergeBlocked` when not ready.
- Keep Git/Jujutsu details behind `ForemanServer.VcsAdapter`.

## Storage and Tests

- Default tests use term event store and temp paths from `test_helper.exs`; do not assume Ecto SQL Sandbox/DataCase.
- `Repo` is supervised only for Postgres event-store mode; Postgres mode requires `DATABASE_URL`.
- Preserve `RuntimeSafety` guards against test port/user-storage collisions.
- Targeted verification examples: `cd packages/foreman_server && mix test test/event_store_test.exs test/projection_store_test.exs`, `mix test test/worker_protocol_test.exs test/http_router_test.exs`, and area-specific files named by the change.

## Do Not

- Do not infer authoritative run/task state from raw logs when events/projections exist.
- Do not bypass worker sequence validation.
- Do not mark a PR merged from closed/open/draft state.
- Do not use ambient user `DATABASE_URL` or persistent storage in tests unless explicitly testing Postgres mode.
