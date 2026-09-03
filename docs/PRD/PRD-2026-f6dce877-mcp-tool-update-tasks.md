---
document_id: PRD-2026-f6dce877
label: prd-mcp-tool-update-tasks
version: 1.0.0
status: Draft
date: 2026-09-03
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 39
readiness_score: 4.1
---

# PRD: MCP Tool Update Tasks

Foreman task title read from `FOREMAN_TASK_TITLE`: **MCP tool update tasks**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 4 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 14/14 (100%) |
| Acceptance criteria coverage | 14/14 (100%) |
| Risk flags | 5 |
| Dependencies | 10 |
| Open ambiguity markers | 9 |
| TRD decisions required | 5 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Advertise task operation tools consistently | Must | Medium | 3 |
| REQ-002 | List tasks through MCP | Must | Medium | 3 |
| REQ-003 | Get one task through MCP | Must | Low | 2 |
| REQ-004 | Update mutable task fields through MCP | Must | High | 4 |
| REQ-005 | Preserve task lifecycle policy | Must | High | 4 |
| REQ-006 | Expose run status queries | Must | Medium | 3 |
| REQ-007 | Keep read/write policy default-safe | Must | High | 3 |
| REQ-008 | Share behavior across MCP transports | Must | Medium | 2 |
| REQ-009 | Return typed MCP errors | Must | Medium | 3 |
| REQ-010 | Emit safe telemetry | Must | Low | 2 |
| REQ-011 | Document tool inventory and behavior | Should | Medium | 2 |
| REQ-012 | Cover task/run query edge cases with tests | Should | Medium | 3 |
| REQ-013 | Avoid pagination and ordering ambiguity | Should | Medium | 3 |
| REQ-014 | Preserve existing work/run tools | Should | Medium | 2 |

## 1. Executive Summary

Foreman's MCP surface should let agentic clients inspect and update tasks, then query run status without shelling through the Go CLI or scraping human output. The requested product is a focused MCP expansion: task list/get/update operations plus run status queries, implemented at Foreman's existing command/projection boundaries.

This PRD treats MCP as an external integration, not a second domain model. Reads come from `ProjectionStore`; mutations go through `CommandGateway.dispatch_operator/2`; all failures return structured MCP tool errors. Existing task and run projections stay the source of truth.

Foreman mode auto-selected STANDARD depth. Interviews were skipped under `--foreman`; unresolved product choices are marked inline with explicit clarification markers.

## 2. Background and Evidence

### 2.1 Current codebase shape

Foreman is a multi-package repo:

- `packages/foreman_server` — Elixir/Phoenix/OTP backend, event store, projections, scheduler, MCP server.
- `packages/foreman_cli` — Go CLI.
- `packages/jido_harness` — Elixir harness integration.

The MCP implementation lives under `packages/foreman_server/lib/foreman_server/mcp/`. `ForemanServer.MCP.Tools` owns tool schemas and handlers; `ForemanServer.MCP.Policy` hides/refuses write tools when MCP workflow writes are disabled; both HTTP and stdio transports share dispatch.

### 2.2 Relevant existing contracts

- `CommandGateway.dispatch_operator/2` is the public mutation boundary. Its allowed operator commands include `task.create`, `task.approve`, `task.retry`, `task.update`, `run.cancel`, `run.remove`, and `run.reset`.
- `ProjectionStore.task_projection/1`, `ProjectionStore.list_tasks/0`, and `ProjectionStore.run/1` are the read model surfaces for task and run details.
- Existing docs describe always-advertised read tools and gated write tools under `allow_workflow_writes`.
- Existing docs and tests already mention `foreman_task_list`, `foreman_task_get`, and `foreman_task_update`; the TRD must verify current implementation before deciding whether this PRD is net-new implementation, correction, or completion work.

### 2.3 Product problem

MCP clients need direct task and run status operations. Without them, agents must compose lower-level run/work reads, use CLI commands, or guess state from logs. That makes workflow automation brittle and increases divergence between HTTP, stdio MCP, CLI docs, and domain command policy.

## 3. Personas

### 3.1 Agentic MCP client operator

Uses Pi, Claude Code, or another MCP-aware client to create, inspect, update, and monitor Foreman work. Needs concise machine-readable task and run state.

### 3.2 Foreman maintainer

Needs MCP capabilities to stay aligned with aggregate contracts, projection shapes, authorization policy, docs, and tests.

### 3.3 Automation workflow

Runs Foreman operations unattended. Needs stable errors, no silent policy bypass, and enough run status detail to make next-step decisions.

## 4. Scope

### In scope

- MCP task list, get, and update tools.
- MCP run status query surface.
- Schema, handler, policy, telemetry, docs, and tests for those tools.
- HTTP and stdio parity.
- Explicit task-status and run-status semantics.

### Out of scope

- New Foreman domain lifecycle states.
- New Go CLI commands unless required only for documentation parity.
- Bulk task mutation.
- Streaming run watch.
- New workflow submission behavior.
- Bypassing `CommandGateway` or `ProjectionStore`.

## 5. Assumptions From Foreman Mode

- Primary user is an MCP-capable agent or automation client.
- Existing MCP server remains hosted by `packages/foreman_server`.
- Task updates mutate only already-supported public task fields.
- Run status query should be cheaper and more focused than fetching all run artifacts, but the exact surface remains unresolved [NEEDS CLARIFICATION: Should run status be a new `foreman_run_status` tool or a narrowed mode/field on `foreman_run_get`?].
- Task writes use the existing MCP write policy unless a separate task-write flag is requested [NEEDS CLARIFICATION: Should task mutations share `allow_workflow_writes`, or should task writes have a separate `allow_task_writes` policy?].

## 6. Requirements

### 6a. Task Operation Tools

### REQ-001: Advertise task operation tools consistently

Priority: Must  
Complexity: Medium

MCP clients MUST be able to discover the task operation tools that Foreman supports.

- AC-001-1: Given MCP write policy permits task writes, when a client calls `tools/list`, then task operation schemas include `foreman_task_list`, `foreman_task_get`, and `foreman_task_update`.
- AC-001-2: Given MCP write policy denies writes, when a client calls `tools/list`, then read-only task tools are still advertised and task mutation tools are omitted.
- AC-001-3: Given a task tool schema is advertised, when a JSON Schema validator checks it, then required fields, optional fields, types, and enums match the handler contract.

### REQ-002: List tasks through MCP

Priority: Must  
Complexity: Medium

MCP clients MUST be able to list task projections with safe filtering.

- AC-002-1: Given tasks exist, when a client calls `foreman_task_list`, then the response contains task projections and a total count.
- AC-002-2: Given `project_id` is provided, when a client lists tasks, then only tasks belonging to that project are returned.
- AC-002-3: Given `status` is provided, when a client lists tasks, then only tasks matching that status are returned; the accepted status enum is explicit [NEEDS CLARIFICATION: What is the canonical MCP task status enum: `open/ready/in_progress/blocked/closed/failed`, aggregate status values, provider status values, or a mapped subset?].

### REQ-003: Get one task through MCP

Priority: Must  
Complexity: Low

MCP clients MUST be able to fetch a single task projection by ID.

- AC-003-1: Given a known `task_id`, when a client calls `foreman_task_get`, then the full current task projection is returned.
- AC-003-2: Given an unknown `task_id`, when a client calls `foreman_task_get`, then the tool returns a typed `NOT_FOUND` error and no empty placeholder.

### REQ-004: Update mutable task fields through MCP

Priority: Must  
Complexity: High  
Risk: Task mutation can corrupt lifecycle state if it bypasses aggregate policy.

MCP clients MUST be able to update supported mutable task fields through the existing operator command path.

- AC-004-1: Given write policy permits task writes and a client supplies `title`, `description`, `priority`, or `status`, when it calls `foreman_task_update`, then Foreman dispatches `task.update` through `CommandGateway.dispatch_operator/2`.
- AC-004-2: Given no mutable fields are supplied, when `foreman_task_update` is called, then the tool returns `INVALID_PARAMS` and dispatches no command.
- AC-004-3: Given unsupported fields are supplied, when `foreman_task_update` is called, then unknown fields are rejected or stripped according to the normalized boundary contract [NEEDS CLARIFICATION: Should unknown MCP task update fields be rejected with `INVALID_PARAMS` or silently dropped by schema/key normalization?].
- AC-004-4: Given a successful update, when the tool responds, then the response includes the command result or refreshed task projection consistently [NEEDS CLARIFICATION: Should mutation tools return the gateway command result only, or a refreshed projection after synchronous projection apply?].

### REQ-005: Preserve task lifecycle policy

Priority: Must  
Complexity: High  
Risk: External clients may try to set status values that conflict with scheduler-owned transitions.

Task updates MUST NOT allow MCP clients to bypass Foreman's lifecycle protections.

- AC-005-1: Given a task is in a lifecycle state where a requested status transition is invalid, when MCP calls `foreman_task_update`, then the aggregate rejects the command and the MCP error preserves the structured domain reason.
- AC-005-2: Given MCP updates `status`, when the status maps to a provider-tracked task state, then Foreman does not directly mutate external provider state unless the domain command already supports that behavior [NEEDS CLARIFICATION: Should MCP task status updates sync to Beads/task providers, or remain Foreman-projection-only events?].
- AC-005-3: Given a running task is bound to a run, when an MCP client attempts to close or fail it manually, then the outcome follows the existing aggregate contract and cannot fabricate run completion.
- AC-005-4: Given the TRD implements task update, when it chooses allowed fields and status transitions, then it verifies the choice against `ForemanServer.Aggregates.Task` and pins each accepted/rejected transition with tests.

### 6b. Run Status Query

### REQ-006: Expose run status queries

Priority: Must  
Complexity: Medium

MCP clients MUST be able to query the status of one run without inferring it from logs or events.

- AC-006-1: Given a known `run_id`, when a client uses the run status query surface, then the response includes at minimum `run_id`, `status`, terminal indicator if available, current phase summary if available, task/work linkage if available, and last known update timestamp if available [NEEDS CLARIFICATION: Which exact fields are mandatory for the v1 run status payload?].
- AC-006-2: Given an unknown `run_id`, when a client queries run status, then the tool returns typed `NOT_FOUND`.
- AC-006-3: Given a terminal run, when status is queried, then the response clearly distinguishes `completed`, `failed`, and `cancelled` from active states.

### REQ-007: Keep read/write policy default-safe

Priority: Must  
Complexity: High  
Risk: Tool inventory may accidentally expose mutations in default installs.

MCP policy MUST keep reads available by default and writes denied unless enabled.

- AC-007-1: Given default MCP config, when `tools/list` is called, then read tools including task list/get and run status are advertised.
- AC-007-2: Given default MCP config, when `foreman_task_update` is called directly despite not being advertised, then the call is refused before command dispatch.
- AC-007-3: Given writes are enabled, when task update is advertised, then the same authorization and policy path gates HTTP and stdio transports.

### REQ-008: Share behavior across MCP transports

Priority: Must  
Complexity: Medium

HTTP and stdio MCP transports MUST expose identical tools and handler behavior.

- AC-008-1: Given the same config and tool arguments, when a client calls over HTTP and stdio, then schemas, success payloads, and errors are equivalent.
- AC-008-2: Given a tool is added or removed, when tests run, then they prove both transports use the shared dispatch/tool registry rather than duplicated tool lists.

### REQ-009: Return typed MCP errors

Priority: Must  
Complexity: Medium

All task and run status failures MUST be represented as MCP tool errors, not transport-level crashes.

- AC-009-1: Given required params are missing, when a task or run status tool is called, then the tool returns `INVALID_PARAMS` naming the missing key.
- AC-009-2: Given a domain command fails, when `foreman_task_update` handles it, then the MCP response uses a typed domain error and includes the inspectable reason without leaking secrets.
- AC-009-3: Given a projection or event-store read fails, when the read tool handles it, then failure is not converted to an empty success.

### REQ-010: Emit safe telemetry

Priority: Must  
Complexity: Low

Foreman MUST emit enough telemetry to debug tool usage without leaking task content.

- AC-010-1: Given a task or run status tool completes, when telemetry is emitted, then metadata includes tool name, outcome, and duration only.
- AC-010-2: Given a task description or title is updated, when telemetry/logging occurs, then the content is not logged unless existing Foreman policy already allows it.

### 6c. Documentation, Tests, and Compatibility

### REQ-011: Document tool inventory and behavior

Priority: Should  
Complexity: Medium

Operator documentation SHOULD describe the new MCP task and run status behavior.

- AC-011-1: Given implementation is complete, when `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md` are reviewed, then MCP tool inventory, read/write gating, task update semantics, and run status payload behavior match the code.
- AC-011-2: Given a tool is intentionally unavailable in default config, when docs list it, then they state whether it is hidden, refused, or always available.

### REQ-012: Cover task/run query edge cases with tests

Priority: Should  
Complexity: Medium

The implementation SHOULD include tests for success, policy refusal, invalid params, and not-found cases.

- AC-012-1: Given task list/get/update tests run, then they cover success, unknown task, missing arguments, no-op update, and denied writes.
- AC-012-2: Given run status tests run, then they cover active, terminal, and unknown runs.
- AC-012-3: Given docs and schemas claim accepted status values, when tests run, then each accepted value has at least schema or handler coverage.

### REQ-013: Avoid pagination and ordering ambiguity

Priority: Should  
Complexity: Medium

Task listing SHOULD define ordering and bounds so clients can rely on stable output.

- AC-013-1: Given many tasks exist, when `foreman_task_list` is called, then ordering is deterministic [NEEDS CLARIFICATION: Should default order be created-at descending, updated-at descending, priority, provider order, or projection insertion order?].
- AC-013-2: Given many tasks exist, when the list would exceed the response limit, then pagination or truncation behavior is explicit [NEEDS CLARIFICATION: What default and maximum page sizes should MCP task listing enforce?].
- AC-013-3: Given pagination is supported, when a client requests the next page, then no task is skipped or duplicated under a stable projection snapshot.

### REQ-014: Preserve existing work/run tools

Priority: Should  
Complexity: Medium

Adding task operations and run status SHOULD NOT break existing work and run tools.

- AC-014-1: Given existing MCP clients call `foreman_work_get`, `foreman_run_get`, `foreman_run_get_events`, `foreman_run_get_activity`, or `foreman_run_get_logs`, when this feature ships, then existing success and error shapes remain compatible.
- AC-014-2: Given run status is implemented as a new tool or a narrowed `foreman_run_get` mode, when clients use the existing full `foreman_run_get`, then its current behavior remains supported.

## 7. Dependency Map

| Requirement | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | REQ-007, REQ-008 | Tool registry decision | Tool discovery must reflect policy. |
| REQ-002 | None | Status enum/order/page decisions | Read-only projection query. |
| REQ-003 | None | None | Read-only projection query. |
| REQ-004 | REQ-005, REQ-007, REQ-009 | Task update aggregate contract | Mutation path must stay command-gated. |
| REQ-005 | None | Aggregate transition audit | Prevent lifecycle bypass. |
| REQ-006 | None | New-tool-vs-mode decision | Read-only run projection query. |
| REQ-007 | REQ-001, REQ-004 | Policy flag decision | Default-safe inventory. |
| REQ-008 | REQ-001 | Shared dispatch tests | Prevent transport drift. |
| REQ-009 | REQ-002, REQ-003, REQ-004, REQ-006 | Error taxonomy choice | No permissive fallback. |
| REQ-010 | REQ-002, REQ-004, REQ-006 | Telemetry metadata review | Privacy constraint. |
| REQ-011 | All behavior reqs | Final implementation shape | Docs after code truth. |
| REQ-012 | REQ-002, REQ-003, REQ-004, REQ-006, REQ-007 | Test fixture stability | Validation gate. |
| REQ-013 | REQ-002 | Pagination/order decisions | Needed before stable client automation. |
| REQ-014 | REQ-006 | Compatibility test coverage | Protect existing MCP clients. |

Implementation clusters:

1. **Read surfaces:** REQ-002, REQ-003, REQ-006, REQ-009.
2. **Mutation surface:** REQ-004, REQ-005, REQ-007, REQ-010.
3. **Transport/tool inventory:** REQ-001, REQ-008, REQ-014.
4. **Docs/tests hardening:** REQ-011, REQ-012, REQ-013.

No circular dependencies identified.

## 8. Technical Dependency Mapping

| Component | Direction | Data/Contract | Notes |
|---|---|---|---|
| `ForemanServer.MCP.Tools` | MCP client → Foreman | Tool schemas, handler dispatch | Primary implementation boundary. |
| `ForemanServer.MCP.Policy` | Foreman → MCP client | Tool advertisement/refusal | Must hide/refuse write tools safely. |
| `ProjectionStore` | Tools → read model | Task/run projections | Source for list/get/status reads. |
| `CommandGateway` | Tools → command boundary | `task.update` operator command | Required for task mutations. |
| `Aggregates.Task` | Command gateway → event | `TaskUpdated` validation | Source of lifecycle truth. |
| HTTP MCP router | Client ↔ server | Streamable HTTP MCP | Must share tool registry. |
| stdio MCP task | Client ↔ server | JSON-RPC stdio | Must share tool registry. |
| Docs | Operator ↔ product | Tool inventory and policy | Must update after behavior changes. |

## 9. Adversarial Review

Foreman mode auto-applied recommended resolutions where safe.

1. **Issue: Run status surface is underspecified.** A full run projection may be too verbose, but a new tool risks tool sprawl.  
   **Resolution:** Keep requirement explicit while marking the new-tool-vs-mode choice for TRD clarification.

2. **Issue: Task status enum can drift across aggregate, provider, and docs.**  
   **Resolution:** Require canonical enum decision and tests against schema/handler behavior.

3. **Issue: Task updates may bypass lifecycle semantics.**  
   **Resolution:** Require `CommandGateway.dispatch_operator/2` and aggregate transition tests.

4. **Issue: Write policy name `allow_workflow_writes` is broader than task mutation.**  
   **Resolution:** Mark separate policy flag as clarification rather than silently expanding operator expectations.

5. **Issue: Task list without pagination/order can become unstable.**  
   **Resolution:** Add REQ-013 with clarification markers for default order and limits.

6. **Issue: Existing repo may already contain partial task-tool implementation.**  
   **Resolution:** Require TRD to verify current code and classify work as add, correct, or complete before changing code.

7. **Issue: Docs can drift from code because CLI docs and user guide already mention MCP tools.**  
   **Resolution:** Add REQ-011 requiring docs to be reconciled after implementation.

Ambiguity scan complete: 9 items marked for clarification.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4.2 | Covers task list/get/update, run status, policy, errors, telemetry, docs, tests. |
| Testability | 4.3 | Every Must/Should req has objective ACs. |
| Clarity | 3.9 | Clear boundaries, but 8 marked decisions remain for TRD/refinement. |
| Feasibility | 4.0 | Uses existing MCP/projection/command paths; risk is status/policy semantics. |
| Overall | 4.1 | PASS |

Gate decision: **PASS**. Save PRD. Concerns remain but are marked inline and suitable for `/ensemble-refine-prd` or TRD decision capture.

## 11. Suggested Next Steps

1. Refine open clarification markers if product decisions are available.
2. Create a TRD: `/ensemble-create-trd docs/PRD/PRD-2026-f6dce877-mcp-tool-update-tasks.md`.
3. Before implementation, verify current MCP code and docs because this workspace already references some requested task tools.
