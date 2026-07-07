---
document_id: PRD-2026-014
version: 1.0.2
status: Draft
date: 2026-06-16
scale_depth: STANDARD
author: Lead Agent (PRD Phase via ensemble:create-prd)
total_requirements: 25
readiness_score: 4.63
readiness_gate: PASS
---

# PRD-2026-014: Elixir Backend Orchestration Migration

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 25 (REQ-001 through REQ-025) |
| **Must** | 18 |
| **Should** | 6 |
| **Could** | 1 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 25/25 (100%) |
| **Risk Flags** | 25 |
| **Cross-Requirement Dependencies** | 23 |
| **Readiness Score** | 4.63 / 5.0 |
| **Ambiguity Markers** | 0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman has evolved from a CLI-driven agent runner into a long-running orchestration system: it manages projects, tasks, runs, phases, workers, worktrees, GitHub PR gates, CodeRabbit review gates, sentinel runs, inbox messages, reset/retry flows, and multi-project daemon state. The current TypeScript backend handles these concerns through a mix of subprocesses, Postgres rows, worktree/filesystem state, logs, native task rows, merge queues, and CLI commands. This has produced increasing complexity and recurring failure classes: state drift between task rows and active runs, delayed external status visibility, flaky daemon integration tests, ambiguous recovery behavior, and manual reconciliation logic.

Foreman needs an orchestration backend whose runtime model matches the product: long-running supervised actors, durable event history, projections for read models, explicit state machines, observable transitions, and robust crash recovery.

### 1.2 Solution Overview

Migrate Foreman's backend orchestration from the current TypeScript daemon to an Elixir/OTP server using CQRS/event-oriented architecture while retaining:

1. A Node.js CLI for developer ergonomics and npm distribution.
2. A Node/Pi SDK worker for existing Pi SDK execution.
3. Postgres as the durable store, with an append-only event log and projection tables.
4. Existing Foreman workflows and user-facing behaviors during migration.
5. Adapter-based model execution so Foreman can eventually target Pi SDK, Anthropic, OpenAI, OpenRouter, OpenLLM-compatible endpoints, and other providers.

The Elixir server becomes the source of orchestration truth. Node becomes an edge/runtime layer: CLI client, Pi SDK bridge, and compatibility shim.

### 1.3 Value Proposition

- **Reduced orchestration bugs:** OTP supervision and explicit state machines replace ad hoc process/status inference.
- **Improved visibility:** every transition is an event; status/board/watch/inbox become projections.
- **Reliable recovery:** server restarts detect live workers, reattach when possible, restart when necessary.
- **Lower test flake rate:** integration tests exercise supervised processes and deterministic event transitions instead of racing subprocess readiness.
- **Simpler CLI:** Node CLI sends commands to the server and renders projections; it no longer owns orchestration logic.
- **Provider flexibility:** Pi SDK remains supported while a pluggable model execution adapter enables future direct-provider execution.

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | Pain Point |
|------|-------------|------------|
| **Solo/lead operator** | Runs Foreman locally across multiple projects | Needs reliable status, reset, recovery, and fewer false failures |
| **Developer** | Uses Foreman to execute implementation tasks | Needs simple CLI, predictable worktree behavior, and attach/log visibility |
| **Engineering lead** | Monitors many tasks/agents | Needs trustworthy board/watch/status projections and audit history |
| **Maintainer** | Extends workflows, prompts, VCS, providers, and integrations | Needs simpler backend boundaries and fewer cross-cutting TS status paths |
| **Agent worker** | Node/Pi SDK process executing model sessions | Needs clear command contract and durable event handoff |

### 2.2 Current Workflow

```text
foreman task create / Jira / sentinel / plan
→ TypeScript daemon or CLI stores task/run state
→ dispatcher creates worktree + starts Node agent-worker
→ agent-worker runs workflow phases via Pi SDK, bash, builtins
→ logs/reports/mail/state updated through mixed paths
→ status/watch/debug infer state from task rows, run rows, logs, branches, reports
→ reset/retry/merge reconcile discrepancies manually
```

### 2.3 Desired Workflow

```text
Node CLI/API/integration emits Command
→ Elixir command handler validates and appends domain events
→ RunSupervisor starts/continues RunServer actor
→ RunServer advances explicit phase state machine
→ WorkerAdapter starts Node/Pi SDK worker or direct-provider worker
→ worker streams events back to Elixir
→ projections update task/run/phase/board/watch/inbox views
→ recovery supervisor reconciles workers/worktrees/external systems after crash
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-1 | Replace TS orchestration state ownership with Elixir/OTP server | New runs are owned by Elixir RunServer actors |
| G-2 | Preserve existing Foreman user workflows during migration | Existing documented commands have compatibility equivalents |
| G-3 | Reduce state drift between tasks, runs, phases, workers, and PRs | Status projections match event log in 100% of consistency checks |
| G-4 | Improve recovery after server/worker crashes | Server reattaches or restarts orphan workers within 60s by default |
| G-5 | Lower integration flake rate | CI integration flakes from daemon readiness/state races reduced by 80%+ over 30 days |
| G-6 | Keep Pi SDK usable without blocking future providers | Pi SDK worker adapter ships in v1; provider adapter interface defined |
| G-7 | Simplify CLI mental model | New CLI groups commands by task/run/project/server/logs and deprecates duplicate aliases |
| G-8 | Maintain auditability | Every user-visible state transition can be traced to a command/event pair |

### 3.2 Non-Goals

- Full removal of Node in v1.
- Full removal of Pi SDK in v1.
- Rewriting the TUI in Elixir/Phoenix LiveView in v1.
- Removing Git/Jujutsu VCS support.
- Replacing Postgres.
- Reimplementing every model provider directly in v1.
- Live migration of active in-flight TS runs; active TS runs may drain before cutover instead.

---

## 4. Proposed Architecture

### 4.1 Target System

```text
┌─────────────────────────────────────────────────────────────┐
│ Node CLI                                                     │
│ - command parsing                                            │
│ - output rendering                                           │
│ - local bootstrap/update                                     │
│ - compatibility aliases                                      │
└───────────────┬─────────────────────────────────────────────┘
                │ HTTP over localhost
┌───────────────▼─────────────────────────────────────────────┐
│ Elixir Foreman Server                                        │
│ - Command handlers                                           │
│ - Event store                                                │
│ - Project/Task/Run/Phase supervisors                         │
│ - CQRS projections                                           │
│ - Recovery/reconciliation                                    │
│ - Workflow interpreter                                       │
│ - VCS/PR/merge orchestration                                 │
│ - Inbox/PubSub                                               │
└───────────────┬─────────────────────────────────────────────┘
                │ worker protocol over HTTP over localhost
┌───────────────▼─────────────────────────────────────────────┐
│ Node Worker Layer                                            │
│ - Pi SDK worker adapter                                      │
│ - direct provider adapters over time                         │
│ - tool execution bridge                                      │
│ - worktree-local process control                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 CQRS/Event Model

- **Commands:** intent submitted by CLI, integrations, sentinel, scheduler, or worker callbacks.
- **Events:** append-only facts such as `TaskCreated`, `RunStarted`, `PhaseStarted`, `WorkerHeartbeat`, `ToolCallFinished`, `PhaseFailed`, `PrChecksPending`, `RunRecovered`.
- **Projections:** queryable read models for CLI/status/watch/board/debug/inbox.
- **Actors:** one supervised process per active project/run/worker where useful.
- **External reality:** worktrees, git branches, PR status, and OS processes are not projections; they are external systems. The Elixir server owns reconciliation by comparing durable events/projections with observed external reality and emitting reconciliation events.

### 4.3 Migration Principle

The migration shall be incremental. The first production slice must prove value without requiring every Foreman feature to be rewritten at once.

Recommended first slice:

```text
Elixir server owns project/task/run/phase state + event log
Node CLI talks to Elixir
Node/Pi worker still executes phases
Existing TS orchestrator remains behind compatibility mode until feature parity
```

---

## 5. Feature Areas

1. Elixir server runtime and supervision tree
2. Event store and projections
3. Node CLI client and streamlined command surface
4. Node/Pi SDK worker bridge
5. Workflow execution and phase state machines
6. Recovery/reconciliation engine
7. VCS/worktree/PR/merge orchestration
8. Existing integrations parity: sentinel, Jira/GitHub, inbox, board/watch/status, plan/PRD/TRD, reset/retry/attach/logs
9. Migration/coexistence tooling
10. Comparative architecture spike: Elixir/OTP vs WolverineFx/Marten vs control alternatives
11. Observability and testing

---

## 6. Functional Requirements

### REQ-001: Elixir Server Runtime

**Priority:** Must  
**Complexity:** High  
**Type:** Functional
**Risk:** [RISK: foundational runtime replacement]

Foreman shall provide an Elixir/OTP server that owns orchestration state for projects, tasks, runs, phases, workers, queues, inbox, and recovery.

- AC-001-1: Given the server is started, when it initializes, then it loads configured projects from durable storage and starts supervision trees for active projects.
- AC-001-2: Given the server receives a command from the Node CLI, when validation succeeds, then it records the command outcome as durable events.
- AC-001-3: Given the server crashes and restarts, when it boots, then it rebuilds in-memory actors from durable events/projections.

### REQ-002: Durable Event Store

**Priority:** Must  
**Complexity:** High  
**Type:** Functional
**Risk:** [RISK: data migration and event schema design]

Foreman shall use an append-only event store as the durable source of orchestration truth.

- AC-002-1: Given any task/run/phase transition, when the transition occurs, then a domain event is appended before projections are updated.
- AC-002-2: Given an event is appended, when projections are rebuilt from scratch, then task/run status matches current production projection state.
- AC-002-3: Given an event schema changes, when migrations run, then old events remain readable through versioned decoders.

### REQ-003: CQRS Projections

**Priority:** Must  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: projection schema drift or rebuild inconsistency]

Foreman shall expose read models through projections optimized for CLI, board, watch, status, debug, inbox, and reporting.

- AC-003-1: Given a task is created or updated, when its events are projected, then `foreman task show/list` renders from the task projection.
- AC-003-2: Given a run emits phase/worker events, when `foreman status` is called, then the run projection displays active, in-progress, failed, blocked, and completed counts without log inference.
- AC-003-3: Given projection corruption or drift is detected, when a rebuild is requested, then projections can be dropped and rebuilt from events.

### REQ-004: Streamlined Node CLI

**Priority:** Must  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: CLI/server bootstrap and compatibility behavior confusion]

Foreman shall retain a Node CLI that delegates orchestration commands to the Elixir server and streamlines overlapping commands.

- AC-004-1: Given the server is running, when a user runs `foreman task create`, `foreman run`, `foreman status`, or `foreman logs`, then the CLI calls the server API rather than mutating DB state directly.
- AC-004-2: Given legacy aliases such as `--task`, `dashboard`, or deprecated command names are used, when compatibility mode is enabled, then the CLI warns and maps to the new command.
- AC-004-3: Given the server is not running, when a command requires it, then the CLI auto-starts the local server by default or prints a clear `foreman server start` instruction if auto-start fails or is disabled.

### REQ-005: Simplified CLI Command Surface

**Priority:** Should  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: command consolidation may disrupt existing operator muscle memory]

Foreman should consolidate commands into a smaller, clearer surface.

Proposed groups:

```text
foreman server start|stop|status|doctor
foreman project add|list|show|remove|sync
foreman task create|list|show|approve|update|close|note|deps
foreman run start|list|show|retry|reset|attach|logs
foreman board
foreman watch
foreman inbox list|send|watch
foreman workflow list|show|install|validate
foreman plan prd|trd|from-prd
foreman vcs worktree|merge|pr
foreman sentinel start|stop|status
foreman integration jira|github
```

- AC-005-1: Given a user runs a legacy command, when an equivalent new command exists, then the CLI prints the new spelling.
- AC-005-2: Given documentation is generated, when CLI reference is built, then deprecated aliases are clearly marked.
- AC-005-3: Given a new user follows `foreman --help`, when they scan commands, then lifecycle verbs are grouped by domain.

### REQ-006: Node/Pi SDK Worker Bridge

**Priority:** Must  
**Complexity:** High  
**Type:** Functional
**Risk:** [RISK: worker protocol, streaming, tool-call compatibility]

Foreman shall preserve Pi SDK execution through a Node worker bridge controlled by the Elixir server.

- AC-006-1: Given Elixir starts a phase requiring model execution, when the selected adapter is `pi_sdk`, then it starts or reuses a Node worker that calls `createAgentSession()`.
- AC-006-2: Given the worker receives tool calls, when tools complete, then structured tool events stream back to Elixir.
- AC-006-3: Given the worker exits unexpectedly, when Elixir observes missing heartbeat or process exit, then the run is marked recoverable and recovery policy starts.
- AC-006-4: Given current workflow prompts/tools are used, when executed through the bridge, then existing artifacts and reports are produced with equivalent semantics.

### REQ-007: Provider Adapter Interface

**Priority:** Should  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: provider abstraction may outpace v1 Pi SDK focus]

Foreman should define a provider-agnostic execution adapter so future workers can use Anthropic, OpenAI, OpenRouter, OpenLLM-compatible servers, or other providers without changing orchestration.

- AC-007-1: Given a workflow specifies a model/provider, when execution starts, then provider selection is resolved through an adapter registry.
- AC-007-2: Given Pi SDK is unavailable in v1, when execution is requested without a production-ready adapter, then Foreman fails before execution with a clear message that Pi SDK is the only required production adapter for v1.
- AC-007-3: Given a provider lacks Pi-specific tool semantics, when a workflow uses unsupported tools, then Foreman fails before execution with actionable validation.

### REQ-008: Workflow Execution State Machines

**Priority:** Must  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: state machine modeling errors could block valid workflow transitions]

Foreman shall model every run and phase as explicit state machines owned by Elixir actors.

- AC-008-1: Given a workflow is loaded, when a run starts, then the run state machine records phase order and current phase.
- AC-008-2: Given a phase passes, fails, retries, or times out, when the event is recorded, then next transition is deterministic and testable.
- AC-008-3: Given a retry loop such as QA ⇄ developer or PR-review ⇄ developer, when retry limits are reached, then failure state includes retry history.

### REQ-009: Existing Workflow Parity

**Priority:** Must  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: workflow parity gaps could break existing automation]

Foreman shall support existing workflow types and phase patterns: default, quick, smoke, task, feature, bug, chore, docs, question, and epic.

- AC-009-1: Given an existing YAML workflow, when migrated or loaded, then phase order, model selection, retry rules, artifacts, mail hooks, and builtins are preserved.
- AC-009-2: Given an epic workflow, when PRD/TRD/implementation phases run, then planning artifacts remain accessible under docs/reports or configured report paths.
- AC-009-3: Given a bash or builtin phase exists, when executed by Elixir, then command output and exit status are converted to phase events.

### REQ-010: Task and Project Management Parity

**Priority:** Must  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: task/project parity gaps could create migration regressions]

Foreman shall preserve native task/project management capabilities.

- AC-010-1: Given a project is registered, when listed or shown, then the projection includes path, status, default branch, config, and health.
- AC-010-2: Given a task is created, approved, blocked, closed, or annotated, when the command succeeds, then event and projection state update atomically.
- AC-010-3: Given dependencies exist, when dispatchable tasks are queried, then blocked ready tasks are excluded until blockers close.

### REQ-011: Run Dispatch and Scheduling

**Priority:** Must  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: scheduler capacity bugs could over-dispatch or starve runs]

Foreman shall dispatch runs through supervised Elixir scheduling instead of ad hoc daemon loops.

- AC-011-1: Given ready tasks exist and capacity is available, when scheduler ticks, then eligible tasks are claimed and run actors are started.
- AC-011-2: Given capacity is exhausted, when more tasks are ready, then tasks remain ready and a projection records skipped/capacity reason.
- AC-011-3: Given project-level concurrency limits exist, when dispatching, then limits are enforced across CLI, daemon, and integrations.

### REQ-012: Recovery and Reconciliation

**Priority:** Must  
**Complexity:** High  
**Type:** Functional
**Risk:** [RISK: external reality cannot be fully event-sourced]

Foreman shall discover, reattach to, or restart workers after server crash, worker crash, host restart, or state drift.

- AC-012-1: Given Elixir restarts while a Node/Pi worker is still running, when heartbeat/session metadata is recoverable, then Elixir reattaches and emits `WorkerReattached`.
- AC-012-2: Given the worker cannot be reattached, when restart policy allows, then Elixir restarts the phase from the last safe checkpoint and emits `WorkerRestarted`.
- AC-012-3: Given projections disagree with external state such as OS processes, worktrees, git branches, or GitHub PRs, when reconciliation runs, then observed differences are recorded as events and resolved by policy.

### REQ-013: VCS and Worktree Management

**Priority:** Must  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: VCS/worktree edge cases can corrupt or strand workspace state]

Foreman shall preserve Git and Jujutsu VCS backend behavior, worktree isolation, cleanup, rebase, branch creation, and merge support.

- AC-013-1: Given a run starts, when worktree creation succeeds, then the worktree path and branch/revision are recorded as events.
- AC-013-2: Given a stale worktree exists, when a new run starts, then Foreman follows configured reuse/clean/rebase policy.
- AC-013-3: Given Git or Jujutsu backend is selected, when VCS operations execute, then backend-specific details remain behind a VCS adapter.

### REQ-014: PR Gates and Merge Orchestration

**Priority:** Must  
**Complexity:** High  
**Type:** Functional
**Risk:** [RISK: external GitHub eventual consistency]

Foreman shall preserve create-pr, pr-wait, prepare-pr-review, pr-review, and merge gates, including late-check stability behavior.

- AC-014-1: Given a PR is created, when GitHub checks and review data are delayed, then readiness projections include pending/seen/stable states rather than false-ready.
- AC-014-2: Given a PR reaches stable ready state, when merge phase starts, then merge gate revalidates readiness before merging.
- AC-014-3: Given merge fails, when `foreman run show` or debug is used, then failure reason is visible from events and reports.

### REQ-015: Inbox and Agent Mail

**Priority:** Must  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: message delivery semantics may diverge during event-backed migration]

Foreman shall preserve agent mail/inbox behavior as event-backed messages.

- AC-015-1: Given a phase starts/completes/fails, when mail hooks are configured, then messages are appended as events and projected to inbox.
- AC-015-2: Given an operator sends a message to an active run, when the worker supports receiving it, then delivery status is tracked.
- AC-015-3: Given `foreman inbox --watch` is used, when new messages arrive, then updates stream without polling full history.

### REQ-016: Sentinel and External Monitors

**Priority:** Must  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: external integration idempotency failures could duplicate work]

Foreman shall preserve sentinel, Jira monitor, GitHub integration, and other external triggers through server-side command ingestion.

- AC-016-1: Given sentinel detects repeated test failure, when threshold is reached, then a bug task is created/updated through Elixir commands.
- AC-016-2: Given Jira/GitHub integrations detect external transitions, when configured, then tasks are created with external links and dedupe keys.
- AC-016-3: Given integration input is duplicated, when processed, then idempotency prevents duplicate tasks/runs.

### REQ-017: Logs, Reports, and Debug

**Priority:** Must  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: log/artifact references may drift from event timelines]

Foreman shall preserve logs/reports/debug workflows while reducing reliance on raw log inference.

- AC-017-1: Given a worker emits stdout/stderr/tool/assistant events, when stored, then `foreman logs` can render compact or raw views.
- AC-017-2: Given phase artifacts are written, when debug is invoked, then debug references both event timeline and artifact files.
- AC-017-3: Given logs are purged, when events remain, then historical status/debug summaries are still possible.

### REQ-018: Attach and Interactive Recovery

**Priority:** Should  
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: attach support depends on provider/session capabilities]

Foreman should support attaching to active or recently completed worker sessions where the worker adapter supports it.

- AC-018-1: Given a Pi SDK worker exposes an attach/session identifier, when `foreman run attach` is called, then the CLI opens an interactive or streaming attach mode.
- AC-018-2: Given attach is unsupported for a provider, when requested, then Foreman prints the reason and alternative logs/control commands.
- AC-018-3: Given a human interrupts a phase, when resume is requested, then the run records the interruption and next action.

### REQ-019: Plan/PRD/TRD Support

**Priority:** Should  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: planning compatibility gaps could break PRD/TRD workflows]

Foreman should preserve planning flows while simplifying their command surface.

- AC-019-1: Given a user requests PRD/TRD planning, when `foreman plan prd|trd` runs, then planning phases execute through the same worker adapter/event pipeline.
- AC-019-2: Given planning artifacts are created, when tasks are generated, then traceability links are stored as events/projections.
- AC-019-3: Given existing `/ensemble:create-prd` or `/skill:ensemble-create-prd` flows are used, when compatibility mode is enabled, then they remain available.

### REQ-020: Migration and Coexistence

**Priority:** Must  
**Complexity:** High  
**Type:** Functional
**Risk:** [RISK: dual-write and compatibility complexity]

Foreman shall support incremental migration from TS daemon to Elixir server.

- AC-020-1: Given an existing Foreman project, when migration runs, then projects, tasks, runs, workflows, inbox messages, and config are imported or mapped.
- AC-020-2: Given TS-era runs exist, when viewed after migration, then their historical records remain readable.
- AC-020-3: Given migration has not completed, when compatibility mode is enabled, then `run`, `status`, `watch`, `reset`, `retry`, `stop`, `merge`, `pr`, `attach`, `inbox`, `task`, `plan`, `sling`, and `doctor` can delegate to legacy TS code.

### REQ-021: Testing and Deterministic Simulation

**Priority:** Must  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: deterministic simulations may miss real subprocess edge cases]

Foreman shall provide deterministic tests for orchestration without requiring full external subprocess races.

- AC-021-1: Given a run state machine, when tested, then phase transitions can be simulated in-memory with event assertions.
- AC-021-2: Given worker failures are simulated, when recovery tests run, then expected recovery events are emitted deterministically.
- AC-021-3: Given CLI integration tests run, when server readiness is required, then tests use supervised test server APIs instead of arbitrary subprocess sleeps.

### REQ-022: Observability and Operations

**Priority:** Should  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: metrics and timelines may add overhead or expose partial truth]

Foreman should expose operational metrics, health checks, and event timeline views.

- AC-022-1: Given `foreman server doctor` runs, when the server is healthy, then it validates DB, projections, workers, VCS, provider adapters, and integrations.
- AC-022-2: Given metrics are enabled, when runs progress, then counters/timers are emitted for phase duration, retries, failures, recoveries, worker restarts, and projection lag.
- AC-022-3: Given a status anomaly occurs, when debug is invoked, then event timeline identifies the first inconsistent transition.

### REQ-023: Security and Isolation

**Priority:** Should  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: remote access increases authentication and secret-handling requirements]

Foreman should maintain or improve process isolation, secret handling, and command authorization.

- AC-023-1: Given worker processes start, when environment is prepared, then secrets are scoped to the project/run and forbidden variables are stripped.
- AC-023-2: Given server API is exposed beyond local socket, when authentication is configured, then commands require an auth token or equivalent.
- AC-023-3: Given destructive commands are requested, when executed, then authorization and audit events are recorded.

### REQ-024: Documentation and Operator Education

**Priority:** Could  
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: incomplete operator docs could make migration unsafe]

Foreman should update documentation to explain the new architecture, migration path, command changes, and recovery model.

- AC-024-1: Given the migration ships, when users read the docs, then README, User Guide, CLI Reference, and architecture docs describe Elixir server + Node CLI + Node worker responsibilities.
- AC-024-2: Given commands are renamed or deprecated, when users run old commands, then docs and CLI warnings point to replacements.
- AC-024-3: Given operators need to troubleshoot, when they read docs, then event/projection/recovery concepts are explained with examples.

### REQ-025: Comparative Architecture Spike

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional
**Risk:** [RISK: committing to Elixir before validating WolverineFx/Marten tradeoffs]

Foreman shall run a bounded comparative architecture spike before TRD commitment, comparing Elixir/OTP against WolverineFx/Marten and at least one control alternative for Foreman's orchestration workload.

- AC-025-1: Given the spike starts, when prototypes are built, then Elixir/OTP and WolverineFx/Marten each implement the same minimal lifecycle: create task → approve task → dispatch simulated worker → stream status → complete run → rebuild read model.
- AC-025-2: Given a simulated worker crashes mid-phase, when recovery runs, then each prototype demonstrates its attach/restart strategy and records the operator-visible recovery timeline.
- AC-025-3: Given the prototypes are evaluated, when the spike report is written, then it compares runtime supervision, durable messaging/CQRS, event/projection rebuild, local developer setup, Node CLI integration, Node/Pi worker boundary, observability, testing complexity, and migration risk.
- AC-025-4: Given WolverineFx's durable inbox/outbox, saga persistence, scheduled message handling, dead-letter support, and Marten/Postgres event-store fit are evaluated, when the recommendation is made, then the report explicitly explains whether those benefits outweigh OTP supervision for Foreman's local long-running worker/process model.

---

## 7. Non-Functional Requirements

### Performance

- Server projection reads for `status`, `task list`, and `run show` should return in <250ms for 100 active/recent tasks on a local machine.
- Event append path should support at least 100 events/sec locally for bursty worker logs/tool events.
- Worker event streaming should not block phase execution if non-critical projections lag.

### Reliability

- Server restart must recover or classify all active runs.
- Projection rebuild must be idempotent.
- Worker heartbeats must detect orphaned/stuck workers.
- Recovery policies must be explicit, not inferred from stale timestamps alone.

### Security

- Server transport should default to authenticated HTTP, binding to localhost for local use and allowing explicitly configured remote connections.
- Secrets must be redacted from events/logs/projections.
- Destructive commands must produce audit events.

### Observability

- Every state transition must be traceable from command → event → projection.
- Operator-facing debug should prefer event timeline over raw log scraping.
- Projection lag and worker heartbeat age must be visible.

### Maintainability

- Elixir domain modules should isolate task/run/phase state from adapters.
- Node worker protocol must be versioned and contract-tested.
- Legacy TS compatibility must have an explicit sunset plan.

---

## 8. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|-----|-------------|----------|------------|----------|
| REQ-001 | Elixir Server Runtime | Must | High | 3 |
| REQ-002 | Durable Event Store | Must | High | 3 |
| REQ-003 | CQRS Projections | Must | High | 3 |
| REQ-004 | Streamlined Node CLI | Must | Medium | 3 |
| REQ-005 | Simplified CLI Command Surface | Should | Medium | 3 |
| REQ-006 | Node/Pi SDK Worker Bridge | Must | High | 4 |
| REQ-007 | Provider Adapter Interface | Should | High | 3 |
| REQ-008 | Workflow Execution State Machines | Must | High | 3 |
| REQ-009 | Existing Workflow Parity | Must | High | 3 |
| REQ-010 | Task and Project Management Parity | Must | Medium | 3 |
| REQ-011 | Run Dispatch and Scheduling | Must | High | 3 |
| REQ-012 | Recovery and Reconciliation | Must | High | 3 |
| REQ-013 | VCS and Worktree Management | Must | High | 3 |
| REQ-014 | PR Gates and Merge Orchestration | Must | High | 3 |
| REQ-015 | Inbox and Agent Mail | Must | Medium | 3 |
| REQ-016 | Sentinel and External Monitors | Must | Medium | 3 |
| REQ-017 | Logs, Reports, and Debug | Must | Medium | 3 |
| REQ-018 | Attach and Interactive Recovery | Should | High | 3 |
| REQ-019 | Plan/PRD/TRD Support | Should | Medium | 3 |
| REQ-020 | Migration and Coexistence | Must | High | 3 |
| REQ-021 | Testing and Deterministic Simulation | Must | Medium | 3 |
| REQ-022 | Observability and Operations | Should | Medium | 3 |
| REQ-023 | Security and Isolation | Should | Medium | 3 |
| REQ-024 | Documentation and Operator Education | Could | Medium | 3 |
| REQ-025 | Comparative Architecture Spike | Must | Medium | 4 |

---

## 9. Dependency Map

| Requirement | Depends On | Notes |
|-------------|------------|-------|
| REQ-001 | — | Foundation server runtime |
| REQ-002 | REQ-001 | Event store requires server runtime |
| REQ-003 | REQ-002 | Projections derive from events |
| REQ-004 | REQ-001, REQ-003 | CLI needs server API and projections |
| REQ-005 | REQ-004 | Command simplification builds on new CLI client |
| REQ-006 | REQ-001, REQ-002 | Worker bridge emits events to server |
| REQ-007 | REQ-006 | Provider abstraction generalizes worker bridge |
| REQ-008 | REQ-001, REQ-002 | State machines write event transitions |
| REQ-009 | REQ-008 | Workflow parity requires state machines |
| REQ-010 | REQ-002, REQ-003 | Task/project operations require commands/events/projections |
| REQ-011 | REQ-008, REQ-010 | Dispatch needs task readiness and run state |
| REQ-012 | REQ-002, REQ-006, REQ-008 | Recovery needs events, workers, state machines |
| REQ-013 | REQ-008, REQ-012 | VCS/worktree state participates in recovery |
| REQ-014 | REQ-013 | PR/merge depends on VCS/worktree state |
| REQ-015 | REQ-002, REQ-003 | Inbox is event-backed projection |
| REQ-016 | REQ-010, REQ-011 | Integrations create tasks/runs |
| REQ-017 | REQ-002, REQ-006 | Logs/reports are worker and event output |
| REQ-018 | REQ-006, REQ-012 | Attach depends on worker protocol and recovery metadata |
| REQ-019 | REQ-006, REQ-009 | Planning phases use worker/workflow execution |
| REQ-020 | REQ-002, REQ-003, REQ-010 | Migration maps old data to new model |
| REQ-021 | REQ-008, REQ-012 | Deterministic tests target state/recovery logic |
| REQ-022 | REQ-002, REQ-003 | Observability derives from events/projections |
| REQ-023 | REQ-001, REQ-006 | Security crosses server and worker boundary |
| REQ-024 | All | Docs describe complete migrated model |
| REQ-025 | — | Must complete before TRD commitment and before selecting final backend stack |

Implementation clusters:

1. **Architecture decision:** REQ-025
2. **Foundation:** REQ-001, REQ-002, REQ-003, REQ-021
3. **CLI + task parity:** REQ-004, REQ-005, REQ-010
4. **Worker + workflow parity:** REQ-006, REQ-008, REQ-009
5. **Recovery + external systems:** REQ-012, REQ-013, REQ-014
6. **Integrations + observability:** REQ-015, REQ-016, REQ-017, REQ-022
7. **Migration + docs:** REQ-020, REQ-024

No circular dependencies identified.

---

## 10. Migration Strategy

### Phase 0: Comparative Architecture Spike

Before committing to the Elixir backend TRD, run a bounded spike comparing the preferred Elixir/OTP approach against WolverineFx/Marten and one control alternative such as Temporal or a disciplined TypeScript CQRS refactor.

#### Spike Candidates

| Candidate | What It Tests | Why It Matters |
|-----------|---------------|----------------|
| **Elixir/OTP + Oban + Postgres event store** | supervised RunServer/PhaseServer/WorkerBridge actors, event append, projection rebuild, Phoenix PubSub-style status streaming | Best runtime fit for Foreman's long-running local workers, process supervision, attach/restart, and live visibility |
| **WolverineFx + Marten/Postgres** | command/message handlers, durable inbox/outbox, saga persistence, scheduled messages, dead-letter handling, Marten event streams/projections | Strongest off-the-shelf durable CQRS/messaging option; may reduce custom event-store/outbox work |
| **Control alternative** | Temporal, NATS/BullMQ, or TS CQRS refactor using the same scenario | Prevents false binary choice and validates whether migration cost is justified |

#### Shared Spike Scenario

Each candidate must implement the same minimal scenario:

1. Create and approve a task through a Node CLI shim.
2. Dispatch a run with one simulated prompt phase.
3. Stream run/phase/worker status to a watch/status client.
4. Emit durable events or messages for task/run/phase/worker transitions.
5. Rebuild the read model/projection from durable history.
6. Simulate worker crash mid-phase.
7. Demonstrate recovery: reattach if possible, otherwise restart from a safe checkpoint.
8. Produce an operator timeline explaining what happened.

#### Spike Decision Criteria

| Criterion | Weight | Notes |
|-----------|--------|-------|
| Runtime supervision and crash isolation | High | Foreman's hardest problem is many local long-running workers/processes |
| Durable command/event processing | High | WolverineFx/Marten may be stronger here than custom Elixir event-store code |
| Worker attach/restart semantics | High | Must model real Node/Pi SDK worker behavior, not just in-memory messages |
| Node CLI integration | Medium | CLI must stay Node and thin |
| Node/Pi SDK worker bridge | High | Existing Pi SDK behavior must remain available |
| Projection rebuild and status latency | Medium | Must support watch/status/board/debug without log inference |
| Local developer setup | Medium | Extra runtime/tooling must not make Foreman hard to install or debug |
| Test determinism | High | Spike must reduce daemon/readiness flake class |
| Migration risk | High | Must preserve existing tasks/runs/workflows during coexistence |

#### Expected Output

The spike must produce `docs/TRD/backend-architecture-spike.md` or equivalent with:

- recommendation: Elixir, WolverineFx, or other;
- prototype links/commits;
- pass/fail matrix for the shared scenario;
- explicit explanation of whether WolverineFx's durable inbox/outbox, saga persistence, scheduled messaging, dead-lettering, and Marten/Postgres projections outweigh OTP's supervision model for Foreman;
- final TRD direction and rejected alternatives.

Default hypothesis: **Elixir/OTP remains preferred** because Foreman's core risk is supervised long-running local worker orchestration. WolverineFx remains a serious contender if the spike shows durable CQRS/message semantics dominate and process supervision can be handled cleanly without excessive custom code.

### Phase 1: Hybrid Runtime

- Elixir owns project/task/run events for new test-mode runs.
- Node worker bridge executes deterministic smoke workflow.
- Existing TS daemon remains available.
- Add migration command that imports current projects/tasks/runs as snapshot/import events.

### Phase 2: Workflow Parity

- Move workflow interpretation and phase state machines to Elixir.
- Execute current YAML workflows via worker bridge.
- Preserve reports/artifacts.
- Add event-backed watch/status/debug.

### Phase 3: PR/Merge/Recovery Parity

- Implement worktree/VCS adapters.
- Implement PR gates and merge readiness state.
- Implement crash recovery and worker reattach/restart.
- Add sentinel/Jira/GitHub command ingestion.

### Phase 4: CLI Simplification + Legacy Sunset

- Ship new command grouping.
- Keep compatibility aliases with warnings.
- Document legacy TS daemon sunset criteria.
- Remove or freeze legacy direct-DB command paths.

---

## 11. Existing Use Case Coverage

| Existing Use Case | Target Handling |
|-------------------|-----------------|
| `foreman init` | Node CLI bootstraps config; server registers project |
| `foreman project list/show` | Server projection |
| `foreman task create/list/show/approve/update/close/note/dep` | Command handlers + projections |
| `foreman run` | Scheduler command starts runs; server owns capacity |
| `foreman status/watch/board` | Projection reads + PubSub streaming |
| `foreman debug` | Event timeline + artifact summary |
| `foreman logs` | Event-backed logs + worker stdout/stderr references |
| `foreman attach` | Worker adapter attach support |
| `foreman reset/retry/stop` | Recovery commands + state machine transitions |
| `foreman merge/pr` | Server-owned PR/merge gate state |
| `foreman worktree` | VCS/worktree adapter operations |
| `foreman sentinel` | Integration/scheduler emits task/run commands |
| Jira/GitHub monitors | Server command ingestion with idempotency |
| Inbox/mail | Event-backed message projection |
| Workflow YAML/prompts | Existing workflows loaded/migrated; validation in server |
| PRD/TRD planning | Worker-backed planning phases |
| Tasks legacy compatibility | Import/compat layer only; not primary backend |
| Doctor/purge | Server health/projection/log maintenance |

---

## 12. Adversarial Review

### Issue 1: Rewriting too much at once could stall Foreman development

**Resolution:** Require an architecture spike and hybrid runtime first. Do not attempt full feature parity before proving event/projection + worker bridge value.

### Issue 2: Event sourcing can increase complexity if overused

**Resolution:** Use event store for orchestration domain facts, not for high-volume raw token streams. Store large logs/artifacts separately and reference them from events.

### Issue 3: External state can still drift

**Resolution:** Treat worktrees, OS processes, GitHub PRs, and provider sessions as external systems. Reconciliation observes them and emits events; projections are not assumed to make drift impossible.

### Issue 4: Node/Pi bridge can become a second daemon with hidden state

**Resolution:** Keep worker protocol narrow and server-owned. Node worker is disposable execution runtime; Elixir owns lifecycle state.

### Issue 5: CLI simplification may disrupt muscle memory

**Resolution:** Keep compatibility aliases with deprecation warnings and docs. Remove only after usage telemetry or explicit release milestone.

### Issue 6: Provider abstraction may dilute v1 focus

**Resolution:** Ship Pi SDK adapter first. Define provider interface, but mark direct Anthropic/OpenAI/OpenRouter/OpenLLM adapters as Should/Could unless needed to unblock Pi SDK risk.

### Issue 7: Migration may corrupt or obscure historical run data

**Resolution:** Import historical data as snapshot/import events and keep raw legacy tables/logs readable until sunset. Do not rewrite historical artifacts destructively.

### Issue 8: Elixir may be selected too early because it matches the preferred mental model

**Resolution:** Add REQ-025 and make the first phase a comparative architecture spike. WolverineFx/Marten must be tested against the same Foreman-specific lifecycle and recovery scenario before the TRD locks the backend stack.

---

## 13. Implementation Readiness Gate

| Dimension | Score | Notes |
|-----------|-------|-------|
| Completeness | 4.75 | Covers server, CLI, workers, workflows, recovery, VCS, PR gates, integrations, docs, comparative architecture spike, and migration/coexistence decisions |
| Testability | 4.75 | Every requirement has ACs; clarified transport, scale, and coexistence choices support concrete TRD test fixtures |
| Clarity | 4.75 | Architecture direction clear; transport, protocol, migration, scale, and v1 provider decisions resolved |
| Feasibility | 4.25 | Incremental hybrid path reduces risk; full parity remains high effort |
| **Overall** | **4.63** | **PASS** |

Gate decision: PASS. This PRD is ready for TRD creation after the comparative architecture spike.

Ambiguity scan complete: 0 items marked for clarification.

---

## 14. Resolved Decisions

1. Active TypeScript runs may drain before cutover; live migration is not required.
2. The Node CLI should auto-start the Elixir server by default for normal local commands, with a manual `foreman server start` instruction when auto-start fails or is disabled.
3. Node CLI ↔ Elixir server transport is HTTP over localhost by default.
4. Elixir server ↔ Node/Pi SDK worker protocol is HTTP over localhost.
5. No non-Pi production adapter is required in v1; define the adapter interface and keep Pi SDK as the only required production adapter.
6. The server may allow remote connections in v1 when explicitly configured and authenticated.
7. Projection performance target is 100 active/recent tasks returning in <250ms locally.
8. The control alternative for the comparative spike remains open and should be selected during spike planning.

---

## 15. Suggested Next Steps

1. Run the comparative backend architecture spike before backend TRD commitment.
2. Run `/ensemble:create-trd docs/PRD/PRD-2026-014-elixir-backend-orchestration.md` after the spike recommendation.
3. If Elixir remains selected, begin with: Elixir event store + one run state machine + Node CLI status projection + simulated worker.
4. If WolverineFx wins, write the TRD around WolverineFx/Marten command handlers, durable inbox/outbox, sagas, Node CLI bridge, and Node/Pi worker boundary.

---

## 16. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2026-06-16 | 1.0.0 | Lead Agent (PRD Phase) | Initial draft via ensemble:create-prd workflow |
| 2026-06-16 | 1.0.1 | Lead Agent | Added comparative architecture spike for Elixir/OTP vs WolverineFx/Marten before TRD commitment |
| 2026-06-16 | 1.0.2 | Pi Agent | Resolved clarification markers, converted metadata to YAML frontmatter, updated health/readiness scores, added requirement type metadata and risk indicators |
