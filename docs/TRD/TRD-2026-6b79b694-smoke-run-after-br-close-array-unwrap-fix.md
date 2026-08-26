---
document_id: TRD-2026-6b79b694
label: trd-smoke-run-after-br-close-array-unwrap-fix
version: 0.1.0
status: Draft
date: 2026-08-09
prd_reference: PRD-2026-6b79b694
prd_label: prd-smoke-run-after-br-close-array-unwrap-fix
scale_depth: LIGHT
total_requirements: 6
total_acceptance_criteria: 18
design_readiness_score: 3.8
readiness_score: 3.8
total_tasks: 9
kind: trd
---

# TRD: Smoke — Run After `br close` Array-Unwrap Fix

## 1. Executive Summary

This TRD implements PRD `PRD-2026-6b79b694` for a Foreman smoke run after the Beads `br close --json` singleton-array acknowledgement fix. The smoke verifies that a `type: plan` task selects the bundled `plan` workflow, creates PRD/TRD artifacts at deterministic paths, then completes through Beads provider close handling without failing when `br close --json` returns `[ { ... } ]` instead of `{ ... }`.

The regression target is terminal Beads completion. A passing run proves Foreman accepts only a singleton array whose item has the requested task id and `status: closed`, while rejecting wrong-id, non-closed, malformed, or multi-item acknowledgements.

Target artifacts:

- PRD: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`
- TRD: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md`

## 2. Scope

### 2.1 In Scope

- Validate task type `plan` selects the bundled `plan` workflow.
- Validate `create-prd` runs before `create-trd`.
- Validate deterministic planning context for run `run-6b79b6948c5b2de0cb679a6d92c44e9a`.
- Validate required-file gates use exact `planning.prd_path` and `planning.trd_path` values.
- Validate terminal completion invokes `br close <task-id> --json`.
- Validate singleton-array `br close` acknowledgement handling.
- Validate provider completion errors remain diagnosable and do not falsely close wrong tasks.

### 2.2 Out of Scope

- Semantic scoring of generated PRD/TRD quality.
- Testing every Beads command.
- Replacing unit tests for `BeadsAdapter.complete/3`.
- Validating non-Beads task providers.
- Retrying unrelated workflow or infrastructure failures.

## 3. Existing System Assumptions

- Active Foreman runtime has bundled workflows installed from `packages/foreman_server/priv/defaults/workflows`.
- Bundled workflow `plan` is mapped to tasks with `type: plan`.
- Bundled `plan` workflow phase order is:
  1. `create-prd`
  2. `create-trd`
- `create-prd` invokes `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` invokes `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- Required-file gates validate exact resolved artifact paths after command completion.
- Beads task provider terminal completion uses `br close <id> --json`, not `br update --status closed`.

## 4. Technical Design

### 4.1 Workflow Selection Contract

Foreman SHALL select the bundled `plan` workflow when a task's normalized type equals `plan`.

Selection inputs:

| Field | Expected value |
|---|---|
| Task id | `foreman-foreman-smoke-logfix-3-pqhs` |
| Task title | `Smoke run after br close array-unwrap fix` |
| Task type | `plan` |
| Expected workflow | `plan` |

Selection rules:

1. Prefer explicit task type over title text.
2. Match `type: plan` to workflow `plan`.
3. Do not require a CLI workflow override for this smoke.
4. Emit enough run metadata to show task type and selected workflow.

Failure behavior:

```text
workflow_selection_failed(task_id, task_type: "plan", reason: no_matching_workflow)
```

### 4.2 Plan Workflow Phase Contract

The active workflow SHALL resolve the following phase order:

| Order | Phase name | Command | Required file key |
|---:|---|---|---|
| 1 | `create-prd` | `/skill:ensemble-full-create-prd --foreman` | `planning.prd_path` |
| 2 | `create-trd` | `/skill:ensemble-full-create-trd --foreman` | `planning.trd_path` |

`create-trd` SHALL start only after `create-prd` exits successfully and the PRD required-file gate passes.

### 4.3 Deterministic Planning Context

The smoke context SHALL be materialized as:

```json
{
  "run_id": "run-6b79b6948c5b2de0cb679a6d92c44e9a",
  "task_id": "foreman-foreman-smoke-logfix-3-pqhs",
  "phase_id": "run-6b79b6948c5b2de0cb679a6d92c44e9a-p002",
  "working_directory": "/Users/ldangelo/Development/Fortium/foreman",
  "planning": {
    "correlation_id": "6b79b694",
    "document_year": 2026,
    "slug": "smoke-run-after-br-close-array-unwrap-fix",
    "prd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md",
    "trd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md"
  }
}
```

Validation SHALL treat supplied context paths as authoritative. No alternate PRD/TRD path may satisfy required-file gates.

### 4.4 PRD Required-File Gate

After `create-prd` exits successfully, Foreman SHALL resolve `planning.prd_path` and assert the file exists.

Pass condition:

```elixir
File.regular?("/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md") == true
```

Fail condition:

```elixir
{:error, :required_file_missing,
 %{
   phase: "create-prd",
   key: "planning.prd_path",
   path: "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md"
 }}
```

### 4.5 TRD Required-File Gate

After `create-trd` exits successfully, Foreman SHALL resolve `planning.trd_path` and assert this file exists.

Pass condition:

```elixir
File.regular?("/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md") == true
```

Fail condition:

```elixir
{:error, :required_file_missing,
 %{
   phase: "create-trd",
   key: "planning.trd_path",
   path: "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md"
 }}
```

### 4.6 Beads Completion Invocation

After both planning phases complete, Foreman SHALL invoke the Beads task provider completion path for task `foreman-foreman-smoke-logfix-3-pqhs`.

Expected command shape:

```bash
br close foreman-foreman-smoke-logfix-3-pqhs --json
```

The provider SHALL not use this deprecated/incorrect substitute for terminal completion:

```bash
br update foreman-foreman-smoke-logfix-3-pqhs --status closed
```

Completion SHALL be recorded only after provider acknowledgement validation succeeds, or after a documented idempotent already-terminal condition.

### 4.7 Close Acknowledgement Decoder

The Beads adapter SHALL normalize `br close --json` output before validating it.

Accepted object shape:

```json
{"id":"foreman-foreman-smoke-logfix-3-pqhs","status":"closed"}
```

Accepted singleton-array shape:

```json
[{"id":"foreman-foreman-smoke-logfix-3-pqhs","status":"closed"}]
```

Validation rules:

1. If output is a JSON object, validate that object.
2. If output is a JSON array, accept only arrays with exactly one item.
3. Validate item/object `id` equals requested task id.
4. Validate item/object `status` equals `closed`.
5. Reject empty arrays, multi-item arrays, wrong ids, non-closed statuses, non-object items, malformed JSON, or missing fields with a provider contract error.

Suggested pure function shape:

```elixir
defp normalize_close_ack(%{} = ack), do: {:ok, ack}
defp normalize_close_ack([%{} = ack]), do: {:ok, ack}
defp normalize_close_ack(_), do: {:error, :invalid_close_ack_shape}
```

### 4.8 Provider Error Mapping and Diagnostics

When close acknowledgement validation fails, Foreman SHALL expose a bounded provider error containing:

- command family: `br close`
- task id: `foreman-foreman-smoke-logfix-3-pqhs`
- closed-vocabulary reason, e.g. `:invalid_close_ack_shape`, `:close_ack_id_mismatch`, or `:close_ack_status_not_closed`

Provider diagnostics SHALL avoid leaking raw unsafe side-channel text. Raw command output may be retained only in existing internal debug artifacts/logs subject to normal sanitization.

## 5. Implementation Tasks

### Task 1 — Verify workflow type mapping

- Inspect installed/source workflow metadata and workflow-selection path.
- Confirm a task with `type: plan` resolves to workflow `plan`.
- Confirm title text is not the deciding input.

Done when: run metadata shows selected workflow `plan` for task type `plan`.

### Task 2 — Verify active plan workflow phase order

- Inspect active bundled `plan` workflow.
- Confirm `create-prd` appears before `create-trd`.
- Confirm required file keys are `planning.prd_path` and `planning.trd_path`.

Done when: resolved phase order is `create-prd`, then `create-trd`.

### Task 3 — Verify deterministic context

- Validate run id, task id, phase id, correlation id, slug, year, and working directory.
- Validate PRD/TRD absolute paths match sections 4.3-4.5.
- Ensure retries reuse the same context for this run.

Done when: phase context matches section 4.3 exactly.

### Task 4 — Verify PRD artifact gate

- Confirm PRD exists at `planning.prd_path`.
- Confirm missing PRD fails `create-prd` with `:required_file_missing` in isolated validation.
- Confirm `create-prd` completion is recorded only after gate success.

Done when: PRD gate pass/fail is tied to exact PRD path.

### Task 5 — Verify TRD artifact gate

- Confirm this TRD exists at `planning.trd_path`.
- Confirm missing TRD fails `create-trd` with `:required_file_missing` in isolated validation.
- Confirm `create-trd` completion is recorded only after gate success.

Done when: TRD gate pass/fail is tied to exact TRD path.

### Task 6 — Verify provider completion command

- Inspect provider execution or runtime event output after workflow success.
- Confirm Foreman invokes `br close foreman-foreman-smoke-logfix-3-pqhs --json`.
- Confirm Foreman does not substitute `br update --status closed`.

Done when: terminal completion evidence shows the `br close` command path.

### Task 7 — Verify singleton-array acknowledgement acceptance

- Use runtime smoke evidence or targeted adapter test evidence.
- Confirm `[ { "id": "foreman-foreman-smoke-logfix-3-pqhs", "status": "closed" } ]` returns success.
- Confirm object-shaped acknowledgement remains accepted.

Done when: valid object and valid singleton-array acknowledgements both close successfully.

### Task 8 — Verify acknowledgement rejection cases

- Confirm singleton array with wrong id fails.
- Confirm singleton array with non-closed status fails.
- Confirm empty/multi-item arrays fail.
- Confirm malformed output maps to a provider contract error.

Done when: invalid acknowledgements cannot report terminal task success.

### Task 9 — Record smoke result

- Capture pass/fail evidence for workflow selection, phase order, artifact gates, provider command, and close acknowledgement shape.
- If source workflows or prompts changed, run `foreman init --force` before dispatch validation.
- Preserve artifact paths in the run report.

Done when: smoke result includes selected workflow, phase order, PRD path, TRD path, `br close` command, and acknowledgement validation outcome.

## 6. Validation Plan

### 6.1 Static Validation

Read active `plan` workflow and confirm:

- workflow name/type mapping is `plan`
- `create-prd` is first
- `create-prd.requiredFile` is `planning.prd_path`
- `create-trd.requiredFile` is `planning.trd_path`

Read Beads adapter completion code and confirm:

- terminal completion uses `br close`
- object acknowledgement shape is accepted
- singleton-array acknowledgement shape is unwrapped and validated
- wrong id, non-closed status, malformed, empty array, and multi-item array cases fail

### 6.2 Artifact Validation

Run checks:

```bash
test -f /Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md
test -f /Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md
```

Pass criteria:

- Both commands exit `0`.
- Paths match `planning.prd_path` and `planning.trd_path` exactly.

### 6.3 Targeted Adapter Validation

Run targeted Beads adapter tests that cover close acknowledgement decoding.

Minimum cases:

| Case | Input | Expected |
|---|---|---|
| Object closed | `{ "id": task_id, "status": "closed" }` | success |
| Singleton array closed | `[ { "id": task_id, "status": "closed" } ]` | success |
| Wrong id | `[ { "id": "other", "status": "closed" } ]` | provider contract error |
| Non-closed status | `[ { "id": task_id, "status": "open" } ]` | provider contract error |
| Multi-item array | `[ { ... }, { ... } ]` | provider contract error |

### 6.4 Runtime Smoke Validation

When the Foreman run is executed, validate authoritative event/projection order:

```text
workflow.selected(plan)
phase.started(create-prd)
phase.completed(create-prd)
phase.started(create-trd)
phase.completed(create-trd)
provider.complete.started(br close)
provider.complete.succeeded(task_id: foreman-foreman-smoke-logfix-3-pqhs)
run.completed
```

Terminal run completion must occur after `phase.completed(create-trd)` and provider close success.

### 6.5 Negative Artifact Validation

Temporarily moving either required file during an isolated validation run should cause the owning phase to fail with:

- reason: `:required_file_missing`
- key: `planning.prd_path` or `planning.trd_path`
- path: exact resolved absolute path

Do not perform destructive negative validation against shared smoke artifacts unless using an isolated copy or disposable run.

## 7. Requirement Traceability

| PRD Requirement | Design coverage | Validation |
|---|---|---|
| REQ-001: Plan task dispatch remains intact | Sections 4.1, 5 Tasks 1-2 | Runtime selected workflow and phase order |
| REQ-002: Planning context is deterministic | Sections 4.3, 5 Task 3 | Context/path inspection |
| REQ-003: Required planning artifacts gate phase success | Sections 4.2, 4.4, 4.5, 5 Tasks 4-5 | Artifact checks and phase-gate evidence |
| REQ-004: Beads completion accepts singleton array close acknowledgement | Sections 4.7, 5 Tasks 7-8 | Targeted adapter tests and smoke close evidence |
| REQ-005: Terminal run completion records successful provider close | Sections 4.6, 4.8, 5 Task 6 | Runtime provider completion events/output |
| REQ-006: Smoke output is operator-friendly | Sections 4.8, 5 Task 9 | Run details/projection/provider diagnostics |

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Existing artifacts from prior run mask gate failure | False pass | Use unique correlation id `6b79b694` and exact absolute paths |
| Singleton-array unwrap accepts too broad a shape | Wrong task closure or false success | Accept exactly one object, then validate exact id and `status: closed` |
| Provider diagnostics leak raw command output | Unsafe/noisy operator output | Emit closed-vocabulary error code and bounded command/task metadata |
| Runtime workflow copy is stale | Smoke validates old behavior | Run `foreman init --force` after workflow/prompt source changes |
| Projection lags event store | Apparent order mismatch | Validate against authoritative ordered events when needed |

## 9. Rollback Plan

This TRD is a planning artifact only. If it is incorrect:

1. Replace or amend this file at `planning.trd_path`.
2. Preserve document id `TRD-2026-6b79b694` and the same path unless run context changes.
3. Re-run artifact existence validation.

No runtime code rollback is required for this document.

## 10. Open Questions

None. The run id, task id, task type, correlation id, slug, PRD path, and TRD path are supplied by context.

## 11. Readiness Checklist

- [x] PRD reference captured
- [x] Task-type dispatch design captured
- [x] Phase order captured
- [x] Required artifact paths captured
- [x] Beads close acknowledgement contract captured
- [x] Provider completion diagnostics captured
- [x] Validation plan captured
- [x] Requirement traceability complete
- [x] Paired PRD exists

---

*Generated: 2026-08-09 | Document ID: TRD-2026-6b79b694 | Scale: LIGHT | Draft v0.1.0*
