---
document_id: PRD-2026-8066e22d
label: prd-smoke-run-after-closed-issue-schema-fix
version: 0.1.0
status: Draft
date: 2026-08-09
scale_depth: LIGHT
total_requirements: 6
readiness_score: 3.8
---

# PRD: Smoke — Run After Closed-Issue Schema Fix

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

This PRD defines a Foreman smoke run after the Beads closed-issue schema fix. The smoke validates that a `type: plan` task can execute the bundled `plan` workflow, create deterministic planning artifacts, and complete through the Beads task provider after `br close --json` returns a closed issue payload that must pass the cached `:closed_issue` schema.

The target regression is terminal Beads task completion after the adapter began validating closed issue payloads against the correct schema. A successful smoke proves Foreman still selects the `plan` workflow, creates the PRD and TRD at exact context paths, invokes `br close`, validates the returned closed issue payload, and records terminal run completion only after provider completion succeeds.

## 2. Background and Evidence

Foreman's bundled `plan` workflow creates planning documents through ordered command phases:

- `create-prd` runs `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` runs `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- Runtime context provides `working_directory`, `planning.prd_path`, `planning.trd_path`, `planning.correlation_id`, `planning.document_year`, and `planning.slug`.
- Required-file gates fail a phase if the expected artifact is not present at the resolved path.

The fixed Beads adapter behavior is expected to parse `br close --json` output as a closed issue payload and validate it through `JsonSchemaCache.validate(:closed_issue, payload)` before returning a terminal `%Issue{status: "closed"}`. The payload must include the required issue fields, match the requested id, and report `status: "closed"`.

Smoke context:

- Run id: `run-8066e22db819f69002468779cafeee11`
- Phase id: `run-8066e22db819f69002468779cafeee11-p001`
- Task id: `foreman-foreman-smoke-closchema-l8wb`
- Task title: `Smoke run after closed-issue schema fix`
- Task description: empty
- Task type: `plan`
- Correlation id: `8066e22d`
- Slug: `smoke-run-after-closed-issue-schema-fix`
- PRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`
- TRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`

## 3. Personas

### 3.1 Foreman operator

Runs smoke workflows after Beads adapter, schema-cache, task-provider, scheduler, or terminal-completion changes. Needs a clear pass/fail signal that successful runs close their Beads tasks with schema-valid closed issue payloads.

### 3.2 Foreman maintainer

Uses the smoke as a regression guard while modifying `BeadsAdapter.complete/3`, `JsonSchemaCache`, provider error mapping, required-file gates, or terminal run handling.

## 4. Goals and Non-Goals

### Goals

- Verify a task with `type: plan` selects the bundled `plan` workflow.
- Verify `create-prd` and `create-trd` write artifacts at exact planning paths.
- Verify terminal run completion invokes Beads task completion through `br close --json`.
- Verify the closed issue acknowledgement is validated against the cached `:closed_issue` schema.
- Verify schema, id, and status failures do not silently mark the task complete.
- Keep failures diagnosable through visible phase, artifact path, provider command, task id, and provider error code.

### Non-Goals

- Scoring PRD or TRD content quality.
- Testing every Beads command or every issue schema field variation.
- Replacing targeted unit tests for `BeadsAdapter.complete/3` or `JsonSchemaCache`.
- Validating non-Beads task providers.
- Retrying or repairing unrelated workflow failures.

## 5. Requirements

### REQ-001: Must | Critical | Plan task dispatch remains intact

Foreman MUST select the bundled `plan` workflow when this smoke task declares `type: plan`.

- AC-001-1: Given task `foreman-foreman-smoke-closchema-l8wb` has `type: plan`, when the run starts, then Foreman selects the bundled `plan` workflow.
- AC-001-2: Given the selected workflow is resolved, when phase order is inspected, then `create-prd` is first and `create-trd` follows.
- AC-001-3: Given the task title mentions a closed-issue schema fix, when workflow selection occurs, then selection is based on task type rather than title text.

### REQ-002: Must | High | Planning context is deterministic

Foreman MUST pass deterministic planning context to planning phases so artifacts can be correlated with this smoke run.

- AC-002-1: Given run id `run-8066e22db819f69002468779cafeee11`, when planning context is built, then `planning.correlation_id` is `8066e22d`.
- AC-002-2: Given task title `Smoke run after closed-issue schema fix`, when planning context is built, then `planning.slug` is `smoke-run-after-closed-issue-schema-fix`.
- AC-002-3: Given document year `2026`, when artifact paths are built, then PRD and TRD filenames are prefixed by `PRD-2026-8066e22d-` and `TRD-2026-8066e22d-`.

### REQ-003: Must | High | Required planning artifacts gate phase success

Foreman MUST mark planning phases successful only after their required artifacts exist at the exact resolved paths.

- AC-003-1: Given `create-prd` completes, when the required-file gate runs, then the PRD exists at `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`.
- AC-003-2: Given `create-trd` completes, when the required-file gate runs, then the TRD exists at `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`.
- AC-003-3: Given either artifact is missing after command completion, when its gate runs, then the corresponding phase fails with `:required_file_missing` and records the resolved path.

### REQ-004: Must | Critical | Beads completion validates the closed issue schema

Foreman's Beads task provider MUST validate a successful `br close --json` acknowledgement as a closed issue payload before accepting terminal completion.

- AC-004-1: Given the run completes successfully, when Foreman invokes `br close foreman-foreman-smoke-closchema-l8wb --json`, then the returned payload is validated with the cached `:closed_issue` schema.
- AC-004-2: Given the closed issue payload is missing schema-required fields, when the adapter validates the acknowledgement, then completion fails with `SCHEMA_VALIDATION_FAILED` rather than reporting terminal success.
- AC-004-3: Given the payload passes schema validation but contains a different id or non-closed status, when the adapter validates the acknowledgement, then completion fails with `BR_CONTRACT_MISMATCH` rather than closing the wrong task or reporting false success.

### REQ-005: Must | High | Terminal run completion records successful provider close

Foreman MUST record the smoke run as terminal complete only after workflow phases pass and Beads task completion succeeds or is idempotently already terminal.

- AC-005-1: Given both planning artifact gates pass, when terminal completion is processed, then Foreman invokes the Beads provider completion path using `br close`, not `br update --status closed`.
- AC-005-2: Given `br close` returns a schema-valid closed issue acknowledgement for `foreman-foreman-smoke-closchema-l8wb`, when provider completion returns, then the runner records task execution completion.
- AC-005-3: Given provider completion fails schema or contract validation, when the run result is inspected, then the failure is associated with Beads close handling and does not silently mark the task closed.

### REQ-006: Should | Medium | Smoke output is operator-friendly

Foreman SHOULD expose enough output for operators to diagnose workflow, artifact, schema, or Beads close failures without reading raw adapter logs first.

- AC-006-1: Given the run starts, when run details are inspected, then task id, task type, selected workflow, and phase id are visible.
- AC-006-2: Given artifact gating fails, when run output is inspected, then output includes phase name, required planning key, and resolved artifact path.
- AC-006-3: Given closed issue schema validation fails, when provider output is inspected, then output identifies command `br close`, task id, and closed-vocab provider error code without leaking raw unsafe side-channel text.

## 6. Dependencies

- Bundled `plan.yaml` workflow installed in the active Foreman runtime and mapped to task type `plan`.
- Ensemble PRD/TRD skills available to the Pi adapter.
- Beads CLI, cached `:closed_issue` schema, and Foreman Beads task provider available for `br close --json` completion handling.

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Existing artifacts from a prior run mask phase-gate problems | False pass | Use unique correlation id `8066e22d` and exact artifact paths |
| Closed issue schema cache is stale or mismatched with installed `br` output | False failure or provider contract drift | Surface `SCHEMA_VALIDATION_FAILED` with command context and refresh / reinstall runtime assets before dispatch validation |

## 8. Success Metrics

- The run for task `foreman-foreman-smoke-closchema-l8wb` selects the bundled `plan` workflow from `type: plan`.
- PRD artifact exists at `docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`.
- TRD artifact exists at `docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`.
- Beads provider completion accepts a schema-valid `br close` acknowledgement and records terminal task completion.

## 9. Open Questions

None for this smoke. Run id, task id, task type, correlation id, slug, and artifact paths are specified by the supplied phase context.

## 10. Readiness Checklist

- [x] User value stated
- [x] Regression target stated
- [x] Required artifacts named
- [x] Acceptance criteria cover all requirements
- [x] Risks captured
- [x] Dependencies listed
- [x] Paired TRD created

---

*Generated: 2026-08-09 | Document ID: PRD-2026-8066e22d | Scale: LIGHT | Draft v0.1.0*
