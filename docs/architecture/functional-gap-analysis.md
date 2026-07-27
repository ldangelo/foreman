# Functional Gap Analysis: `slices/go-elixir-cqrs` vs `main`

**Base:** `main` (current HEAD) vs `slices/go-elixir-cqrs` (HEAD `2ce56919`)
**Purpose:** Identify what the spike has discarded, stubbed, or never implemented vs. the
working system on `main`, so future migration work is scoped and traceable.

---

## 1. Supervision Tree

| Component | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| EventStore | ✓ | ✓ |
| ProjectionStore | ✓ (Postgres-backed, 1753 lines) | ✓ (in-memory only, 140 lines) |
| Repo (Ecto) | ✓ | ✗ |
| `Overwatch` (worker lifecycle) | ✓ | ✗ |
| `ProjectRegistry` | ✓ | ✗ |
| `Scheduler` | ✓ | ✗ (aggregate exists but unused) |
| `PrMonitor` | ✓ | ✗ |
| `RuntimeSafety` | ✓ | ✗ |
| `RuntimeInfo` | ✓ | ✗ |
| `InboxRegistry` | ✓ | ✗ |
| `RunDynamicSupervisor` | ✓ | ✗ |
| `ProjectDynamicSupervisor` | ✓ | ✗ |
| `Http.Endpoint` (Phoenix) | ✓ (conditional) | ✗ |
| Application children | 12 | 4 |

**Gap:** The slice has a minimal 4-child OTP tree. The full system starts 12 children including
Ecto Repo, two DynamicSupervisors, Overwatch, Scheduler, PrMonitor, and a Phoenix endpoint.

---

## 2. Command / Event Flow

### 2a. Command Router

| | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| Lines of code | 617 | 90 |
| Entry point | `CommandRouter.handle/1` | `CommandRouter.dispatch/2` |
| Planning flow commands | ✓ | ✗ |
| Migration import commands | ✓ | ✗ |
| Inbox / external trigger | ✓ | ✗ |
| Security check wrapper | ✓ | ✗ |
| Inbox correlation | ✓ | ✗ |
| Ingress normalization | ✓ | ✗ |
| Aggregate actor delegation | ✗ (direct aggregate calls) | ✓ (via `Actor.via/1`) |

**Gap:** The slice's `CommandRouter` is a thin actor-delegating shell. Main's router handles
7 distinct command categories with correlation, planning flows, migration ingestion, inbox,
and security checks. The slice's router dispatches only to `ForemanServer.Aggregator`.

### 2b. Event Structs (Typed vs Inline)

| | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `events/` directory | ✗ | ✓ (10 modules) |
| Literal-string event types in aggregates | ~70 distinct | all lack typed structs (except Phase static-map subset) |
| Phase static-map event types | `PhaseFailed`, `PhaseTimedOut`, `PhaseRetried`, `PhaseSkipped` | same — no structs |
| Worker open-ended forwarding | `event_type` from command payload | same — no struct possible |
| Typed structs with `@enforce_keys` | ✗ | ✗ — no event module uses it |
| Typed structs with `@type t` | ✗ | ✗ — no event module uses it |
| `@derive Jason.Encoder` | ✗ | ✓ — 9 of 10 event modules |

**Gap:** `events/` has 10 typed struct modules. Against the ~70 literal string event types
emitted by aggregates: the 10 modules cover a subset, but the count is not precisely
establishable from source alone — `Worker` accepts an arbitrary `event_type` from the
command payload (open-ended channel), `Phase` derives 4 event types via static map
(`PhaseFailed`, `PhaseTimedOut`, `PhaseRetried`, `PhaseSkipped`) that are not in
`events/`, and `ToolCall` computes `ToolCallApproved`/`ToolCallDenied` from conditionals.
No event module uses `@enforce_keys` or `@type t`. All `apply_event` implementations use
string-keyed `case Aggregate.event_type(event)` switching. `EventCodec` does not exist.
Article IX is not implemented.
### 2c. Command Router

| | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `CommandRouter` module | ✓ (617 lines) | ✓ (90 lines, rewritten) |
| `AggregateRouter` module | ✓ (337 lines) | ✗ (removed) |
| Planning flow commands | ✓ | ✗ |
| Migration import commands | ✓ | ✗ |
| Inbox / external trigger | ✓ | ✗ |
| Security check wrapper | ✓ | ✗ |
| Aggregate actor delegation | ✗ (direct aggregate calls) | ✓ (via `Actor.via/1`) |

**Gap:** The slice's `CommandRouter` is a thin 90-line actor-delegating shell vs main's 617-line
handler. `AggregateRouter` (337 lines) was removed entirely. Main's router handles 7 distinct
command categories with correlation, planning flows, migration ingestion, inbox, and security
checks; the slice dispatches only to `ForemanServer.Aggregator`.


---

## 3. Projection Store

| Query function | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `project/1` | ✓ (Postgres-backed) | ✓ (in-memory) |
| `project_list/0` | ✓ | ✗ |
| `task/1` | ✓ | ✗ |
| `task_list/0` | ✓ | ✗ |
| `status_counts/0` | ✓ | ✗ |
| `dispatchable_tasks/0` | ✓ | ✗ |
| `run/1` | ✓ | ✗ |
| `worker/1` | ✓ | ✗ |
| Postgres persistence | ✓ | ✗ |
| `rebuild/1-2` (full replay) | ✓ | ✗ |
| `snapshot/0` | ✓ | ✗ |
| `ProjectionStore.Postgres` backend | ✓ | ✗ |

**Gap:** The slice's `ProjectionStore` is a 140-line in-memory map keyed by `project_id`.
It handles only `ProjectRegistered`, `ProjectArchived`, and `ProjectReactivated` events.
Every other entity (`Task`, `Run`, `Worker`, `Phase`) has no read model on the slice.

---

## 4. Runtime / Worker System

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `Overwatch` (worker lifecycle) | ✓ | ✗ |
| `RuntimeSafety` | ✓ | ✗ |
| Worker heartbeat projection | ✓ | ✗ |
| `WorkerHeartbeat` event → projection | ✓ | ✗ |
| Worker launch / exit events | ✓ (Overwatch emits) | ✓ (structs + Worker aggregate); no runtime emitter |
| `worker_launcher_test.exs` | ✓ | ✗ |
| `worker_protocol_test.exs` | ✓ | ✗ |
| `overwatch_test.exs` | ✓ | ✗ |

**Gap:** The slice has no worker runtime. `Overwatch`, worker heartbeats, and worker
projection are absent. The `Worker` aggregate exists on the slice but is not exercised
by any test.

---

## 5. HTTP API

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| Phoenix `Http.Endpoint` | ✓ (conditional) | ✗ |
| `http_router_test.exs` | ✓ | ✗ |
| Go CLI → Phoenix HTTP ingress | Designed | ✗ (no HTTP server) |

**Gap:** No HTTP endpoint exists. The Go CLI cannot currently reach the Elixir backend.

---

## 6. Integrations

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `Inbox` | ✓ | ✗ |
| `IntegrationIngestion` | ✓ | ✗ |
| `attach_bridge_test.exs` | ✓ | ✗ |
| `integration_ingestion_test.exs` | ✓ | ✗ |
| `migration_importer_test.exs` | ✓ | ✗ |
| External trigger commands | ✓ | ✗ |

**Gap:** All external ingestion paths (attach bridge, webhook ingestion, migration import)
are absent.

---

## 7. VCS / PR / Planning

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `PrMonitor` | ✓ | ✗ |
| `vcs_adapter_test.exs` | ✓ | ✗ |
| `pr_gate_test.exs` | ✓ | ✗ |
| `pr_monitor_test.exs` | ✓ | ✗ |
| `planning_flow_test.exs` | ✓ | ✗ |
| Planning flow command routing | ✓ | ✗ |
| PR gate / monitoring | ✓ | ✗ |

**Gap:** No VCS integration, PR monitoring, or planning flow. `PlanningFlow` aggregate exists
but is not routed in the command path.

---

## 8. Recovery / Scheduler / Operations

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `recovery_engine_test.exs` | ✓ | ✗ |
| `scheduler_test.exs` | ✓ | ✗ |
| `operations_test.exs` | ✓ | ✗ |
| `debug_views_test.exs` | ✓ | ✗ |
| `ProviderRegistry` | ✓ | ✗ |
| Scheduler aggregate | ✓ | ✓ (present but unroutable / not started) |
| `Scheduler` started in app | ✓ | ✗ |

**Gap:** No recovery engine or scheduler runtime. Scheduler aggregate (`scheduler.tick/claim/skip`)
exists but is not started in the application and has no routing path.

---

## 9. Tests

| Category | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| Total test files | 30 | 2 |
| Aggregate tests | ✓ | ✓ (AC1 — actor/aggregate) |
| Command router tests | ✓ | ✗ |
| Projection store tests | ✓ | ✗ |
| Event store tests | ✓ | ✗ |
| Worker protocol tests | ✓ | ✗ |
| HTTP router tests | ✓ | ✗ |
| Integration ingestion | ✓ | ✗ |
| Migration importer | ✓ | ✗ |
| Pr monitor / gate | ✓ | ✗ |
| Planning flow | ✓ | ✗ |
| Recovery engine | ✓ | ✗ |
| Scheduler | ✓ | ✗ |
| Overwatch | ✓ | ✗ |
| Security | ✓ | ✗ |
| Runtime safety | ✓ | ✗ |
| Runtime info | ✓ | ✗ |

**Gap:** The slice has 2 test files (AC1 aggregate/actor, AC2 duplicate/out-of-order) — a
greenfield skeleton. All 28 other test suites from `main` are absent.

---

## 10. Configuration / Environment

| | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `Repo` (Ecto) | ✓ | ✗ |
| `schema: "public"` in EventStore config | ✗ | ✓ |
| `FOREMAN_RUNTIME_MODE` | Used | Not used |
| `FOREMAN_SERVER_HTTP_ENABLED` | ✓ | ✗ |
| `RuntimeInfo` adapter selection | ✓ | ✗ |
| Multiple adapter support | EventStore, VCS, etc. | Single adapter |

**Gap:** The slice has a single hardcoded adapter configuration. Main uses `RuntimeInfo`
to select between `:postgres`/`:memory` adapters and multiple VCS adapters.

---

## Summary: Gaps by Migration Effort

### Critical (no backend can function)
1. **HTTP endpoint** — Go CLI has no ingress to send commands
2. **ProjectionStore** — No read model for Task, Run, Worker, Phase; only Project exists
3. **Command categories** — Planning, migration, inbox, external trigger paths are absent

### High (operational requirements)
4. **Typed event structs** — 10 event modules exist (~14% of ~70+ enumerated emitted types); `Worker.apply_event` also recognizes cross-aggregate events (`ToolCallFinished`, `AssistantMessage`, `WorkerStdout`, `WorkerStderr`, `RunCompleted`, `RunFailed`) not emitted by Worker. `Worker.handle_command` forwards arbitrary `event_type` from the command payload — the full authoritative set cannot be enumerated statically. No `@enforce_keys` or `@type t` anywhere. `EventCodec` does not exist. Article IX not implemented.
5. **EventStore schema** — Main uses Ecto/Repo migrations; slice uses raw `schema: "public"`
6. **Worker runtime** — `Overwatch`, heartbeats, worker projection absent
7. **Tests** — 28 test files missing; no regression safety for any feature outside AC1/AC2

### Medium (future capability)
8. **PrMonitor / VCS** — PR gates and VCS integration not started
9. **Recovery / Scheduler** — Scheduler aggregate present but not started or routed; no recovery engine
10. **RuntimeSafety / RuntimeInfo** — Environment adapter selection absent
11. **Ecto Repo** — No database-backed read models or schema migrations

---

*Generated: 2026-07-27 | Branch: `slices/go-elixir-cqrs` @ `6489b3d2`*
*See [missing-components.md](./missing-components.md) for every component that must be built,
migrated, or explicitly replaced for the new architecture to be functionally equivalent to `main`.*
