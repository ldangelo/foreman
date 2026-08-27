---
document_id: TRD-2026-cd07a086
label: trd-durable-run-log-store
kind: trd
prd_reference: docs/PRD/PRD-2026-cd07a086-durable-run-log-store.md
version: 1.0.0
status: Draft
date: 2026-08-27
design_readiness_score: 4.1
---

# TRD: Durable Run Log Store for `foreman_run_get_logs`

## Metadata

| Field | Value |
|---|---|
| Document ID | TRD-2026-cd07a086 |
| PRD Reference | docs/PRD/PRD-2026-cd07a086-durable-run-log-store.md |
| Version | 1.0.0 |
| Status | Draft |
| Date | 2026-08-27 |
| Design Readiness Score | 4.1 |

## Source Task

Title: `Implement durable run log store for foreman_run_get_logs`

Description: `foreman_run_get_logs returns UNAVAILABLE. The WorkerStdout/WorkerStderr event channel exists on worker:<run_id>:<worker_id> streams but has no producer, and Logger output is console-only and not keyed by run_id. Design a durable run log store and wire run_logs/1 to it so logs are retrievable via MCP after a run ends.`

## Requirements Validation

PRD validation passed.

- Required PRD sections present: Product Summary, User Analysis, Goals, Technical Requirements, Acceptance Criteria.
- Requirements use sequential `REQ-001` through `REQ-015` identifiers.
- Acceptance criteria use `AC-NNN-M` identifiers and are testable.
- Readiness score: 4.2, PASS.
- Clarification markers are resolved here as implementation decisions, not deferred to code generation.

## Domain Analysis

| Domain | Scope |
|---|---|
| Worker runtime | Capture stdout/stderr from the production Jido harness worker path and emit through `WorkerProtocol`. |
| Event sourcing | Reuse `WorkerStdout` / `WorkerStderr` events on `worker:<run_id>:<worker_id>` streams. |
| Projection read model | Materialize bounded log entries in `ProjectionStore` and rebuild them from committed worker events. |
| MCP API | Map `ProjectionStore.run_logs/1` success and typed failures through `foreman_run_get_logs`. |
| Safety | Redact before persistence, serialize control characters safely, and document retention/truncation. |
| Testing | Cover producer wiring, event replay, MCP results, unknown/empty/failure cases, and docs. |

Brownfield assessment: Foreman already has Overwatch, WorkerProtocol, typed worker events, EventStore replay, ProjectionStore read details, and MCP tool dispatch. The gap is producer + projection + typed response shape.

## Reused Capabilities

No foundational TRD capabilities were found in `docs/TRD` for this feature. Capability registry is empty. No duplicate foundational task rows emitted.

## Architecture Decision

Chosen approach: **Option C — reuse worker event streams with bounded projection and production producer wiring**.

### Alternatives Considered

| Option | Design | Pros | Cons | Risk |
|---|---|---|---|---|
| A | Add a separate per-run log file store and read files from MCP. | Quick append/read path; avoids replay work. | Duplicates event-store boundary; weak rebuild story; harder reset/retention semantics. | High contract drift. |
| B | Add a new database-backed log table with direct producer writes. | Scales query volume; flexible indexes. | Adds a second write model beside Worker aggregate; more migration and consistency surface. | Medium-high complexity. |
| C | Emit redacted `WorkerStdout` / `WorkerStderr` through `WorkerProtocol`; project bounded logs from worker streams. | Reuses existing aggregate, stream names, sequence allocation, replay, and MCP boundary. | Requires careful capture adapter and projection bounds. | Balanced. |

### Key Technical Decisions

1. Producer boundary: production code must call `WorkerProtocol.emit(:worker_stdout | :worker_stderr, payload)` only from the worker runtime adapter path. No controller, MCP tool, or projection may append log events directly.
2. Event shape: persist redacted `line` content plus `run_id`, `worker_id`, and Tracker-allocated `sequence`. Returned entries add `channel`, `timestamp`, `event_number`, and `stream_id` when available.
3. Ordering: sort by committed event-store position when available; tie-break by `timestamp`, `worker_id`, `sequence`, then `channel`. This gives deterministic cross-worker order.
4. Capture bounds: default capture cap is 10,000 lines or 5 MiB per `(run_id, worker_id)`, whichever arrives first. Further output is omitted and represented by projection metadata (`truncated: true`, omitted line/byte counts) rather than infinite event emission.
5. Retrieval bounds: default `foreman_run_get_logs` returns the latest 500 entries. Maximum accepted limit is 5,000 entries. Offset/cursor is out of scope for this slice; tail semantics are deterministic and documented.
6. Redaction: redact before event persistence using the same secret-pattern discipline as Foreman config/env handling: bearer/API-key/private-key/token/password patterns and exact configured secret values when available. Tests must prove redacted content is what persists.
7. Empty vs absent: unknown run returns `{:error, :run_not_found}` / MCP `NOT_FOUND`; known run with no output returns `{:ok, %{entries: [], ...}}`; store/projection failures return typed errors, never empty success.
8. Retention/reset: logs are retained with worker events for the run. Reset/retry logs remain under their originating `run_id`; no cross-run grouping is added. Purged/expired worker events return a typed unavailable/expired failure if the run is known but log source is no longer readable.
9. Logger exclusion: ordinary `Logger` output is never copied into run logs unless it is explicitly captured through the worker stdout/stderr path and keyed by run/worker.

## System Architecture Design

### Components

| Component | Responsibility |
|---|---|
| `ForemanServer.Overwatch.Adapters.JidoHarnessWorker` | Start the production harness run, observe provider/process stdout/stderr events, apply bounds/redaction, emit worker log events, surface capture failures. |
| `ForemanServer.Overwatch.WorkerProtocol` | Existing sole worker lifecycle/log event boundary. Keep API total for stdout/stderr payloads. |
| `ForemanServer.Overwatch.Tracker` | Allocate sequence, dispatch `worker.record`, and preserve deterministic command ids. |
| `ForemanServer.Events.WorkerStdout` / `WorkerStderr` | Durable event structs for redacted output units. Extend only if required by tests; keep typed fields. |
| `ForemanServer.ProjectionStore` | Maintain `run_logs` projection state, expose `run_logs/1`, rebuild from EventStore worker streams. |
| `ForemanServer.MCP.Tools` | Return logs via `foreman_run_get_logs` and map all documented errors. |
| Docs | Explain limits, redaction, empty/unknown semantics, and Logger exclusion. |

### Data Flow

```text
Jido provider/process output
  -> JidoHarnessWorker capture sink
  -> redaction + safe serialization + per-worker cap
  -> WorkerProtocol.emit(:worker_stdout | :worker_stderr)
  -> Tracker sequence allocation
  -> worker:<run_id>:<worker_id> event stream
  -> ProjectionStore incremental apply / rebuild
  -> ProjectionStore.run_logs(run_id)
  -> MCP foreman_run_get_logs response
```

### Response Shape

`ProjectionStore.run_logs/1` returns:

```elixir
{:ok,
 %{
   run_id: run_id,
   entries: [
     %{
       worker_id: worker_id,
       channel: "stdout" | "stderr",
       sequence: integer,
       timestamp: integer | nil,
       content: binary,
       stream_id: binary,
       event_number: integer | nil
     }
   ],
   count: non_neg_integer,
   limit: pos_integer,
   truncated: boolean,
   omitted_entries: non_neg_integer,
   omitted_bytes: non_neg_integer
 }}
| {:error, :run_not_found}
| {:error, :log_store_unavailable}
| {:error, {:log_store_failed, term}}
```

MCP maps the same contract totally: `NOT_FOUND`, successful empty result, `UNAVAILABLE`, or `RUN_DETAIL_FAILED`.

## Master Task List

### 1.1 Sprint 1

#### Story 1.1

| id | task | status | Est. | Deps |
|---|---|---|---:|---|
| RLS-T001 | Define the `ProjectionStore.run_logs/1` return contract, response metadata, tail limit defaults, and typed error atoms in `packages/foreman_server/lib/foreman_server/projection_store.ex` and MCP docs comments. | [ ] | 3h |  |
| RLS-T002 | Add a worker log policy module for redaction, safe control-character serialization, per-worker capture caps, and omitted line/byte counters. | [ ] | 5h | RLS-T001 |
| RLS-T003 | Add or extend typed worker log event normalization so `WorkerStdout` and `WorkerStderr` persist redacted `line`, timestamp when available, and sequence-compatible payloads. | [ ] | 3h | RLS-T001,RLS-T002 |
| VLD-T001 | Add contract tests for log policy defaults, redaction before persistence, safe serialization, and typed return/error atoms. | [ ] | 4h | RLS-T001,RLS-T002,RLS-T003 |

### 1.2 Sprint 1

#### Story 1.2

| id | task | status | Est. | Deps |
|---|---|---|---:|---|
| RLS-T004 | Extend `ProjectionStore` state with bounded per-run log projection storage keyed by `run_id`, preserving empty-known-run state separately from unknown run. | [ ] | 5h | RLS-T003 |
| RLS-T005 | Project `WorkerStdout` and `WorkerStderr` events into ordered log entries during incremental `apply_events/1` without direct EventStore writes. | [ ] | 5h | RLS-T004 |
| RLS-T006 | Rebuild log projections from committed `worker:<run_id>:<worker_id>` streams using deterministic ordering and loud failure behavior for malformed log events. | [ ] | 6h | RLS-T005 |
| VLD-T002 | Add ProjectionStore tests for empty known run, stdout/stderr projection, cross-worker ordering, bounds metadata, malformed event handling, and rebuild replay. | [ ] | 6h | RLS-T004,RLS-T005,RLS-T006 |

### 2.1 Sprint 2

#### Story 2.1

| id | task | status | Est. | Deps |
|---|---|---|---:|---|
| RLS-T007 | Replace the `:no_log_store` known-run branch in `ProjectionStore.run_logs/1` with the new log projection read path and typed store-failure handling. | [ ] | 3h | RLS-T006 |
| RLS-T008 | Update `ForemanServer.MCP.Tools.run_detail/2` handling for the new log success and failure tuples while preserving `NOT_FOUND` and loud unexpected-result behavior. | [ ] | 3h | RLS-T007 |
| RLS-T009 | Add telemetry/diagnostic metadata for log retrieval outcomes, truncation, empty known runs, and failing projection/store layers. | [ ] | 3h | RLS-T008 |
| VLD-T003 | Add MCP tests for populated logs, known empty logs, unknown run, malformed params, projection failure, and unexpected tuple handling. | [ ] | 5h | RLS-T007,RLS-T008,RLS-T009 |

### 2.2 Sprint 2

#### Story 2.2

| id | task | status | Est. | Deps |
|---|---|---|---:|---|
| RLS-T010 | Change `JidoHarnessWorker` from terminal-result-only execution to a supervised start/stream/await flow that can observe provider/process stdout and stderr events while preserving existing result normalization. | [ ] | 7h | RLS-T002,RLS-T003 |
| RLS-T011 | Emit captured stdout/stderr through `WorkerProtocol.emit(:worker_stdout / :worker_stderr, ...)` with cap enforcement and typed capture-failure diagnostics. | [ ] | 5h | RLS-T010 |
| RLS-T012 | Ensure worker exit, task crash, detached await, timeout, and cleanup paths cannot silently report false-empty logs after capture setup failure. | [ ] | 4h | RLS-T011 |
| VLD-T004 | Add production-adapter tests proving `JidoHarnessWorker` emits `WorkerStdout` and `WorkerStderr` via `WorkerProtocol`, applies redaction, enforces caps, and still returns normalized worker results. | [ ] | 6h | RLS-T010,RLS-T011,RLS-T012 |

### 3.1 Sprint 3

#### Story 3.1

| id | task | status | Est. | Deps |
|---|---|---|---:|---|
| RLS-T013 | Add an end-to-end worker-to-MCP integration path using the production Overwatch/Jido harness boundary and real event/projection flow. | [ ] | 6h | RLS-T006,RLS-T008,RLS-T011 |
| RLS-T014 | Define retention, purge, and retry/reset semantics in code paths and error messages: logs are per originating run, expired known logs are typed unavailable, and retries use their new run ids. | [ ] | 4h | RLS-T007,RLS-T013 |
| RLS-T015 | Exclude ordinary server `Logger` messages from log projection and add guard tests so only worker stdout/stderr events can appear in `foreman_run_get_logs`. | [ ] | 3h | RLS-T005,RLS-T013 |
| VLD-T005 | Add end-to-end tests for completed/failed/cancelled terminal runs, replay after projection reset, reset/retry run separation, expired-log semantics, and Logger exclusion. | [ ] | 6h | RLS-T013,RLS-T014,RLS-T015 |

### 3.2 Sprint 3

#### Story 3.2

| id | task | status | Est. | Deps |
|---|---|---|---:|---|
| RLS-T016 | Update `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md` with log retrieval behavior, auth expectations, limits, redaction, empty vs unknown semantics, and Logger exclusion. | [ ] | 4h | RLS-T014,RLS-T015 |
| RLS-T017 | Update `AGENTS.md` and `CLAUDE.md` only where operator or agent expectations change for Foreman log retrieval and docs discipline. | [ ] | 2h | RLS-T016 |
| RLS-T018 | Run targeted Elixir tests and a fresh CLI/source verification pass for affected MCP/docs behavior; record evidence in the implementation report. | [ ] | 3h | VLD-T001,VLD-T002,VLD-T003,VLD-T004,VLD-T005,RLS-T016,RLS-T017 |
| VLD-T006 | Verify docs and parser compatibility: all task rows keep `[ ]` status, deps resolve to emitted ids, and `foreman_run_get_logs` docs match source behavior. | [ ] | 2h | RLS-T018 |

## Sprint Planning

| Sprint | Focus | Task IDs | Exit Criteria |
|---|---|---|---|
| 1 | Contract, safety policy, projection model | RLS-T001,RLS-T002,RLS-T003,VLD-T001,RLS-T004,RLS-T005,RLS-T006,VLD-T002 | `ProjectionStore` can represent and rebuild bounded redacted logs from worker events. |
| 2 | MCP read path and production producer | RLS-T007,RLS-T008,RLS-T009,VLD-T003,RLS-T010,RLS-T011,RLS-T012,VLD-T004 | Known runs return logs or empty success; production worker emits stdout/stderr events. |
| 3 | End-to-end semantics, docs, verification | RLS-T013,RLS-T014,RLS-T015,VLD-T005,RLS-T016,RLS-T017,RLS-T018,VLD-T006 | MCP retrieval works after terminal state; docs and verification are complete. |

Critical path: RLS-T001 -> RLS-T002 -> RLS-T003 -> RLS-T004 -> RLS-T005 -> RLS-T006 -> RLS-T007 -> RLS-T008 -> RLS-T013 -> RLS-T014 -> RLS-T016 -> RLS-T018 -> VLD-T006.

No task is estimated at 8h or more. No circular dependencies identified.

## Acceptance Criteria Traceability

| Requirement | Acceptance Criteria | Task Coverage |
|---|---|---|
| REQ-001 | AC-001-1, AC-001-2, AC-001-3 | RLS-T003,RLS-T004,RLS-T005,RLS-T006,VLD-T002 |
| REQ-002 | AC-002-1, AC-002-2, AC-002-3 | RLS-T010,RLS-T011,RLS-T012,VLD-T004 |
| REQ-003 | AC-003-1, AC-003-2, AC-003-3 | RLS-T007,RLS-T008,VLD-T003 |
| REQ-004 | AC-004-1, AC-004-2 | RLS-T001,RLS-T005,RLS-T006,VLD-T002 |
| REQ-005 | AC-005-1, AC-005-2, AC-005-3 | RLS-T004,RLS-T007,RLS-T008,VLD-T003 |
| REQ-006 | AC-006-1, AC-006-2 | RLS-T001,RLS-T002,RLS-T007,RLS-T011,VLD-T001,VLD-T003 |
| REQ-007 | AC-007-1, AC-007-2, AC-007-3 | RLS-T002,RLS-T008,RLS-T011,VLD-T001,VLD-T004 |
| REQ-008 | AC-008-1, AC-008-2 | RLS-T013,VLD-T005 |
| REQ-009 | AC-009-1, AC-009-2 | RLS-T006,VLD-T002,VLD-T005 |
| REQ-010 | AC-010-1, AC-010-2 | RLS-T009,RLS-T012,VLD-T003,VLD-T004 |
| REQ-011 | AC-011-1, AC-011-2 | RLS-T014,VLD-T005 |
| REQ-012 | AC-012-1, AC-012-2 | RLS-T001,RLS-T007,RLS-T008,VLD-T003 |
| REQ-013 | AC-013-1, AC-013-2, AC-013-3 | RLS-T013,VLD-T003,VLD-T004,VLD-T005 |
| REQ-014 | AC-014-1 | RLS-T016,RLS-T017,VLD-T006 |
| REQ-015 | AC-015-1 | RLS-T015,VLD-T005 |

## Target Files

| Path | Planned Change |
|---|---|
| `packages/foreman_server/lib/foreman_server/projection_store.ex` | Add log projection state, rebuild/apply handlers, and `run_logs/1` contract. |
| `packages/foreman_server/lib/foreman_server/mcp/tools.ex` | Map new log results/errors for `foreman_run_get_logs`. |
| `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` | Capture provider/process stdout/stderr and emit through WorkerProtocol. |
| `packages/foreman_server/lib/foreman_server/overwatch/worker_protocol.ex` | Tighten stdout/stderr payload contract only if needed. |
| `packages/foreman_server/lib/foreman_server/events/worker_stdout.ex` | Extend event fields only if required by typed payload tests. |
| `packages/foreman_server/lib/foreman_server/events/worker_stderr.ex` | Extend event fields only if required by typed payload tests. |
| `packages/foreman_server/test/foreman_server/projection_store*_test.exs` | Add projection and rebuild tests. |
| `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` | Add MCP run log contract tests. |
| `packages/foreman_server/test/foreman_server/overwatch/**/*test.exs` | Add production worker output capture tests. |
| `README.md` | Document user-visible log retrieval behavior if README has MCP/operator section. |
| `docs/user-guide.md` | Document operator behavior, limits, redaction, retention, empty vs unknown semantics. |
| `docs/cli-reference.md` | Update MCP tool reference for `foreman_run_get_logs`. |
| `AGENTS.md` | Update agent/operator expectation only if implementation changes agent workflow guidance. |
| `CLAUDE.md` | Update only if local agent instructions change. |

## Foreman Compatibility Check

| Check | Result |
|---|---|
| Parser-safe tables | yes |
| Required columns present | `id`, `task`, `status`, `Est.`, `Deps` |
| Dependency orphans | 0 |
| Uncovered requirements | 0 |
| Status cells | all `[ ]` |

Foreman compatibility check: parser-safe=yes, dependency-orphans=0, uncovered-reqs=0

## Next Step

Run native task creation after review:

```bash
foreman sling prd docs/PRD/PRD-2026-cd07a086-durable-run-log-store.md
```
