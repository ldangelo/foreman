---
document_id: TRD-2026-6bc2fec8
label: trd-messaging-stall-detection
version: 1.0.0
status: Draft
date: 2026-09-04
prd_reference: docs/PRD/PRD-2026-6bc2fec8-messaging-stall-detection.md
prd_label: prd-messaging-stall-detection
scale_depth: STANDARD
total_requirements: 15
total_acceptance_criteria: 40
design_readiness_score: 4.6
readiness_score: 4.6
total_tasks: 35
kind: trd
---

# TRD: Use messaging stall detection and failure reporting

Foreman task title from `FOREMAN_TASK_TITLE`: **Use messaging stall detection and failure reporting**.

## 1. Executive Summary

This TRD converts `PRD-2026-6bc2fec8` into a brownfield implementation plan for durable phase-level stall detection. The design adds one canonical detector path for active phases, derives activity from persisted events/projections, records stalls through aggregate commands, and exposes the resulting stall state through existing run/task/CLI/MCP/cockpit/debug surfaces.

Source verification found these relevant contracts:

- `ForemanServer.StuckDetector` scans active run projections and dispatches `run.flag_stuck` after idle run activity; it already respects `RunExecutorLiveness` future deadlines.
- `ProjectionStore.stuck_runs/2` uses run `last_event_at_ms`; it does not model phase-specific output or messaging progress.
- `ProjectionStore.run/1`, `phases_for_run/1`, `run_logs/1`, and `run_activity/1` are current read-model surfaces for run, phase, output, and worker activity.
- Worker event types include `WorkerStarted`, `WorkerHeartbeat`, `WorkerExited`, `WorkerStdout`, `WorkerStderr`, `AssistantMessage`, and `ToolCallFinished`; heartbeats currently touch run activity and must not count as output progress for this feature.
- Inbox projections fold `InboxMessageAppended` and `InboxDeliveryUpdated`; only appended messages count as messaging progress in v1.
- Run failure/stuck mutations already flow through `CommandGateway` / `CommandRouter` / `Aggregates.Run`; projections are read models only.
- `foreman run get/list` read `/api/runs`; MCP `foreman_run_status` reads `ProjectionStore.run/1` and `phases_for_run/1`.

## 2. Architecture Decision

### 2.1 Domain Analysis

| Domain | Requirements | Design owner |
|---|---|---|
| Stall scope and workflow metadata | REQ-001, REQ-004, REQ-006 | Workflow validator + phase projection metadata |
| Activity projection | REQ-002, REQ-003, REQ-009 | `ProjectionStore` derived phase/run stall fields |
| Periodic detection | REQ-005, REQ-006, REQ-010, REQ-012, REQ-014 | New `ForemanServer.StallDetector` GenServer |
| Durable reporting | REQ-007, REQ-008, REQ-011 | Run aggregate command + typed event + projections |
| Operator surfaces | REQ-008, REQ-011, REQ-015 | API, CLI JSON, MCP DTO, cockpit/debug readers |
| Docs/tests | REQ-013, REQ-014, REQ-015 | Foreman docs + ExUnit/Go tests |

The repo is brownfield. The design reuses event-store, aggregate, projection, workflow validation, CLI, and MCP boundaries rather than adding a side-channel monitor.

### 2.2 Capability Reuse Check

`trd-graph-cli.js capabilities docs/TRD --json` returned an empty capability registry, and `overlap` returned no overlaps. No foundational TRD provides this exact capability.

Existing code capabilities reused directly:

| Capability | Reuse source | Usage |
|---|---|---|
| Active run liveness safety net | `ForemanServer.StuckDetector` | Preserve run-level stuck behavior; share deadline exemption semantics. |
| Active invocation deadlines | `ForemanServer.RunExecutorLiveness` | Exempt quiet-but-in-time agent invocations. |
| Durable output and activity reads | `ProjectionStore.run_logs/1`, `run_activity/1` | Source agent output/progress from persisted worker events. |
| Run/task read models | `ProjectionStore.run/1`, `phases_for_run/1`, `task_projection/1` | Canonical surface for all transports. |
| Aggregate mutation boundary | `CommandGateway` / `CommandRouter` / `Aggregates.Run` | Record stall reports without projection writes. |
| Inbox event projection | `InboxMessageAppended`, `InboxDeliveryUpdated` handlers | Source messaging progress from appended messages only. |

### 2.3 Architecture Alternatives

#### Option A — Extend `StuckDetector` only

Reuse the current run idle scanner and add extra branches for phase output and inbox activity.

- **Pros:** Smallest module count; one scheduler.
- **Cons:** Blurs run-idle stuck vs phase-stall semantics; harder to preserve heartbeat treatment; risks large conditional detector.
- **Complexity:** Low initial, high maintenance.
- **Risk:** Medium-high.

#### Option B — External watchdog process over logs/status

Add a separate watchdog that polls CLI/API/logs and reports failures.

- **Pros:** Decoupled from core server internals.
- **Cons:** Violates PRD event/projection source requirement; duplicates transport logic; stale/laggy by design.
- **Complexity:** Medium.
- **Risk:** High.

#### Option C — New phase stall detector over projections (chosen)

Add a focused `ForemanServer.StallDetector` that scans active run/phase projection state, consults `RunExecutorLiveness`, emits telemetry, and dispatches a typed run aggregate command such as `run.report_stall` to persist `RunStallReported`. Extend projections/DTOs/surfaces to render one canonical stall state.

- **Pros:** Best fit brownfield; keeps durable source of truth; separates phase stalls from run stuck; preserves aggregate/projection boundaries; testable with deterministic time.
- **Cons:** Requires projection schema extension and workflow metadata validation.
- **Complexity:** Medium.
- **Risk:** Medium, mitigated by narrow PRs and characterization tests.

Foreman mode: auto-selected Option C (new phase stall detector over projections).

### 2.4 System Architecture

| Component | Responsibility | Change |
|---|---|---|
| Workflow phase schema/validator | Typed phase metadata | Accept `stall_detection` map or enum with `kind`, `threshold_ms`, and policy; reject malformed overrides loudly. |
| `ProjectionStore` | Canonical activity/stall read model | Track phase `output_activity_at_ms`, `messaging_activity_at_ms`, `stall_policy`, `latest_stall`; expose run/task latest stall. |
| `ForemanServer.StallDetector` | Periodic stall scan | Scan active phases, apply thresholds and exemptions, dispatch one stall command per idempotency key. |
| `RunExecutorLiveness` | Active agent invocation deadline registry | Read-only dependency; no ownership change. |
| `Aggregates.Run` | Durable stall event emission | Add command handling for `run.report_stall` or equivalent typed command with terminal/attention policy guard. |
| `RunStallReported` event | Durable fact | Include run, task, phase, kind, threshold, idle duration, detected time, policy, idempotency key. |
| Telemetry | Operational signals | Emit scan and detection measurements with stall kind, phase, run, skipped/exempted counts. |
| API/CLI/MCP/cockpit/debug | Operator rendering | Read canonical projection fields; do not recompute stall rules per transport. |
| Docs | Operator contract | Document defaults, disable value, workflow overrides, surfaces, and recovery commands. |

### 2.5 Data Flow

```text
Worker/inbox/domain event
  -> EventStore.append
  -> ProjectionStore.apply_events
  -> phase/run activity fields advance when event qualifies
  -> StallDetector.scan(now_ms)
  -> ProjectionStore.stall_candidates(now_ms, config)
  -> RunExecutorLiveness.lookup(run_id, now_ms) for agent phases
  -> CommandGateway.dispatch_system(%{type: "run.report_stall", ...})
  -> Aggregates.Run validates active/nonterminal/idempotency
  -> RunStallReported event
  -> ProjectionStore latest_stall fields + task attention fields
  -> API/CLI/MCP/cockpit/debug render same reason
```

Qualifying activity:

- Agent output progress: `WorkerStarted`, `WorkerExited`, `WorkerStdout`, `WorkerStderr`, `AssistantMessage`, `ToolCallFinished`, `PhaseStarted`, `PhaseCompleted`, `PhaseFailed`.
- Not agent output progress: `WorkerHeartbeat` alone.
- Messaging progress: `InboxMessageAppended` for the run/phase/thread when correlated.
- Not messaging progress by default: `InboxDeliveryUpdated` read/delivery-only updates.

### 2.6 Data Contracts

`RunStallReported` payload:

```elixir
%{
  run_id: binary(),
  task_id: binary() | nil,
  phase_id: binary(),
  phase_index: non_neg_integer() | nil,
  phase_name: binary() | nil,
  stall_kind: "agent_no_output" | "messaging_no_progress",
  policy: "fail" | "attention",
  threshold_ms: pos_integer(),
  idle_ms: non_neg_integer(),
  activity_at_ms: non_neg_integer() | nil,
  detected_at_ms: non_neg_integer(),
  idempotency_key: binary(),
  reason: binary()
}
```

Projection fields:

- Phase: `output_activity_at_ms`, `messaging_activity_at_ms`, `stall_detection_kind`, `stall_threshold_ms`, `stall_policy`, `latest_stall`.
- Run: `latest_stall`, optional `failure_reason`, status/terminal policy derived by aggregate event semantics.
- Task: `latest_stall` / attention marker when the active/latest run has a stall.

Config defaults:

- `:agent_no_output_stall_threshold_ms` = `900_000`.
- `:messaging_no_progress_stall_threshold_ms` = `1_800_000`.
- Documented disable value: `false` or `:disabled` only; non-positive integers are malformed and fail validation.
- Per-phase YAML override wins over app default; malformed override fails workflow validation.

## Master Task List

### PR 1: Activity model and workflow metadata
**Shippable State:** Operators can define and validate stall policy metadata in workflow phases, and Foreman projections expose deterministic activity timestamps for agent and messaging phases without changing run outcomes.

- [ ] **TRD-001** Define typed stall policy structs/helpers for agent and messaging scopes in `packages/foreman_server/lib/foreman_server/workflow` and config modules. (3h) [satisfies REQ-001, REQ-004, REQ-006]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-004-1, AC-004-2, AC-006-3
  - Implementation ACs:
    - Given absent config, when defaults load, then agent threshold is 900000 ms and messaging threshold is 1800000 ms.
    - Given a malformed non-positive integer, when config validates, then validation returns a typed error and does not silently disable detection.
- [ ] **TRD-001-TEST** Add config/unit tests for default thresholds, documented disable value, and malformed threshold rejection. (2h) [verifies TRD-001] [satisfies REQ-004] [depends: TRD-001]
  - Validates PRD ACs: AC-004-1, AC-004-2
  - Implementation ACs:
    - Given default app env, when tests read stall config, then expected defaults are returned.
    - Given `0`, negative, or wrong-type threshold, when validation runs, then a typed error is asserted.
- [ ] **TRD-002** Extend workflow phase schema/validator to accept explicit stall metadata (`agent`, `messaging`, threshold override, policy) and reject phase-name heuristics. (4h) [satisfies REQ-001, REQ-004, REQ-006]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-004-3, AC-006-3
  - Implementation ACs:
    - Given `stall_detection: messaging`, when workflow validation succeeds, then the phase spec carries messaging stall kind.
    - Given only a phase name containing "message", when no metadata exists, then no messaging scope is inferred.
- [ ] **TRD-002-TEST** Add workflow validator tests for valid overrides, malformed overrides, and no name-based classification. (2h) [verifies TRD-002] [satisfies REQ-001, REQ-004] [depends: TRD-002]
  - Validates PRD ACs: AC-001-2, AC-004-3
  - Implementation ACs:
    - Given a malformed override, when validation runs, then it returns a specific error tuple.
    - Given equivalent phase names with/without metadata, when validated, then only metadata changes stall kind.
- [ ] **TRD-003** Extend phase projections with activity fields and stall metadata copied from phase start/snapshot data. (4h) [satisfies REQ-001, REQ-002, REQ-003, REQ-011]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-002-1, AC-003-1, AC-011-3
  - Implementation ACs:
    - Given `PhaseStarted`, when projected, then phase activity timestamps initialize from event time.
    - Given no stall has been reported, when projection is read, then stall fields are nil/absent.
- [ ] **TRD-003-TEST** Add projection tests for phase metadata initialization and absent-stall projection shape. (2h) [verifies TRD-003] [satisfies REQ-001, REQ-011] [depends: TRD-003]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-011-3
  - Implementation ACs:
    - Given phase-start events with explicit stall metadata, when projected, then kind/threshold/policy fields match.
    - Given active phase no stall event, when `phases_for_run/1` is read, then latest stall is nil.
- [ ] **TRD-004** Update projection event handlers so qualifying worker/phase events advance agent output activity but `WorkerHeartbeat` does not. (4h) [satisfies REQ-002, REQ-009]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-009-3
  - Implementation ACs:
    - Given stdout/stderr/assistant/tool/phase lifecycle events, when applied, then output activity advances to event time.
    - Given only heartbeat events, when applied, then output activity timestamp is unchanged while existing run liveness behavior remains intact.
- [ ] **TRD-004-TEST** Add projection tests proving output event advancement, heartbeat exclusion, and raw-log ignorance. (3h) [verifies TRD-004] [satisfies REQ-002, REQ-009, REQ-014] [depends: TRD-004]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-009-3, AC-014-1
  - Implementation ACs:
    - Given synthetic worker output events, when projected in timestamp order, then output activity equals latest qualifying event.
    - Given a compatibility log file changes without an event, when projections are read, then activity is unchanged.
- [ ] **TRD-005** Update inbox projection/correlation logic so `InboxMessageAppended` advances messaging activity and `InboxDeliveryUpdated` does not by default. (3h) [satisfies REQ-003, REQ-006]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-006-1
  - Implementation ACs:
    - Given an appended inbox message for a run, when projected, then messaging activity advances.
    - Given only delivery/read update, when projected, then messaging progress activity is unchanged.
- [ ] **TRD-005-TEST** Add inbox projection tests for appended-message progress and delivery-update non-progress. (2h) [verifies TRD-005] [satisfies REQ-003, REQ-014] [depends: TRD-005]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-014-1
  - Implementation ACs:
    - Given message append then delivery update, when projected, then only append timestamp becomes messaging activity.
    - Given no run correlation, when event applies, then detector candidate state is unchanged.

### PR 2: Stall detector and durable reporting
**Shippable State:** Active runs with no qualifying agent output or messaging progress are reported once as durable stall facts with clear policy-controlled run state.

- [ ] **TRD-006** Add `ForemanServer.StallDetector` one-shot scan over active phase projections with injected clock/dispatch functions for deterministic tests. (5h) [satisfies REQ-005, REQ-006, REQ-010, REQ-012]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-006-1, AC-006-2, AC-010-1, AC-012-2
  - Implementation ACs:
    - Given active phase activity inside threshold, when scan runs, then no command dispatch occurs.
    - Given idle duration equals or exceeds threshold, when scan runs, then exactly one stall command is prepared.
- [ ] **TRD-006-TEST** Add detector unit tests for agent and messaging candidate selection at threshold boundaries. (3h) [verifies TRD-006] [satisfies REQ-005, REQ-006, REQ-014] [depends: TRD-006]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-006-1, AC-006-2, AC-014-1
  - Implementation ACs:
    - Given idle time threshold minus one, when scanned, then no stall is emitted.
    - Given idle time at threshold, when scanned, then the expected stall kind is emitted.
- [ ] **TRD-007** Integrate `RunExecutorLiveness.lookup/2` into agent stall scans so valid future deadlines exempt quiet agent phases until expiration. (3h) [satisfies REQ-005, REQ-009]
  - Validates PRD ACs: AC-005-3, AC-009-2
  - Implementation ACs:
    - Given registered executor PID and future deadline, when no output exists, then scan skips the phase.
    - Given expired or stale-owner deadline, when no output exceeds threshold, then scan may report a stall.
- [ ] **TRD-007-TEST** Add liveness exemption tests covering future, expired, stale-owner, and absent deadline cases. (3h) [verifies TRD-007] [satisfies REQ-005, REQ-009, REQ-014] [depends: TRD-007]
  - Validates PRD ACs: AC-005-3, AC-009-2, AC-014-3
  - Implementation ACs:
    - Given future deadline owned by current executor, when scanned, then dispatch list is empty.
    - Given stale PID owner, when scanned, then no exemption applies.
- [ ] **TRD-008** Add typed `RunStallReported` event, codec registration, and event tests with required payload fields. (4h) [satisfies REQ-007, REQ-010]
  - Validates PRD ACs: AC-007-1, AC-010-1, AC-010-2
  - Implementation ACs:
    - Given complete payload, when encoded/decoded, then all stall fields round-trip.
    - Given missing run/phase/kind fields, when decoded, then validation fails loudly.
- [ ] **TRD-008-TEST** Add event codec tests for valid stall payloads and malformed payload rejection. (2h) [verifies TRD-008] [satisfies REQ-007] [depends: TRD-008]
  - Validates PRD ACs: AC-007-1
  - Implementation ACs:
    - Given `agent_no_output` and `messaging_no_progress`, when decoded, then both kinds are accepted.
    - Given unknown stall kind, when decoded, then a typed error is returned or raised per codec convention.
- [ ] **TRD-009** Add run aggregate command handling for stall reporting with terminal-state guard, attention/fail policy, and idempotency key metadata. (5h) [satisfies REQ-007, REQ-009, REQ-010]
  - Validates PRD ACs: AC-001-3, AC-007-2, AC-009-1, AC-009-2, AC-010-1, AC-010-2, AC-014-2
  - Implementation ACs:
    - Given terminal run, when stall command dispatches, then aggregate rejects or no-ops without mutating terminal state.
    - Given duplicate idempotency key, when command re-dispatches, then no duplicate active stall event is persisted.
- [ ] **TRD-009-TEST** Add aggregate/command gateway tests for active, terminal, duplicate, and policy-specific stall command paths. (4h) [verifies TRD-009] [satisfies REQ-007, REQ-009, REQ-010, REQ-014] [depends: TRD-009]
  - Validates PRD ACs: AC-001-3, AC-007-2, AC-009-2, AC-010-1, AC-010-2, AC-014-2, AC-014-3
  - Implementation ACs:
    - Given active run and fail policy, when command succeeds, then run outcome matches existing failure/stuck semantics without contradiction.
    - Given repeated scan after no activity, when command dispatches again, then event count remains one.
- [ ] **TRD-010** Wire `StallDetector` supervision/config schedule alongside existing `StuckDetector` without replacing heartbeat, recovery, or run-stuck behavior. (3h) [satisfies REQ-009, REQ-012]
  - Validates PRD ACs: AC-009-1, AC-009-2, AC-012-2
  - Implementation ACs:
    - Given app boot with detection enabled, when supervisor starts, then both stuck and stall detectors are supervised.
    - Given detection disabled by documented value, when app boots, then detector is not scheduled and config is explicit.
- [ ] **TRD-010-TEST** Add supervision/config tests proving stall detector starts only when enabled and does not alter Overwatch tracker ownership. (2h) [verifies TRD-010] [satisfies REQ-009, REQ-012] [depends: TRD-010]
  - Validates PRD ACs: AC-009-1, AC-012-2
  - Implementation ACs:
    - Given enabled config, when child specs are built, then `StallDetector` is present.
    - Given `WorkerUnresponsive`, when tracker emits recovery events, then sequence allocation remains tracker-owned.

### PR 3: Canonical projections and operator surfaces
**Shippable State:** Operators and automation can see the latest stall reason consistently through run/task APIs, CLI JSON, MCP status, cockpit/debug, and inbox attention metadata.

- [ ] **TRD-011** Project `RunStallReported` into phase/run/task latest stall fields and attention-needed task selection without fabricating inbox messages. (5h) [satisfies REQ-007, REQ-008, REQ-011]
  - Validates PRD ACs: AC-007-1, AC-007-3, AC-008-1, AC-008-2, AC-011-1, AC-011-2, AC-011-3
  - Implementation ACs:
    - Given stall event, when `ProjectionStore.run/1` is read, then latest stall fields include kind, reason, threshold, idle, detected time.
    - Given inbox enabled, when stall projects, then attention metadata exists without adding an `InboxMessageAppended` row.
- [ ] **TRD-011-TEST** Add projection tests for run/task/phase latest stall fields and no-fabricated-message behavior. (3h) [verifies TRD-011] [satisfies REQ-008, REQ-011, REQ-014] [depends: TRD-011]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-011-1, AC-011-2, AC-011-3, AC-014-3
  - Implementation ACs:
    - Given stall event for run with task, when task projection/list is read, then task is attention-selectable.
    - Given stall event, when inbox thread messages are read, then message count is unchanged unless an actual message was appended.
- [ ] **TRD-012** Extend HTTP run/task projection serializers and `foreman run get/list` JSON output to include canonical stall fields from projections only. (3h) [satisfies REQ-008, REQ-011, REQ-015]
  - Validates PRD ACs: AC-007-3, AC-008-1, AC-011-1, AC-011-2, AC-015-1, AC-015-2
  - Implementation ACs:
    - Given stalled run, when `/api/runs/:id` and `foreman run get` are read, then JSON includes same latest stall object.
    - Given non-stalled run, when read, then stall fields are absent or null, not synthetic defaults.
- [ ] **TRD-012-TEST** Add API/Go CLI tests or fixture tests for run/task stall field rendering and non-stalled absence. (3h) [verifies TRD-012] [satisfies REQ-008, REQ-011, REQ-015] [depends: TRD-012]
  - Validates PRD ACs: AC-008-1, AC-011-1, AC-011-2, AC-011-3, AC-015-1
  - Implementation ACs:
    - Given API fixture with latest stall, when CLI command renders JSON, then field names match API.
    - Given no stall in fixture, when rendered, then no fake reason appears.
- [ ] **TRD-013** Extend MCP run-status DTO and cockpit/debug readers to render the canonical stall reason without recomputing detector rules. (4h) [satisfies REQ-007, REQ-011, REQ-015]
  - Validates PRD ACs: AC-007-3, AC-011-1, AC-015-1, AC-015-2
  - Implementation ACs:
    - Given `foreman_run_status` reads a stalled run, then DTO includes latest stall and failure/attention reason from projection.
    - Given cockpit/debug reads the same run, then display text uses the projection reason, not local stall calculations.
- [ ] **TRD-013-TEST** Add MCP/cockpit/debug tests proving transport parity and no duplicated stall computation. (3h) [verifies TRD-013] [satisfies REQ-011, REQ-015] [depends: TRD-013]
  - Validates PRD ACs: AC-011-1, AC-015-1, AC-015-2
  - Implementation ACs:
    - Given one stalled run projection, when MCP and HTTP DTOs are read, then stall fields match.
    - Given transport code paths, when searched/tested, then detector threshold logic remains server-side only.
- [ ] **TRD-014** Add operator-facing inbox/Agent Mail attention metadata rendering for stall facts without appending synthetic messages. (3h) [satisfies REQ-008, REQ-015]
  - Validates PRD ACs: AC-008-2, AC-015-1, AC-015-2
  - Implementation ACs:
    - Given a stall fact, when inbox surface renders run metadata, then stall attention is visible.
    - Given no actual message body, when inbox messages list renders, then no fabricated message appears.
- [ ] **TRD-014-TEST** Add inbox/Agent Mail surface tests for attention metadata and no message fabrication. (2h) [verifies TRD-014] [satisfies REQ-008, REQ-015] [depends: TRD-014]
  - Validates PRD ACs: AC-008-2, AC-015-1
  - Implementation ACs:
    - Given stall projection with inbox thread, when rendered, then metadata displays stall reason.
    - Given stall projection only, when messages are listed, then list is unchanged.

### PR 4: Observability, races, docs, and validation
**Shippable State:** Operators can tune, diagnose, and recover from stall alerts with documented config/recovery guidance and deterministic tests covering boundary/race behavior.

- [ ] **TRD-015** Add telemetry for detector scans, detected stalls, skipped/exempted candidates, idle duration, threshold, run, phase, and stall kind. (3h) [satisfies REQ-012]
  - Validates PRD ACs: AC-012-1, AC-012-2
  - Implementation ACs:
    - Given detected stall, when telemetry fires, then measurements include idle and threshold.
    - Given clean scan, when diagnostics are enabled, then scan/skipped/exempted counts are inspectable without noisy logs.
- [ ] **TRD-015-TEST** Add telemetry tests for stall detection and clean-scan diagnostics. (2h) [verifies TRD-015] [satisfies REQ-012] [depends: TRD-015]
  - Validates PRD ACs: AC-012-1, AC-012-2
  - Implementation ACs:
    - Given test telemetry handler, when stall emits, then expected metadata keys are asserted.
    - Given no stalled candidates, when scan completes, then diagnostic count event is asserted.
- [ ] **TRD-016** Add race/restart tests for terminal event during scan, concurrent scans, projection rebuild, and same phase re-stall after new activity. (4h) [satisfies REQ-010, REQ-014]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-014-2, AC-014-3
  - Implementation ACs:
    - Given terminal event arrives before aggregate mutation, when stall command runs, then stale mutation is blocked.
    - Given new activity after a stall then later idle gap, when scanned, then new idempotency key permits one new report.
- [ ] **TRD-016-TEST** Run/add integration tests covering restart/projection rebuild and concurrent detector scans. (3h) [verifies TRD-016] [satisfies REQ-010, REQ-014] [depends: TRD-016]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-014-2, AC-014-3
  - Implementation ACs:
    - Given rebuilt projections from event log, when detector scans, then duplicate stalls are not emitted.
    - Given two scans race, when both see same candidate, then aggregate/event idempotency stores one active report.
- [ ] **TRD-017** Update `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `docs/workflow-yaml-reference.md`, and `docs/troubleshooting.md` with real config names, defaults, disable behavior, status fields, alert surfaces, and recovery paths. (4h) [satisfies REQ-013, REQ-015]
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-015-3
  - Implementation ACs:
    - Given docs are read, when operator searches stall detection, then config/defaults/status/recovery guidance is present.
    - Given CLI examples are documented, when checked against Go/Elixir source or fresh build, then command names/fields match.
- [ ] **TRD-017-TEST** Add documentation/source validation checklist or tests proving documented commands/fields match source and stale binary is not used. (2h) [verifies TRD-017] [satisfies REQ-013, REQ-015] [depends: TRD-017]
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-015-3
  - Implementation ACs:
    - Given docs mention run/task status fields, when source validation script/checklist runs, then fields match source DTOs.
    - Given root `./foreman` differs, when validation is performed, then fresh source/build is used instead.
- [ ] **TRD-018** Run focused validation suite and fix only regressions caused by this feature. (3h) [satisfies REQ-014, REQ-015]
  - Validates PRD ACs: AC-014-1, AC-014-2, AC-014-3, AC-015-1, AC-015-2, AC-015-3
  - Implementation ACs:
    - Given focused ExUnit/Go tests run, when complete, then detector/projection/workflow/MCP/CLI/doc checks pass.
    - Given unrelated pre-existing failures appear, when reported, then they are documented separately and not hidden as pass.

## 4. Dependency Map and PR Boundary Validation

Critical path:

```text
TRD-001 -> TRD-002 -> TRD-003 -> TRD-004/TRD-005 -> TRD-006 -> TRD-007 -> TRD-008 -> TRD-009 -> TRD-010 -> TRD-011 -> TRD-012/TRD-013/TRD-014 -> TRD-015/TRD-016/TRD-017 -> TRD-018
```

No circular dependencies identified. No task is estimated at 8h+.

PR shippability:

- PR 1: Adds validated metadata and activity projections only; no public stall outcomes yet, so existing behavior remains stable.
- PR 2: Adds durable reporting and detector; public effect is explicit stall/failure/attention facts for active runs.
- PR 3: Adds user/automation visibility across existing surfaces from one projection state.
- PR 4: Adds observability, race proof, docs, and final validation.

## 5. Sprint Planning

## Sprint 1: Activity and detector foundation

- PR 1 and PR 2.
- Focus: typed policy, projection activity model, detector, aggregate event, idempotency.

## Sprint 2: Surfaces and operator proof

- PR 3.
- Focus: run/task/API/CLI/MCP/cockpit/debug/inbox visibility parity.

## Sprint 3: Observability, docs, validation

- PR 4.
- Focus: telemetry, races, recovery docs, validation evidence.

## 6. Acceptance Criteria Traceability

| Requirement | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Define stallable execution scopes | TRD-001, TRD-002, TRD-003 | TRD-002-TEST, TRD-003-TEST |
| REQ-002 | Track output activity from worker events | TRD-003, TRD-004 | TRD-004-TEST |
| REQ-003 | Track messaging activity from inbox events | TRD-003, TRD-005 | TRD-005-TEST |
| REQ-004 | Configure stall thresholds safely | TRD-001, TRD-002 | TRD-001-TEST, TRD-002-TEST |
| REQ-005 | Detect agent-phase stalls without false positives | TRD-006, TRD-007 | TRD-006-TEST, TRD-007-TEST |
| REQ-006 | Detect messaging stalls without false positives | TRD-001, TRD-002, TRD-005, TRD-006 | TRD-006-TEST |
| REQ-007 | Report detected stalls as failure facts | TRD-008, TRD-009, TRD-011, TRD-013 | TRD-008-TEST, TRD-009-TEST |
| REQ-008 | Alert operators about stuck tasks | TRD-011, TRD-012, TRD-014 | TRD-011-TEST, TRD-012-TEST, TRD-014-TEST |
| REQ-009 | Preserve existing liveness semantics | TRD-004, TRD-007, TRD-009, TRD-010 | TRD-004-TEST, TRD-007-TEST, TRD-009-TEST, TRD-010-TEST |
| REQ-010 | Keep detection idempotent | TRD-006, TRD-008, TRD-009, TRD-016 | TRD-009-TEST, TRD-016-TEST |
| REQ-011 | Expose stall state in projections | TRD-003, TRD-011, TRD-012, TRD-013 | TRD-003-TEST, TRD-011-TEST, TRD-012-TEST, TRD-013-TEST |
| REQ-012 | Provide operational observability | TRD-006, TRD-010, TRD-015 | TRD-010-TEST, TRD-015-TEST |
| REQ-013 | Document operator recovery paths | TRD-017 | TRD-017-TEST |
| REQ-014 | Test boundary and race conditions | TRD-004, TRD-005, TRD-006, TRD-009, TRD-011, TRD-016, TRD-018 | TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-009-TEST, TRD-011-TEST, TRD-016-TEST |
| REQ-015 | Avoid new transport-specific behavior | TRD-012, TRD-013, TRD-014, TRD-017, TRD-018 | TRD-012-TEST, TRD-013-TEST, TRD-014-TEST, TRD-017-TEST |

Traceability check: 15 requirements covered, 0 uncovered, 0 orphaned annotations.

## 7. MCP Enhancement

MCP enhancement: skipped (no MCP tools detected in this Pi session).

## 8. Adversarial Review

### 8.1 Architecture Self-Critique

1. **Issue:** `WorkerHeartbeat` currently calls `touch_run_for_payload/2`, so a naive detector over run `last_event_at_ms` would miss no-output stalls.
   - **Resolution:** Detector reads phase output/messaging timestamps, not run `last_event_at_ms`; PR 1 pins heartbeat exclusion in projection tests.
2. **Issue:** Messaging phase correlation may be incomplete when inbox events only carry run/thread metadata.
   - **Resolution:** PR 1/3 require explicit metadata projection and safe run-level fallback; malformed or uncorrelated messages must not fabricate progress for the wrong phase.
3. **Issue:** Existing `run.flag_stuck` already sets terminal `stuck`; adding `run.report_stall` could create contradictory terminal states.
   - **Resolution:** Aggregate terminal guards and policy-specific state transitions are explicit in PR 2; tests cover race with `RunFlaggedStuck`.

### 8.2 Task Coverage Analysis

1. **Issue:** Operator alerting spans several transports; drift risk is high if each computes reason text.
   - **Resolution:** PR 3 requires all surfaces to read projection `latest_stall` fields; no transport-local detector logic.
2. **Issue:** Docs must not promise speculative auto-kill/restart behavior.
   - **Resolution:** PR 4 docs scope recovery to existing operator-controlled reset/kill-switch/retry/manual paths.

Scratch parser self-check performed with `trd-cli.js parse` after save. Task lines include required checkbox prefix.

### 8.3 Dependency and Estimate Review

1. **Issue:** Projection shape is a prerequisite for detector and surfaces; implementing surfaces early would cause DTO churn.
   - **Resolution:** PR order enforces projection metadata/activity before detector and transport rendering.
2. **Issue:** Race/idempotency tasks depend on both aggregate and projection behavior.
   - **Resolution:** Race proof is split into PR 2 aggregate tests and PR 4 restart/concurrency tests.

### 8.4 Testability Review

Implementation ACs use observable inputs/outputs: config validation results, projection fields, event counts, telemetry events, API/CLI/MCP DTO fields, and docs/source checks. No subjective AC remains without pass/fail criteria.

## 9. Design Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 4.6 | Components, event flow, projection fields, aggregate command, detector, and surfaces are defined. |
| Task coverage | 4.7 | Every PRD requirement has implementation and test coverage; tasks preserve parser-visible checkbox format. |
| Dependency clarity | 4.5 | Dependencies are explicit and acyclic; PR boundaries follow projection -> detector -> surfaces -> validation. |
| Estimate confidence | 4.5 | No task exceeds 5h; tests are paired with risky changes. |
| Overall | 4.6 | PASS |

Gate decision: PASS.

## 10. Validation Plan

Focused commands for implementation phase:

```bash
cd packages/foreman_server && mix test \
  test/foreman_server/stuck_detector_test.exs \
  test/foreman_server/run_executor_liveness_test.exs \
  test/foreman_server/projection_store_runs_test.exs \
  test/foreman_server/projection_store_test.exs \
  test/foreman_server/aggregates/run_flag_stuck_test.exs \
  test/foreman_server/events/run_flagged_stuck_test.exs \
  test/foreman_server/mcp/tools_test.exs \
  test/foreman_server/workflow/loader_test.exs \
  test/foreman_server/workflow/phase_spec_test.exs

go test ./packages/foreman_cli/cmd/foreman

git diff --check
```

Docs validation must verify CLI/API examples against Go/Elixir source or a fresh build, not the stale root `./foreman` artifact.

## 11. Next Steps

1. Review and approve this TRD.
2. Run `/ensemble-configure-team docs/TRD/TRD-2026-6bc2fec8-messaging-stall-detection.md`.
3. Run `/ensemble-implement-trd-beads docs/TRD/TRD-2026-6bc2fec8-messaging-stall-detection.md` only after approval.
