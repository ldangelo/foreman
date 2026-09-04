---
document_id: PRD-2026-6bc2fec8
label: prd-messaging-stall-detection
version: 1.0.0
status: Draft
date: 2026-09-04
scale_depth: STANDARD
total_requirements: 15
total_acceptance_criteria: 40
readiness_score: 4.1
---

# PRD: Use messaging stall detection and failure reporting

Foreman task title read from `FOREMAN_TASK_TITLE`: **Use messaging stall detection and failure reporting**

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
| Risk flags | 11 |
| Dependencies | 11 |
| Open ambiguity markers | 12 |
| TRD decisions required | 8 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Define stallable execution scopes | Must | Medium | 3 |
| REQ-002 | Track output activity from worker events | Must | High | 3 |
| REQ-003 | Track messaging activity from inbox events | Must | Medium | 2 |
| REQ-004 | Configure stall thresholds safely | Must | Medium | 3 |
| REQ-005 | Detect agent-phase stalls without false positives | Must | High | 3 |
| REQ-006 | Detect messaging stalls without false positives | Must | High | 3 |
| REQ-007 | Report detected stalls as failure facts | Must | High | 3 |
| REQ-008 | Alert operators about stuck tasks | Must | Medium | 2 |
| REQ-009 | Preserve existing liveness semantics | Must | High | 3 |
| REQ-010 | Keep detection idempotent | Must | Medium | 2 |
| REQ-011 | Expose stall state in projections | Must | Medium | 3 |
| REQ-012 | Provide operational observability | Should | Medium | 2 |
| REQ-013 | Document operator recovery paths | Should | Low | 2 |
| REQ-014 | Test boundary and race conditions | Should | Medium | 3 |
| REQ-015 | Avoid new transport-specific behavior | Should | Medium | 3 |

## 1. Executive Summary

Foreman already has worker heartbeat liveness and run-level stuck detection. Those mechanisms catch dead or idle runs, but they do not explicitly express the product-level stall this task asks for: a long-running messaging or agent phase that is still alive yet has produced no useful output for too long.

This PRD defines configurable stall detection for active phases based on durable Foreman events, not raw log scraping. Agent-phase output activity comes from worker event streams such as stdout, stderr, assistant messages, tool-call completions, and phase lifecycle events. Messaging activity comes from Foreman's inbox/message projections. When a phase stalls past a threshold, Foreman records a clear failure/attention fact, alerts operators, and avoids silently leaving tasks in an apparently progressing state.

Foreman mode auto-selected STANDARD depth. Interviews and adversarial issue prompts were skipped under `--foreman`; unresolved choices are marked inline with `[NEEDS CLARIFICATION: ...]` for PRD refinement.

## 2. Background and Evidence

### 2.1 Current codebase shape

Foreman is a multi-package repo:

- `packages/foreman_server` — Elixir/Phoenix/OTP backend, event store, projections, scheduler, Overwatch, worker protocol, MCP, and recovery.
- `packages/foreman_cli` — Go CLI and operator surfaces.
- `packages/jido_harness` — Elixir harness integration.

Relevant current contracts found during reconnaissance:

- `ForemanServer.StuckDetector` periodically scans active run projections and dispatches `run.flag_stuck` after an idle threshold, defaulting to 15 minutes.
- `ProjectionStore.stuck_runs/2` derives stuck candidates from active run `last_event_at_ms`.
- `RunExecutorLiveness` publishes active invocation deadlines so a long but in-time agent call is not incorrectly flagged stuck.
- `Overwatch.Tracker` emits `WorkerUnresponsive` when heartbeat timeout expires, defaulting to 60 seconds.
- Worker output is persisted through `WorkerStdout`, `WorkerStderr`, `AssistantMessage`, `ToolCallFinished`, `WorkerHeartbeat`, `WorkerStarted`, and `WorkerExited` style event records.
- Inbox behavior is represented by `InboxMessageAppended` and `InboxDeliveryUpdated` projections.

### 2.2 Product problem

Operators need Foreman to detect phases that appear alive but make no visible progress. Today a run can have heartbeat/liveness signals while not producing meaningful output, or a messaging phase can wait indefinitely for mail/inbox progress. The requested product should convert those silent stalls into explicit failure/attention reporting so operators can recover tasks before pipeline wall-clock limits or manual inspection are required.

## 3. Personas

### 3.1 Foreman operator

Runs multi-phase Foreman tasks and needs stuck work to become visible with enough context to choose reset, retry, kill-switch, or manual intervention.

### 3.2 Foreman maintainer

Needs stall detection to reuse event/projection boundaries, avoid duplicate liveness systems, and keep tests deterministic.

### 3.3 Automation client

Consumes run/task status and inbox signals programmatically. Needs machine-readable stall facts instead of human-only log text.

## 4. Scope

### In scope

- Detect no-output stalls for active agent phases.
- Detect no-message-progress stalls for active messaging phases.
- Configurable thresholds with safe defaults.
- Failure/attention reporting when stalls are detected.
- Operator alert visibility in existing status, inbox, debug, or projection surfaces [NEEDS CLARIFICATION: Which operator surface is the primary alert destination: task status, inbox, cockpit attention lane, CLI stderr, or all of these?].
- Tests for event-driven activity, idempotency, race handling, and threshold behavior.
- Documentation of configuration and recovery behavior.

### Out of scope

- Replacing `StuckDetector`, `RunExecutorLiveness`, or `Overwatch.Tracker`.
- Scraping raw log files as authoritative activity.
- New agent provider behavior or SDK changes.
- Auto-killing operating-system processes unless the existing recovery path already owns that behavior [NEEDS CLARIFICATION: Should stall detection only report failures, or also terminate/restart the stalled worker automatically?].
- New messaging product features unrelated to stall detection.

## 5. Assumptions From Foreman Mode

- "Output" means durable worker/projection activity visible to Foreman, not terminal bytes that bypass event persistence.
- Agent-phase stalls use a separate no-output threshold from heartbeat timeout and pipeline wall-clock budget.
- Messaging stalls apply only to phases explicitly classified as messaging/waiting phases [NEEDS CLARIFICATION: What exact workflow phase metadata identifies a "messaging phase"?].
- The first release should fail/flag the run or phase and alert the operator rather than silently retrying.
- Existing recovery operations remain operator-controlled unless a later PRD/TRD requests auto-remediation.

## 6. Requirements

### 6a. Activity Model

### REQ-001: Define stallable execution scopes

Priority: Must
Complexity: Medium
Risk: If scope classification is fuzzy, normal long-running phases may be flagged incorrectly.

Foreman MUST distinguish agent-phase stall detection from messaging-phase stall detection.

- AC-001-1: Given a workflow phase is executing through the agent/worker path, when stall detection evaluates it, then it uses the agent-phase activity model.
- AC-001-2: Given a workflow phase is classified as messaging/waiting, when stall detection evaluates it, then it uses the messaging activity model [NEEDS CLARIFICATION: Should classification come from phase name, workflow metadata, prompt command type, or runtime event type?].
- AC-001-3: Given a run is terminal (`completed`, `failed`, `cancelled`, `stuck`, or blocked by an explicit operator decision), when stall detection scans, then no new stall report is emitted for that run.

### REQ-002: Track output activity from worker events

Priority: Must
Complexity: High
Risk: Output activity can drift if one worker event type updates liveness and another does not.

Foreman MUST derive agent-phase no-output activity from durable worker/phase events.

- AC-002-1: Given a worker emits stdout, stderr, assistant message, tool-call completion, phase start, phase completion, or phase failure, when projections update, then the active phase's output-activity timestamp advances.
- AC-002-2: Given only heartbeat events occur, when no-output stall detection evaluates the phase, then heartbeat alone does not count as output activity [NEEDS CLARIFICATION: Should heartbeat-only progress ever extend the no-output deadline for providers known to suppress streaming output?].
- AC-002-3: Given a raw compatibility log file changes without a corresponding persisted worker event, when stall detection evaluates activity, then the raw file change is ignored.

### REQ-003: Track messaging activity from inbox events

Priority: Must
Complexity: Medium
Risk: Inbox delivery and message append events can represent different kinds of progress.

Foreman MUST derive messaging activity from existing inbox/message events and projections.

- AC-003-1: Given an inbox message is appended for the run, when messaging stall detection evaluates the phase, then the messaging-activity timestamp advances.
- AC-003-2: Given only a delivery/read-status update occurs, when messaging stall detection evaluates the phase, then Foreman treats it according to the configured activity policy [NEEDS CLARIFICATION: Do delivery/read acknowledgements count as messaging progress, or only new messages?].

### REQ-004: Configure stall thresholds safely

Priority: Must
Complexity: Medium
Risk: Thresholds that default too low create noisy false failures; thresholds that default too high hide stuck tasks.

Operators MUST be able to configure no-output and messaging stall thresholds.

- AC-004-1: Given no custom config is set, when Foreman starts, then no-output stall detection uses a documented safe default [NEEDS CLARIFICATION: Is the desired default 15 minutes to match `StuckDetector`, 5 minutes, or workflow-specific?].
- AC-004-2: Given config sets a non-positive threshold, when Foreman validates config, then detection is disabled only when the documented disable value is used; malformed values fail loudly.
- AC-004-3: Given a phase declares an override threshold, when detection evaluates that phase, then the phase override wins over application default if the override is valid [NEEDS CLARIFICATION: Are per-phase YAML overrides required for v1?].

### 6b. Stall Detection

### REQ-005: Detect agent-phase stalls without false positives

Priority: Must
Complexity: High
Risk: Long-running tools and quiet model calls may be legitimate within their own timeout window.

Foreman MUST detect active agent phases that exceed the no-output threshold while respecting existing invocation deadlines.

- AC-005-1: Given an agent phase has output activity within the configured threshold, when the detector scans, then no stall report is emitted.
- AC-005-2: Given an agent phase has no output activity for at least the threshold and is not exempted by an explicit in-flight deadline policy, when the detector scans, then a stall is reported once.
- AC-005-3: Given an agent invocation has a valid future timeout deadline from `RunExecutorLiveness`, when no output has occurred, then the detector follows the documented exemption policy rather than contradicting `StuckDetector` [NEEDS CLARIFICATION: Should no-output stalls ignore, shorten, or respect `RunExecutorLiveness` deadlines?].

### REQ-006: Detect messaging stalls without false positives

Priority: Must
Complexity: High
Risk: Some messaging phases intentionally wait for humans or external systems.

Foreman MUST detect messaging phases that have not produced message progress for the configured threshold.

- AC-006-1: Given a messaging phase is waiting and inbox/message activity occurs within the threshold, when the detector scans, then no stall report is emitted.
- AC-006-2: Given a messaging phase has no message activity for at least the threshold, when the detector scans, then Foreman reports a messaging stall with run, task, phase, and idle duration.
- AC-006-3: Given a phase is explicitly waiting for operator input, when detection scans, then the configured wait-for-human policy is applied [NEEDS CLARIFICATION: Should explicit operator-wait phases be exempt, warned only, or failed after threshold?].

### REQ-007: Report detected stalls as failure facts

Priority: Must
Complexity: High
Risk: Reporting only through logs would preserve the current silent-failure problem.

Foreman MUST convert stall detections into durable failure/attention facts.

- AC-007-1: Given a stall is detected, when Foreman records it, then the durable event/projection includes run ID, task ID when known, phase name/index, stall kind (`agent_no_output` or `messaging_no_progress`), threshold, idle duration, and detected timestamp.
- AC-007-2: Given the stall reporting path mutates run or task state, when it dispatches, then it uses existing aggregate command boundaries rather than writing projections directly.
- AC-007-3: Given a stall is recorded, when status/debug/inbox surfaces render the run, then they show a human-readable failure reason rather than a generic timeout.

### REQ-008: Alert operators about stuck tasks

Priority: Must
Complexity: Medium
Risk: A durable event without a visible operator surface still leaves work unattended.

Foreman MUST surface stall reports to operators through existing attention channels.

- AC-008-1: Given a stall is detected, when the operator views active/attention task or run status, then the stalled task/run is visible with the stall reason.
- AC-008-2: Given an inbox/Agent Mail surface is enabled for the run, when a stall is detected, then Foreman creates or exposes an operator-facing alert message [NEEDS CLARIFICATION: Should alert messages be persisted as `InboxMessageAppended`, a separate event, or projection-only attention metadata?].

### REQ-009: Preserve existing liveness semantics

Priority: Must
Complexity: High
Risk: Duplicating liveness logic can break worker recovery and run stuck detection.

Stall detection MUST complement, not replace, heartbeat and run-stuck mechanisms.

- AC-009-1: Given `Overwatch.Tracker` emits `WorkerUnresponsive`, when stall detection is also enabled, then sequence allocation and worker recovery fan-out remain owned by the tracker.
- AC-009-2: Given `StuckDetector` flags a run stuck from `ProjectionStore.stuck_runs/2`, when no-output detection exists, then both mechanisms produce consistent terminal/attention outcomes and do not race into contradictory statuses.
- AC-009-3: Given raw worker output retention truncates old lines, when stall detection evaluates activity timestamps, then it uses retained projection metadata or event timestamps rather than counting visible log lines.

### REQ-010: Keep detection idempotent

Priority: Must
Complexity: Medium
Risk: Periodic scans can spam failures or alerts.

Foreman MUST emit at most one active stall report per run/phase/stall-kind gap.

- AC-010-1: Given a detector scans repeatedly while the same phase remains stalled, when no new activity occurs, then no duplicate failure or alert is produced for the same run/phase/kind.
- AC-010-2: Given new qualifying activity occurs after a stall report and the same phase later stalls again, when the detector scans, then a new report may be emitted with a distinct idempotency key.

### REQ-011: Expose stall state in projections

Priority: Must
Complexity: Medium
Risk: Automation cannot react if stall facts stay event-only.

Run/task projections MUST expose enough stall state for CLI, MCP, cockpit, and debug consumers.

- AC-011-1: Given a stall is reported for a run, when `ProjectionStore.run/1` or equivalent run status DTO is read, then it exposes the latest stall kind, reason, threshold, idle duration, and detected timestamp.
- AC-011-2: Given a task has an active or latest run with a stall report, when task list/status surfaces render, then the task is selectable as attention-needed.
- AC-011-3: Given no stall has been reported, when status projections are read, then stall fields are absent or `nil` rather than fabricated defaults.

### 6c. Operations, Documentation, and Tests

### REQ-012: Provide operational observability

Priority: Should
Complexity: Medium
Risk: Operators need enough telemetry to tune thresholds without reading event streams manually.

Foreman SHOULD emit telemetry and diagnostics for stall detector behavior.

- AC-012-1: Given a stall is detected, when telemetry is observed, then measurements include idle duration and threshold, and metadata includes run ID, phase, and stall kind.
- AC-012-2: Given a detector scan finds no stalled runs, when diagnostics are enabled, then scan counts and skipped/exempted counts are inspectable without noisy logs.

### REQ-013: Document operator recovery paths

Priority: Should
Complexity: Low

Foreman SHOULD document how operators configure, interpret, and recover from stalls.

- AC-013-1: Given the feature ships, when operators read the user guide and CLI reference, then they can find the config names, defaults, disable behavior, and alert surfaces.
- AC-013-2: Given a stall alert appears, when operators follow docs, then they can choose among run reset, kill-switch, retry, or manual intervention based on current Foreman recovery policy.

### REQ-014: Test boundary and race conditions

Priority: Should
Complexity: Medium
Risk: Time-based detectors commonly fail under race, restart, and projection-lag conditions.

Foreman SHOULD pin stall behavior with deterministic tests.

- AC-014-1: Given synthetic worker output, inbox, heartbeat, and phase events, when tests apply events in timestamp order, then detector decisions match the activity model.
- AC-014-2: Given a terminal event arrives before or during stall reporting, when the detector dispatches, then aggregate policy prevents stale stall mutation.
- AC-014-3: Given detector scans run concurrently or after restart, when the same stall candidate is found, then idempotency prevents duplicate alerts.

### REQ-015: Avoid new transport-specific behavior

Priority: Should
Complexity: Medium
Risk: CLI, MCP, and cockpit can drift if each computes stall state independently.

Foreman SHOULD expose one canonical stall state for all operator surfaces.

- AC-015-1: Given CLI status, MCP run status, and cockpit read the same stalled run, when they render it, then they use the same projection fields and reason text.
- AC-015-2: Given a future transport adds stall display, when it needs data, then it reads projections/DTOs instead of reimplementing detector rules.
- AC-015-3: Given docs mention stall status, when commands are verified, then examples match Go/Elixir source or a fresh build rather than stale checked-in binaries.

## 7. Non-Functional Requirements

Covered in the requirement set above:

- Reliability: REQ-005, REQ-006, REQ-009, REQ-010, REQ-014.
- Observability: REQ-007, REQ-008, REQ-011, REQ-012.
- Security/safety: REQ-007 and REQ-009 require aggregate-command boundaries and avoid projection-only mutation.
- Performance: Detector scans should operate over active runs/projections only; no raw log or event-stream full scans in steady state.
- Accessibility/operator clarity: Alert text must be visible in existing text CLI/cockpit surfaces.

## 8. Dependency Map

| Requirement | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | — | Messaging phase classification decision | Defines scope for the rest. |
| REQ-002 | REQ-001 | Worker event timestamp availability | Agent activity source. |
| REQ-003 | REQ-001 | Inbox activity policy decision | Messaging activity source. |
| REQ-004 | REQ-001 | Config/default decisions | Shared threshold contract. |
| REQ-005 | REQ-002, REQ-004 | `RunExecutorLiveness` policy decision | Agent detector. |
| REQ-006 | REQ-003, REQ-004 | Human-wait policy decision | Messaging detector. |
| REQ-007 | REQ-005, REQ-006 | Aggregate command/event choice | Durable report. |
| REQ-008 | REQ-007 | Alert surface decision | Operator visibility. |
| REQ-009 | REQ-005, REQ-007 | Existing stuck/liveness semantics | Safety invariant. |
| REQ-010 | REQ-007 | Idempotency key design | Prevents spam. |
| REQ-011 | REQ-007 | Projection schema choice | Consumers. |
| REQ-012 | REQ-005, REQ-006, REQ-007 | Telemetry naming | Ops tuning. |
| REQ-013 | REQ-004, REQ-008, REQ-011 | Final implementation shape | Docs. |
| REQ-014 | REQ-002, REQ-003, REQ-010 | Deterministic time hooks | Test proof. |
| REQ-015 | REQ-011 | Shared DTO/projection shape | Prevents drift. |

Implementation clusters:

1. Activity + config: REQ-001 through REQ-004.
2. Detection + reporting: REQ-005 through REQ-010.
3. Surfaces + docs/tests: REQ-011 through REQ-015.

No circular dependencies identified.

## 9. Adversarial Review

### Issue 1: Heartbeats could hide no-output stalls

Problem: Existing worker heartbeat activity proves process liveness, not useful phase progress.

Resolution auto-applied under Foreman mode: REQ-002 states heartbeat alone does not count as output activity unless a refined policy says otherwise.

### Issue 2: `StuckDetector` already uses run idle time

Problem: Adding another detector could duplicate or race existing run-stuck behavior.

Resolution auto-applied under Foreman mode: REQ-009 requires complementary semantics and aggregate-command boundaries.

### Issue 3: Messaging phase definition is ambiguous

Problem: The task names messaging phases but current workflows may not have explicit phase metadata for that category.

Resolution auto-applied under Foreman mode: REQ-001 includes a clarification marker and makes phase classification a first-class requirement.

### Issue 4: Operator alert destination is unspecified

Problem: A durable event without visible UI/CLI/inbox output still fails the product goal.

Resolution auto-applied under Foreman mode: REQ-008 requires attention surfacing and marks the exact alert channel for refinement.

### Issue 5: Threshold defaults are product-sensitive

Problem: Too-low values will false-fail legitimate long tool calls; too-high values leave work stuck too long.

Resolution auto-applied under Foreman mode: REQ-004 requires documented safe defaults and marks specific default values for refinement.

### Issue 6: Human wait states can look stalled by design

Problem: Some messaging phases may intentionally wait for operator or reviewer input.

Resolution auto-applied under Foreman mode: REQ-006 requires an explicit wait-for-human policy marker.

### Issue 7: Reporting semantics could be too destructive

Problem: The description says trigger failure reporting but not whether to terminate/restart workers.

Resolution auto-applied under Foreman mode: Scope excludes automatic process killing unless later clarified; failure/attention reporting is required.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4.0 | Covers activity, thresholds, detection, reporting, alerts, projections, docs, tests. |
| Testability | 4.3 | ACs are event/projection observable; time-based tests need deterministic clocks. |
| Clarity | 3.8 | 12 ambiguity markers remain for phase classification, thresholds, and alert policy. |
| Feasibility | 4.2 | Fits existing Overwatch, StuckDetector, ProjectionStore, and inbox boundaries. |
| Overall | 4.1 | PASS |

Gate decision: PASS. PRD saved.

Concerns: The TRD must resolve the 12 inline `[NEEDS CLARIFICATION]` markers before implementation or carry them into an explicit refine step. Under `--foreman`, concerns were logged and saving proceeded.

Ambiguity scan complete: 12 items marked for clarification.
