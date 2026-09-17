---
document_id: PRD-2026-cf992a03
label: prd-agent-inbox-write-tool-run-progress
version: 1.0.0
status: Draft
date: 2026-09-17
scale_depth: STANDARD
total_requirements: 15
total_acceptance_criteria: 39
readiness_score: 4.6
---

# PRD: Agent-Facing Inbox Write Tool for Run Progress Visibility

Foreman task title read from `FOREMAN_TASK_TITLE`: **Add agent-facing inbox write tool for run progress visibility**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 4 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 15/15 (100%) |
| Acceptance criteria coverage | 15/15 (100%) |
| Risk flags | 9 |
| Dependencies | 11 |
| Open ambiguity markers | 4 |
| TRD decisions required | 4 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Expose a write-capable inbox send MCP tool | Must | Medium | 3 |
| REQ-002 | Route inbox.send through the existing command gateway | Must | High | 3 |
| REQ-003 | Preserve write-tool policy and default safety | Must | High | 3 |
| REQ-004 | Validate and normalize input without atom leaks | Must | Medium | 3 |
| REQ-005 | Create deterministic message identifiers for retries | Must | Medium | 3 |
| REQ-006 | Return typed errors and safe success payloads | Must | Medium | 3 |
| REQ-007 | Keep foreman_inbox_get as the read-side verification path | Must | Low | 2 |
| REQ-008 | Instruct bundled workflow agents to post progress | Must | Medium | 3 |
| REQ-009 | Make progress narration useful but non-blocking | Must | Medium | 2 |
| REQ-010 | Protect operator inbox quality and safety | Must | Medium | 3 |
| REQ-011 | Emit telemetry without leaking prompt/output content | Must | Low | 2 |
| REQ-012 | Cover HTTP and stdio MCP parity | Should | Medium | 2 |
| REQ-013 | Document operator-visible behavior | Should | Medium | 2 |
| REQ-014 | Preserve existing logs and activity tools | Should | Low | 2 |
| REQ-015 | Leave delivery-status updates out of v1 | Should | Low | 3 |

## 1. Executive Summary

Foreman already has a per-run inbox read path: `InboxThread` handles `inbox.send`, `ProjectionStore.inbox_thread/1` projects messages, and `foreman_inbox_get` reads them. The missing product behavior is write visibility from the running agent. Today operators can inspect raw stdout/stderr through `foreman_run_get_logs` and liveness through `foreman_run_get_activity`, but cannot see intentional structured progress notes in the operator inbox.

This PRD requires a write-capable MCP tool, named `foreman_inbox_send` unless the TRD finds a better existing convention. The tool lets dispatched agents append concise progress messages to the run's operator inbox. It must route through the event-sourced domain path, obey MCP write policy, and be advertised in bundled workflow prompts so progress narration becomes normal workflow behavior rather than ad hoc stdout.

Foreman mode auto-selected STANDARD depth. Clarifying interviews and adversarial issue confirmations were skipped under `--foreman`; unresolved product choices are marked inline with clarification markers.

## 2. Background and Evidence

Relevant code areas:

- `packages/foreman_server/lib/foreman_server/mcp/tools.ex` owns MCP schemas and handlers.
- `packages/foreman_server/lib/foreman_server/mcp/policy.ex` owns write-tool gating.
- `packages/foreman_server/lib/foreman_server/command_gateway.ex` owns public operator mutations.
- `packages/foreman_server/lib/foreman_server/aggregates/inbox_thread.ex` handles `inbox.send` and `inbox.delivery.update`.
- `packages/foreman_server/lib/foreman_server/projection_store.ex` exposes `inbox_thread/1`.
- `packages/foreman_server/priv/defaults/workflows/prompts/*.md` contains bundled prompts for dispatched agents.

Existing contracts:

- `InboxThread` accepts `run_id`, `message_id`, `body`, and optional `metadata` for `inbox.send`.
- Duplicate `message_id` values are rejected inside a thread.
- `CommandRouter.aggregate_module_for("inbox:" <> _)` already routes inbox streams to `InboxThread`.
- `foreman_inbox_get` reads projected inbox messages and returns an empty message list when no thread exists.
- `CommandGateway.dispatch_operator/2` is the intended public mutation boundary, but currently does not allow `inbox.send`.
- `MCP.Policy` uses a closed write-tool list and hides/refuses write tools when writes are disabled.

## 3. Personas

- **Dispatched agent:** needs a simple tool to report milestones, blockers, and handoff notes.
- **Foreman operator:** needs concise per-run progress updates distinct from logs and heartbeats.
- **Foreman maintainer:** needs event-sourced boundaries, policy, transport parity, docs, and tests preserved.

## 4. Scope

In scope: `foreman_inbox_send`; `inbox.send` gateway allow-listing; MCP schema, validation, handler, policy, telemetry, tests; HTTP/stdio parity; bundled prompt guidance; docs updates.

Out of scope: implementation during this PRD phase; delivery-status write tool; replacing logs/activity tools; streaming inbox UI; new aggregate/projection architecture; separate write-policy flag unless TRD review requires it.

## 5. Assumptions From Foreman Mode

- Primary product name is **Add agent-facing inbox write tool for run progress visibility**.
- First tool name should be `foreman_inbox_send`, matching `foreman_inbox_get`.
- Existing `allow_workflow_writes` should gate this write in v1 because current MCP policy has one closed write-tool list. [NEEDS CLARIFICATION: Should inbox progress writes share `allow_workflow_writes`, or should they have a separate lower-risk `allow_inbox_writes` flag?]
- Messages are operator-facing status notes, not full logs or private scratchpads.
- Agents should post coarse milestone updates, not per-step chatter. [NEEDS CLARIFICATION: What exact default cadence should bundled prompts require: phase start/end only, every major milestone, or time-based updates such as every 5 minutes?]
- Metadata may include `phase_id`, `worker_id`, and `severity`, but runtime availability must be verified. [NEEDS CLARIFICATION: Which worker/run context fields are always available to MCP tool callers at runtime?]

## 6. Requirements

### REQ-001: Expose a write-capable inbox send MCP tool

Priority: Must
Complexity: Medium
Risk: Tool schemas can drift from handlers.

MCP clients MUST be able to discover and call a write tool that appends one operator-inbox message to a run.

- AC-001-1: Given MCP write policy permits the tool, when a client calls `tools/list`, then `foreman_inbox_send` is advertised with JSON Schema fields for `run_id`, `body`, optional `message_id`, and optional metadata.
- AC-001-2: Given valid arguments, when a client calls `foreman_inbox_send`, then an inbox message is appended to the run's `inbox:<run_id>` stream.
- AC-001-3: Given the schema is advertised, when validated, then required fields, optional fields, types, and maximum lengths match the handler contract.

### REQ-002: Route inbox.send through the existing command gateway

Priority: Must
Complexity: High
Risk: Bypassing the gateway would create a second public mutation path.

The tool MUST dispatch `inbox.send` through Foreman's public mutation boundary, not by writing projections, appending events directly, or calling aggregates manually.

- AC-002-1: Given `foreman_inbox_send` dispatches a valid message, when implementation is inspected, then it uses `CommandGateway.dispatch_operator/2` or another existing public operator path approved by the TRD.
- AC-002-2: Given `CommandGateway.dispatch_operator/2` is used, when `inbox.send` is submitted, then the gateway explicitly allows `inbox.send` and validates the same envelope fields as other operator commands.
- AC-002-3: Given any other inbox command is submitted through the operator path without explicit allow-listing, when dispatch runs, then it returns `{:error, {:command_not_allowed, type}}` or a typed invalid-envelope error.

### REQ-003: Preserve write-tool policy and default safety

Priority: Must
Complexity: High
Risk: Default MCP installs could expose mutation unexpectedly.

Inbox sending MUST be treated as a write tool and denied by default unless configured write policy permits it.

- AC-003-1: Given default MCP config, when a client calls `tools/list`, then `foreman_inbox_send` is not advertised.
- AC-003-2: Given default MCP config, when a client directly calls `foreman_inbox_send`, then MCP policy refuses it before command dispatch.
- AC-003-3: Given writes are enabled, when a client calls through HTTP or stdio MCP, then both transports use the same policy decision.

### REQ-004: Validate and normalize input without atom leaks

Priority: Must
Complexity: Medium
Risk: User-supplied metadata can create atom leaks or inconsistent shapes.

The tool MUST accept only schema-declared top-level fields and safe JSON-compatible metadata.

- AC-004-1: Given `run_id` or `body` is missing or blank, when `foreman_inbox_send` is called, then it returns `INVALID_PARAMS` and dispatches no command.
- AC-004-2: Given undeclared top-level arguments are supplied through MCP transport, when dispatch normalizes arguments, then undeclared keys do not create atoms.
- AC-004-3: Given metadata is supplied, when the tool builds the payload, then metadata remains JSON-safe and excludes prompt/output secrets by default.

### REQ-005: Create deterministic message identifiers for retries

Priority: Must
Complexity: Medium
Risk: Retry behavior can duplicate progress notes or falsely report failure.

The tool MUST handle `message_id` and `command_id` so retrying a status update is safe.

- AC-005-1: Given a client supplies `message_id`, when the tool dispatches, then the payload uses that exact message ID after validation.
- AC-005-2: Given a client omits `message_id`, when the tool dispatches, then Foreman generates a collision-resistant message ID and returns it.
- AC-005-3: Given the same message is retried with the same `message_id`, when the aggregate reports an existing message, then the MCP response maps it to either idempotent success or a typed duplicate error, pinned by tests. [NEEDS CLARIFICATION: Should duplicate `message_id` be reported as success with the existing message ID, or as a typed `ALREADY_EXISTS` error?]

### REQ-006: Return typed errors and safe success payloads

Priority: Must
Complexity: Medium
Risk: Generic errors make agent recovery impossible.

The tool MUST expose clear MCP error codes and a bounded success DTO.

- AC-006-1: Given command dispatch succeeds, when the tool responds, then it returns JSON containing at least `run_id`, `message_id`, and `status: "sent"`.
- AC-006-2: Given dispatch fails due to domain validation, when the tool responds, then the MCP error preserves a typed code and safe reason, never success-with-error.
- AC-006-3: Given an unknown run is supplied, when product behavior is implemented, then the TRD either proves pre-run inbox creation is acceptable or adds a run-existence check returning `NOT_FOUND`; the chosen behavior is tested.

### REQ-007: Keep foreman_inbox_get as the read-side verification path

Priority: Must
Complexity: Low

Operators and agents MUST verify appended messages through the existing read tool.

- AC-007-1: Given `foreman_inbox_send` succeeds, when `foreman_inbox_get` is called for the same `run_id`, then the new message appears in deterministic order.
- AC-007-2: Given a run has no inbox messages, when `foreman_inbox_get` is called, then it returns `{run_id, messages: []}` and is not confused with write failure.

### REQ-008: Instruct bundled workflow agents to post progress

Priority: Must
Complexity: Medium
Risk: A tool with no prompt instruction will remain unused in normal runs.

Bundled workflow prompts MUST tell dispatched agents to use the inbox write tool for operator-facing progress.

- AC-008-1: Given bundled prompts are installed, when an agent runs a standard phase, then the prompt tells it to call `foreman_inbox_send` for major progress updates when available.
- AC-008-2: Given a bundled prompt is edited, when implementation is complete, then `foreman init --force` is documented or run as needed so runtime prompts do not stay stale.
- AC-008-3: Given a phase does not need progress narration, when the prompt executes, then lack of inbox writes does not fail the phase by itself.

### REQ-009: Make progress narration useful but non-blocking

Priority: Must
Complexity: Medium
Risk: Required frequent updates can distract agents and inflate tool usage.

Agents SHOULD post concise milestones without turning inbox writes into mandatory busywork.

- AC-009-1: Given an agent starts, reaches a material milestone, hits a blocker, or finishes a phase, when `foreman_inbox_send` is available, then prompt guidance tells it to send a concise note with current state and next action.
- AC-009-2: Given the inbox write tool is denied, unavailable, or fails, when an agent attempts to report progress, then prompt guidance tells it to continue work and mention the failed status update in the final artifact only if relevant.

### REQ-010: Protect operator inbox quality and safety

Priority: Must
Complexity: Medium
Risk: Inbox can become noisy or leak sensitive content.

Inbox progress messages MUST be concise and safe for operator consumption.

- AC-010-1: Given a message body exceeds the configured maximum length, when `foreman_inbox_send` is called, then it returns `INVALID_PARAMS` or truncates only if schema explicitly declares truncation.
- AC-010-2: Given a progress message would contain secrets, private prompts, or large logs, when prompt guidance is followed, then agents do not send that content through the inbox.
- AC-010-3: Given multiple notes are sent by one phase, when an operator reads the inbox, then messages include enough context to distinguish phase/source.

### REQ-011: Emit telemetry without leaking prompt/output content

Priority: Must
Complexity: Low

Foreman MUST record operational telemetry for the new write tool without storing message bodies in telemetry metadata.

- AC-011-1: Given `foreman_inbox_send` succeeds or fails, when telemetry is captured, then the tool name and outcome are recorded.
- AC-011-2: Given telemetry metadata is inspected, then it does not include full `body`, prompt text, command output, or secrets.

### REQ-012: Cover HTTP and stdio MCP parity

Priority: Should
Complexity: Medium

Both MCP transports SHOULD expose and execute the same inbox write behavior.

- AC-012-1: Given HTTP and stdio MCP components are listed, when tool names are compared, then both include or both omit `foreman_inbox_send` according to policy.
- AC-012-2: Given valid calls through both transports, when the same message is sent, then both paths normalize arguments the same way and produce equivalent command payloads.

### REQ-013: Document operator-visible behavior

Priority: Should
Complexity: Medium

Foreman's operator and agent documentation SHOULD describe the new inbox progress path.

- AC-013-1: Given this feature is implemented, when docs are reviewed, then `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, and `AGENTS.md` are either updated or explicitly recorded as not needing edits with a reason.
- AC-013-2: Given an operator wants run visibility, when docs are read, then they distinguish `foreman_inbox_get`/`foreman_inbox_send` from `foreman_run_get_logs` and `foreman_run_get_activity`.

### REQ-014: Preserve existing logs and activity tools

Priority: Should
Complexity: Low

The new inbox write path SHOULD complement, not replace, existing run inspection tools.

- AC-014-1: Given `foreman_inbox_send` is added, when existing MCP run-detail tests run, then `foreman_run_get_logs`, `foreman_run_get_events`, `foreman_run_get_activity`, and `foreman_inbox_get` keep existing semantics.
- AC-014-2: Given an operator debugs a run, when inbox progress is insufficient, then raw logs and activity tools remain available as lower-level evidence.

### REQ-015: Leave delivery-status updates out of v1

Priority: Should
Complexity: Low

The first release SHOULD avoid delivery-status mutation unless a separate product need is approved.

- AC-015-1: Given `InboxThread` supports `inbox.delivery.update`, when this feature lands, then no `foreman_inbox_delivery_update` MCP tool is exposed unless a TRD expands scope.
- AC-015-2: Given delivery-status updates remain internal, when tool policy is inspected, then only `foreman_inbox_send` is added for inbox writes.
- AC-015-3: Given future work needs delivery statuses, when a new PRD/TRD is created, then it can reuse this feature's policy, schema, and projection patterns.

## 7. Non-Functional Requirements

- Security: default-deny write policy; no secret leakage in telemetry or prompts.
- Reliability: event-sourced command path; idempotent message IDs.
- Observability: MCP telemetry plus read-side verification.
- Performance: coarse progress notes, not high-frequency streaming.
- Maintainability: no duplicate mutation path; docs and tests pin the contract.

## 8. Dependency Map

| Requirement | Depends On | Notes |
|---|---|---|
| REQ-001 | — | Defines the external tool surface. |
| REQ-002 | REQ-001 | Tool implementation needs a mutation path. |
| REQ-003 | REQ-001 | Policy must know the new write tool name. |
| REQ-004 | REQ-001 | Schema and boundary validation. |
| REQ-005 | REQ-002, REQ-004 | Idempotency relies on valid message and command IDs. |
| REQ-006 | REQ-002, REQ-005 | Error/success mapping wraps dispatch outcomes. |
| REQ-007 | REQ-001, REQ-002 | Read-side proof after write. |
| REQ-008 | REQ-001, REQ-003 | Prompts can instruct use after tool and policy exist. |
| REQ-009 | REQ-008 | Defines behavioral cadence. |
| REQ-010 | REQ-008, REQ-009 | Quality and safety constraints on message bodies. |
| REQ-011 | REQ-001, REQ-006 | Telemetry wraps the tool call. |
| REQ-012 | REQ-001, REQ-003 | Transport parity depends on common wiring. |
| REQ-013 | REQ-001, REQ-008 | Docs describe visible behavior after contract stabilizes. |
| REQ-014 | REQ-001 | Existing tools must not regress. |
| REQ-015 | — | Explicit scope boundary. |

Requirement clusters: MCP contract (REQ-001 through REQ-007, REQ-011, REQ-012), agent behavior (REQ-008 through REQ-010), and docs/compatibility (REQ-013 through REQ-015). No circular dependencies identified.

## 9. Adversarial Review

1. **Write policy may be too broad.** Reusing `allow_workflow_writes` may be too coarse. Resolution: require default-deny behavior now and mark separate-flag choice for clarification.
2. **Duplicate retry semantics are ambiguous.** `InboxThread` rejects duplicate `message_id`, but retries may need idempotent success. Resolution: require deterministic IDs and a tested TRD decision.
3. **Prompt instruction may not provide `run_id`.** Resolution: require TRD verification of runtime context availability and metadata shape.
4. **Inbox spam could reduce visibility.** Resolution: require coarse milestone guidance and message length/safety constraints.
5. **Logs/activity tools remain necessary.** Resolution: explicitly preserve existing run-detail tool behavior.

## 10. Implementation Readiness Gate

| Dimension | Score | Rationale |
|---|---:|---|
| Completeness | 4.6 | Covers tool surface, routing, policy, prompts, docs, tests, telemetry, and non-goals. |
| Testability | 4.7 | All Must/Should requirements have concrete ACs; ambiguity markers become TRD decisions. |
| Clarity | 4.4 | Main behavior is clear; policy flag, duplicate semantics, and runtime context need clarification. |
| Feasibility | 4.7 | Reuses existing aggregate, projection, MCP, and gateway patterns. |

Overall readiness score: **4.6 PASS**

Gate decision: **PASS — save the PRD.**

Ambiguity scan complete: 4 items marked for clarification.

## 11. Suggested Next Step

```bash
/ensemble-create-trd docs/PRD/PRD-2026-cf992a03-agent-inbox-write-tool-run-progress.md
```
