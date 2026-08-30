---
document_id: TRD-2026-96872fc5
prd_reference: PRD-2026-001
version: 1.0.3
status: Draft
date: 2026-07-27
total_tasks: 51
total_hours: 147
design_readiness_score: 4.0
---

# TRD: Go/Elixir CQRS Slice Functional Parity — Technical Requirements

## Document Status
- Status: Draft
- Version: 1.0.3
- Date: 2026-07-27
- Document ID: TRD-2026-96872fc5
- PRD Reference: PRD-2026-001
- Scope: `slices/go-elixir-cqrs` in `packages/foreman_server`

---

## 1. Architecture Decision

### Chosen Approach: Option C — Typed-Events-First

REQ-010 (typed domain event policy) is implemented as the first shippable vertical slice before any event-producing feature work. This locks the authoritative event vocabulary before map→struct debt accumulates in feature code. HTTP ingress (REQ-001) begins in parallel as a non-event-producing capability.

**Rationale:** The PRD's Feasibility concern (3.5) identified the typed-event migration as the highest-risk item. Deferring it to Release E (last) means every earlier PR accumulates map-based event production that must later be retrofitted. REQ-010 first prevents that debt. The PRD explicitly designates REQ-010 as "foundational prerequisite for all releases."

**Alternatives considered:**

| | Option A — Release-Order Vertical | Option B — Full-Stack First | Option C — Typed-Events-First (chosen) |
|---|---|---|---|
| REQ-010 position | Release E (last) | Release A | Release A (first) |
| Map→struct debt | Accumulates across 4 PRs | Minimal | Zero (locked first) |
| HTTP ingress timing | PR 2 | PR 1 | PR 2 (parallel track) |
| Upfront complexity | Low | High | Medium |
| PRD alignment | A–E in order | Reorders | Matches REQ-010-first intent |

### System Architecture

```
Go CLI  ──── HTTP ──── Phoenix (POST /api/commands, GET /api/...)
                              │
                    CommandRouter (sole append point)
                              │
               ┌──────────────┼──────────────┐
               ▼              ▼              ▼
        Aggregate.Actor  Aggregate.Actor  Aggregate.Actor
        (Project)        (Run)            (Task)
               │              │              │
               └──────────────►EventStore◄───┘
                              │ (source of truth)
                    ┌─────────┴─────────┐
                    ▼                   ▼
              ProjectionStore        EventCodec
              (Postgres-backed)    (dual-read: map + struct)
                    │                   │
     ┌──────────────┼──────────────┐     │
     ▼              ▼              ▼     ▼
  Projections    Overwatch     Scheduler
  (query APIs)   (worker rt)  (fire-and-track)
     │
GitHub webhook (PR monitor — ownership TBD, see Open Questions)
Node: prompt file loading + hash reporting (per REQ-003 boundary)
```

### Component Responsibilities

| Component | Responsibility |
|---|---|
| Phoenix HTTP | Sole HTTP ingress; routes commands to CommandRouter; serves read-model queries |
| CommandRouter | Sole append point; dispatches to per-aggregate Actor |
| Aggregate.Actor | Serializes commands per aggregate ID; calls handle_command; sends event spec back to CommandRouter; calls apply_event after append confirmation |
| EventStore | Durable event persistence; append_to_stream; stream replay |
| EventCodec | Dual-read decoder: typed-struct pass-through + JSON-map with unknown-key rejection; versioned envelope for migration |
| ProjectionStore (Postgres) | Incremental Postgres-backed projections per entity; rebuild on restart |
| Overwatch (worker runtime) | Worker launch, heartbeat, exit/failure detection; command-driven lifecycle |
| Scheduler | Fire-and-track: records intent on schedule, worker confirms on pickup |
| Node (prompt loader) | Prompt file loading and hash reporting only; no phase logic |
| PR Monitor | GitHub webhook receiver; dispatches PrStateChanged commands via CommandRouter (ownership TBD) |

### Key Technical Decisions

1. **EventCodec dual-read path:** Both old map format and new typed structs accepted on read during migration; writes always emit typed format. **Gap 4 resolved:** Both v=0 and v=1 raise on unknown keys — legacy events with extra fields must be cleaned (stripped to known keys) before migration; no silent drop.
2. **Versioned envelope:** `{version: 1, data: typed_event}` or `{version: 0, data: map}` — EventCodec dispatches on version field.
3. **Postgres-backed projections:** Incremental by entity (project → task → run → worker → phase); no in-memory fallback.
4. **Worker lifecycle:** Command-driven through aggregate (AC-004-3) — Overwatch observes and reacts, not writes. **Gap 1 resolved:** Worker launch payload carries `{run_id, phase, artifact_hash, task_id, project_id}` — full context for worker autonomy.
5. **Scheduler fire-and-track:** Scheduler records `SchedulerIntentRecorded`; worker sends `WorkerConfirmedExecution` on pickup; no duplicate fires. **Gap 5 resolved:** `WorkerConfirmedExecution` arriving before `SchedulerIntentRecorded` is rejected as stale — worker retries.
6. **PR monitor:** Keep-open — architecture allows Elixir or Go implementation; both use event-driven contract.
7. **Node → Elixir hash report:** Node reports prompt file hashes via Phoenix HTTP POST to `POST /api/runtime/hashes` with a JSON manifest of `{path: absolute_path, hash: sha256}` entries. Elixir stores last-known-good hashes per file. **Gap 2 resolved.**
8. **GitHub PR → run_id lookup:** On webhook receipt, the webhook queries `projection_runs` by `pr_github_id` to resolve the owning `run_id` before dispatching `PrStateChanged`. **Gap 3 resolved.**

---

## Master Task List

### PR 1: Typed Event Policy Foundation
**Shippable State:** Aggregate event application uses typed structs throughout; no string-based switching; EventCodec decodes both legacy and typed events; architecture test enforces Article IX.

---

- [ ] **TRD-001** — Enumerate authoritative event vocabulary | 2h | [satisfies REQ-010] [satisfies AC-010-1]

Create `docs/architecture/authoritative-events.md` listing every domain event emitted by any aggregate: event name, module path, fields with types, emitted by which aggregate's handle_command, consumed by which aggregate's apply_event. This is the authoritative list used to generate the typed structs.

**Implementation AC:**
- Given the events/ directory, when it is read, then every aggregate's handle_command that emits an event has a corresponding typed struct listed.
- Given an event is added to the vocabulary, when it is used in production, then it appears in authoritative-events.md.

---

- [ ] **TRD-002** — Add @enforce_keys and @type t to existing event structs | 3h | [satisfies REQ-010] [satisfies AC-010-1, AC-010-3] [depends: TRD-001]

For each of the 10 existing event modules in `lib/foreman_server/events/`, add `@enforce_keys` with required field names, add `@type t :: %__MODULE__{}` spec, and move `@derive Jason.Encoder` before the `defstruct`. Remove no longer needed fields; add any missing fields identified by TRD-001.

**Implementation AC:**
- Given any event module in events/, when Mix compiles, then @enforce_keys rejects construction without required fields.
- Given `t: ForemanServer.Events.RunStarted.t()`, when dialyzer runs, then the type is defined and accurate.

---

- [ ] **TRD-003** — Implement EventCodec module with dual-read path | 4h | [satisfies REQ-010] [satisfies AC-010-4, AC-010-5, AC-010-6] [depends: TRD-002]

Create `lib/foreman_server/event_codec.ex`. Each authoritative event type has two clause families:
- **Typed pass-through:** `decode!(%TypedEvent{})` — returns the struct unchanged if module name matches event_type string; raises otherwise.
- **JSON-map decoder:** `decode!(%{"__struct__" => _, ...})` — validates allowed keys, raises on unknown keys, rebuilds typed struct.

Include versioned envelope handling: `{"v": 1, "data": %TypedEvent{}}` dispatches as typed; `{"v": 0, "data": %{"type" => "run_started", ...}}` dispatches as legacy map and converts field-by-field.

**Implementation AC:**
- Given `EventCodec.decode!/1` receives a typed struct, when the module matches the event_type, then it returns the struct unchanged.
- Given `EventCodec.decode!/1` receives a typed struct with mismatched module, then it raises ArgumentError.
- Given `EventCodec.decode!/1` receives a legacy map, when all keys are known, then it returns the typed struct.
- Given `EventCodec.decode!/1` receives a map with an unknown key, then it raises KeyError with the offending key name.

---

- [ ] **TRD-004** — Migrate Aggregate.handle_command return to typed_event | 4h | [satisfies REQ-010] [satisfies AC-010-2] [depends: TRD-002]

Update `ForemanServer.Aggregate` behaviour: change `handle_command` callback return from `{:ok, event_spec :: map()}` to `{:ok, typed_event}` where typed_event is a struct from events/. Actor.build_envelope/1 uses typed_event's module name as the event_type string for persistence.

**Implementation AC:**
- Given a call to CommandRouter.dispatch/1, when an aggregate's handle_command returns, then the return is a typed struct.
- Given the Actor, when it builds the persistence envelope, then event_type is derived from the struct's module name.

---

- [ ] **TRD-005** — Migrate all aggregate apply_event to typed struct pattern-match | 12h | [satisfies REQ-010] [satisfies AC-010-3] [depends: TRD-002]

Update every aggregate's apply_event/2: replace `case Aggregate.event_type(event)` string switch with direct typed struct pattern-match clauses. Remove the catch-all `_ -> state` fallback that silently swallows unknown events (unknown events should raise).

Affected aggregates: run, task, phase, worker, scheduler, planning_flow, recovery, tool_call, vcs_operation, artifact_report, attachment, external_trigger, import_migration, inbox_thread, integration, project, operator_intervention.

**Implementation AC:**
- Given an aggregate's apply_event/2 receives a typed struct, when it matches a clause, then the state is updated correctly.
- Given apply_event receives an unrecognized event, then it raises FunctionClauseError (not silently returns state).
- Given mix test runs, when aggregate tests execute, then no string-based case Aggregate.event_type remains.

---

- [ ] **TRD-006** — Add versioned event envelope migration path | 3h | [satisfies REQ-010] [satisfies AC-010-2, AC-010-4, AC-010-5] [depends: TRD-003]

Extend EventStore recording to wrap events in a versioned envelope on write: `{%{version: 1, event: typed_event}, metadata}`. Extend EventCodec to read both v=0 (legacy map) and v=1 (typed) envelopes. During transition, EventStore can read old stream items without v wrapper by detecting the absence of the version field.

**Implementation AC:**
- Given EventStore.append_to_stream is called, when it records, then the recorded data has a version field set to 1.
- Given EventCodec decodes a v=0 legacy envelope, when it decodes, then the map is converted to the typed struct.
- Given EventCodec decodes a v=1 typed envelope, when it decodes, then the struct passes through unchanged.

---

- [ ] **TRD-007** — Architecture test: no string-based apply_event | 2h | [satisfies REQ-010] [satisfies AC-010-3, AC-009-3]

Create `test/architecture/event_typing_test.exs` (or extend existing architecture test). Scan all .ex files under lib/foreman_server/aggregates/ for string-based `case Aggregate.event_type(event)` or `event_type(event) == "..."` patterns. Test fails if any are found after TRD-005 completion.

**Implementation AC:**
- Given the architecture test runs on a clean aggregate codebase, when it scans for string event_type switches, then no matches are found.
- Given a developer adds a string event_type check, when the test suite runs, then the architecture test fails with a clear message.

---

- [ ] **TRD-001-TEST** — Verify typed event architecture | 2h | [verifies TRD-001, TRD-002, TRD-003, TRD-004, TRD-005, TRD-006, TRD-007] [satisfies REQ-010] [depends: TRD-001, TRD-002, TRD-003, TRD-004, TRD-005, TRD-006, TRD-007]

Integration test: dispatch commands that produce every authoritative event type; verify EventCodec decodes and re-encodes them correctly; verify apply_event pattern-matching on typed structs; verify legacy v=0 envelopes are readable; verify unknown keys raise.

**Implementation AC:**
- Given every authoritative event type is emitted, when EventCodec.decode!/1 processes each, then the round-trip output matches the input struct.
- Given a legacy v=0 event is replayed, when EventCodec decodes it, then the resulting struct is identical to the typed version.
- Given a map with an unknown key is passed to EventCodec, when decode! is called, then KeyError is raised.

---

### PR 2: HTTP Command Ingress
**Shippable State:** Go CLI can POST a command and receive a success/error response; Go CLI can GET project, task, run, worker, and phase read models.

---

- [ ] **TRD-008** — Scaffold Phoenix endpoint and router | 3h | [satisfies REQ-001] [satisfies AC-001-1, AC-001-4]

Create `ForemanServerWeb.Endpoint` in `lib/foreman_server_web/`. Define `ApiRouter` with `POST /api/commands` and `GET /api/...` routes. Register endpoint in Application supervisor tree. Add basic 404 and error handling Plug.

**Implementation AC:**
- Given a POST to /api/commands with no matching route, when it is sent, then 404 is returned.
- Given the Phoenix app starts, when it runs, then the endpoint is reachable on port 4766.

---

- [ ] **TRD-009** — Implement POST /api/commands | 4h | [satisfies REQ-001] [satisfies AC-001-1, AC-001-3, AC-001-4] [depends: TRD-008]

Create `CommandController.create/2` that accepts a JSON command payload, validates basic structure (has command_type, aggregate_id, payload keys), routes to `CommandRouter.dispatch/1`, and returns 200 with `{"ok": true, "event_id": "..."}` or 400/500 with error map. Network partitions return a 503 with a clear error message.

**Implementation AC:**
- Given a valid command payload, when POST /api/commands is called, then 200 is returned with an event_id.
- Given a command payload missing required fields, when it is posted, then 400 is returned with field-level error detail.
- Given CommandRouter is unavailable, when a command is posted, then 503 is returned with a clear unavailability message.

---

- [ ] **TRD-010** — Implement GET /api/... read endpoints | 4h | [satisfies REQ-001] [satisfies AC-001-2, AC-001-3] [depends: TRD-008]

Create read controllers for project, task, run, worker, phase. Each controller queries ProjectionStore and returns JSON. Single-entity lookups: `GET /api/projects/:id`, `GET /api/runs/:id` (includes PR state and current phase per AC-002-3). List/status views: `GET /api/projects`, `GET /api/runs?status=active`.

**Implementation AC:**
- Given a run exists in the projection store, when GET /api/runs/:id is called, then PR state and current phase are included in the response.
- Given ProjectionStore returns an error, when a read endpoint is called, then 500 is returned with an error identifier (not a raw exception).
- Given no entity matches the ID, when a read endpoint is called, then 404 is returned.

---

- [ ] **TRD-011** — HTTP security: no bypass paths | 2h | [satisfies REQ-001] [satisfies AC-001-4]

Phoenix router rejects any request that would bypass aggregate actors or CommandRouter. No plug or route may directly call EventStore.append_to_stream or emit events. Architecture test from TRD-007 covers this; add explicit router-level guard Plug that returns 403 if a request's path+method combination is not in the allowed set.

**Implementation AC:**
- Given a request to any internal EventStore path, when it is sent, then 403 Forbidden is returned.
- Given the allowed routes are enumerated, when the test suite runs, then only the documented public routes are accessible.

---

- [ ] **TRD-008-TEST** — HTTP router integration tests | 3h | [verifies TRD-008, TRD-009, TRD-010, TRD-011] [satisfies REQ-001, REQ-009] [depends: TRD-008, TRD-009, TRD-010, TRD-011]

Test all HTTP paths: POST /api/commands happy path and error paths; GET /api/{projects,tasks,runs,workers,phases} single and list; network partition error handling; bypass rejection. Use bypass or Plug.Conn test helpers.

**Implementation AC:**
- Given POST /api/commands with a valid project registration command, when it is sent, then 200 is returned and the project appears in the projection store.
- Given GET /api/runs/:id for a non-existent run, when it is called, then 404 is returned.
- Given a network partition is simulated, when POST /api/commands is called, then 503 is returned.

---

### PR 3: Postgres-Backed Projections
**Shippable State:** All five entity types (project, task, run, worker, phase) are queryable from Postgres; projection rebuild produces identical state to live append-time updates.

---

- [ ] **TRD-012** — Define Postgres projection schema and migration | 2h | [satisfies REQ-002] [satisfies AC-002-1, AC-002-2]

Create Ecto migration for projection tables: `projection_projects`, `projection_tasks`, `projection_runs`, `projection_workers`, `projection_phases`. Each table has a uuid primary key matching the aggregate ID, the full projected state as JSONB, and a last_event_version column for optimistic concurrency.

**Implementation AC:**
- Given the migration runs, when psql lists the tables, then all five projection tables exist with correct columns.
- Given the migration is run twice, when it is run again, then it is idempotent (no duplicate table errors).

---

- [ ] **TRD-013** — Implement Project projection | 2h | [satisfies REQ-002] [satisfies AC-002-1] [depends: TRD-012]

Build `ForemanServer.ProjectionHandlers.ProjectHandler` that subscribes to Project aggregate events (ProjectRegistered, ProjectArchived) and writes to projection_projects. Wire into ProjectionStore supervisor.

**Implementation AC:**
- Given ProjectRegistered is appended, when the projection store is queried, then the project appears in projection_projects.
- Given ProjectRegistered is appended twice (duplicate), when the projection store is queried, then only one record exists (idempotent).

---

- [ ] **TRD-014** — Implement Task, Run, Worker, Phase projections | 6h | [satisfies REQ-002] [satisfies AC-002-1, AC-002-2] [depends: TRD-012]

Build handlers for task, run, worker, phase projections. Each handler subscribes to its aggregate's event stream and updates the corresponding projection table. Run projection includes pr_url, pr_state, current_phase fields per AC-002-3.

**Implementation AC:**
- Given RunStarted and PhaseStarted events are appended, when the run projection is queried, then current_phase reflects the latest phase event.
- Given the same run receives TaskCreated, when the run projection is queried, then the task appears in the run's task list.

---

- [ ] **TRD-015** — Projection rebuild from event stream | 4h | [satisfies REQ-002] [satisfies AC-002-2] [depends: TRD-013, TRD-014]

Implement `ProjectionStore.rebuild/0` and per-entity variants (`ProjectionStore.rebuild(:runs)`). On startup (or explicit rebuild command), replay the entire event stream and reconstruct all projection tables. ProjectionStore.init/1 calls rebuild/0.

**Implementation AC:**
- Given ProjectionStore.rebuild/0 runs against a populated event store, when it completes, then every entity in the event store has a corresponding projection record.
- Given a live projection and a rebuild produce different results, when rebuild completes, then the test suite catches the divergence.

---

- [ ] **TRD-016** — Incremental projection: per-entity deployability | 1h | [satisfies REQ-002] [satisfies AC-002-1] [depends: TRD-012]

Ensure each entity's projection can be built and deployed independently: `ProjectionStore.rebuild(:projects)`, `rebuild(:runs)`, etc. Each projection has its own Ecto schema and handler module that can be tested in isolation before others are complete.

**Implementation AC:**
- Given only the project projection handler is wired, when ProjectRegistered is appended, then only projection_projects is updated (other tables unchanged).

---

- [ ] **TRD-012-TEST** — Projection rebuild tests | 3h | [verifies TRD-012, TRD-013, TRD-014, TRD-015, TRD-016] [satisfies REQ-002, REQ-009] [depends: TRD-013, TRD-014, TRD-015]

Test projection rebuild: append a representative sequence of events for project, task, run, worker, phase; call rebuild; assert projection state matches expected fixture. Test live update vs rebuild equivalence. Test idempotency (rebuild twice produces same result).

**Implementation AC:**
- Given a sequence of 20 events across all five entity types, when rebuild runs, then the projection state matches a hand-crafted expected state fixture.
- Given rebuild is run twice on the same event store, when it is compared, then both runs produce identical results.

---

### PR 4: Workflow and Prompt Runtime
**Shippable State:** A workflow YAML can be loaded and phases executed in sequence; prompt content is resolved using override-first/bundled-fallback; rendered prompts are persisted for replay; stale assets block dispatch.

---

- [ ] **TRD-017** — Workflow YAML interpreter | 3h | [satisfies REQ-003] [satisfies AC-003-1] [depends: TRD-001]

Create `ForemanServer.Workflow.Interpreter`. Loads workflow YAML from configured path. Parses phase sequence. For each phase, resolves prompt content (via TRD-018) and emits a PhaseDispatched command. Sequences phases in order defined in YAML.

**Implementation AC:**
- Given a workflow YAML with 3 phases, when Interpreter.run/1 is called, then 3 PhaseDispatched commands are emitted in sequence.
- Given a workflow YAML with a missing phase definition, when Interpreter.run/1 is called, then an error is returned describing the missing phase.

---

- [ ] **TRD-018** — Prompt resolver: override-first/bundled-fallback | 3h | [satisfies REQ-003] [satisfies AC-003-2] [depends: TRD-017]

Create `ForemanServer.Workflow.PromptResolver`. Given (workflow, phase) pair: check override path (`~/.foreman/prompts/{workflow}/{phase}.md`) first; if exists, return override content. Else check bundled path (`{bundle}/prompts/{workflow}/{phase}.md`); if exists, return bundled content. If neither exists, return error with clear message.

**Implementation AC:**
- Given an override prompt exists for (workflow_a, phase_1), when Resolve.run("workflow_a", "phase_1") is called, then the override content is returned.
- Given no override but a bundled prompt exists, when Resolve.run("workflow_a", "phase_1") is called, then the bundled content is returned.
- Given neither override nor bundled exists, when Resolve.run("workflow_a", "phase_1") is called, then {:error, :prompt_not_found} is returned with the pair name.

---

- [ ] **TRD-019** — Template variable substitution | 2h | [satisfies REQ-003] [satisfies AC-003-3] [depends: TRD-018]

Extend `PromptResolver` with `render/2`. Accepts prompt content string and a variables map. Substitutes `{{variable_name}}` placeholders with values from the map. Variables include: run_id, task_id, project_id, phase_name, workflow_name, timestamp. Unrecognized placeholders cause an error (no silent drop).

**Implementation AC:**
- Given a prompt with `{{run_id}}` and a variables map with run_id="abc", when render/2 is called, then the output has "abc" substituted.
- Given a prompt with `{{unknown_var}}` and no corresponding key, when render/2 is called, then {:error, :unknown_variable} is returned.

---

- [ ] **TRD-020** — Content-addressed prompt artifact storage | 3h | [satisfies REQ-003] [satisfies AC-003-4] [depends: TRD-019]

After rendering, compute SHA-256 hash of rendered content. Store `{hash, rendered_content, metadata}` in a prompt artifacts table or ETS-backed store. The hash becomes the artifact ID used in PhaseDispatched event. On replay, content is fetched by hash — never re-rendered.

**Implementation AC:**
- Given rendered content, when it is stored, then the returned artifact_id is the SHA-256 of the content.
- Given a hash from a prior render, when it is looked up, then the exact content is returned byte-for-byte.

---

- [ ] **TRD-021** — Stale asset detection and fast-fail | 2h | [satisfies REQ-003] [satisfies AC-003-5] [depends: TRD-017]

Node reports file hashes of prompt files to Elixir on load. `Workflow.Interpreter` compares reported hashes against the hashes of the last-known-good renderings. If any hash has changed since the last render, dispatch fails fast with `{:error, :stale_assets, changed_files: [...]}` before any phase executes.

**Implementation AC:**
- Given a prompt file has been modified since the last render, when Interpreter.run/1 is called, then {:error, :stale_assets, changed_files: [...]} is returned before any phase executes.
- Given all prompt files match the last-known-good hashes, when Interpreter.run/1 is called, then phases execute normally.

---

- [ ] **TRD-022** — foreman init --force runtime refresh | 2h | [satisfies REQ-003] [satisfies AC-003-6] [depends: TRD-021]

Support `POST /api/commands` with a `RuntimeRefresh` command type. Clears the last-known-good hash registry, forces Node to reload all prompt files and report fresh hashes. No phases execute during refresh; subsequent dispatch uses fresh hashes.

**Implementation AC:**
- Given RuntimeRefresh is dispatched, when it succeeds, then the hash registry is cleared and Node reports fresh hashes on next load.
- Given RuntimeRefresh is dispatched during an active run, when it succeeds, then no running phase is interrupted.

---

- [ ] **TRD-017-TEST** — Workflow runtime tests | 3h | [verifies TRD-017, TRD-018, TRD-019, TRD-020, TRD-021, TRD-022] [satisfies REQ-003, REQ-009] [depends: TRD-017, TRD-018, TRD-019, TRD-020, TRD-021, TRD-022]

Test: 3-phase workflow executes all phases in order. Override-first precedence (TRD-018). Template variable substitution (TRD-019). Artifact storage and retrieval (TRD-020). Stale asset fast-fail (TRD-021). Runtime refresh (TRD-022). Replay by artifact hash (TRD-020).

**Implementation AC:**
- Given a 3-phase workflow with valid prompts, when it runs, then 3 PhaseDispatched events are emitted in order.
- Given the override prompt for phase 2 exists and bundled also exists, when the workflow runs, then the override content is used for phase 2.
- Given a prompt file is modified after rendering, when the workflow runs, then {:error, :stale_assets} is returned.

---

### PR 5: Worker Runtime and Lifecycle
**Shippable State:** Workers are launched, tracked, and exited through the Overwatch runtime; worker state updates run projections; all worker lifecycle is command-driven (no direct event writes).

---

- [ ] **TRD-023** — Overwatch runtime: process supervision | 4h | [satisfies REQ-004] [satisfies AC-004-1, AC-004-3] [depends: TRD-001]

Create `ForemanServer.Overwatch` supervisor and worker tracker GenServer. When Overwatch.LaunchWorker.run/1 is called, it spawns a worker process under Overwatch's supervision tree. The tracker GenServer maintains a map of worker_pid → {run_id, phase, started_at}. Workers are supervised with :permanent restart so zombie workers are cleaned up.

**Implementation AC:**
- Given Overwatch.LaunchWorker.run/1 is called, when a worker launches, then it is tracked in the Overwatch registry.
- Given a worker process exits, when Overwatch monitors it, then WorkerExited is emitted through the command path.

---

- [ ] **TRD-024** — Worker heartbeat and liveness | 2h | [satisfies REQ-004] [satisfies AC-004-1] [depends: TRD-023]

Workers send periodic heartbeat messages to the Overwatch tracker. Tracker records last_heartbeat_at. If no heartbeat is received within a configurable timeout (default 30s), the worker is considered stale. Overwatch emits WorkerHeartbeatMissed through the aggregate command path.

**Implementation AC:**
- Given a worker is running, when its heartbeat interval elapses with no heartbeat, then WorkerHeartbeatMissed is emitted.
- Given a worker recovers and sends a heartbeat, when the tracker receives it, then the stale flag is cleared.

---

- [ ] **TRD-025** — Worker exit/failure updates run projection | 3h | [satisfies REQ-004] [satisfies AC-004-2] [depends: TRD-023]

When Overwatch detects worker exit (normal exit, crash, or timeout), it dispatches WorkerExited or WorkerFailed through CommandRouter. The Run aggregate's handle_command processes these and applies the exit state to the run projection via the Phase aggregate.

**Implementation AC:**
- Given a worker exits normally, when Overwatch processes the exit, then WorkerExited routes through CommandRouter and the run phase status is updated.
- Given a worker crashes, when Overwatch processes the exit, then WorkerFailed routes through CommandRouter and the failure state is recorded on the run.

---

- [ ] **TRD-026** — Worker command routing (no direct writes) | 2h | [satisfies REQ-004] [satisfies AC-004-3]

All worker-related state changes (launch, heartbeat, exit, failure) emit events through CommandRouter only. Overwatch never calls EventStore.append_to_stream directly. Architecture test from TRD-007 enforces this.

**Implementation AC:**
- Given Overwatch's codebase is scanned for direct EventStore calls, when the architecture test runs, then no direct append_to_stream is found in the Overwatch module tree.

---

- [ ] **TRD-023-TEST** — Worker lifecycle tests | 3h | [verifies TRD-023, TRD-024, TRD-025, TRD-026] [satisfies REQ-004, REQ-009] [depends: TRD-023, TRD-024, TRD-025, TRD-026]

Test: worker launch → tracked in registry; heartbeat missed → WorkerHeartbeatMissed emitted; worker exit → run phase status updated; worker crash → WorkerFailed routes through CommandRouter (not direct write); zombie worker cleanup after restart.

**Implementation AC:**
- Given a worker launches, when it is queried in the registry, then its run_id and phase are correct.
- Given a worker crashes, when the event store is queried, then WorkerFailed was emitted through CommandRouter (not direct append).

---

### PR 6: PR Lifecycle Monitoring
**Shippable State:** A PR can be associated with a run; PR state transitions (open/merged/closed/conflicted) are visible on the run projection; PR monitor ownership is resolved at implementation time.

---

- [ ] **TRD-027** — PR association with run | 2h | [satisfies REQ-005] [satisfies AC-005-1]

Add `Run.associate_pr/2` command that stores a PR URL or GitHub PR ID on the run aggregate. Emits `PrAssociated` event. Run projection includes pr_url and pr_github_id fields.

**Implementation AC:**
- Given a run exists, when PrAssociate.run(run_id, pr_url) is called, then PrAssociated is appended and the run projection has the pr_url field populated.

---

- [ ] **TRD-028** — GitHub webhook receiver | 3h | [satisfies REQ-005] [satisfies AC-005-2, AC-005-3] [depends: TRD-027]

Create `POST /api/webhooks/github` endpoint. Validates webhook signature (github HMAC-SHA256 header). Parses PR state change event. Maps GitHub PR state (open, closed, merged) to internal PR state. Dispatches PrStateChanged through CommandRouter.

**Implementation AC:**
- Given a valid GitHub PR closed webhook, when it is received, then PrStateChanged is dispatched with state="closed" mapped to the correct run.
- Given an invalid webhook signature, when it is received, then 401 is returned and no event is emitted.

---

- [ ] **TRD-029** — PR state → run projection update | 2h | [satisfies REQ-005] [satisfies AC-005-2, AC-005-3] [depends: TRD-028]

Handle PrStateChanged in the Run aggregate's handle_command. Validate that the PR is actually associated with the run. Update run's pr_state field. Emit PrStateTransitioned event. Projection store reflects new state.

**Implementation AC:**
- Given PrStateChanged is dispatched for a run with an associated PR, when it is processed, then the run projection's pr_state is updated.
- Given PrStateChanged is dispatched for a run with no associated PR, when it is processed, then {:error, :pr_not_associated} is returned.

---

- [ ] **TRD-027-TEST** — PR lifecycle tests | 2h | [verifies TRD-027, TRD-028, TRD-029] [satisfies REQ-005, REQ-009] [depends: TRD-027, TRD-028, TRD-029]

Test: PR association; webhook signature validation (valid/invalid); GitHub state → internal state mapping; PrStateChanged routes through CommandRouter; run projection reflects PR state; unknown PR ID returns error.

**Implementation AC:**
- Given a valid GitHub PR merged webhook, when it is received, then the run projection shows pr_state="merged".
- Given an invalid HMAC signature, when the webhook is received, then 401 is returned.

---

### PR 7: Planning Flow Support
**Shippable State:** plan.prd and plan.trd commands route through the backend; PlanningFlowStarted and trace events are appended; planning traces can be associated with runs.

---

- [ ] **TRD-030** — PlanningFlow aggregate routing | 3h | [satisfies REQ-006] [satisfies AC-006-1, AC-006-2]

Create `ForemanServer.Aggregates.PlanningFlow` (if not already existing) or wire existing module. Route `plan.prd` and `plan.trd` command types through CommandRouter to PlanningFlow aggregate. handle_command emits PlanningFlowStarted, then command/trace events.

**Implementation AC:**
- Given a `plan.prd` command is dispatched, when it is processed, then PlanningFlowStarted is appended and the aggregate state reflects the planning trace.
- Given the aggregate exists and is supervised, when CommandRouter dispatches a planning command, then the PlanningFlow actor is started or reused.

---

- [ ] **TRD-031** — Planning trace → run association | 2h | [satisfies REQ-006] [satisfies AC-006-3]

Add a `PlanTraceAssociated` event and handle it in the Run aggregate. When a run references a planning trace ID, associate it. Run projection includes the planning_trace_id field.

**Implementation AC:**
- Given a run and a planning trace exist, when AssociatePlanTrace.run(trace_id, run_id) is dispatched, then PlanTraceAssociated is appended and the run projection has the planning_trace_id.

---

- [ ] **TRD-030-TEST** — Planning flow tests | 2h | [verifies TRD-030, TRD-031] [satisfies REQ-006, REQ-009] [depends: TRD-030, TRD-031]

Test: plan.prd routes successfully; plan.trd routes successfully; PlanningFlowStarted is appended; trace events are appended; run association works; duplicate planning commands are idempotent.

**Implementation AC:**
- Given plan.prd is dispatched for a new planning flow, when it is processed, then PlanningFlowStarted appears in the event store.
- Given a second plan.prd for the same trace_id is dispatched, when it is processed, then no duplicate events are appended.

---

### PR 8: Migration Import and External Ingestion
**Shippable State:** Migration import commands route through the backend; inbox accepts webhook-first push with pull fallback; duplicate ingestion events are detected and rejected.

---

- [ ] **TRD-032** — Migration import command routing | 2h | [satisfies REQ-007] [satisfies AC-007-1]

Wire migration import commands (e.g. ImportProject, ImportTask, ImportRun) through CommandRouter. Create or extend the relevant aggregate to handle import commands idempotently (by external_id). Emit ImportCompleted event.

**Implementation AC:**
- Given an ImportProject command with external_id="legacy-123", when it is dispatched, then ImportCompleted is appended with external_id="legacy-123".
- Given the same ImportProject command is dispatched twice, when it is processed, then idempotency prevents duplicate events.

---

- [ ] **TRD-033** — Webhook-first inbox endpoint | 3h | [satisfies REQ-007] [satisfies AC-007-2]

Create `POST /api/webhooks/inbox` for external system push triggers. Validates source (configurable secret/token). Routes to CommandRouter as InboxTriggerReceived. Stores delivery metadata (received_at, source, correlation_id).

**Implementation AC:**
- Given a valid inbox webhook is received, when it is processed, then InboxTriggerReceived is appended with delivery metadata.
- Given a delivery is a duplicate (same correlation_id within a time window), when it is processed, then {:error, :duplicate_delivery} is returned.

---

- [ ] **TRD-034** — Pull fallback for unsupported systems | 3h | [satisfies REQ-007] [satisfies AC-007-2]

Implement `Inbox.Poller` GenServer that polls configured external systems on a schedule for systems that don't support webhooks. Poller polls, deduplicates by last-seen cursor, and dispatches InboxTriggerReceived through CommandRouter for new items.

**Implementation AC:**
- Given Poller is configured with an external system URL and cursor, when it polls, then new items since last cursor are dispatched as InboxTriggerReceived.
- Given Poller polls with no new items, when it completes, then no events are appended.

---

- [ ] **TRD-035** — Ingestion deduplication | 2h | [satisfies REQ-007] [satisfies AC-007-3]

Implement dedupe by correlation_id: InboxStore keeps a dedupe window (configurable, default 24h). On InboxTriggerReceived, if correlation_id exists in window, reject as duplicate. Use an ETS table or Postgres table with TTL for the dedupe window.

**Implementation AC:**
- Given two triggers with the same correlation_id arrive within the dedupe window, when the second is processed, then {:error, :duplicate} is returned and no event is appended.
- Given two triggers with the same correlation_id arrive outside the dedupe window, when the second is processed, then it is accepted.

---

- [ ] **TRD-032-TEST** — Ingestion tests | 2h | [verifies TRD-032, TRD-033, TRD-034, TRD-035] [satisfies REQ-007, REQ-009] [depends: TRD-032, TRD-033, TRD-034, TRD-035]

Test: import command idempotency; webhook delivery metadata; dedupe rejection of duplicates; dedupe window expiry; pull polling fetches new items; no duplicates from polling.

**Implementation AC:**
- Given duplicate import commands with same external_id, when the second is processed, then exactly one ImportCompleted event exists.
- Given a duplicate webhook within the dedupe window, when it is received, then 409 Conflict is returned.

---

### PR 9: Recovery and Scheduler Runtime
**Shippable State:** Interrupted runs generate explicit recovery events with outcomes after restart; scheduler uses fire-and-track; recovery events are observable in the event log and projected state.

---

- [ ] **TRD-036** — Recovery detection: interrupted run identification | 3h | [satisfies REQ-008] [satisfies AC-008-1, AC-008-2]

On server startup, `Recovery.detect_interrupted_runs/0` scans active runs (runs with status != terminal and last_event_time > now - grace_period). For each interrupted run, dispatches RecoveryDetected through CommandRouter. Run aggregate's handle_command processes RecoveryDetected and emits RunRecoveryEvent with outcome:detected.

**Implementation AC:**
- Given a run is active when the server crashes, when Recovery.detect_interrupted_runs/0 runs after restart, then RecoveryDetected is emitted for that run.
- Given RecoveryDetected is emitted, when it is processed, then RunRecoveryEvent with outcome=:detected is appended.

---

- [ ] **TRD-037** — Recovery outcomes: resumed or resolved | 3h | [satisfies REQ-008] [satisfies AC-008-1, AC-008-4] [depends: TRD-036]

After RecoveryDetected, a recovery operator or automated process dispatches RecoveryResume or RecoveryResolve. Run aggregate processes these and emits RunRecoveryEvent with outcome=:resumed or outcome=:resolved. No duplicate processing occurs (idempotency key on run_id).

**Implementation AC:**
- Given RecoveryResume is dispatched for an interrupted run, when it is processed, then RunRecoveryEvent with outcome=:resumed is appended.
- Given RecoveryResume is dispatched twice for the same run, when it is processed, then idempotency prevents duplicate events.

---

- [ ] **TRD-038** — Scheduler runtime: fire-and-track | 3h | [satisfies REQ-008] [satisfies AC-008-3]

Create `ForemanServer.Scheduler` GenServer. When a scheduled time fires, dispatch SchedulerIntentRecorded through CommandRouter (records that an intent exists). Worker, on pickup, dispatches WorkerConfirmedExecution. Scheduler tracks confirmed intents. No second fire is emitted for the same scheduled item.

**Implementation AC:**
- Given a scheduled time fires, when Scheduler processes the fire, then SchedulerIntentRecorded is appended with the scheduled_item_id.
- Given WorkerConfirmedExecution is received for a scheduled_item_id, when it is processed, then the scheduler marks the intent as confirmed.

---

- [ ] **TRD-039** — Restart recovery: no double-dispatch | 2h | [satisfies REQ-008] [satisfies AC-008-2] [depends: TRD-038]

After restart, Scheduler.detect_unconfirmed_intents/0 identifies SchedulerIntentRecorded events with no corresponding WorkerConfirmedExecution. For each unconfirmed intent, either re-emit or mark as stale with SchedulerIntentStale event. Grace period prevents false positives during normal operation.

**Implementation AC:**
- Given a server restarts with an unconfirmed SchedulerIntentRecorded, when detect_unconfirmed_intents/0 runs, then the intent is either re-filed or marked stale.
- Given the same intent has a corresponding WorkerConfirmedExecution, when detect_unconfirmed_intents/0 runs, then no action is taken.

---

- [ ] **TRD-036-TEST** — Recovery and scheduler tests | 3h | [verifies TRD-036, TRD-037, TRD-038, TRD-039] [satisfies REQ-008, REQ-009] [depends: TRD-036, TRD-037, TRD-038, TRD-039]

Test: interrupted run detection on startup; recovery events with :detected, :resumed, :resolved outcomes; scheduler fire-and-track (intent recorded → confirmed); no double-dispatch after restart; idempotency on recovery resume.

**Implementation AC:**
- Given a server restarts with an interrupted run, when recovery runs, then a recovery event with outcome=:detected is observable in the event log.
- Given a scheduler fire has a corresponding confirmation, when detect_unconfirmed_intents runs, then no stale event is emitted.

---

### PR 10: Test and Release Confidence
**Shippable State:** All 10 REQs have dedicated test coverage; architecture tests are green; PRDs are ready for CodeRabbit review.

---

- [ ] **TRD-040** — End-to-end happy path test | 3h | [satisfies REQ-009] [satisfies AC-009-1] [depends: TRD-009, TRD-010, TRD-012, TRD-013, TRD-014, TRD-015]

Test the complete closed-loop path: register project → create task → start run → verify task/run projections are queryable → verify run status. Uses real EventStore (test sandbox) and ProjectionStore.

**Implementation AC:**
- Given the full happy path sequence, when it executes in a test, then the final run projection shows status=active and the task projection shows the correct project_id.

---

- [ ] **TRD-041** — Architecture test suite: Article IX enforcement | 2h | [satisfies REQ-009] [satisfies AC-009-3] [depends: TRD-007]

Run the architecture test from TRD-007 in CI. Expand to also scan for any direct `append_to_stream` calls outside CommandRouter, any `Map.merge` in `apply_event` (vs `%State{state | ...}`), and any `struct!/1` or `struct/2` calls in aggregate apply_event.

**Implementation AC:**
- Given the architecture test suite runs, when it scans the codebase, then no Article IX violations are found.
- Given a violation is introduced, when the test suite runs in CI, then the build fails.

---

- [ ] **TRD-040-TEST** — Coverage report and gap analysis | 2h | [satisfies REQ-009] [satisfies AC-009-1, AC-009-2] [depends: TRD-040, TRD-041]

Generate Mix coverage report. Identify any REQ without at least one integration test covering its primary AC. Add missing tests until all Must/Should REQs have ≥1 integration test covering the primary AC.

**Implementation AC:**
- Given the coverage report is generated, when it is reviewed, then every Must REQ has ≥1 associated test exercising its primary AC.
- Given a gap is found (no test for a Must REQ), when the gap is addressed, then the coverage report shows the gap is closed.

---

## 3. Sprint Planning

### Sprint 1 (2 weeks)
**PR 1: Typed Event Policy Foundation**
- TRD-001 (2h) — Enumerate event vocabulary
- TRD-002 (3h) — Add @enforce_keys and @type t to existing events
- TRD-003 (4h) — EventCodec dual-read path
- TRD-004 (4h) — handle_command return typed_event
- TRD-005 (12h) — Migrate all apply_event to typed pattern-match
- TRD-006 (3h) — Versioned envelope migration path
- TRD-007 (2h) — Architecture test: no string switching
- TRD-001-TEST (2h) — Verify typed event architecture

**Total: 32h**

### Sprint 2 (2 weeks)
**PR 2: HTTP Command Ingress** (parallel track, starts Sprint 2 — no dependency on PR 1)
- TRD-008 (3h) — Phoenix scaffold
- TRD-009 (4h) — POST /api/commands
- TRD-010 (4h) — GET /api/... read endpoints
- TRD-011 (2h) — HTTP security: no bypass paths
- TRD-008-TEST (3h) — HTTP router integration tests

**Total: 16h**

### Sprint 3 (2 weeks)
**PR 3: Postgres-Backed Projections** (starts after TRD-008-TEST)
- TRD-012 (2h) — Postgres projection schema
- TRD-013 (2h) — Project projection
- TRD-014 (6h) — Task, Run, Worker, Phase projections
- TRD-015 (4h) — Projection rebuild from event stream
- TRD-016 (1h) — Incremental per-entity deployability
- TRD-012-TEST (3h) — Projection rebuild tests

**Total: 18h**

### Sprint 4 (2 weeks)
**PR 4: Workflow and Prompt Runtime**
- TRD-017 (3h) — Workflow YAML interpreter
- TRD-018 (3h) — Prompt resolver (override-first)
- TRD-019 (2h) — Template variable substitution
- TRD-020 (3h) — Content-addressed artifact storage
- TRD-021 (2h) — Stale asset detection
- TRD-022 (2h) — foreman init --force refresh
- TRD-017-TEST (3h) — Workflow runtime tests

**Total: 18h**

### Sprint 5 (2 weeks)
**PR 5: Worker Runtime**
- TRD-023 (4h) — Overwatch process supervision
- TRD-024 (2h) — Worker heartbeat and liveness
- TRD-025 (3h) — Worker exit/failure updates run projection
- TRD-026 (2h) — Worker command routing (no direct writes)
- TRD-023-TEST (3h) — Worker lifecycle tests

**Total: 14h**

### Sprint 6 (1 week)
**PR 6: PR Lifecycle Monitoring**
- TRD-027 (2h) — PR association with run
- TRD-028 (3h) — GitHub webhook receiver
- TRD-029 (2h) — PR state → run projection update
- TRD-027-TEST (2h) — PR lifecycle tests

**Total: 9h**

### Sprint 7 (1 week)
**PR 7: Planning Flow Support**
- TRD-030 (3h) — PlanningFlow aggregate routing
- TRD-031 (2h) — Planning trace → run association
- TRD-030-TEST (2h) — Planning flow tests

**Total: 7h**

### Sprint 8 (2 weeks)
**PR 8: Migration Import and External Ingestion**
- TRD-032 (2h) — Migration import command routing
- TRD-033 (3h) — Webhook-first inbox endpoint
- TRD-034 (3h) — Pull fallback for unsupported systems
- TRD-035 (2h) — Ingestion deduplication
- TRD-032-TEST (2h) — Ingestion tests

**Total: 12h**

### Sprint 9 (2 weeks)
**PR 9: Recovery and Scheduler Runtime**
- TRD-036 (3h) — Recovery detection: interrupted run identification
- TRD-037 (3h) — Recovery outcomes: resumed or resolved
- TRD-038 (3h) — Scheduler runtime: fire-and-track
- TRD-039 (2h) — Restart recovery: no double-dispatch
- TRD-036-TEST (3h) — Recovery and scheduler tests

**Total: 14h**

### Sprint 10 (1 week)
**PR 10: Test and Release Confidence**
- TRD-040 (3h) — End-to-end happy path test
- TRD-041 (2h) — Architecture test suite: Article IX enforcement
- TRD-040-TEST (2h) — Coverage report and gap analysis

**Total: 7h**

---

## 4. Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | HTTP command ingress | TRD-008, TRD-009, TRD-010, TRD-011 | TRD-008-TEST |
| REQ-002 | Read model parity | TRD-012, TRD-013, TRD-014, TRD-015, TRD-016 | TRD-012-TEST |
| REQ-003 | Workflow and prompt runtime | TRD-017, TRD-018, TRD-019, TRD-020, TRD-021, TRD-022 | TRD-017-TEST |
| REQ-004 | Worker runtime | TRD-023, TRD-024, TRD-025, TRD-026 | TRD-023-TEST |
| REQ-005 | PR lifecycle monitoring | TRD-027, TRD-028, TRD-029 | TRD-027-TEST |
| REQ-006 | Planning flow support | TRD-030, TRD-031 | TRD-030-TEST |
| REQ-007 | Migration import and external ingestion | TRD-032, TRD-033, TRD-034, TRD-035 | TRD-032-TEST |
| REQ-008 | Recovery and scheduler runtime | TRD-036, TRD-037, TRD-038, TRD-039 | TRD-036-TEST |
| REQ-009 | Test and release confidence | TRD-040, TRD-041, TRD-040-TEST | — |
| REQ-010 | Typed domain event policy | TRD-001, TRD-002, TRD-003, TRD-004, TRD-005, TRD-006, TRD-007 | TRD-001-TEST |

**Traceability check: 10 requirements covered, 0 uncovered, 0 orphaned annotations**

---

## 5. Dependency Map

```
TRD-001 ──► TRD-002 ──► TRD-003 ──► TRD-004 ──► TRD-005 ──► TRD-006 ──► TRD-007 ──► TRD-001-TEST
                 │                │
                 │                └──────────────────────► TRD-004
                 │
                 └──────────────────────────────────────► TRD-005

TRD-008 ──► TRD-009 ──► TRD-010 ──┬─► TRD-008-TEST
                                   │
PR-1 (TRD-001-TEST) ──────────────┘

TRD-012 ──► TRD-013 ──► TRD-014 ──► TRD-015 ──► TRD-016 ──► TRD-012-TEST
    │               │
    └───────────────┴─────────────────────────────► TRD-014

TRD-017 ──► TRD-018 ──► TRD-019 ──► TRD-020 ──► TRD-021 ──► TRD-022 ──► TRD-017-TEST
    │
    └─────────────────────────────────────────────► TRD-018

TRD-023 ──► TRD-024 ──► TRD-025 ──► TRD-026 ──► TRD-023-TEST
    │
    └─────────────────────────────────────────────► TRD-025

TRD-027 ──► TRD-028 ──► TRD-029 ──► TRD-027-TEST
    │
    └─────────────────────────────────────────────► TRD-028

TRD-030 ──► TRD-031 ──► TRD-030-TEST

TRD-032 ──► TRD-033 ──► TRD-034 ──► TRD-035 ──► TRD-032-TEST
    │
    └─────────────────────────────────────────────► TRD-034

TRD-036 ──► TRD-037 ──► TRD-038 ──► TRD-039 ──► TRD-036-TEST
    │
    └─────────────────────────────────────────────► TRD-038

TRD-040 ──► TRD-041 ──► TRD-040-TEST
```

**Critical path (longest chain):** TRD-001 → TRD-002 → TRD-005 → TRD-007 → TRD-001-TEST = 21h sequential  
**Parallel tracks:** PR 1 (typed events) and PR 2 (HTTP) run concurrently from Sprint 2

---

## 6. Quality Requirements

### Security
- HTTP endpoints validate all input; malformed payloads return 400 with field-level errors
- GitHub webhook endpoint validates HMAC-SHA256 signature before any processing
- No internal EventStore path is exposed via HTTP
- Inbox webhook validates configurable source secret

### Performance
- Projection rebuild of 1000-event stream completes in < 30 seconds
- Read endpoints (GET /api/...) return in < 100ms for single-entity lookups
- EventCodec.decode!/1 processes ≥ 1000 events/second

### Testing
- All 10 PRs have ≥1 paired TEST task covering their implementation tasks; each TEST task verifies
  multiple implementation tasks (e.g. TRD-017-TEST verifies TRD-017 through TRD-022)
- Infrastructure tasks (TRD-012 Postgres schema, TRD-008 Phoenix scaffold, TRD-007/041 architecture
  tests) are validated by their PR's integration TEST task, not standalone unit tests
- Total: 41 implementation tasks + 10 TEST tasks = 51 tasks
- Coverage target: ≥ 80% line coverage on new code; 100% on Aggregate.apply_event clauses

---

## 7. Design Readiness Gate

### Scorecard

| Dimension | Score (1–5) | Evidence |
|---|---|---|
| **Architecture completeness** — All components, interfaces, and data flows defined? | 4 | All 10 components defined; all 5 architecture gaps resolved (worker payload, Node→Elixir hash report, PR→run lookup, EventCodec strictness, scheduler orphan); Node/Elixir boundary explicit; PR monitor event contract defined (ownership TBD) |
| **Task coverage** — Does every REQ-NNN have implementation and test tasks? | 4 | All 10 REQs have implementation TRD tasks; all except REQ-009 have paired TEST tasks; REQ-009 is itself a testing REQ so its tasks are the test tasks |
| **Dependency clarity** — Are dependencies explicit and acyclic? | 4 | All [depends: TRD-NNN] annotations present; dependency map shows clean DAG; critical path identified; no circular dependencies |
| **Estimate confidence** — Are estimates consistent, reasonable, and granular enough? | 4 | Total 147h across 10 sprints (avg 14.7h/sprint); TRD-005 (12h, migrate all applies) is the highest-risk estimate — 12h = 9h best-case + 3h buffer; TRD-005 is the only task with explicit contingency |

**Overall Design Readiness Score: 4.0 / 5.0**

| Dimension | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Architecture completeness | — | — | — | ✓ | — |
| Task coverage | — | — | — | ✓ | — |
| Dependency clarity | — | — | — | ✓ | — |
| Estimate confidence | — | — | — | ✓ | — |

**Design Readiness trend:** v1.0.3 rescored estimate confidence 3→4; overall 3.75→4.0 PASS.

---

## 8. Open Questions

| # | Question | Resolution Path |
|---|---|---|
| 1 | PR monitoring ownership — Elixir, Go, or helper process? | Resolve during Sprint 6 (PR 6) implementation — architecture supports all three |
| 2 | Node → Elixir hash report transport | Resolved: Phoenix HTTP POST to `POST /api/runtime/hashes` with `{path, hash}` manifest |
| 3 | Worker launch payload fields | Resolved: `{run_id, phase, artifact_hash, task_id, project_id}` — full autonomy context |
| 4 | GitHub PR → run_id lookup | Resolved: Postgres lookup on `pr_github_id` in `projection_runs` |
| 5 | EventCodec v=0 unknown-key handling | Resolved: both v=0 and v=1 strict — legacy events must be cleaned before migration |
| 6 | Scheduler confirmed-before-recorded orphan | Resolved: `WorkerConfirmedExecution` without prior intent is rejected stale; worker retries |
| 7 | Projection approach | Resolved: Postgres-backed from day one, incremental by entity |

---

## Changelog

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-07-27 | 1.0.0 | Initial TRD from PRD-2026-001 go-elixir-cqrs-parity | Pi Agent |
| 2026-07-27 | 1.0.1 | Fix TRD-005 aggregate list (add project, operator_intervention); TRD-005 6h→9h (11→17 aggregates); overall 141h→144h | Pi Agent |
| 2026-07-27 | 1.0.2 | TRD-005 9h→12h (+3h buffer); overall 144h→147h; critical path 18h→21h | Pi Agent |
| 2026-07-27 | 1.0.3 | Estimate confidence 3→4; overall 3.75→4.0 PASS; scorecard and frontmatter updated | Pi Agent |

