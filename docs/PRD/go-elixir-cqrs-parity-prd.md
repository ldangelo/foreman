# PRD: Go/Elixir CQRS Slice Functional Parity

## Document Status
- Status: Draft
- Date: 2026-07-27
- Scope: `slices/go-elixir-cqrs` in `packages/foreman_server`
- Primary codebase: Elixir `ForemanServer` backend intended to serve a Go CLI

## 1. Executive Summary

Foreman already has a greenfield Elixir event-sourced backend slice with durable event storage, supervised aggregate actors, synchronous projection updates, and core aggregates for projects, tasks, runs, workers, and phases. What it does not yet have is enough surrounding product behavior to replace or safely migrate the current `main` workflow.

This PRD defines the product requirements to turn the slice from an architecture spike into a functionally credible Foreman backend for real operator use. The required outcome is not “more infrastructure”; it is end-to-end workflow parity for the core operator journey:

1. register a project
2. create and schedule work
3. run a workflow through prompts/phases/workers
4. observe results through query APIs and projections
5. create and monitor PRs
6. recover safely after interruption
7. ingest external triggers and migration data when needed

The product must preserve the architectural commitments already encoded in the slice:
- EventStore remains the source of truth.
- `CommandRouter` remains the sole append point.
- Phoenix is the only HTTP ingress.
- Aggregate actors remain supervised, serialized, and rehydrated from streams.

## 2. Background and Evidence

The current slice already proves part of the target design:
- `ForemanServer.Application` starts EventStore, ProjectionStore, Aggregator, and CommandRouter, confirming a minimal event-sourced runtime exists (`packages/foreman_server/lib/foreman_server/application.ex`).
- `ForemanServer.CommandRouter` delegates commands to per-aggregate actors and is the sole production append path (`packages/foreman_server/lib/foreman_server/command_router.ex`).
- `ForemanServer.Aggregate.Actor` enforces append-then-apply ordering, rehydration, and optimistic concurrency behavior (`packages/foreman_server/lib/foreman_server/aggregate/actor.ex`).
- `ForemanServer.ProjectionStore` only projects projects today, leaving task/run/worker/phase queries absent (`packages/foreman_server/lib/foreman_server/projection_store.ex`).

Repository analysis also shows major parity gaps versus `main`:
- no Phoenix endpoint or HTTP router for Go CLI ingress
- no read-model parity for tasks, runs, workers, or phases
- no worker runtime (`Overwatch`), PR monitor, runtime safety, or runtime info
- no workflow/prompt runtime
- no routed planning flow, migration import, inbox, or integration ingestion
- no recovery engine or scheduler runtime
- only 2 test files vs ~30 on `main`

Sources:
- `docs/architecture/spike-slice-spec.md`
- `docs/architecture/functional-gap-analysis.md`
- `docs/architecture/missing-components.md`

## 3. Problem Statement

The slice currently validates a backend architecture, not the Foreman product experience. A Go CLI cannot use this backend end-to-end because the system lacks HTTP ingress, sufficient query surfaces, workflow execution, PR lifecycle monitoring, recovery behavior, and external ingestion paths. Without those capabilities, the slice cannot replace `main`, support migration, or serve operators reliably.

## 4. Product Vision

Deliver a production-credible Foreman backend where a Go CLI can act strictly as a command/query client while the Elixir service owns event-sourced state, workflow orchestration, recovery, and operational visibility.

## 5. Target Users

### Primary Users
- Foreman operators running task and run workflows
- Engineers migrating Foreman from the current system to the Go/Elixir architecture
- Developers integrating the Go CLI with the Elixir backend

### Secondary Users
- Platform engineers supporting runtime health, recovery, and operational diagnostics
- Teams importing historical data or triggering runs from external systems

## 6. Product Goals

### Goal 1 — Closed-loop operator workflow
A user can drive Project → Task → Run → completion → PR outcome entirely through supported command/query surfaces.

### Goal 2 — Architectural integrity under real usage
The slice keeps its core invariants while adding product behavior: single append path, aggregate serialization, restart recovery, and event-log truth.

### Goal 3 — Migration credibility
The system supports the `main` behaviors that existing installations depend on, or explicitly replaces them with equivalent supported flows.

### Goal 4 — Operational safety
Crashes, restarts, stale prompts/workflows, duplicate commands, and external triggers are handled predictably and observably.

## 7. Non-Goals

This PRD does not require:
- replacing EventStore with another persistence model
- moving command mutation out of Phoenix
- redesigning Foreman workflows beyond parity-driven needs
- adding new end-user product areas unrelated to parity
- introducing speculative abstractions for future providers before current parity exists
- building a new UI beyond the command/query surfaces needed by the Go CLI and operators

## 8. User Stories

### Core execution
- As an operator, I can register a project, create a task, start a run, and see the run and task status update through query APIs.
- As an operator, I can inspect current phase, worker, completion status, and PR status for a run.
- As an operator, I can trust that duplicate or out-of-order worker completion does not corrupt state.

### Workflow and prompts
- As an operator, I can run a workflow whose phases resolve the correct prompt content for the selected workflow and phase.
- As an operator, I get a fast failure if installed prompts/workflows are stale.
- As an auditor, I can replay exactly what prompt content was rendered for a phase.

### PR and VCS lifecycle
- As an operator, I can associate a PR with a run and observe whether it is open, merged, closed, or conflicted.
- As a team, we can continue the PR → run → merge workflow expected from `main`.

### Recovery and runtime safety
- As an operator, interrupted runs resume or surface a clear recovery state after server restart.
- As a platform engineer, I can identify blocked runs, missing worker activity, and restart outcomes.

### External ingestion and migration
- As an integrator, I can trigger runs through an inbox/external command path.
- As a migration engineer, I can import historical data through event-backed migration flows.

## 9. Functional Requirements

### FR1 — HTTP command ingress
The backend MUST expose Phoenix HTTP endpoints for command submission and read-model queries.

Requirements:
1. `POST /api/commands` routes all mutations to `CommandRouter.dispatch/1`.
2. Read endpoints exist for, at minimum: project, task, run, worker, and phase status.
3. HTTP responses normalize command success/error semantics for Go CLI consumption.
4. No HTTP path bypasses aggregate actors or the single append path.

Success measure:
- A Go CLI command/query client can complete the closed-loop happy path only through HTTP.

### FR2 — Read model parity for operational entities
The projection layer MUST project and query the entities operators actually inspect.

Requirements:
1. Project, task, run, worker, and phase projections exist.
2. Projection rebuild from the event log reproduces the same read state as live append-time projection updates.
3. Queries exist for single-entity lookup and list/status views needed by CLI workflows.
4. PR state and current phase are queryable from the run view.

Success measure:
- Operators do not need to inspect raw events for ordinary task/run monitoring.

### FR3 — Workflow and prompt runtime
The backend MUST execute workflow definitions and resolve prompts with replay-safe rendered content.

Requirements:
1. Workflow YAML is loaded and interpreted for phase sequencing.
2. Prompt resolution uses `(workflow, phase)` selection semantics compatible with current Foreman behavior.
3. Template rendering substitutes runtime variables before execution.
4. Rendered prompt content, or a content-addressed immutable artifact, is persisted for replay.
5. Dispatch fails fast when runtime prompts/workflows are stale.
6. `foreman init --force`-style refresh behavior is supported for installed runtime assets.

Success measure:
- A workflow run can be replayed and audited without re-resolving mutable prompt files.

### FR4 — Worker runtime and lifecycle management
The product MUST own worker lifecycle, not just worker events.

Requirements:
1. A runtime component equivalent to `Overwatch` launches, tracks, and exits workers.
2. Worker heartbeat or equivalent liveness state is surfaced for operators.
3. Worker launch, exit, and failure states update projections.
4. Worker-related command flow remains command-driven, not direct event writes.

Success measure:
- A run can advance through real worker activity, not just synthetic aggregate tests.

### FR5 — PR lifecycle monitoring
The backend MUST support Foreman’s PR-centric workflow after run completion.

Requirements:
1. A run can store a PR URL or equivalent PR identity.
2. The system monitors PR state transitions: open, merged, closed, conflict/error.
3. PR state changes emit events that update the run projection.
4. The monitoring design may live in Go, Elixir, or a separate process, but the evented contract must be stable.

Success measure:
- Operators can tell whether a completed run’s PR is awaiting review, merged, or closed without manual GitHub inspection.

### FR6 — Planning flow support
The backend MUST support planning commands already modeled by the domain.

Requirements:
1. `plan.prd` and `plan.trd` command types route successfully.
2. `PlanningFlow` commands append `PlanningFlowStarted`, command/trace, and completion events.
3. Planning traces can be associated with runs.
4. Planning flow behavior is test-covered through command routing, not aggregate-only unit coverage.

Success measure:
- Existing planning workflows are preserved or cleanly migrated.

### FR7 — Migration import and external ingestion
The backend MUST support the non-interactive ingestion paths required for continuity.

Requirements:
1. Migration import commands are routable and event-backed.
2. Inbox/external trigger commands are routable and delivery status is tracked.
3. Integration ingestion maintains dedupe/correlation semantics.
4. External ingestion paths are observable in read models or operator diagnostics.

Success measure:
- Existing automation and migration workflows do not require fallback to `main`.

### FR8 — Recovery and scheduler runtime
The system MUST remain operational after interruption and support queued work dispatch.

Requirements:
1. Recovery behavior detects interrupted runs after restart.
2. Recovery emits explicit events for resumed or resolved states.
3. Scheduler runtime is started and routable where scheduling is part of the slice contract.
4. Recovery and scheduling behaviors are test-covered under restart scenarios.

Success measure:
- A process restart does not strand active runs in silent indeterminate states.

### FR9 — Test and release confidence
Parity work MUST be proven through targeted automated coverage.

Requirements:
1. HTTP router tests cover command ingress and read-model queries.
2. Projection rebuild tests cover multi-entity replay.
3. Planning flow, migration import, inbox/integration, PR monitor, recovery, scheduler, and worker runtime each have dedicated tests.
4. Existing AC1–AC6 architectural guarantees remain green.

Success measure:
- The slice has product-level evidence, not only aggregate-level evidence.

### FR10 — Typed domain event policy enforcement
The slice MUST enforce the Article IX typed-event contract: closed event vocabulary, typed emit/apply/replay, and unknown-key rejection.

Requirements:
1. Every authoritative domain event is a typed struct in `lib/foreman_server/events/` with `@enforce_keys`, `@type t`, `@derive Jason.Encoder` before `defstruct`.
2. When emitting an event, `handle_command` returns `{:ok, typed_event}`; the Actor builds the persistence envelope using aggregate ID, current version, and derived event ID.
3. Aggregate `apply_event/2` pattern-matches typed event structs directly — no string-keyed `case Aggregate.event_type(event)` switching. (Projection adapters are out of scope; they legitimately consume `EventData`/`RecordedEvent` envelopes.)
4. `EventCodec.decode!/2` has two clause families per authoritative event type: (a) typed Erlang-term struct pass-through that rejects a struct whose module does not match the `event_type` string, and (b) JSON-deserialized map decoder that validates allowed keys and rejects unknown keys.
5. Unknown keys in deserialized maps raise — no silent drop.
6. `%EventData{}` and `%RecordedEvent{}` are used only as persistence envelopes; `apply_event` never receives them as domain types.
7. The `worker.record` forwarding channel is closed — no open `event_type` from command payload.

Evidence:
- `aggregate.ex:47-50`: `handle_command` returns `{:ok, event_spec :: map()}` — no typed struct contract
- `aggregate.ex:89-94`: `event_type/1` matches `%RecordedEvent{}` and atom/string `event_type`/`type` keys — not a closed typed vocabulary
- `run.ex:54-134`: `apply_event` uses string `case Aggregate.event_type(event)` switch with catch-all `_ -> state`
- `task.ex`, `phase.ex`, `worker.ex`, `scheduler.ex`: identical string-switch `apply_event` pattern
- No `EventCodec` module found in codebase
- `events/` directory does not exist — no typed event structs defined

Success measure:
- All aggregate `apply_event/2` clauses pattern-match typed structs; no string-based switching remains. `EventCodec` has both typed-pass-through and JSON-map clauses per authoritative event type. Architecture test enforces no direct `append_to_stream` calls.

## 10. Release Criteria

**Foundational prerequisite for all releases:** FR10 (typed event policy) must be implemented before any event-producing FR is considered complete. FR9 (test confidence) is a cross-cutting gate required for all releases.

### Release A — Closed-loop API parity
Required before any serious Go CLI integration claim:
- FR1 implemented
- FR2 implemented for project/task/run minimum
- happy-path query flow proven end-to-end
- FR9 test coverage for FR1–FR2

### Release B — Workflow execution parity
Required before workflow-driven task execution migration:
- FR3 implemented
- FR4 minimally implemented
- stale runtime protection enforced
- FR9 test coverage for FR3–FR4

### Release C — PR and recovery parity
Required before operator adoption:
- FR5 implemented
- FR8 implemented
- run interruption and PR state visibility proven
- FR9 test coverage for FR5–FR8

### Release D — Continuity parity
Required before deprecating `main`-only operational paths:
- FR6 implemented
- FR7 implemented
- migration/import/inbox flows proven
- FR9 test coverage for FR6–FR7

**Release E — Typed event policy enforcement**
Required before production deployment — typed events are a hard architectural invariant enforced across all releases:
- FR10 implemented (typed structs, EventCodec, no string-switch apply_event)
- architecture test enforces Article IX contract
- `events/` directory has one struct per authoritative event type

## 11. Acceptance Criteria

The product is acceptable when all of the following are true:
1. A Go CLI can register a project, create a task, start a run, complete a run, and fetch resulting task/run state over HTTP only.
2. Task, run, worker, and phase projections rebuild correctly from the event log.
3. Workflow execution stores replay-safe rendered prompt content.
4. Stale prompt/workflow assets block dispatch with a clear error.
5. PR state is visible on the run after completion.
6. Planning flow commands, migration import commands, and inbox/external triggers all route through the backend successfully.
7. Recovery after restart resumes or clearly resolves interrupted work.
8. The architecture rules in `docs/standards/constitution.md` remain intact.
9. All authoritative domain events are typed structs in `lib/foreman_server/events/` with `@enforce_keys`, `@type t`, `@derive Jason.Encoder` before `defstruct`.
10. Every `apply_event` clause pattern-matches typed event structs directly — no string `case Aggregate.event_type(event)` switching.
11. `EventCodec.decode!/2` has one explicit clause per authoritative event type; both typed-struct and JSON-map paths reject mismatched module/event_type.
12. Unknown keys in deserialized event maps raise a clear error — no silent drop.
13. The `worker.record` forwarding channel is closed; no open `event_type` from command payload is emitted.

## 12. Success Metrics

### Product metrics
- 100% of core operator workflow steps complete through supported command/query APIs
- 0 required fallbacks to raw event inspection for routine run/task status checks
- 0 direct event-store writes outside `CommandRouter` in production code
- 100% recovery of appended events after restart/replay in supported scenarios

### Engineering metrics
- Dedicated automated test coverage exists for each parity area listed in FR1–FR10
- Projection rebuild matches live projection state for representative multi-entity fixtures
- Routing coverage includes planning, migration, inbox, and PR update paths
- Typed event architecture test enforces no string-based `apply_event` switching


## 13. Constraints and Principles

The implementation MUST preserve these repo-defined constraints:
- `CommandRouter` is the sole append point.
- Aggregate actors serialize commands by aggregate ID.
- Aggregate state mutates only after append confirmation.
- Phoenix is the sole HTTP ingress.
- Event sourcing remains the source of truth.

The implementation SHOULD prefer boring parity over speculative redesign.

## 14. Risks and Open Questions

### Risks
1. Prompt/runtime parity may sprawl if the current Node loader and Elixir runtime remain partially duplicated.
2. PR monitoring ownership (Go vs Elixir vs helper process) can delay delivery if not decided early.
3. Projection growth may expose the limits of the current in-memory projection approach before Postgres-backed read models are restored.
4. Migration/import and inbox paths may uncover hidden coupling to `main` semantics not fully captured in current docs.

### Open Questions
1. Should PR monitoring live in Elixir, Go, or a helper process? What are the trade-offs of each approach?
2. Should Inbox/external trigger commands use a push or pull model for delivery? What are the latency/complexity trade-offs?
3. What are the specific failure modes and recovery paths for the scheduler runtime under different interruption scenarios?
4. What are the performance/scalability limits of the current in-memory projection approach?

## 15. Recommended Delivery Order

1. Typed event policy (FR10) first — defines the authoritative event vocabulary and replay contract before any event-producing work begins.
2. Establish HTTP ingress (FR1) second — unblocks all other integration work.
3. Projections for core entities (FR2) third.
4. Workflow/prompt runtime (FR3) fourth.
5. Worker runtime (FR4) fifth.
6. PR lifecycle (FR5) sixth.
7. Planning flow (FR6) seventh.
8. Migration/import and inbox (FR7) eighth.
9. Recovery and scheduler (FR8) ninth.
10. Expanded product tests (FR9) tenth.

## 16. Out of Scope Until Parity Is Proven

Do not expand into multi-provider abstractions, speculative UI work, or new end-user product areas before parity is established. Adding features before the core loop is proven will dilute focus and create maintenance surface area without solving the hard problems.

- Auto-merge after CodeRabbit PASS
- Speculative multi-provider abstractions
- Web UI beyond command/query surfaces
- New end-user product areas

## 17. Appendix: Source Highlights

- Required architecture and standards: `docs/architecture/spike-slice-spec.md`, `docs/standards/constitution.md`, `AGENTS.md`
- Required parity gaps and acceptance intent: `docs/architecture/functional-gap-analysis.md`, `docs/architecture/missing-components.md`
- Existing codebase for evidence: `packages/foreman_server/lib/foreman_server/`, `packages/foreman_server/config/config.exs`
- Node CLI for behavior reference: `src/`, `clients/cockpit/`
