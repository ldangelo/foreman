---
document_id: PRD-2026-3af4e093
version: 1.0.0
status: Draft
date: 2026-07-27
scale_depth: LIGHT
total_requirements: 8
readiness_score: 4.25
---

# PRD: Foreman Multi-Project Agent Orchestration

## PRD Health Summary

| Priority | Count |
|---|---|
| Must | 7 |
| Should | 1 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---|
| AC coverage | 8/8 (100%) |
| Risk flags | 0 |
| Dependencies | 5 |
| Ambiguity markers | 0 |

---

## Product Summary

**Problem:** Developers juggling agent output across many projects lack a single pane of glass for monitoring and managing tasks. Existing solutions fall short on task management, customization, or PR generation.

**Solution:** Foreman provides multi-project agent orchestration — one interface managing agents and tasks across many projects simultaneously. Each task creates an isolated worktree and executes an Ensemble workflow (PRD→TRD or fix-issue). Completeness is verified by passing existing unit/integration tests and documentation — then a PR is generated. CodeRabbit review follows PR creation. The target is 95% autonomous completion without user intervention.

**Target users:** Developers who need autonomous, end-to-end task completion through to an opened PR with CodeRabbit PASS, with minimal manual intervention.

---

## Goals and Non-Goals

### Goals
1. Single pane of glass across multiple projects and agents
2. Autonomous task-to-PR completion at 95% rate, zero operator intervention
3. Isolated worktree per task; no cross-contamination
4. Ensemble PRD/TRD and fix-issue workflow execution
5. Completeness verified by tests, documentation, and CodeRabbit PASS

### Non-Goals
- Auto-merge (deferred to future release)
- Durable queueing for Ensemble outage (fail-fast with operator notification)
- UI beyond command/query surfaces
- Speculative provider abstractions

---

## Requirements by Feature Area

### Multi-Project Orchestration

### REQ-001: Must | High | Single-pane project/agent visibility
A developer can see task, run, and agent status across all registered projects in one view.

- AC-001-1: Given a developer, when they open Foreman, then they see task/run/agent status across all registered projects in one view
- AC-001-2: Given a task in Ready state, when the user initiates it, then it transitions to In Progress and begins orchestration

### REQ-002: Must | High | Isolated worktree per task
Each task creates and owns an isolated worktree; cleanup happens when the task is done.

- AC-002-1: Given a task transitions to In Progress, when orchestration begins, then an isolated worktree is created for that task
- AC-002-2: Given orchestration completes, when the worktree is no longer needed, then it is cleaned up

### Workflow Dispatch

### REQ-003: Must | High | User-selectable Ensemble workflow dispatch
The operator selects PRD/TRD or fix-issue at task start; default is fix-issue.

- AC-003-1: Given a worktree exists, when the user selected PRD/TRD, then the PRD/TRD workflow is dispatched to Ensemble
- AC-003-2: Given a worktree exists, when the user selected fix-issue, then the fix-issue workflow is dispatched to Ensemble
- AC-003-3: Given a worktree exists, when no workflow is selected, then the default fix-issue workflow is dispatched to Ensemble

### REQ-004: Must | High | Completeness gates: tests → documentation → PR → CodeRabbit → Done
Completeness requires tests pass, documentation exists, PR is created, then CodeRabbit analysis returns PASS.

- AC-004-1: Given tests pass and documentation exists, when all prerequisites are met, then PR is created and CodeRabbit analysis is requested
- AC-004-2: Given CodeRabbit returns a PASS verdict, when the task advances, then it is marked Done
- AC-004-3: Given tests fail, documentation is absent, or CodeRabbit returns FAIL, when a fix-issue cycle runs, then the retry budget decrements (max 3 attempts)
- AC-004-4: Given retry budget is exhausted, when tests still fail or CodeRabbit still returns FAIL, then the task is marked Blocked with last failure diagnostics and the operator is notified

### PR Lifecycle

### REQ-005: Must | High | PR opened after pre-PR gates pass
A PR is opened against the target branch once tests pass and documentation exists (pre-PR gates). CodeRabbit review follows PR creation.

- AC-005-1: Given tests pass and documentation exists, when pre-PR gates are met, then a PR is opened against the target branch
- AC-005-2: Given PR creation fails with a retryable error, then the system retries automatically; non-retryable errors surface to the user

### Failure Classification

### REQ-006: Must | High | Backend unavailability: recovery and clear error
Backend outage triggers recovery attempt; clear error if recovery fails.

- AC-006-1: Given the backend is unavailable, when a command is submitted, then recovery is attempted and a clear error is returned if recovery fails
- AC-006-2: Given recovery succeeds, when commands are resubmitted, then no duplicate processing occurs
### REQ-007: Should | Medium | Transient infrastructure failure handling
Transient failures (network timeout, service unavailable) trigger retry; permanent failures surface immediately.

- AC-007-1: Given Ensemble is unavailable, when a workflow is dispatched, then transport retry is attempted
- AC-007-2: Given retry is exhausted, when Ensemble is still unavailable, then the task is marked Blocked and the operator is notified with diagnostics

### Non-Functional

### REQ-008: Must | High | 95% autonomous completion rate
Percentage of tasks entering In Progress that reach Done with zero operator interventions, over a 30-day rolling window. Excludes user-cancelled tasks and infrastructure outages.

- AC-008-1: Given a task enters In Progress, when it reaches Done without any operator intervention, then it counts toward the autonomy numerator
- AC-008-2: Given the measurement window closes, when the percentage of autonomous completions is below 95%, then the operator is alerted to investigate

---

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---|
| REQ-001 | Single-pane project/agent visibility | Must | High | 2 |
| REQ-002 | Isolated worktree per task | Must | High | 2 |
| REQ-003 | User-selectable Ensemble workflow dispatch | Must | High | 3 |
| REQ-004 | Completeness gates: tests → PR → CodeRabbit → Done | Must | High | 4 |
| REQ-005 | PR generated after all gates pass | Must | High | 2 |
| REQ-006 | Backend unavailability: recovery and clear error | Must | High | 2 |
| REQ-007 | Transient infrastructure failure handling | Should | Medium | 2 |
| REQ-008 | 95% autonomous completion rate | Must | High | 2 |

---

## Dependency Map

- REQ-002 → REQ-001 (worktree requires orchestration to start)
- REQ-003 → REQ-002 (dispatch requires worktree)
- REQ-004 → REQ-003 (completeness gates require dispatch)
- REQ-005 → REQ-004 (PR requires gates passed)
- REQ-006 → independent (must be addressed before production)
- REQ-007 → independent (failure handling cross-cuts all)
- REQ-008 → REQ-004 (autonomy metric requires completion gates)

---

## Risks and Open Questions

### Risks
1. Ensemble unavailability without durable queueing may increase operator interventions, affecting the 95% target.
2. Retry budget (3 attempts) may be insufficient for flaky tests; monitor and adjust if needed.
3. CodeRabbit analysis latency may extend task completion time.

### Open Questions
1. Max retry per infrastructure transient — confirmed at 2 transport retries before Blocked.
2. Measurement infrastructure for the 95% metric — requires logging task state transitions and operator interventions.
3. Monitoring/alerting for Blocked tasks — defer to ops setup.

---

## Implementation Readiness Gate

| Dimension | Score (1–5) |
|---|---|
| Completeness | 5 |
| Testability | 4 |
| Clarity | 4 |
| Feasibility | 4 |

**Overall: 4.25 — PASS**
