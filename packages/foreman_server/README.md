# ForemanServer

Elixir/OTP application shell for Foreman's backend orchestration migration.

This package is internal to the Foreman repository. It establishes the first server runtime boundary for TRD-2026-014:

- OTP application supervisor: `ForemanServer.Supervisor`
- Projection process: `ForemanServer.ProjectionStore`
- dependency-free durable event log shell with Postgres-compatible event envelopes: `ForemanServer.EventStore`
- versioned event encoding/decoding: `ForemanServer.EventCodec`
- Postgres schema contract: `priv/repo/migrations/001_create_event_store.sql`
- CQRS projection pipeline and rebuild entry point: `ForemanServer.ProjectionStore` / `ForemanServer.EventStore.rebuild_projections/0`
- authenticated JSON HTTP command API: `ForemanServer.Http.Router`
- project/task command handlers and projection reads (`/api/v1/projects`, `/api/v1/tasks`, `/api/v1/tasks/dispatchable`)
- run and phase OTP actors: `ForemanServer.RunActor` / `ForemanServer.PhaseActor`
- supervised scheduler and capacity checks: `ForemanServer.Scheduler`
- Node/Pi worker HTTP protocol: `/worker/v1/phases/:phase_id/start`, `/worker/v1/events`, `/worker/v1/heartbeat`
- provider adapter registry with Pi SDK as the only v1 production adapter: `ForemanServer.ProviderRegistry`
- workflow YAML interpreter and phase executor: `ForemanServer.WorkflowInterpreter`
- deterministic orchestration simulation harness: `ForemanServer.SimulationHarness`
- worker recovery and external-state reconciliation engine: `ForemanServer.RecoveryEngine`
- event-owned Git/Jujutsu VCS and worktree adapter boundary: `ForemanServer.VcsAdapter`
- PR gate and merge orchestration state machine: `ForemanServer.PrGate`
- event-backed inbox and agent mail projection: `ForemanServer.Inbox`
- idempotent sentinel/Jira/GitHub `ExternalTriggerCommand` ingestion via the command API: `ForemanServer.IntegrationIngestion`
- event-backed logs, reports, and debug timeline views: `ForemanServer.DebugViews` via authenticated `GET /api/v1/runs/:run_id/logs[?view=raw]`, `/report`, and `/debug`; debug views redact common secrets and truncate large strings before returning compact/raw output.
- dynamic project process supervisor: `ForemanServer.ProjectDynamicSupervisor`
- configured project registry: `ForemanServer.ProjectRegistry`
- project/task command boundary: `ForemanServer.CommandRouter`

Later TRD tasks replace the dependency-free shell stores with Postgres-backed event storage, projections, HTTP APIs, and Node/Pi worker protocols.

## Development

```bash
cd packages/foreman_server
mix test
```
