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
| Events emitted from `handle_command` (literal `event_type: "…"`) | no typed modules | ~70 distinct types emitted; 10 have fielded modules, none use `@enforce_keys` or `@type t` |
| Events recognized on replay in `apply_event` (cross-aggregate) | same as emitted (no events/) | `Worker.apply_event` recognizes 6 cross-aggregate types not emitted by Worker: `ToolCallFinished`, `AssistantMessage`, `WorkerStdout`, `WorkerStderr`, `RunCompleted`, `RunFailed` |
| Worker forwarding channel | unknown from grep | open — `Worker.handle_command` reads `event_type` directly from command payload; any string accepted; full vocabulary unstatable |
| Phase static-map event types | emitted but untyped | `PhaseFailed`, `PhaseTimedOut`, `PhaseRetried`, `PhaseSkipped` — emitted via static map, no module |
| Typed structs with `@enforce_keys` | ✗ | ✗ — no event module uses it |
| Typed structs with `@type t` | ✗ | ✗ — no event module uses it |
| `@derive Jason.Encoder` | ✗ | ✓ — 9 of 10 event modules |
| `EventCodec` module | ✗ | ✗ — does not exist |

**Gap:** `events/` has 10 typed struct modules but none have `@enforce_keys` or `@type t`. Against the ~70 distinct event types emitted from `handle_command` across all aggregates, the 10 modules cover a subset. The Worker forwarding channel (`worker.record` → `event_type: event_type`) accepts any string — the authoritative vocabulary is open-ended and cannot be enumerated statically until the channel is closed. `Worker.apply_event` additionally recognizes 6 cross-aggregate event types on replay. `Phase` derives 4 types via static map with no module. `EventCodec` does not exist. Article IX is not implemented.
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

## 5. Workflow + Prompt Runtime

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| `WorkflowInterpreter` module | ✓ (259 lines, YAML loader) | ✗ |
| YAML workflow with `phase_order` list | ✓ | ✗ |
| Per-phase `prompt` field in YAML (inline string metadata only) | ✓ | ✗ |
| Per-phase `command` / builtin (`/…`) support | ✓ | ✗ |
| Prompt file loader (`loadPrompt(phase, vars, workflow, projectRoot)`) | ✓ (Node CLI; Elixir `WorkflowInterpreter` does not use it) | ✗ |
| Elixir `WorkflowInterpreter` integration with prompt loader | ✗ | ✗ |
| Template renderer (`renderTemplate` — `{{variable}}` substitution) | ✓ (Node CLI) | ✗ |
| Prompt resolver selects override/bundled prompt for `(workflow, phase)` | ✓ (Node CLI; not wired to Elixir) | ✗ |
| Workflow staleness detection (`checkWorkflows` in `Doctor`) | ✓ (via `foreman doctor`) | ✗ |
| Dispatch staleness gate (`foreman run` fails fast on stale) | ✗ (AGENTS.md policy only; not wired in dispatch path) | ✗ |
| `foreman init --force` refresh | ✓ (in `src/cli/commands/init.ts`) | ✗ |
| Immutable rendered prompt or content-addressed artifact stored for replay | ✗ | ✗ |
| Content/content-addressed hash captured in run/phase events | ✗ | ✗ |

**Gap:** `main` has a full prompt subsystem in the Node CLI (`prompt-loader.ts`: `loadPrompt`, `renderTemplate`,
`checkStalePrompts`, `REQUIRED_PHASES`). It resolves the end-user override or bundled prompt for a given
`(workflow, phase)` pair, validates it against required phase markers, and renders it with context inputs.
The Elixir `WorkflowInterpreter` is a separate system: it loads YAML workflows with a `prompt` field but treats
it as inline string metadata, not a file reference, and does not call the Node CLI loader. Aggregates (`Phase`)
enforce phase lifecycle and invariants; the prompt resolver handles override resolution, loading, and rendering.
A hash alone only detects drift — determinism requires the rendered prompt content (or a content-addressed
artifact) to be stored and replayed as-is. Neither branch captures rendered prompt content in events.
`foreman init --force` is verified in `main`'s `init.ts`. Staleness detection exists as `Doctor.checkWorkflows()`
but is not a dispatch gate.

## 6. HTTP API

| Feature | `main` | `slices/go-elixir-cqrs` |
|---|---|---|
| Phoenix `Http.Endpoint` | ✓ (conditional) | ✗ |
| `http_router_test.exs` | ✓ | ✗ |
| Go CLI → Phoenix HTTP ingress | Designed | ✗ (no HTTP server) |

**Gap:** No HTTP endpoint exists. The Go CLI cannot currently reach the Elixir backend.

---

## 7. Integrations

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

## 9. Recovery / Scheduler / Operations

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

## 10. Tests

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
4. **Typed event structs** — 10 event modules exist (~14% of ~70+ enumerated emitted types); `Worker.apply_event` also recognizes cross-aggregate events (`ToolCallFinished`, `AssistantMessage`, `WorkerStdout`, `WorkerStderr`, `RunCompleted`, `RunFailed`) not emitted by Worker. `Worker.handle_command` forwards arbitrary `event_type` from the command payload. No `@enforce_keys` or `@type t` anywhere. `EventCodec` does not exist. Article IX not implemented.
5. **Workflow + Prompt Runtime** — `main` has `prompt-loader.ts` (`loadPrompt`, `renderTemplate`, `checkStalePrompts`, `REQUIRED_PHASES`, `installBundledPrompts`) in the Node CLI and `WorkflowInterpreter` (259 lines, YAML) in Elixir — two separate systems. The Elixir side treats `prompt` as inline string metadata and does not call the Node CLI loader. Aggregates (`Phase`) enforce lifecycle; the prompt resolver handles override resolution, loading, and rendering. A hash alone only detects drift — determinism requires the rendered prompt or content-addressed artifact stored for replay. Neither branch captures rendered prompt content in events. `foreman init --force` verified in `init.ts`. `Doctor.checkWorkflows()` exists but is not a dispatch gate.
6. **EventStore schema** — Main uses Ecto/Repo migrations; slice uses raw `schema: "public"`
7. **Worker runtime** — `Overwatch`, heartbeats, worker projection absent
8. **Tests** — 28 test files missing; no regression safety for any feature outside AC1/AC2

### Medium (future capability)
9. **PrMonitor / VCS** — PR gates and VCS integration not started
10. **Recovery / Scheduler** — Scheduler aggregate present but not started or routed; no recovery engine
11. **RuntimeSafety / RuntimeInfo** — Environment adapter selection absent
12. **Ecto Repo** — No database-backed read models or schema migrations

---

*Generated: 2026-07-27 | Based on gap analysis @ `6489b3d2`*
*See [missing-components.md](./missing-components.md) for every component that must be built,
migrated, or explicitly replaced for the new architecture to be functionally equivalent to `main`.*
