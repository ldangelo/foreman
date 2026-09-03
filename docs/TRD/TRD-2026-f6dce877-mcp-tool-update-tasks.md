---
document_id: TRD-2026-f6dce877
label: trd-mcp-tool-update-tasks
version: 1.0.1
status: Draft
date: 2026-09-03
prd_reference: docs/PRD/PRD-2026-f6dce877-mcp-tool-update-tasks.md
prd_label: prd-mcp-tool-update-tasks
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 39
design_readiness_score: 4.7
readiness_score: 4.7
total_tasks: 24
kind: trd
---

# TRD: MCP Tool Update Tasks

Foreman task title read from `FOREMAN_TASK_TITLE`: **MCP tool update tasks**.

## 1. Executive Summary

This TRD turns `PRD-2026-f6dce877` into a focused implementation plan for Foreman's MCP task and run-status surface. The work is brownfield and must first classify existing partial task-tool behavior, then complete/correct the shared MCP registry, handlers, policy gate, telemetry, tests, and docs.

Current source verification found:

- `ForemanServer.MCP.Tools` already advertises and handles `foreman_task_list`, `foreman_task_get`, and `foreman_task_update`.
- `foreman_run_status` does not exist yet.
- `ForemanServer.MCP.Policy` already hides/refuses `foreman_task_create`, `foreman_task_update`, and other write tools behind `allow_workflow_writes`.
- HTTP (`ForemanServer.MCP`) and stdio (`ForemanServer.MCP.Stdio`) both delegate tool wiring/calls through `ForemanServer.MCP.Dispatch`; `Dispatch.input_validator/1` atomizes only declared schema keys.
- `ProjectionStore.list_tasks/0` already sorts by `task_id`, but MCP task list currently lacks `limit`, `offset`, `next_offset`, and status enum schema.
- `ProjectionStore.run/1` and `ProjectionStore.phases_for_run/1` provide the read-model source for a bounded run-status DTO.
- `Aggregates.Task` accepts statuses `open`, `ready`, `in_progress`, `blocked`, `closed`, `failed`; `task.update` validates status/priority and dispatches `TaskUpdated`.
- Current update schema text omits `blocked` in one description, so schema/docs must be corrected to the aggregate enum rather than copied forward.
- Docs already mention task tools and write gating, but not `foreman_run_status` or task-list pagination.

## 2. Architecture Decision

### 2.1 Alternatives Considered

#### Option A — Patch only missing `foreman_run_status` (rejected)

Add the new run-status tool and leave current task tools unchanged.

- **Pros:** Smallest diff, fastest path to a new advertised tool.
- **Cons:** Leaves known PRD gaps: task list has no pagination envelope, schema omits canonical status enum, update arg normalization is not explicitly whitelisted in handler code, and docs/tests remain partial.
- **Risk:** Medium. Product would appear complete while automation clients still see unstable task list semantics.

#### Option B — Build a separate MCP task/run service layer (rejected)

Introduce a new service module that owns task/run DTOs, policy, errors, telemetry, and transport mapping.

- **Pros:** Clean separation and reusable DTO helpers.
- **Cons:** Duplicates boundaries already centralized in `ForemanServer.MCP.Tools`, `ForemanServer.MCP.Dispatch`, `ProjectionStore`, and `CommandGateway`.
- **Risk:** High. Adds a second model and violates the PRD's command/projection-boundary constraint.

#### Option C — Complete the existing shared MCP tools boundary (chosen)

Keep `ForemanServer.MCP.Tools` as the schema/handler owner and `ForemanServer.MCP.Dispatch` as the transport-independent auth/policy/arg-normalization boundary. Add a small run-status projection helper, tighten task schemas/handler validation, preserve command dispatch for writes, and expand tests/docs.

- **Pros:** Best fit for the codebase, minimum new surface area, preserves HTTP/stdio parity, keeps all reads from projections and all writes through `CommandGateway.dispatch_operator/2`.
- **Cons:** Requires careful tests to distinguish existing partial behavior from completed behavior.
- **Risk:** Low-medium. Main risk is changing task-list response shape; mitigated by documenting the new envelope and keeping full task projection entries unchanged.

Foreman mode: auto-selected Option C (complete the existing shared MCP tools boundary).

### 2.2 System Architecture

| Component | Responsibility | Change |
|---|---|---|
| `ForemanServer.MCP.Tools` | Tool schemas and handler implementations | Add `foreman_run_status`; tighten task schemas; add pagination/filter validation; whitelist update fields; expose typed errors. |
| `ForemanServer.MCP.Dispatch` | Shared HTTP/stdio auth, policy, result wrapping, schema-key normalization | Keep as single transport boundary; add/adjust tests only unless schema-key normalization needs a bug fix. |
| `ForemanServer.MCP.Policy` | Write-tool advertisement/refusal | Keep `foreman_task_update` write-gated by `allow_workflow_writes`; verify direct-call refusal. |
| `ProjectionStore` | Source of truth for task/run read models | Use `list_tasks/0`, `task_projection/1`, `run/1`, and `phases_for_run/1`; add no alternate read store. |
| `CommandGateway` | Operator mutation boundary | `foreman_task_update` dispatches only `task.update`; no direct aggregate/provider writes. |
| `Aggregates.Task` | Task lifecycle/status validation | Audit and pin accepted/rejected status transitions; do not create new lifecycle states. |
| `ForemanServer.MCP.ToolError` | MCP error contract | Return `INVALID_PARAMS`, `NOT_FOUND`, `DOMAIN_ERROR`, or existing dispatch policy errors; never wrap errors as success data. |
| Telemetry | Debug metadata | Emit tool name, outcome, duration; avoid task title/description content. |
| Docs | Operator contract | Reconcile README, user guide, and CLI reference with shipped MCP behavior after code changes. |

### 2.3 Data Flow

#### Read task list/get

```text
MCP client
  -> HTTP or stdio transport
  -> ForemanServer.MCP.Dispatch.components/call
  -> ForemanServer.MCP.Policy (reads allowed)
  -> ForemanServer.MCP.Tools
  -> ProjectionStore.list_tasks/0 or task_projection/1
  -> JSON-encoded MCP tool result or typed ToolError
```

Task list filters by declared `project_id` and canonical `status`, preserves `ProjectionStore.list_tasks/0` task-id ascending order, applies offset pagination, and returns `%{tasks, total, limit, offset, next_offset}`.

#### Run status

```text
MCP client
  -> foreman_run_status %{run_id}
  -> ProjectionStore.run(run_id)
  -> ProjectionStore.phases_for_run(run_id)
  -> bounded status DTO
```

The run-status DTO includes `run_id`, `status`, `terminal`, `project_id`, `task_id`, `workflow_name`, `current_phase`, `started_at_ms`, `last_event_at_ms`, and optional `failure_reason`. `current_phase` is derived from the latest in-progress phase, otherwise latest phase by index/last-event timestamp. No log/event scraping is used.

#### Task update

```text
MCP client
  -> foreman_task_update %{task_id, mutable fields}
  -> Dispatch schema-key normalization drops undeclared keys without atom creation
  -> Policy.authorized? (write gate)
  -> Tools whitelist known mutable fields and reject no-op payloads
  -> CommandGateway.dispatch_operator(%{type: "task.update", aggregate_id: "task:<id>", payload})
  -> Aggregates.Task validates existence, priority, status, lifecycle transition
  -> MCP result returns gateway result only
```

No Beads/provider sync is added. Clients that need fresh state call `foreman_task_get` after a successful update.

### 2.4 Integration Points and Data Contracts

- **Tool schemas:** JSON Schema must declare required keys, optional keys, status enums, `limit`/`offset` integer bounds, and no unsupported mutation keys.
- **Task status enum:** `open`, `ready`, `in_progress`, `blocked`, `closed`, `failed`.
- **Pagination:** default `limit` 100, max 500, default `offset` 0; `next_offset` omitted or `nil` when no next page exists.
- **Typed errors:** missing/invalid params use `INVALID_PARAMS`; unknown task/run uses `NOT_FOUND`; domain command failures use `DOMAIN_ERROR` with inspectable sanitized reason; policy denial uses existing `POLICY_REFUSED` in dispatch.
- **Key normalization:** `Dispatch.input_validator/1` remains the only transport string-key-to-atom boundary; handlers whitelist mutable fields again so direct atom-keyed calls cannot smuggle unsupported update fields.
- **Telemetry:** `Telemetry.mcp_tool_call(duration_us, tool_name, outcome)` only; no title/description logging.

## 3. Reused Capabilities

Capability registry CLI `trd-graph-cli.js` was not present in this workspace/plugin install, so no machine registry was available. Manual overlap review of `docs/TRD` found no foundational TRD that provides this exact MCP task/run-status completion. Existing shared capabilities reused by reference in code, not reimplemented:

| Capability | Reuse source | Usage |
|---|---|---|
| MCP shared transport dispatch | `ForemanServer.MCP.Dispatch` | HTTP and stdio parity. |
| Write policy gate | `ForemanServer.MCP.Policy` | Default-safe task update. |
| Projection reads | `ProjectionStore` | Task/run source of truth. |
| Operator command dispatch | `CommandGateway.dispatch_operator/2` | Task mutation boundary. |
| Task lifecycle validation | `ForemanServer.Aggregates.Task` | Status and transition policy. |

## 4. Master Task List

### PR 1: Read-only task and run-status MCP contract

**Shippable State:** MCP clients can discover read-only task tools and `foreman_run_status`, list/get tasks with stable pagination, and query bounded run status without using logs or the CLI.

- [ ] **TRD-001** — Audit current MCP task/run implementation and record add/correct/complete decisions (2h) [satisfies REQ-014]
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given current MCP source is inspected, when implementation begins, then existing task tools are classified as keep/correct/extend rather than duplicated.
    - Given existing run tools are inspected, when run status is added, then `foreman_run_get*` compatibility risks are documented in code-review notes.

- [ ] **TRD-001-TEST** — Pin audit findings with regression tests for existing run/work tools (3h) [verifies TRD-001] [satisfies REQ-014] [depends: TRD-001]
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given existing run/work MCP tests run, when new status code is present, then `foreman_work_get`, `foreman_run_get`, events, activity, and logs keep their documented shapes.
    - Given compatibility tests fail, when failures are reviewed, then implementation does not rewrite expected behavior unless source contract intentionally changed.

- [ ] **TRD-002** — Add/tighten MCP schemas for task list/get/update and new `foreman_run_status` (4h) [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-006] [satisfies REQ-013]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-002-3, AC-006-1, AC-013-2
  - Implementation AC checklist:
    - Given writes are enabled, when `Tools.list_tools/0` is filtered by policy, then task list/get/update and run status appear as required.
    - Given writes are disabled, when tools are listed, then read tools and run status remain and task update is omitted.
    - Given schemas are inspected, then task status enum and pagination fields match handler behavior.
    - Given task update schema is inspected, then `blocked` is included with the aggregate-supported status enum.

- [ ] **TRD-002-TEST** — Test tool advertisement and JSON Schema contract (4h) [verifies TRD-002] [satisfies REQ-001] [satisfies REQ-013] [depends: TRD-002]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-013-2
  - Implementation AC checklist:
    - Given default policy, when tests list tools, then read tools include `foreman_task_list`, `foreman_task_get`, and `foreman_run_status`.
    - Given write policy enabled, when tests list tools, then `foreman_task_update` is also present.
    - Given schema fixtures are validated, when enum/bounds drift, then tests fail loudly.

- [ ] **TRD-003** — Complete task list/get handlers with filtering, pagination, and typed read errors (5h) [satisfies REQ-002] [satisfies REQ-003] [satisfies REQ-009] [satisfies REQ-013] [depends: TRD-002]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-003-1, AC-003-2, AC-009-1, AC-009-3, AC-013-1, AC-013-2, AC-013-3
  - Implementation AC checklist:
    - Given tasks exist, when listed with no filters, then response is task-id ascending and includes `total`, `limit`, `offset`, and page data.
    - Given `project_id` or `status` is supplied, when listed, then only matching tasks are returned.
    - Given an unknown task id, when fetched, then `NOT_FOUND` is returned with no placeholder map.

- [ ] **TRD-003-TEST** — Test task list/get success, filters, pagination, missing params, and not-found (5h) [verifies TRD-003] [satisfies REQ-002] [satisfies REQ-003] [satisfies REQ-009] [satisfies REQ-012] [satisfies REQ-013] [depends: TRD-003]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-003-1, AC-003-2, AC-009-1, AC-009-3, AC-012-1, AC-013-1, AC-013-2, AC-013-3
  - Implementation AC checklist:
    - Given more than one page of tasks, when fetching page 1 and page 2 against a stable projection, then no task is skipped or duplicated.
    - Given required args are absent for get, when tool is called, then `INVALID_PARAMS` names `task_id`.
    - Given invalid status/limit/offset is supplied, when list runs, then an `INVALID_PARAMS` error is returned.

- [ ] **TRD-004** — Implement `foreman_run_status` from run and phase projections (5h) [satisfies REQ-006] [satisfies REQ-009] [depends: TRD-002]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-009-1, AC-009-3
  - Implementation AC checklist:
    - Given a known active run, when status is queried, then bounded DTO fields are present and `terminal` is false.
    - Given a terminal run, when status is queried, then status distinguishes `completed`, `failed`, and `cancelled` and `terminal` is true.
    - Given phases exist, when status is queried, then `current_phase` is derived deterministically from projections.

- [ ] **TRD-004-TEST** — Test run status active, terminal, unknown, and missing-param cases (4h) [verifies TRD-004] [satisfies REQ-006] [satisfies REQ-009] [satisfies REQ-012] [depends: TRD-004]
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-009-1, AC-009-3, AC-012-2
  - Implementation AC checklist:
    - Given active and terminal projection fixtures, when status tests run, then DTO shape and terminal semantics are exact.
    - Given an unknown run, when queried, then `NOT_FOUND` is returned.
    - Given missing `run_id`, when called, then `INVALID_PARAMS` names `run_id`.

### PR 2: Safe MCP task update path

**Shippable State:** Authorized MCP clients can update only supported task fields through Foreman's existing command/lifecycle policy; unauthorized clients get refusal before dispatch.

- [ ] **TRD-005** — Whitelist task update args and reject no-op/invalid mutation payloads (4h) [satisfies REQ-004] [satisfies REQ-009] [depends: TRD-002]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-009-1
  - Implementation AC checklist:
    - Given only undeclared fields are supplied through a transport, when args reach the handler, then no atom is created and `INVALID_PARAMS` is returned if no mutable field remains.
    - Given no mutable fields are supplied, when update is called, then no command dispatch occurs.
    - Given supported fields are supplied, when payload is built, then only `title`, `description`, `priority`, and `status` are present with `task_id`.

- [ ] **TRD-005-TEST** — Test update arg normalization, no-op rejection, and unsupported-field handling (4h) [verifies TRD-005] [satisfies REQ-004] [satisfies REQ-009] [satisfies REQ-012] [depends: TRD-005]
  - Validates PRD ACs: AC-004-2, AC-004-3, AC-009-1, AC-012-1
  - Implementation AC checklist:
    - Given undeclared JSON keys, when routed through `Dispatch` validation, then keys remain non-atoms and handler ignores them safely.
    - Given no supported update fields remain, when update runs, then test asserts `INVALID_PARAMS` and no gateway call.

- [ ] **TRD-006** — Preserve policy-gated command dispatch for task updates (4h) [satisfies REQ-004] [satisfies REQ-007] [satisfies REQ-008] [depends: TRD-005]
  - Validates PRD ACs: AC-004-1, AC-004-4, AC-007-1, AC-007-2, AC-007-3, AC-008-1
  - Implementation AC checklist:
    - Given default config, when `foreman_task_update` is called through dispatch, then `POLICY_REFUSED` returns before `CommandGateway`.
    - Given writes are enabled, when update succeeds, then `CommandGateway.dispatch_operator/2` handles a `task.update` command.
    - Given update succeeds, then response is the gateway result and not a synthesized fresh task projection.

- [ ] **TRD-006-TEST** — Test default-deny write policy and successful dispatch path (4h) [verifies TRD-006] [satisfies REQ-004] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-012] [depends: TRD-006]
  - Validates PRD ACs: AC-004-1, AC-004-4, AC-007-1, AC-007-2, AC-007-3, AC-008-1, AC-012-1
  - Implementation AC checklist:
    - Given write policy false, when direct dispatch calls update, then policy refuses before command dispatch.
    - Given write policy true and valid payload, when update runs, then test observes a `TaskUpdated` command result.

- [ ] **TRD-007** — Audit and pin aggregate task status/lifecycle behavior for MCP updates (5h) [satisfies REQ-005] [satisfies REQ-009] [depends: TRD-006]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3, AC-005-4, AC-009-2
  - Implementation AC checklist:
    - Given each canonical task status, when aggregate update validation runs, then accepted/rejected outcomes match `Aggregates.Task` contract.
    - Given running/bound tasks are manually closed/failed through update, when aggregate accepts or rejects, then no run completion is fabricated.
    - Given domain rejects a transition, when MCP handles it, then structured domain reason is preserved safely.

- [ ] **TRD-007-TEST** — Test accepted/rejected task status updates and domain error mapping (5h) [verifies TRD-007] [satisfies REQ-005] [satisfies REQ-009] [satisfies REQ-012] [depends: TRD-007]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3, AC-005-4, AC-009-2, AC-012-3
  - Implementation AC checklist:
    - Given invalid task status, when MCP update dispatches, then `DOMAIN_ERROR` contains the aggregate reason.
    - Given accepted canonical statuses, when tests run, then each value has schema or handler coverage.
    - Given provider-tracked tasks, when status updates, then no TaskProvider sync call is introduced.

### PR 3: Transport parity, telemetry, and compatibility hardening

**Shippable State:** HTTP and stdio MCP clients receive equivalent tool schemas, payloads, errors, and safe telemetry without regressions to existing work/run tools.

- [ ] **TRD-008** — Verify HTTP/stdio use the shared dispatch/tool registry for new tools (3h) [satisfies REQ-001] [satisfies REQ-008] [depends: TRD-003] [depends: TRD-004] [depends: TRD-006]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-008-1, AC-008-2
  - Implementation AC checklist:
    - Given both transports initialize with same config, when components are listed, then tool names and schemas are equivalent.
    - Given a new tool is added, when architecture tests scan transport modules, then no duplicated tool list appears.

- [ ] **TRD-008-TEST** — Test transport parity for schemas, success payloads, and typed errors (4h) [verifies TRD-008] [satisfies REQ-001] [satisfies REQ-008] [depends: TRD-008]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-008-1, AC-008-2
  - Implementation AC checklist:
    - Given HTTP and stdio dispatch paths call the same registry, when test fixtures call read/update/status tools, then results are equivalent.
    - Given a transport-local tool list is introduced, when architecture test runs, then it fails.

- [ ] **TRD-009** — Ensure MCP task/run telemetry is safe and complete (3h) [satisfies REQ-010] [depends: TRD-003] [depends: TRD-004] [depends: TRD-006]
  - Validates PRD ACs: AC-010-1, AC-010-2
  - Implementation AC checklist:
    - Given task/read/update/status tools complete, when telemetry fires, then metadata contains tool, outcome, and duration only.
    - Given task title/description changes, when telemetry/log assertions inspect events, then content is absent.

- [ ] **TRD-009-TEST** — Test telemetry metadata excludes task content (3h) [verifies TRD-009] [satisfies REQ-010] [depends: TRD-009]
  - Validates PRD ACs: AC-010-1, AC-010-2
  - Implementation AC checklist:
    - Given sensitive title/description fixture data, when update and reads complete, then telemetry assertions do not contain that content.
    - Given success/not-found/domain-error outcomes, when telemetry fires, then outcome labels are present.

- [ ] **TRD-010** — Preserve existing MCP work/run tools while adding run status (3h) [satisfies REQ-014] [depends: TRD-004]
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given `foreman_run_status` is implemented, when existing run tools are called, then their handlers and payloads are unchanged unless tests explicitly prove compatible additions.
    - Given existing docs mention run detail tools, when docs are updated, then `foreman_run_status` is documented as additive.

- [ ] **TRD-010-TEST** — Run compatibility regression tests for existing MCP work/run tools (3h) [verifies TRD-010] [satisfies REQ-014] [depends: TRD-010]
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given existing tool fixtures, when tests run, then old run/work tools still pass.
    - Given run status fixture exists, when `foreman_run_get` is called, then it does not return the bounded status DTO by accident.

### PR 4: Operator docs and final validation

**Shippable State:** Operators can read the repo docs to know exactly which MCP task/run-status tools exist, which are write-gated, what payloads/errors look like, and how to validate them.

- [ ] **TRD-011** — Reconcile MCP documentation with implemented task/run-status behavior (4h) [satisfies REQ-011] [depends: TRD-010]
  - Validates PRD ACs: AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given implementation is complete, when docs are updated, then README, user guide, and CLI reference describe actual tool inventory, gating, task update semantics, pagination, and run-status payload.
    - Given default config hides a write tool, when docs list it, then docs state hidden/refused semantics.

- [ ] **TRD-011-TEST** — Review docs against source and run doc hygiene checks (3h) [verifies TRD-011] [satisfies REQ-011] [depends: TRD-011]
  - Validates PRD ACs: AC-011-1, AC-011-2
  - Implementation AC checklist:
    - Given docs mention MCP tools, when source schemas are compared, then no documented tool/payload is absent from code.
    - Given docs are edited, when `git diff --check` runs, then no whitespace errors are present.

- [ ] **TRD-012** — Run final focused validation for MCP task/run-status slice (4h) [satisfies REQ-012] [satisfies REQ-014] [depends: TRD-011]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-012-3, AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given all MCP tests are complete, when focused ExUnit files run, then task list/get/update, run status, policy, dispatch, telemetry, and compatibility pass.
    - Given full repo constraints are available, when final validation runs, then formatting and relevant test suites pass or blockers are recorded truthfully.

- [ ] **TRD-012-TEST** — Capture final validation evidence and failure diagnostics (2h) [verifies TRD-012] [satisfies REQ-012] [satisfies REQ-014] [depends: TRD-012]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-012-3, AC-014-1, AC-014-2
  - Implementation AC checklist:
    - Given validation succeeds, when completion report is written, then commands and results are recorded.
    - Given validation is blocked, when completion report is written, then exact command, failure, and next step are recorded.

## 5. Dependency Graph

Critical path:

```text
TRD-001
  -> TRD-002
    -> TRD-003 -> TRD-003-TEST
    -> TRD-004 -> TRD-004-TEST
    -> TRD-005 -> TRD-006 -> TRD-007 -> TRD-007-TEST
      -> TRD-008 (also depends on TRD-003/TRD-004) -> TRD-008-TEST
      -> TRD-009 -> TRD-009-TEST
      -> TRD-010 -> TRD-010-TEST
        -> TRD-011 -> TRD-011-TEST
          -> TRD-012 -> TRD-012-TEST
```

No circular dependencies. No task estimate is 8h or larger.

## 6. Sprint Planning

## Sprint 1: Read model and schemas

- PR 1: `TRD-001` through `TRD-004-TEST`.
- Goal: complete read-only MCP contract and run status DTO.

## Sprint 2: Safe writes and policy

- PR 2: `TRD-005` through `TRD-007-TEST`.
- Goal: complete command-gated task update without policy bypass.

## Sprint 3: Parity, telemetry, docs

- PR 3 and PR 4: `TRD-008` through `TRD-012-TEST`.
- Goal: prove transport parity, compatibility, safe telemetry, and operator documentation.

## 7. Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Advertise task operation tools consistently | TRD-002, TRD-008 | TRD-002-TEST, TRD-008-TEST |
| REQ-002 | List tasks through MCP | TRD-002, TRD-003 | TRD-003-TEST |
| REQ-003 | Get one task through MCP | TRD-003 | TRD-003-TEST |
| REQ-004 | Update mutable task fields through MCP | TRD-005, TRD-006 | TRD-005-TEST, TRD-006-TEST |
| REQ-005 | Preserve task lifecycle policy | TRD-007 | TRD-007-TEST |
| REQ-006 | Expose run status queries | TRD-002, TRD-004 | TRD-004-TEST |
| REQ-007 | Keep read/write policy default-safe | TRD-006 | TRD-006-TEST |
| REQ-008 | Share behavior across MCP transports | TRD-006, TRD-008 | TRD-006-TEST, TRD-008-TEST |
| REQ-009 | Return typed MCP errors | TRD-003, TRD-004, TRD-005, TRD-007 | TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-007-TEST |
| REQ-010 | Emit safe telemetry | TRD-009 | TRD-009-TEST |
| REQ-011 | Document tool inventory and behavior | TRD-011 | TRD-011-TEST |
| REQ-012 | Cover task/run query edge cases with tests | TRD-012 | TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST, TRD-012-TEST |
| REQ-013 | Avoid pagination and ordering ambiguity | TRD-002, TRD-003 | TRD-002-TEST, TRD-003-TEST |
| REQ-014 | Preserve existing work/run tools | TRD-001, TRD-010, TRD-012 | TRD-001-TEST, TRD-010-TEST, TRD-012-TEST |

Traceability check: 14 requirements covered, 0 uncovered, 0 orphaned annotations.

## 8. Adversarial Review

### 8.1 Architecture Self-Critique

1. **Issue: `foreman_run_status` could drift from `foreman_run_get`.** If it hand-builds state from events or logs, it becomes a second run model.
   - **Resolution:** Derive only from `ProjectionStore.run/1` and `ProjectionStore.phases_for_run/1`; compatibility tests assert `foreman_run_get` remains unchanged.

2. **Issue: Update key normalization spans dispatch and handler.** Dispatch drops no undeclared atoms, but handler could still accept atom keys from direct tests/callers.
   - **Resolution:** Handler must explicitly whitelist mutable fields and reject no-op payloads after whitelisting; tests cover transport and direct handler paths.

3. **Issue: Task status transitions are permissive today except historical `merged`.** PRD demands lifecycle protection but current aggregate contract may intentionally allow manual terminal updates.
   - **Resolution:** Do not invent stricter lifecycle in MCP. Audit `Aggregates.Task`, pin current accepted/rejected transitions, and preserve domain reasons when rejected.

### 8.2 Task Coverage Analysis

1. **Issue: Existing task-tool implementation can make tasks look done before PRD semantics are met.** Current list/get/update exist, but list lacks pagination envelope and `foreman_run_status` is absent.
   - **Resolution:** TRD-001 forces classification; TRD-002/TRD-003/TRD-004 complete the gaps before write work.

2. **Issue: Docs already mention task tools, so documentation could overstate run-status availability if updated too early.**
   - **Resolution:** TRD-011 depends on compatibility hardening and requires docs to match source after implementation, not desired future behavior.

3. **Issue: Machine TRD parser CLI was unavailable in this worktree/plugin install.** A broken symlink exists at `/Users/ldangelo/.pi/agent/skills/packages/development/lib/trd-cli.js` and `trd-graph-cli.js` was absent.
   - **Resolution:** This draft uses the required checkbox task format and was validated by a local regex self-check; implementation phase should use the real CLI if restored.

### 8.3 Dependency and Estimate Review

1. **Issue: Longest dependency chain crosses all four PRs.** Late docs/final validation depend on code shape.
   - **Resolution:** Keep PRs small and independently shippable; no task exceeds 5h, and compatibility tests are introduced before docs.

2. **Issue: Transport parity could become implicit.** If tests only call `Tools.call_tool/2`, they miss HTTP/stdio wiring.
   - **Resolution:** TRD-008 and TRD-008-TEST explicitly inspect/call shared `Dispatch.components/0` and transport callback wiring.

### 8.4 Testability Review

- All implementation ACs use observable source, schema, payload, error, or telemetry outcomes.
- Subjective terms are avoided or paired with pass/fail checks.
- Focused test files should include `packages/foreman_server/test/foreman_server/mcp/tools_test.exs`, `policy_test.exs`, `mcp_transport_test.exs`, and any new telemetry/dispatch tests.

## 9. Design Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 4.5 | Components, data flows, policy, DTO, and transport boundaries are defined. |
| Task coverage | 4.7 | Every PRD requirement has implementation and test tasks; task lines use parser-visible checkboxes. |
| Dependency clarity | 4.6 | Dependencies are explicit and acyclic; transport parity now waits for list/get and run-status completion. |
| Estimate confidence | 4.4 | Tasks are granular (2h-5h) and match current source complexity; no 8h+ task remains. |
| Overall | 4.7 | PASS |

Gate decision: **PASS**.

## 10. Validation Notes

- PRD source: `docs/PRD/PRD-2026-f6dce877-mcp-tool-update-tasks.md`.
- PRD readiness score: 4.7 PASS.
- Subject match: PRD title and Foreman task title both target MCP tool update tasks.
- MCP enhancement: skipped (no MCP tools detected in this Pi tool surface).
- Capability CLI: unavailable; manual reuse review performed.
- Refinement source spot-checks: `packages/foreman_server/lib/foreman_server/mcp/tools.ex`, `dispatch.ex`, `policy.ex`, `projection_store.ex`, and `aggregates/task.ex`.
- Task parser self-check: 24 parser-visible checkbox task lines intended.

## 11. Suggested Next Steps

1. `/ensemble-configure-team docs/TRD/TRD-2026-f6dce877-mcp-tool-update-tasks.md`
2. `/ensemble-implement-trd-beads docs/TRD/TRD-2026-f6dce877-mcp-tool-update-tasks.md`
3. Before implementation, restore/use the real `trd-cli.js` if available and rerun parser validation.

## 12. Changelog

### 2026-09-03 — v1.0.1

- Refined source verification against current MCP, projection, policy, and task aggregate code.
- Added explicit `blocked` update-schema correction and handler whitelist guidance.
- Tightened transport-parity dependency on completed task list/get and run status behavior.

### 2026-09-03 — v1.0.0

- Created initial TRD from `PRD-2026-f6dce877`.
- Selected brownfield Option C under Foreman mode.
- Added 24 implementation/test tasks across 4 shippable PRs.
- Preserved PRD/TRD correlation id `f6dce877`.
