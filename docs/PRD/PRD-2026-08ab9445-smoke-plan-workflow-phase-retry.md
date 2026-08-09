---
document_id: PRD-2026-08ab9445
label: prd-smoke-plan-workflow-phase-retry
version: 0.1.0
status: Draft
date: 2026-08-09
scale_depth: LIGHT
total_requirements: 6
readiness_score: 3.6
---

# PRD: Smoke — Plan Workflow Phase Retry

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 5 |
| Should | 1 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| AC coverage | 6/6 (100%) |
| Risk flags | 2 |
| Dependencies | 3 |
| Open ambiguity markers | 0 |
| Resolved ambiguity markers | 4 |

## 1. Executive Summary

This PRD defines a smoke-test capability for Foreman's `plan` workflow. The smoke confirms that a plan task can execute the `create-prd` and `create-trd` command phases under an extended failure-policy timeout of 600 seconds, and that each phase leaves its required planning artifact on disk at the paths supplied in the phase context.

The goal is not to validate PRD/TRD content quality. The goal is to prove the workflow contract: Foreman builds deterministic planning paths, forwards Ensemble slash commands at byte zero, waits long enough for agent-backed artifact creation, and records successful phase completion only when artifacts exist.

## 2. Background and Evidence

Foreman's user guide documents the `plan` workflow as a two-phase workflow:

- `create-prd` runs `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` runs `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- The runtime provides `working_directory`, `planning.prd_path`, `planning.trd_path`, `planning.correlation_id`, `planning.document_year`, and `planning.slug` in the request context.
- Missing required files fail the phase with `:required_file_missing`.

Recent smoke intent: `Smoke test of plan workflow with extended failure policy timeout (600s). Verifies create-prd + create-trd phases complete with planning artifacts.`

This PRD captures the product-facing behavior expected from that smoke. Technical implementation details belong in the paired TRD.

## 3. Personas

### 3.1 Foreman operator

Runs workflow smoke tests after changing workflow manifests, phase timeout policy, Pi adapter behavior, or Ensemble command integration. Needs a fast, deterministic pass/fail signal.

### 3.2 Foreman maintainer

Uses the smoke as a regression guard while modifying scheduler, phase executor, worker protocol, workflow defaults, or artifact-gating behavior.

## 4. Goals and Non-Goals

### Goals

- Verify the `plan` workflow can complete both planning phases.
- Verify each phase writes the artifact path provided by Foreman.
- Verify a 600-second phase timeout is honored for slow agent-backed planning work.
- Make failures actionable by showing missing artifact path, phase name, and run id.

### Non-Goals

- Scoring PRD/TRD quality.
- Replacing dedicated unit/integration tests for the phase executor.
- Guaranteeing external agent availability outside the configured timeout window.
- Testing every Ensemble skill option.

## 5. Requirements

### REQ-001: Must | High | Plan smoke task uses the plan workflow

Foreman MUST support running a smoke task of type `plan` that selects the bundled `plan` workflow and executes its phases in order.

- AC-001-1: Given a task with `type: plan`, when the task is approved for execution, then Foreman selects the `plan` workflow.
- AC-001-2: Given the selected workflow starts, when phase execution begins, then `create-prd` runs before `create-trd`.
- AC-001-3: Given either phase fails, when the run projection is queried, then the failing phase and reason are visible.

### REQ-002: Must | High | Planning context is deterministic

Foreman MUST provide deterministic planning context for each run so artifacts can be correlated across retries.

- AC-002-1: Given run id `run-08ab944587c983489434fc648cf3eb5f`, when planning context is built, then `planning.correlation_id` is `08ab9445`.
- AC-002-2: Given task title `Smoke: plan workflow phase retry`, when planning paths are built, then the slug is `smoke-plan-workflow-phase-retry`.
- AC-002-3: Given document year `2026`, when artifact paths are built, then PRD and TRD paths are under `docs/PRD/` and `docs/TRD/` with names prefixed by `PRD-2026-08ab9445-` and `TRD-2026-08ab9445-`.

### REQ-003: Must | High | PRD artifact gate

The `create-prd` phase MUST be considered successful only after the PRD artifact exists at `planning.prd_path`.

- AC-003-1: Given the phase receives `planning.prd_path`, when the Ensemble PRD command completes, then the file exists at that exact absolute path.
- AC-003-2: Given the file is missing after command completion, when the phase gate runs, then the phase fails with `:required_file_missing` and records the missing path.
- AC-003-3: Given the phase is retried after the artifact is created, when the gate runs again, then the phase can proceed without manual metadata edits.

### REQ-004: Must | High | TRD artifact gate

The `create-trd` phase MUST be considered successful only after the TRD artifact exists at `planning.trd_path`.

- AC-004-1: Given the phase receives `planning.trd_path`, when the Ensemble TRD command completes, then the file exists at that exact absolute path.
- AC-004-2: Given the file is missing after command completion, when the phase gate runs, then the phase fails with `:required_file_missing` and records the missing path.
- AC-004-3: Given both artifacts exist, when the run reaches terminal state, then the run is marked complete rather than failed.

### REQ-005: Must | High | Extended timeout policy

The smoke run MUST use a 600-second failure-policy timeout for agent-backed planning phases.

- AC-005-1: Given either planning command is still running before 600 seconds, when no other failure occurs, then Foreman does not mark the phase timed out early.
- AC-005-2: Given a planning command exceeds 600 seconds, when the timeout fires, then Foreman terminates or cancels the worker according to existing worker policy and records a timeout failure.
- AC-005-3: Given the timeout value is configured for the smoke, when phase telemetry or debug output is inspected, then the effective timeout is visible as 600 seconds or 600,000 milliseconds.

### REQ-006: Should | Medium | Smoke output is operator-friendly

Foreman SHOULD expose enough run/phase data for operators to diagnose smoke failures without reading raw worker logs first.

- AC-006-1: Given a phase fails due to missing artifact, when the operator inspects the run, then the output includes phase name, planning key, and resolved artifact path.
- AC-006-2: Given a phase fails due to timeout, when the operator inspects the run, then the output includes phase name, timeout value, and worker/run identifier.
- AC-006-3: Given the smoke succeeds, when the operator inspects the run, then the PRD and TRD artifact paths are visible or derivable from the planning context.

## 6. Dependencies

- Bundled `plan.yaml` workflow installed in the active Foreman runtime.
- Ensemble PRD/TRD skills available to the Pi adapter.
- Foreman worker/Pi adapter able to receive slash commands at byte zero.

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Agent-backed planning can exceed short default timeouts | False smoke failures | Use explicit 600s timeout for the smoke |
| Artifact path mismatch between Foreman context and skill output | Phase gate failure | Require exact-path writes and include path in failure output |

## 8. Success Metrics

- One smoke run completes both `create-prd` and `create-trd` phases.
- PRD artifact exists at `docs/PRD/PRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md`.
- TRD artifact exists at `docs/TRD/TRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md`.
- No phase times out before 600 seconds.

## 9. Open Questions

None for this smoke. The test target, artifact paths, and timeout policy are specified by the run context.

## 10. Readiness Checklist

- [x] User value stated
- [x] Required artifacts named
- [x] Acceptance criteria cover all requirements
- [x] Risks captured
- [x] Dependencies listed
- [ ] Paired TRD created

---

*Generated: 2026-08-09 | Document ID: PRD-2026-08ab9445 | Scale: LIGHT | Draft v0.1.0*
