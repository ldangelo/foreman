---
document_id: TRD-2026-b86c4907
label: trd-smoke-run-with-plan-workflow-task-type
version: 0.1.0
status: Draft
date: 2026-08-09
prd_reference: PRD-2026-b86c4907
prd_label: prd-smoke-run-with-plan-workflow-task-type
scale_depth: LIGHT
total_requirements: 6
total_acceptance_criteria: 18
design_readiness_score: 3.8
readiness_score: 3.8
total_tasks: 8
kind: trd
---

# TRD: Smoke — Run With Plan Workflow Task Type

## 1. Executive Summary

This TRD implements PRD `PRD-2026-b86c4907` for a Foreman smoke run whose task declares `type: plan`. The smoke verifies that Foreman selects the bundled `plan` workflow from task type, starts `create-prd` first, preserves deterministic planning context, and gates phase success on exact planning artifact paths.

The regression target is workflow dispatch by task type. The run must not rely on task title matching, ad hoc workflow overrides, or inferred artifact paths.

Target artifacts:

- PRD: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`
- TRD: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md`

## 2. Scope

### 2.1 In Scope

- Validate bundled workflow selection for tasks with `type: plan`.
- Validate the first required phase is `create-prd`.
- Validate deterministic planning context for run `run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe`.
- Validate `create-prd` receives and gates on `planning.prd_path`.
- Validate `create-trd` is eligible only after `create-prd` completes successfully.
- Validate operator-facing run output includes task type, selected workflow, phase, and artifact-path details.

### 2.2 Out of Scope

- Semantic scoring of generated PRD/TRD quality.
- Testing every workflow type.
- Replacing unit tests for workflow loader/task provider parsing.
- Validating all Ensemble skill options.
- Proving long-running timeout behavior beyond this smoke.

## 3. Existing System Assumptions

- The active Foreman runtime installs bundled workflows from `packages/foreman_server/priv/defaults/workflows`.
- The bundled `plan` workflow is named `plan` and is mapped to task type `plan` by workflow-selection code or installed workflow metadata.
- The bundled `plan` workflow has two command phases, ordered as:
  1. `create-prd`
  2. `create-trd`
- `create-prd` invokes `/skill:ensemble-full-create-prd --foreman` and requires `planning.prd_path`.
- `create-trd` invokes `/skill:ensemble-full-create-trd --foreman` and requires `planning.trd_path`.
- Required-file gates check the exact resolved path after command completion and fail the phase with `:required_file_missing` when absent.

## 4. Technical Design

### 4.1 Workflow Selection Contract

Foreman SHALL select the bundled `plan` workflow when a task's normalized type equals `plan`.

Selection inputs:

| Field | Expected value |
|---|---|
| Task id | `foreman-foreman-smoke-logfix-2-0bve` |
| Task title | `Smoke run with plan workflow task_type` |
| Task type | `plan` |
| Expected workflow | `plan` |

Selection rules:

1. Prefer explicit task type over task title text.
2. Match `type: plan` to the workflow assigned to planning tasks.
3. Do not require a CLI workflow override for this smoke.
4. Emit enough run metadata to show selected workflow and original task type.

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

`create-prd` is the first required phase. `create-trd` must not be projected as complete unless `create-prd` completed and the PRD required-file gate passed.

### 4.3 Deterministic Planning Context

The smoke context SHALL be materialized as:

```json
{
  "run_id": "run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe",
  "task_id": "foreman-foreman-smoke-logfix-2-0bve",
  "phase_id": "run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe-p002",
  "working_directory": "/Users/ldangelo/Development/Fortium/foreman",
  "planning": {
    "correlation_id": "b86c4907",
    "document_year": 2026,
    "slug": "smoke-run-with-plan-workflow-task-type",
    "prd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md",
    "trd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md"
  }
}
```

Derivation rules:

```text
correlation_id = first 8 hex chars after run- prefix
slug = normalized task title, lowercase, hyphenated
PRD path = docs/PRD/PRD-{year}-{correlation_id}-{slug}.md
TRD path = docs/TRD/TRD-{year}-{correlation_id}-{slug}.md
```

Validation SHALL treat supplied context paths as authoritative. No alternate PRD/TRD path may satisfy the gate.

### 4.4 PRD Required-File Gate

After the `create-prd` command exits successfully, Foreman SHALL resolve `planning.prd_path` and assert the file exists.

Pass condition:

```elixir
File.regular?("/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md") == true
```

Fail condition:

```elixir
{:error, :required_file_missing,
 %{
   phase: "create-prd",
   key: "planning.prd_path",
   path: "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md"
 }}
```

The phase SHALL only project as completed after this gate passes.

### 4.5 Ordered Advancement to TRD Phase

The workflow executor SHALL advance from `create-prd` to `create-trd` only after all `create-prd` success conditions hold:

1. Command exits successfully.
2. `planning.prd_path` resolves to the supplied absolute path.
3. Required file exists at that path.
4. Phase state is persisted/projected as complete.

If `create-prd` fails, the failure SHALL remain associated with `create-prd` and the PRD path. `create-trd` SHALL remain pending/not completed.

### 4.6 TRD Required-File Gate

The `create-trd` phase SHALL resolve `planning.trd_path` and gate completion on this file:

```elixir
File.regular?("/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md") == true
```

This TRD file is the expected artifact for phase `run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe-p002`.

### 4.7 Operator-Facing Diagnostics

Run and phase inspection SHALL expose at least:

| Scenario | Required diagnostic fields |
|---|---|
| Run start | `run_id`, `task_id`, `task_type`, selected workflow, current phase id/name |
| Selection failure | `task_id`, `task_type`, attempted workflow match, reason |
| PRD gate failure | phase name, `planning.prd_path`, resolved path, `:required_file_missing` |
| Phase success | completed phase name, required file key, resolved path |

## 5. Implementation Tasks

### Task 1 — Verify workflow type mapping

- Inspect installed/source workflow metadata and workflow-selection path.
- Confirm a task with `type: plan` resolves to workflow `plan`.
- Confirm title text is not the deciding input.

Done when: run metadata shows selected workflow `plan` for task type `plan`.

### Task 2 — Verify active plan workflow phase order

- Inspect active bundled `plan` workflow.
- Confirm `create-prd` appears before `create-trd`.
- Confirm `create-prd` has required file key `planning.prd_path`.

Done when: resolved phase order starts with `create-prd`.

### Task 3 — Verify deterministic context

- Validate run id, task id, phase id, correlation id, slug, year, and working directory.
- Validate PRD/TRD absolute paths match PRD and this TRD.
- Ensure retries reuse the same context.

Done when: phase context matches section 4.3 exactly.

### Task 4 — Verify PRD artifact gate

- Confirm PRD exists at `planning.prd_path`.
- Confirm missing PRD would fail `create-prd` with `:required_file_missing`.
- Confirm `create-prd` completion is recorded only after gate success.

Done when: PRD gate pass/fail is tied to the exact PRD path.

### Task 5 — Verify ordered advancement

- Confirm `create-trd` is not complete while `create-prd` is incomplete/failed.
- Confirm `create-trd` starts or becomes eligible only after `create-prd` completes.
- Confirm failures identify `create-prd` when the PRD gate fails.

Done when: run history shows ordered advancement from PRD to TRD.

### Task 6 — Verify TRD artifact gate

- Confirm this TRD exists at `planning.trd_path`.
- Confirm `create-trd` requires `planning.trd_path`.
- Confirm missing TRD would fail `create-trd` with `:required_file_missing`.

Done when: TRD gate pass/fail is tied to this exact TRD path.

### Task 7 — Verify operator diagnostics

- Inspect run details, phase events, or projection output.
- Confirm task type, selected workflow, phase id/name, required key, and resolved path are visible.
- Confirm failures are diagnosable without raw adapter logs first.

Done when: operator output satisfies REQ-006.

### Task 8 — Record smoke result

- Capture pass/fail evidence for workflow selection, phase order, and artifact gates.
- If source workflows or prompts changed, run `foreman init --force` before dispatch validation.
- Preserve artifact paths in the run report.

Done when: smoke result includes selected workflow, phase order, PRD path, and TRD path.

## 6. Validation Plan

### 6.1 Static Validation

- Read active `plan` workflow and confirm:
  - workflow name is `plan`
  - `create-prd` is first
  - `create-prd.requiredFile` is `planning.prd_path`
  - `create-trd.requiredFile` is `planning.trd_path`

### 6.2 Artifact Validation

Run checks:

```bash
test -f /Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md
test -f /Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md
```

Pass criteria:

- Both commands exit `0`.
- Paths match `planning.prd_path` and `planning.trd_path` exactly.

### 6.3 Runtime Smoke Validation

When the Foreman run is executed, validate the authoritative event/projection order:

```text
workflow.selected(plan)
phase.started(create-prd)
phase.completed(create-prd)
phase.started(create-trd)
phase.completed(create-trd)
```

If a terminal run event is present, it must occur after `phase.completed(create-trd)`.

### 6.4 Negative Validation

Temporarily moving either required file during an isolated validation run should cause the owning phase to fail with:

- reason: `:required_file_missing`
- key: `planning.prd_path` or `planning.trd_path`
- path: exact resolved absolute path

Do not perform destructive negative validation against shared smoke artifacts unless using an isolated copy or disposable run.

## 7. Requirement Traceability

| PRD Requirement | Design coverage | Validation |
|---|---|---|
| REQ-001: Task type selects plan workflow | Sections 4.1, 5 Task 1 | Runtime smoke event/projection: selected workflow `plan` |
| REQ-002: Planning context is deterministic | Sections 4.3, 5 Task 3 | Context/path inspection |
| REQ-003: PRD command receives exact artifact path | Sections 4.2, 4.4, 5 Task 4 | PRD path existence and gate evidence |
| REQ-004: PRD artifact gate controls phase success | Sections 4.4, 6.2 | Phase completion after gate pass |
| REQ-005: Plan workflow remains ordered after PRD creation | Sections 4.2, 4.5, 6.3 | Phase order evidence |
| REQ-006: Smoke output is operator-friendly | Sections 4.7, 5 Task 7 | Run detail/projection inspection |

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Runtime workflow copy is stale | Smoke validates old behavior | Run `foreman init --force` after workflow/prompt source changes |
| Task type dropped before selection | Wrong/no workflow selected | Require task type and selected workflow in run details |
| Existing artifact masks path bug | False pass | Use unique correlation id `b86c4907` and exact absolute paths |
| Projection lags event store | Apparent order mismatch | Validate against authoritative ordered events when needed |

## 9. Rollback Plan

This TRD is a planning artifact only. If it is incorrect:

1. Replace or amend this file at `planning.trd_path`.
2. Preserve the same document id and path for this smoke unless the run context changes.
3. Re-run artifact existence validation.

No runtime code rollback is required for this document.

## 10. Open Questions

None. The run id, task id, type, slug, PRD path, and TRD path are supplied by context.

## 11. Readiness Checklist

- [x] PRD reference captured
- [x] Task-type dispatch design captured
- [x] Phase order captured
- [x] Required artifact paths captured
- [x] Validation plan captured
- [x] Requirement traceability complete
- [x] Paired PRD exists

---

*Generated: 2026-08-09 | Document ID: TRD-2026-b86c4907 | Scale: LIGHT | Draft v0.1.0*
