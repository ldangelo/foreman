---
document_id: PRD-2026-c7004f12
label: prd-smoke-plan-workflow-v5-seqfix
version: 0.1.0
status: Draft
date: 2026-08-09
scale_depth: LIGHT
total_requirements: 6
readiness_score: 3.8
---

# PRD: Smoke — Plan Workflow v5 Sequence Fix

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

This PRD defines a smoke test for Foreman's `plan` workflow sequence fix. The smoke validates that a plan run executes `create-prd` and `create-trd` in order, writes both planning artifacts to the exact paths supplied in run context, and only reports `run.complete` after all required phase gates have passed.

The target regression is premature terminal completion. A successful run proves that `run.complete` is sequenced after the final required planning phase, not after the first planning artifact or an intermediate workflow state.

## 2. Background and Evidence

Foreman's bundled `plan` workflow creates planning documents through two command phases:

- `create-prd` runs `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` runs `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- Runtime context provides `working_directory`, `planning.prd_path`, `planning.trd_path`, `planning.correlation_id`, `planning.document_year`, and `planning.slug`.
- The run is complete only when every phase required by the workflow has completed and every configured artifact gate has passed.

Smoke context:

- Run id: `run-c7004f127c268a96b313fe40e8cb45d2`
- Phase id: `run-c7004f127c268a96b313fe40e8cb45d2-p001`
- Task id: `foreman-foreman-smoke-plan-seqfix-c-znan`
- Task title: `smoke plan workflow v5 seqfix`
- Task description: `Validates run.complete sequence fix`
- Correlation id: `c7004f12`
- Slug: `smoke-plan-workflow-v5-seqfix`
- PRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`
- TRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`

## 3. Personas

### 3.1 Foreman operator

Runs smoke workflows after scheduler, workflow, worker, or adapter changes. Needs a clear pass/fail signal that the run did not complete before all plan phases finished.

### 3.2 Foreman maintainer

Uses the smoke as a regression guard while changing run projection, phase sequencing, terminal event emission, workflow execution, or required-file gate behavior.

## 4. Goals and Non-Goals

### Goals

- Verify `plan` workflow phase order: `create-prd` before `create-trd`.
- Verify `run.complete` is emitted only after the final required phase completes.
- Verify PRD and TRD artifacts exist at exact planning paths.
- Make sequence failures diagnosable through run and phase telemetry.

### Non-Goals

- Scoring PRD/TRD content quality.
- Replacing lower-level unit tests for event sequencing.
- Testing all workflow types.
- Testing all Ensemble skill options.

## 5. Requirements

### REQ-001: Must | High | Plan workflow runs both phases in order

Foreman MUST execute the bundled `plan` workflow as an ordered sequence of planning phases.

- AC-001-1: Given task `foreman-foreman-smoke-plan-seqfix-c-znan` has type `plan`, when the run starts, then Foreman selects the bundled `plan` workflow.
- AC-001-2: Given the workflow starts, when phase execution is observed, then `create-prd` starts before `create-trd`.
- AC-001-3: Given `create-prd` fails, when the run projection is inspected, then `create-trd` is not reported as completed.

### REQ-002: Must | High | Deterministic planning context is preserved

Foreman MUST pass deterministic planning context to each planning phase so artifacts can be correlated with the run.

- AC-002-1: Given run id `run-c7004f127c268a96b313fe40e8cb45d2`, when planning context is built, then `planning.correlation_id` is `c7004f12`.
- AC-002-2: Given task title `smoke plan workflow v5 seqfix`, when planning context is built, then `planning.slug` is `smoke-plan-workflow-v5-seqfix`.
- AC-002-3: Given document year `2026`, when artifact paths are built, then PRD and TRD filenames are prefixed by `PRD-2026-c7004f12-` and `TRD-2026-c7004f12-`.

### REQ-003: Must | High | PRD artifact gate controls `create-prd` success

The `create-prd` phase MUST succeed only when the PRD exists at `planning.prd_path`.

- AC-003-1: Given `create-prd` receives `planning.prd_path`, when the command completes, then the file exists at `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`.
- AC-003-2: Given the PRD file is missing after command completion, when the required-file gate runs, then `create-prd` fails with `:required_file_missing` and records the missing path.
- AC-003-3: Given the PRD gate passes, when phase state is projected, then `create-prd` is visible as completed before `create-trd` starts.

### REQ-004: Must | High | TRD artifact gate controls `create-trd` success

The `create-trd` phase MUST succeed only when the TRD exists at `planning.trd_path`.

- AC-004-1: Given `create-trd` receives `planning.trd_path`, when the command completes, then the file exists at `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`.
- AC-004-2: Given the TRD file is missing after command completion, when the required-file gate runs, then `create-trd` fails with `:required_file_missing` and records the missing path.
- AC-004-3: Given the TRD gate passes, when phase state is projected, then `create-trd` is visible as completed.

### REQ-005: Must | Critical | `run.complete` is sequenced after all required phases

Foreman MUST not emit or project `run.complete` until every required phase in the selected workflow is completed and gated artifacts exist.

- AC-005-1: Given `create-prd` has completed but `create-trd` has not started or completed, when run state is queried, then the run is not terminal complete.
- AC-005-2: Given `create-trd` is running, blocked, failed, or missing its artifact, when run state is queried, then the run is not terminal complete.
- AC-005-3: Given both `create-prd` and `create-trd` complete and both required-file gates pass, when run state is projected, then `run.complete` is emitted or visible after the final phase completion event.

### REQ-006: Should | Medium | Sequence failures are operator-friendly

Foreman SHOULD expose enough run/phase data for operators to diagnose sequence failures without reading raw adapter logs first.

- AC-006-1: Given the run completes, when phase history is inspected, then both phase names and completion order are visible.
- AC-006-2: Given premature completion would have occurred, when the smoke fails or detects it, then output identifies that `run.complete` appeared before `create-trd` completion.
- AC-006-3: Given a required artifact is missing, when the operator inspects run output, then output includes phase name, planning key, and resolved artifact path.

## 6. Dependencies

- Bundled `plan.yaml` workflow installed in the active Foreman runtime.
- Ensemble PRD/TRD skills available to the Pi adapter.
- Foreman projection and event sequencing logic able to represent phase completion before terminal run completion.

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Premature completion is masked by artifact files from prior runs | False pass | Use unique correlation id `c7004f12` and exact artifact paths |
| Projection ordering differs from event-store ordering | Confusing operator result | Require visible phase history and terminal completion order in run output |

## 8. Success Metrics

- `create-prd` completes before `create-trd`.
- PRD artifact exists at `docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`.
- TRD artifact exists at `docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`.
- `run.complete` is observed only after `create-trd` completion and TRD required-file gate success.

## 9. Open Questions

None for this smoke. Run id, task id, correlation id, slug, and artifact paths are specified by the supplied phase context.

## 10. Readiness Checklist

- [x] User value stated
- [x] Sequence-fix target stated
- [x] Required artifacts named
- [x] Acceptance criteria cover all requirements
- [x] Risks captured
- [x] Dependencies listed
- [x] Paired TRD created

---

*Generated: 2026-08-09 | Document ID: PRD-2026-c7004f12 | Scale: LIGHT | Draft v0.1.0*
