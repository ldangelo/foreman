---
document_id: PRD-2026-001
version: 1.0.2
status: Draft
date: 2026-07-27
scale_depth: LIGHT
total_requirements: 10
readiness_score: 4.0
---

# PRD: Go/Elixir CQRS Slice Functional Parity

## Document Status
- Status: Draft
- Version: 1.0.2
- Date: 2026-07-27
- Document ID: PRD-2026-001
- Scope: `slices/go-elixir-cqrs` in `packages/foreman_server`
- Primary codebase: Elixir `ForemanServer` backend intended to serve a Go CLI

## PRD Health Summary

| Priority | Count |
|---|---|
| Must | 8 |
| Should | 2 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---|
| AC coverage | 10/10 (100%) |
| Risk flags | 9 |
| Dependencies | 9 |
| Open questions | 1 (PR monitor ownership) |

---

## 1. Executive Summary

Foreman already has a greenfield Elixir event-sourced backend slice with durable event storage, supervised aggregate actors, synchronous projection updates, and core aggregates for projects, tasks, runs, workers, and phases. What it does not yet have is enough surrounding product behavior to replace or safely migrate the current `main` workflow.

This PRD defines the product requirements to turn the slice from an architecture spike into a functionally credible Foreman backend for real operator use. The required outcome is not "more infrastructure"; it is end-to-end workflow parity for the core operator journey:

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

### REQ-001 — HTTP command ingress | Must | High | ⚠️ Risk: HTTP router adds external attack surface; Go CLI timeout handling
The backend MUST expose Phoenix HTTP endpoints for command submission and read-model queries.

**AC-001-1:** Given a running Elixir backend, when the Go CLI sends `POST /api/commands`, then all mutations route to `CommandRouter.dispatch/1` and a success or error response is returned.

**AC-001-2:** Given a running Elixir backend, when the Go CLI queries `GET /api/...`, then read-model data for project, task, run, worker, and phase is returned.

**AC-001-3:** Given a network partition to the backend, when a command is submitted, then a clear error is returned and no state is silently lost.

**AC-001-4:** Given any HTTP request, when it would bypass aggregate actors or the single append path, then it is rejected with an error.

### REQ-002 — Read model parity for operational entities | Must | Medium | ⚠️ Risk: Projection rebuild may diverge from live state under concurrent writes
The projection layer MUST project and query the entities operators actually inspect. **Incremental build: projections are built entity by entity (project → task → run → worker → phase) — each entity's projection can be built, tested, and deployed independently rather than requiring all five to be complete before any are queryable.**

**AC-002-1:** Given the event log contains events for project, task, run, worker, and phase, when projections are built, then all five entity types are queryable.

**AC-002-2:** Given a projection rebuild runs, when it completes, then the resulting read state matches the state produced by live append-time projection updates.

**AC-002-3:** Given an operator, when they query a run by ID, then PR state and current phase are included in the response.

### REQ-003 — Workflow and prompt runtime | Must | High | ⚠️ Risk: Node loader and Elixir runtime may diverge; stale assets hard to detect
The backend MUST execute workflow definitions and resolve prompts with replay-safe rendered content. **Boundary: Elixir owns phase sequencing and dispatch; Node owns only prompt file loading and refresh.** Stale detection is Elixir's responsibility — Node reports file hashes, Elixir decides whether to fail fast.

**AC-003-1:** Given a workflow YAML file, when a run starts, then the interpreter loads and sequences phases in order.

**AC-003-2:** Given a `(workflow, phase)` pair, when the resolver runs, then the prompt content is resolved using override-first, bundled fallback precedence: if an override prompt exists for the pair it is used; otherwise the bundled prompt for the pair is used; if neither exists the resolver fails with a clear error.

**AC-003-3:** Given template variables in a prompt, when rendering, then runtime values are substituted before execution.

**AC-003-4:** Given rendered prompt content, when a phase executes, then the rendered content or a content-addressed artifact is persisted for replay.

**AC-003-5:** Given stale prompt/workflow assets, when dispatch is attempted, then the system fails fast with a clear error.

**AC-003-6:** Given `foreman init --force`, when it runs, then installed runtime assets are refreshed.

### REQ-004 — Worker runtime and lifecycle management | Must | High | ⚠️ Risk: Worker crash loops; zombie worker cleanup
The product MUST own worker lifecycle, not just worker events.

**AC-004-1:** Given a run is active, when a worker is launched, then a runtime component tracks its lifecycle and surfaces heartbeat or liveness state.

**AC-004-2:** Given a worker exits or fails, when the runtime detects this, then the run projection is updated with the exit/failure state.

**AC-004-3:** Given a worker command, when it is processed, then the command is routed through the aggregate command path, not direct event writes.

### REQ-005 — PR lifecycle monitoring | Must | Medium | ⚠️ Risk: GitHub API rate limits; PR state sync lag
The backend MUST support Foreman's PR-centric workflow after run completion.

**AC-005-1:** Given a run completes, when the operator provides a PR URL or identity, then the PR association is stored on the run.

**AC-005-2:** Given a PR is associated with a run, when GitHub reports a state transition, then the run projection reflects open, merged, closed, or conflicted.

**AC-005-3:** Given PR state changes, when they occur, then events are emitted and the run projection is updated.

### REQ-006 — Planning flow support | Should | Low
The backend MUST support planning commands already modeled by the domain.

**AC-006-1:** Given `plan.prd` or `plan.trd` commands, when they are dispatched, then they route successfully through the backend.

**AC-006-2:** Given a planning flow is active, when commands execute, then `PlanningFlowStarted` and trace events are appended.

**AC-006-3:** Given a planning trace exists, when a run references it, then the trace is associated with the run.

### REQ-007 — Migration import and external ingestion | Should | Medium | ⚠️ Risk: Import may uncover hidden `main` coupling; dedupe semantics complexity
The backend MUST support the non-interactive ingestion paths required for continuity.

**AC-007-1:** Given migration import data, when an import command is dispatched, then it routes through the backend and events are appended.

**AC-007-2:** Given an inbox or external trigger, when it arrives via webhook-first push (with pull fallback for unsupported systems), then the trigger is routed and delivery status is tracked.

**AC-007-3:** Given duplicate ingestion events, when they arrive, then dedupe/correlation semantics prevent duplicate processing.

### REQ-008 — Recovery and scheduler runtime | Must | Medium | ⚠️ Risk: Scheduler may miss fires during outage; double-dispatch on restart
The system MUST remain operational after interruption and support queued work dispatch.

**AC-008-1:** Given an interrupted run, when the server restarts, then recovery detects the interrupted state and resumes or surfaces a clear recovery state.

**AC-008-2:** Given recovery emits events, when the run resumes, then no duplicate processing occurs.

**AC-008-3:** Given the scheduler runtime is active, when a scheduled fire is due, then the scheduler records intent and the worker confirms execution on pickup (fire-and-track).

**AC-008-4:** Given a server restart, when recovery runs, then every interrupted task generates a recovery event with an explicit outcome — detected, resumed, or resolved — observable in the event log and projected state.

### REQ-009 — Test and release confidence | Must | Medium | ⚠️ Risk: Test coverage may miss edge cases in replay paths
Parity work MUST be proven through targeted automated coverage.

**AC-009-1:** Given REQ-001 and REQ-002, when they are implemented, then dedicated HTTP router and projection rebuild tests exist.

**AC-009-2:** Given REQ-003–REQ-008, when each is implemented, then dedicated tests cover workflow, worker, PR, planning, migration, recovery, and scheduling paths.

**AC-009-3:** Given REQ-010, when implemented, then the architecture test enforcing Article IX remains green.

### REQ-010 — Typed domain event policy enforcement | Must | High | ⚠️ Risk: Migration from map→struct breaks existing events; dual-write during transition
The slice MUST enforce the Article IX typed-event contract: closed event vocabulary, typed emit/apply/replay, and unknown-key rejection. **Migration path: during the transition from map-based events to typed structs, EventCodec uses a versioned envelope with a dual-read path — both the old map format and the new typed struct are accepted on read; writes always emit the new typed format. This prevents event loss during replay of legacy events while ensuring all new events are typed.**

**AC-010-1:** Given an authoritative domain event, when it is defined, then it is a typed struct in `lib/foreman_server/events/` with `@enforce_keys`, `@type t`, `@derive Jason.Encoder` before `defstruct`.

**AC-010-2:** Given `handle_command` emits an event, when it returns, then it returns `{:ok, typed_event}`; the Actor builds the persistence envelope using aggregate ID, current version, and derived event ID.

**AC-010-3:** Given an aggregate's `apply_event/2` is called, when it receives an event, then it pattern-matches a typed event struct directly — no string-keyed `case Aggregate.event_type(event)` switching. (Projection adapters are out of scope; they legitimately consume `EventData`/`RecordedEvent` envelopes.)

**AC-010-4:** Given `EventCodec.decode!/2` is called, when it processes a typed Erlang-term struct, then it passes it through unchanged, rejecting any struct whose module does not match the `event_type` string.

**AC-010-5:** Given `EventCodec.decode!/2` is called, when it processes a JSON-deserialized map, then it validates allowed keys, raises on unknown keys, and rebuilds the typed struct.

**AC-010-6:** Given `EventData` or `RecordedEvent` is used, when it is examined, then it is only a persistence envelope — `apply_event` never receives it as a domain type.

**AC-010-7:** Given `worker.record` is dispatched, when it is processed, then no open `event_type` from command payload is emitted; the event type is determined by the aggregate.

**Evidence:**
- `events/`: 10 event modules exist (run_started, task_created, etc.) with `@derive Jason.Encoder` but no `@enforce_keys` or `@type t` — typed struct declarations are incomplete
- `aggregate.ex:47-50`: `handle_command` returns `{:ok, event_spec :: map()}` — no typed struct contract
- `aggregate.ex:89-94`: `event_type/1` matches `%RecordedEvent{}` and atom/string `event_type`/`type` keys — not a closed typed vocabulary
- `run.ex`: `apply_event` uses string `case Aggregate.event_type(event)` switch with catch-all `_ -> state` for non-matching events
- `task.ex`, `phase.ex`, `worker.ex`, `scheduler.ex`: identical string-switch `apply_event` pattern
- No `EventCodec` module found in codebase — no two-clause (typed-pass-through + JSON-map) decoder per event type
- Authoritative event vocabulary is not enumerated in a single authoritative list

## 10. Release Criteria

**Foundational prerequisite for all releases:** REQ-010 (typed event policy) must be implemented before any event-producing REQ is considered complete. REQ-009 (test confidence) is a cross-cutting gate required for all releases.

### Release A — Closed-loop API parity | Must
Required before any serious Go CLI integration claim:
- REQ-001 implemented
- REQ-002 implemented for project/task/run minimum
- happy-path query flow proven end-to-end
- REQ-009 test coverage for REQ-001–REQ-002

### Release B — Workflow execution parity | Must
Required before workflow-driven task execution migration:
- REQ-003 implemented
- REQ-004 minimally implemented
- stale runtime protection enforced
- REQ-009 test coverage for REQ-003–REQ-004

### Release C — PR and recovery parity | Must
Required before operator adoption:
- REQ-005 implemented
- REQ-008 implemented
- run interruption and PR state visibility proven
- REQ-009 test coverage for REQ-005–REQ-008

### Release D — Continuity parity | Should
Required before deprecating `main`-only operational paths:
- REQ-006 implemented
- REQ-007 implemented
- migration/import/inbox flows proven
- REQ-009 test coverage for REQ-006–REQ-007

### Release E — Typed event policy enforcement | Must
Required before production deployment — typed events are a hard architectural invariant enforced across all releases:
- REQ-010 implemented (typed structs, EventCodec, no string-switch apply_event)
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
- Dedicated automated test coverage exists for each parity area listed in REQ-001–REQ-010
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
- Projections are Postgres-backed from day one — not in-memory.

The implementation SHOULD prefer boring parity over speculative redesign.

## 14. Risks and Open Questions

### Risks
1. **REQ-001 — HTTP router adds external attack surface; Go CLI timeout handling** (High complexity)
2. **REQ-002 — Projection rebuild may diverge from live state under concurrent writes** (Medium complexity)
3. **REQ-003 — Node loader and Elixir runtime may diverge; stale assets hard to detect** (High complexity)
4. **REQ-004 — Worker crash loops; zombie worker cleanup** (High complexity)
5. **REQ-005 — GitHub API rate limits; PR state sync lag** (Medium complexity)
6. **REQ-007 — Import may uncover hidden `main` coupling; dedupe semantics** (Medium complexity)
7. **REQ-008 — Scheduler may miss fires during outage; double-dispatch on restart** (Medium complexity)
8. **REQ-009 — Test coverage may miss edge cases in replay paths** (Medium complexity)
9. **REQ-010 — Migration from map→struct breaks existing events; dual-write during transition** (High complexity)

### Open Questions
1. **PR monitoring ownership** — Keep open for implementation planning (Elixir, Go, or helper process)
2. **Inbox/external trigger delivery** — Webhook-first push, pull fallback for systems without webhook support
3. **Scheduler failure modes** — Fire-and-track: scheduler records intent, worker confirms execution on pickup
4. **Projection approach** — Postgres-backed from day one (not in-memory)

## 15. Recommended Delivery Order

1. Typed event policy (REQ-010) first — defines the authoritative event vocabulary and replay contract before any event-producing work begins.
2. Establish HTTP ingress (REQ-001) second — unblocks all other integration work.
3. Projections for core entities (REQ-002) third — Postgres-backed from start.
4. Workflow/prompt runtime (REQ-003) fourth.
5. Worker runtime (REQ-004) fifth.
6. PR lifecycle (REQ-005) sixth.
7. Planning flow (REQ-006) seventh.
8. Migration/import and inbox (REQ-007) eighth.
9. Recovery and scheduler (REQ-008) ninth.
10. Expanded product tests (REQ-009) tenth.

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

## 18. Dependency Map

| From | To | Relationship |
|---|---|---|
| REQ-002 | REQ-001 | Projections require HTTP ingress to be queryable |
| REQ-003 | REQ-002 | Workflow needs projected entities for dispatch |
| REQ-004 | REQ-003 | Worker runtime supports workflow phases |
| REQ-005 | REQ-002 | PR state updates projections |
| REQ-006 | REQ-002 | Planning traces associated with runs |
| REQ-007 | REQ-001 | Ingestion routes through HTTP ingress |
| REQ-008 | REQ-002 | Recovery reads projected run state |
| REQ-009 | REQ-001–REQ-008 | Test coverage gates all functional releases |
| REQ-010 | REQ-001–REQ-008 | Typed events are foundational for all event-producing releases |

## 19. Implementation Readiness Gate

### Scorecard

| Dimension | Score (1–5) | Evidence |
|---|---|---|
| **Completeness** — Are all feature areas covered? | 4 | All 10 REQs have ACs; delivery order, release criteria, dependency map, and open questions sections are complete |
| **Testability** — Does every Must/Should REQ have verifiable ACs? | 4 | AC-003-2 now specifies deterministic override-first/bundled-fallback precedence; AC-008-4 now specifies observable recovery events with explicit outcomes per interrupted task |
| **Clarity** — Could two developers read this and build the same thing? | 4 | GWT format throughout; risks, complexity, and MoSCoW tags present; one open question remaining |
| **Feasibility** — Are all requirements achievable within stated constraints? | 4 | REQ-010 has explicit versioned-envelope + dual-read migration path; REQ-003 has explicit Node/Elixir boundary; projections are incremental by entity |

**Overall Readiness Score: 4.0 / 5.0**

| Dimension | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Completeness | — | — | — | ✓ | — |
| Testability | — | — | — | ✓ | — |
| Clarity | — | — | — | ✓ | — |
| Feasibility | — | — | — | ✓ | — |

**Readiness trend:** v1.0.1 scored 3.5 → v1.0.2 scores **4.0** (improved). Testability and Feasibility improved from explicit mitigations, deterministic AC specificity, and observable behavior definitions.

---

## Changelog

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-07-27 | 1.0.0 | Initial PRD from functional gap analysis | Pi Agent |
| 2026-07-27 | 1.0.2 | Refined: AC-003-2 now specifies override-first/bundled-fallback precedence; AC-008-4 replaced meta "test-covered" with observable recovery events + explicit outcomes per interrupted task; REQ-003 description adds explicit Node/Elixir boundary (Elixir owns phase sequencing, Node owns prompt file loading); REQ-010 description adds versioned-envelope + dual-read migration path; REQ-002 adds incremental projection build note; Readiness Gate score improved 3.5→4.0; REQ-010 Evidence corrected (events/ exists with 10 modules, gap is missing @enforce_keys/@type t, not non-existence) | Pi Agent |
