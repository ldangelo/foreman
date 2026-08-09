---
document_id: PRD-2026-b86c4907
label: prd-smoke-run-with-plan-workflow-task-type
version: 0.1.0
status: Draft
date: 2026-08-09
scale_depth: LIGHT
total_requirements: 6
readiness_score: 3.7
---

# PRD: Smoke — Run With Plan Workflow Task Type

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

This PRD defines a Foreman smoke test for running a task whose `type` is `plan`. The smoke validates that task-type based workflow selection routes the task to the bundled `plan` workflow, starts the `create-prd` phase, preserves deterministic planning context, and writes the PRD artifact to the exact path supplied by the run context.

The target regression is workflow dispatch by task type. A successful PRD phase proves that Foreman can use a task's `type: plan` value to select the `plan` workflow and execute its planning artifact contract without relying on ad hoc workflow overrides or task-title matching.

## 2. Background and Evidence

Foreman's bundled `plan` workflow is expected to handle tasks with `type: plan` and create planning artifacts through ordered command phases:

- `create-prd` runs `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` runs `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- Runtime context provides `working_directory`, `planning.prd_path`, `planning.trd_path`, `planning.correlation_id`, `planning.document_year`, and `planning.slug`.
- Required-file gates fail a phase if the expected artifact is not present at the resolved path.

Smoke context:

- Run id: `run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe`
- Phase id: `run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe-p001`
- Task id: `foreman-foreman-smoke-logfix-2-0bve`
- Task title: `Smoke run with plan workflow task_type`
- Task description: empty
- Task type: `plan`
- Correlation id: `b86c4907`
- Slug: `smoke-run-with-plan-workflow-task-type`
- PRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`
- TRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`

## 3. Personas

### 3.1 Foreman operator

Runs smoke workflows after changing task ingestion, workflow selection, scheduler dispatch, or adapter execution. Needs a clear pass/fail signal that a `plan` task selected the correct workflow.

### 3.2 Foreman maintainer

Uses the smoke as a regression guard while modifying task providers, workflow manifests, workflow loader behavior, run startup, or phase artifact-gating logic.

## 4. Goals and Non-Goals

### Goals

- Verify a task with `type: plan` selects the bundled `plan` workflow.
- Verify the selected workflow starts the `create-prd` phase first.
- Verify deterministic planning context is passed to the PRD command.
- Verify the PRD artifact exists at the exact `planning.prd_path` after the phase completes.
- Keep failures diagnosable through visible task type, selected workflow, phase name, and artifact path.

### Non-Goals

- Scoring PRD or TRD content quality.
- Testing every workflow type.
- Replacing unit tests for workflow matching or task-provider parsing.
- Validating all Ensemble skill options.
- Proving long-running timeout behavior beyond the configured smoke run.

## 5. Requirements

### REQ-001: Must | Critical | Task type selects the plan workflow

Foreman MUST select the bundled `plan` workflow when a task declares `type: plan`.

- AC-001-1: Given task `foreman-foreman-smoke-logfix-2-0bve` has `type: plan`, when the run starts, then Foreman selects the bundled `plan` workflow.
- AC-001-2: Given the selected workflow is inspected, when phase order is resolved, then `create-prd` is the first required phase.
- AC-001-3: Given the task title contains smoke-specific wording, when workflow selection occurs, then selection is based on task type rather than title text.

### REQ-002: Must | High | Planning context is deterministic

Foreman MUST pass deterministic planning context to the selected workflow so artifacts can be correlated with the run.

- AC-002-1: Given run id `run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe`, when planning context is built, then `planning.correlation_id` is `b86c4907`.
- AC-002-2: Given task title `Smoke run with plan workflow task_type`, when planning context is built, then `planning.slug` is `smoke-run-with-plan-workflow-task-type`.
- AC-002-3: Given document year `2026`, when artifact paths are built, then PRD and TRD filenames are prefixed by `PRD-2026-b86c4907-` and `TRD-2026-b86c4907-`.

### REQ-003: Must | High | PRD command receives the exact artifact path

The `create-prd` phase MUST receive the exact PRD path from `planning.prd_path` and use it as the required output location.

- AC-003-1: Given `create-prd` starts, when its command context is materialized, then `planning.prd_path` equals `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`.
- AC-003-2: Given `/skill:ensemble-full-create-prd --foreman` runs, when it creates the PRD, then the file is written at that exact absolute path.
- AC-003-3: Given the PRD file is created elsewhere, when the required-file gate checks `planning.prd_path`, then `create-prd` fails with a missing required file result.

### REQ-004: Must | High | PRD artifact gate controls phase success

The `create-prd` phase MUST be considered successful only after the PRD exists at `planning.prd_path`.

- AC-004-1: Given the PRD command exits successfully, when the required-file gate runs, then Foreman verifies the file exists at `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`.
- AC-004-2: Given the PRD file is missing after command completion, when the gate runs, then `create-prd` fails with `:required_file_missing` and records the resolved path.
- AC-004-3: Given the PRD gate passes, when phase state is projected, then `create-prd` is visible as completed.

### REQ-005: Must | High | Plan workflow remains ordered after PRD creation

Foreman MUST keep the `plan` workflow ordered so later planning phases do not run before the PRD phase succeeds.

- AC-005-1: Given `create-prd` has not completed, when run state is inspected, then `create-trd` is not reported as completed.
- AC-005-2: Given `create-prd` fails its required-file gate, when the run projection is inspected, then the failure is associated with `create-prd` and the PRD path.
- AC-005-3: Given `create-prd` completes and the PRD gate passes, when the workflow advances, then `create-trd` is eligible to run using `planning.trd_path`.

### REQ-006: Should | Medium | Smoke output is operator-friendly

Foreman SHOULD expose enough data for operators to diagnose workflow-selection or artifact-gate failures without reading raw adapter logs first.

- AC-006-1: Given the run starts, when the operator inspects run details, then task id, task type, selected workflow, and phase id are visible.
- AC-006-2: Given workflow selection fails, when the operator inspects the failure, then output identifies `type: plan` and the absence or mismatch of a matching workflow.
- AC-006-3: Given artifact gating fails, when the operator inspects run output, then output includes phase name, required planning key, and resolved artifact path.

## 6. Dependencies

- Bundled `plan.yaml` workflow installed in the active Foreman runtime and mapped to task type `plan`.
- Ensemble PRD/TRD skills available to the Pi adapter.
- Foreman task provider and scheduler preserve the task `type` field through run creation.

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Task type is dropped or renamed before workflow selection | Wrong workflow or no workflow selected | Require visible task type and selected workflow in run details |
| Existing artifact from prior run masks path errors | False pass | Use unique correlation id `b86c4907` and exact artifact paths |

## 8. Success Metrics

- A run for task `foreman-foreman-smoke-logfix-2-0bve` selects the bundled `plan` workflow from `type: plan`.
- `create-prd` starts as the first required phase.
- PRD artifact exists at `docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`.
- `create-prd` phase completion is recorded only after the PRD required-file gate passes.

## 9. Open Questions

None for this smoke. Run id, task id, task type, correlation id, slug, and artifact paths are specified by the supplied phase context.

## 10. Readiness Checklist

- [x] User value stated
- [x] Task-type dispatch target stated
- [x] Required artifacts named
- [x] Acceptance criteria cover all requirements
- [x] Risks captured
- [x] Dependencies listed
- [ ] Paired TRD created

---

*Generated: 2026-08-09 | Document ID: PRD-2026-b86c4907 | Scale: LIGHT | Draft v0.1.0*
