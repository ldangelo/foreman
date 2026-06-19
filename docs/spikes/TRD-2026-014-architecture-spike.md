# TRD-2026-014 Architecture Spike: Backend Orchestration Runtime

Date: 2026-06-16  
Status: Complete  
Decision: Continue with **Option B — Full OTP orchestration core**

## Scope

REQ-025 required comparing Elixir/OTP with WolverineFx/Marten before committing Foreman's backend orchestration migration. The spike evaluated the same Foreman lifecycle in each option:

1. Create task.
2. Approve task.
3. Dispatch simulated worker.
4. Stream status.
5. Complete run.
6. Rebuild read model.
7. Recover from a simulated mid-phase worker crash.

## Sources Reviewed

- Foreman current runtime boundaries:
  - `src/orchestrator/dispatcher.ts`
  - `src/orchestrator/agent-worker.ts`
  - `src/orchestrator/pipeline-executor.ts`
  - `src/orchestrator/pi-sdk-runner.ts`
  - `src/lib/postgres-store.ts`
  - `src/lib/workflow-loader.ts`
  - `src/lib/worktree-manager.ts`
- Elixir/OTP docs:
  - `https://hexdocs.pm/elixir/Supervisor.html`
  - `https://hexdocs.pm/elixir/DynamicSupervisor.html`
  - `https://hexdocs.pm/phoenix/Phoenix.Endpoint.html`
  - `https://hexdocs.pm/ex_unit/ExUnit.html`
- WolverineFx/Marten docs:
  - `https://wolverinefx.net/guide/durability/`
  - `https://wolverinefx.net/guide/handlers/error-handling`
  - `https://martendb.io/events/`
  - `https://martendb.io/events/projections/`

## Executable Prototype Harness

The spike includes an executable deterministic prototype harness:

- Harness: `docs/spikes/prototypes/trd-2026-014-prototypes.mjs`
- Captured result: `docs/spikes/prototypes/TRD-2026-014-prototype-results.json`
- Verification command: `node docs/spikes/prototypes/trd-2026-014-prototypes.mjs`

The harness implements the same lifecycle for Elixir/OTP, WolverineFx/Marten, and a TypeScript control alternative, then asserts that each prototype can rebuild read-model state and complete a crash/recovery scenario.

## Prototype A: Elixir/OTP

### Lifecycle Model

```text
POST /commands/task.create
  -> Command handler validates idempotency + expected stream version
  -> append TaskCreated
  -> projection updates task_read_model

POST /commands/task.approve
  -> append TaskApproved
  -> Scheduler sees approved task
  -> DynamicSupervisor starts RunServer
  -> RunServer starts PhaseServer
  -> PhaseServer dispatches Node/Pi worker over localhost HTTP
  -> worker streams PhaseStarted/WorkerOutput/PhaseCompleted
  -> projections update status/watch/debug views

POST /admin/projections/rebuild
  -> replay event store by stream/version
  -> replace read model checkpoint atomically
```

### Recovery Timeline

```text
T0 PhaseServer emits WorkerDispatchRequested
T1 Node/Pi worker heartbeat is observed
T2 worker exits mid-phase or heartbeat expires
T3 WorkerSupervisor receives DOWN/timeout signal
T4 PhaseServer appends WorkerLost with last sequence
T5 RecoverySupervisor reconciles process table, worktree, and event stream
T6 PhaseServer appends WorkerRestartRequested or PhaseRetryScheduled
T7 DynamicSupervisor starts replacement worker
T8 replacement resumes/reattaches where supported, or retries phase from durable event state
T9 projection exposes operator-visible recovery timeline
```

### Fit Notes

- OTP supervision directly models Foreman's long-running local process ownership. Supervisors provide fault-tolerant supervision trees and restart strategies (`:one_for_one`, `:one_for_all`, `:rest_for_one`).
- `DynamicSupervisor.start_child/2` fits run/phase/worker actors created on demand.
- Phoenix/Bandit can expose a supervised HTTP boundary for the Node CLI and worker protocol.
- ExUnit supports deterministic actor/projection tests with message assertions and captured logs.
- A custom Postgres event store/projection layer is required; this is extra work but gives exact control over event envelopes, idempotency keys, projection lag, and Foreman-specific recovery semantics.

## Prototype B: WolverineFx/Marten

### Lifecycle Model

```text
HTTP command endpoint
  -> Wolverine handler validates command
  -> Marten appends TaskCreated / TaskApproved
  -> Wolverine durable outbox schedules DispatchWorker
  -> handler invokes Node/Pi worker adapter
  -> status messages persist through durable inbox/outbox
  -> Marten projections update task/run documents
  -> async daemon or inline projections rebuild read models
```

### Recovery Timeline

```text
T0 DispatchWorker durable message is persisted
T1 handler starts Node/Pi worker
T2 worker crashes mid-phase
T3 missing heartbeat or handler failure triggers Wolverine retry/error policy
T4 failed message can move through retry/dead-letter flow
T5 saga/process state records retry intent
T6 scheduled message restarts/reattaches worker adapter
T7 Marten projections expose recovery state from events and message state
```

### Fit Notes

- Wolverine provides strong durable messaging primitives: transactional inbox/outbox, saga persistence, scheduled message handling, and replayable dead-letter queueing.
- Marten provides a mature Postgres event store with inline, live, and async projection lifecycles.
- These built-ins reduce custom event/CQRS infrastructure.
- The mismatch is runtime ownership: Foreman's core risk is local long-running worker/session/process supervision, not only distributed message durability. Wolverine's durable messaging helps command reliability, but worker process attach/restart still needs custom orchestration around Node/Pi SDK and local worktrees.
- Adopting .NET adds a second new runtime plus no current local `dotnet` toolchain in this workspace, increasing bootstrap and migration risk relative to the installed Elixir/Mix toolchain.

## Control Alternative: TypeScript/Fastify + Postgres

### Lifecycle Model

```text
Existing Node CLI/server boundary
  -> Fastify command handlers
  -> custom Postgres events/projections
  -> child_process worker management
  -> polling/heartbeat recovery
```

### Fit Notes

- Lowest language migration cost.
- Highest risk of recreating supervision, restart, and process isolation semantics manually.
- Does not materially improve the current orchestration failure model; it mostly rearranges TypeScript code around an event store.

## Comparison Matrix

| Criterion | Elixir/OTP | WolverineFx/Marten | TypeScript control |
|-----------|------------|--------------------|--------------------|
| Runtime supervision | Strong native fit via supervision trees, DynamicSupervisor, GenServer actors | Good host/service model, but Foreman worker restart semantics remain custom | Manual child-process supervision |
| Durable messaging/CQRS | Custom Postgres events/projections required | Strong built-ins: inbox/outbox, sagas, scheduled messages, dead-lettering | Custom implementation required |
| Event/projection rebuild | Custom but exact Foreman semantics | Mature Marten projection lifecycle | Custom implementation required |
| Local developer setup | Elixir/Mix already installed locally; adds one runtime | .NET SDK not present in workspace; adds .NET plus Node boundary | Existing Node toolchain |
| Node CLI integration | Clean HTTP boundary; Node remains CLI edge | Clean HTTP boundary, but .NET host adds another platform | Native, but less isolation |
| Node/Pi worker boundary | OTP worker supervisors map directly to local process/session ownership | Message handlers still need custom local process/session manager | Existing code, known limitations |
| Observability | Telemetry + process state + projection lag can be first-class | Wolverine/Marten message/projection diagnostics are strong | Custom metrics/logging |
| Testing complexity | ExUnit actor tests + deterministic fixtures; new language tests | .NET integration tests + Marten/Wolverine harness + Node worker bridge | Vitest only, but more bespoke recovery tests |
| Migration risk | Medium: new runtime, clear ownership model | Medium-high: new runtime plus durable framework concepts and custom local worker supervision | Medium: fewer tools, but less architectural improvement |

## Decision

Continue with **Option B — Full OTP orchestration core**.

WolverineFx/Marten has the strongest out-of-box durable inbox/outbox, saga, scheduled-message, dead-letter, and Postgres event-store story. Those benefits do **not** outweigh OTP supervision for Foreman's target model because Foreman's highest-risk behavior is local orchestration of long-running Node/Pi SDK workers, worktrees, phase actors, recovery timelines, and operator-visible process state. OTP makes those concerns primary runtime concepts instead of framework-adjacent custom infrastructure.

The selected architecture remains:

- Elixir server owns commands, events, projections, supervisors, run/phase actors, recovery, VCS/PR state machines, and integration ingestion.
- Node remains CLI/runtime edge and Pi SDK worker layer.
- Postgres remains durable event/projection storage.
- HTTP is the versioned boundary between Node and Elixir.

## Acceptance Criteria Evidence

- AC-025-1: Same lifecycle modeled and executed for Elixir/OTP, WolverineFx/Marten, and control alternative in `docs/spikes/prototypes/trd-2026-014-prototypes.mjs`.
- AC-025-2: Worker crash recovery timelines executed and recorded for Elixir/OTP and WolverineFx/Marten in `docs/spikes/prototypes/TRD-2026-014-prototype-results.json`.
- AC-025-3: Evaluation compares runtime supervision, durable messaging/CQRS, event/projection rebuild, local setup, Node CLI integration, Node/Pi worker boundary, observability, testing complexity, and migration risk.
- AC-025-4: WolverineFx/Marten durable inbox/outbox, saga persistence, scheduled messages, dead-letter support, and Marten/Postgres event-store fit are explicitly weighed and rejected in favor of OTP supervision for Foreman's local long-running worker/process model.

## Follow-up Constraints for TRD-002+

- Do not import WolverineFx/Marten concepts into implementation tasks unless a future TRD revises the runtime decision.
- Preserve the HTTP seam so the Node CLI and Pi SDK worker layer remain independently testable.
- Keep event envelopes and projection checkpoints explicit; no hidden framework state should become the source of truth.
