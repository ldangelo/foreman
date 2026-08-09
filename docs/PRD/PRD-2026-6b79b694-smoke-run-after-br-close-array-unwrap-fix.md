---
document_id: PRD-2026-6b79b694
label: prd-smoke-run-after-br-close-array-unwrap-fix
version: 0.1.0
status: Draft
date: 2026-08-09
scale_depth: LIGHT
total_requirements: 6
readiness_score: 3.8
---

# PRD: Smoke — Run After `br close` Array-Unwrap Fix

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

This PRD defines a Foreman smoke run after the Beads `br close --json` array-unwrap fix. The smoke validates that a `type: plan` task can execute the bundled `plan` workflow, create planning artifacts at deterministic paths, and complete through the Beads task provider without failing when `br close` returns a singleton JSON array instead of a JSON object.

The target regression is terminal task completion for Beads-backed runs. A successful smoke proves Foreman's Beads adapter accepts a singleton array acknowledgement from `br close`, validates that the acknowledged issue id matches the task id, validates that the returned status is `closed`, and treats the completion as successful.

## 2. Background and Evidence

Foreman's bundled `plan` workflow creates planning documents through ordered command phases:

- `create-prd` runs `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` runs `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- Runtime context provides `working_directory`, `planning.prd_path`, `planning.trd_path`, `planning.correlation_id`, `planning.document_year`, and `planning.slug`.
- Required-file gates fail a phase if the expected artifact is not present at the resolved path.

The fixed Beads adapter behavior is expected to handle `br close --json` payloads shaped as either:

```json
{"id":"task-id","status":"closed"}
```

or:

```json
[{"id":"task-id","status":"closed"}]
```

Smoke context:

- Run id: `run-6b79b6948c5b2de0cb679a6d92c44e9a`
- Phase id: `run-6b79b6948c5b2de0cb679a6d92c44e9a-p001`
- Task id: `foreman-foreman-smoke-logfix-3-pqhs`
- Task title: `Smoke run after br close array-unwrap fix`
- Task description: empty
- Task type: `plan`
- Correlation id: `6b79b694`
- Slug: `smoke-run-after-br-close-array-unwrap-fix`
- PRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`
- TRD path: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`

## 3. Personas

### 3.1 Foreman operator

Runs smoke workflows after Beads adapter, task-provider, scheduler, or run-completion changes. Needs a clear pass/fail signal that successful runs close their Beads tasks.

### 3.2 Foreman maintainer

Uses the smoke as a regression guard while modifying `BeadsAdapter.complete/3`, command output decoding, provider error mapping, required-file gates, or terminal run handling.

## 4. Goals and Non-Goals

### Goals

- Verify a task with `type: plan` selects the bundled `plan` workflow.
- Verify `create-prd` and `create-trd` write artifacts at exact planning paths.
- Verify terminal run completion invokes Beads task completion through `br close`.
- Verify a singleton JSON array acknowledgement from `br close` is accepted when it contains the requested id and `status: closed`.
- Keep failures diagnosable through visible phase, artifact path, provider command, task id, and close acknowledgement shape.

### Non-Goals

- Scoring PRD or TRD content quality.
- Testing every Beads command.
- Replacing targeted unit tests for `BeadsAdapter.complete/3`.
- Validating non-Beads task providers.
- Retrying or repairing unrelated workflow failures.

## 5. Requirements

### REQ-001: Must | Critical | Plan task dispatch remains intact

Foreman MUST select the bundled `plan` workflow when this smoke task declares `type: plan`.

- AC-001-1: Given task `foreman-foreman-smoke-logfix-3-pqhs` has `type: plan`, when the run starts, then Foreman selects the bundled `plan` workflow.
- AC-001-2: Given the selected workflow is resolved, when phase order is inspected, then `create-prd` is first and `create-trd` follows.
- AC-001-3: Given the task title mentions a Beads close fix, when workflow selection occurs, then selection is based on task type rather than title text.

### REQ-002: Must | High | Planning context is deterministic

Foreman MUST pass deterministic planning context to planning phases so artifacts can be correlated with this smoke run.

- AC-002-1: Given run id `run-6b79b6948c5b2de0cb679a6d92c44e9a`, when planning context is built, then `planning.correlation_id` is `6b79b694`.
- AC-002-2: Given task title `Smoke run after br close array-unwrap fix`, when planning context is built, then `planning.slug` is `smoke-run-after-br-close-array-unwrap-fix`.
- AC-002-3: Given document year `2026`, when artifact paths are built, then PRD and TRD filenames are prefixed by `PRD-2026-6b79b694-` and `TRD-2026-6b79b694-`.

### REQ-003: Must | High | Required planning artifacts gate phase success

Foreman MUST mark planning phases successful only after their required artifacts exist at the exact resolved paths.

- AC-003-1: Given `create-prd` completes, when the required-file gate runs, then the PRD exists at `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`.
- AC-003-2: Given `create-trd` completes, when the required-file gate runs, then the TRD exists at `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`.
- AC-003-3: Given either artifact is missing after command completion, when its gate runs, then the corresponding phase fails with `:required_file_missing` and records the resolved path.

### REQ-004: Must | Critical | Beads completion accepts singleton array close acknowledgement

Foreman's Beads task provider MUST accept a singleton JSON array returned by `br close --json` as a valid close acknowledgement when it represents the requested task in closed state.

- AC-004-1: Given the run completes successfully, when Foreman invokes `br close foreman-foreman-smoke-logfix-3-pqhs --json`, then a response shaped as `[ { "id": "foreman-foreman-smoke-logfix-3-pqhs", "status": "closed" } ]` is treated as a successful close acknowledgement.
- AC-004-2: Given the singleton array contains a different id, when the adapter validates the acknowledgement, then completion fails with a provider contract error rather than closing the wrong task.
- AC-004-3: Given the singleton array contains the requested id but a non-closed status, when the adapter validates the acknowledgement, then completion fails with a provider contract error rather than reporting terminal success.

### REQ-005: Must | High | Terminal run completion records successful provider close

Foreman MUST record the smoke run as terminal complete only after workflow phases pass and Beads task completion succeeds or is idempotently already terminal.

- AC-005-1: Given both planning artifact gates pass, when terminal completion is processed, then Foreman invokes the Beads provider completion path using `br close`, not `br update --status closed`.
- AC-005-2: Given `br close` returns a valid object or singleton-array close acknowledgement, when provider completion returns, then the runner records task execution completion.
- AC-005-3: Given provider completion fails acknowledgement validation, when the run result is inspected, then the failure is associated with Beads close handling and does not silently mark the task closed.

### REQ-006: Should | Medium | Smoke output is operator-friendly

Foreman SHOULD expose enough output for operators to diagnose workflow, artifact, or Beads close failures without reading raw adapter logs first.

- AC-006-1: Given the run starts, when run details are inspected, then task id, task type, selected workflow, and phase id are visible.
- AC-006-2: Given artifact gating fails, when run output is inspected, then output includes phase name, required planning key, and resolved artifact path.
- AC-006-3: Given Beads close acknowledgement validation fails, when provider output is inspected, then output identifies command `br close`, task id, and closed-vocab provider error code without leaking raw unsafe side-channel text.

## 6. Dependencies

- Bundled `plan.yaml` workflow installed in the active Foreman runtime and mapped to task type `plan`.
- Ensemble PRD/TRD skills available to the Pi adapter.
- Beads CLI and Foreman Beads task provider available for `br close --json` completion handling.

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Existing artifacts from a prior run mask phase-gate problems | False pass | Use unique correlation id `6b79b694` and exact artifact paths |
| Array unwrap accepts malformed or multi-item close output too broadly | Wrong task closure or false success | Require singleton-array shape plus exact id match and `status: closed` validation |

## 8. Success Metrics

- The run for task `foreman-foreman-smoke-logfix-3-pqhs` selects the bundled `plan` workflow from `type: plan`.
- PRD artifact exists at `docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`.
- TRD artifact exists at `docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`.
- Beads provider completion accepts a valid singleton-array `br close` acknowledgement and records terminal task completion.

## 9. Open Questions

None for this smoke. Run id, task id, task type, correlation id, slug, and artifact paths are specified by the supplied phase context.

## 10. Readiness Checklist

- [x] User value stated
- [x] Regression target stated
- [x] Required artifacts named
- [x] Acceptance criteria cover all requirements
- [x] Risks captured
- [x] Dependencies listed
- [ ] Paired TRD created

---

*Generated: 2026-08-09 | Document ID: PRD-2026-6b79b694 | Scale: LIGHT | Draft v0.1.0*
