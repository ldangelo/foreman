---
document_id: TRD-2026-c7004f12
label: trd-smoke-plan-workflow-v5-seqfix
version: 0.1.0
status: Draft
date: 2026-08-09
prd_reference: PRD-2026-c7004f12
prd_label: prd-smoke-plan-workflow-v5-seqfix
scale_depth: LIGHT
total_requirements: 6
total_acceptance_criteria: 18
design_readiness_score: 3.8
readiness_score: 3.8
total_tasks: 10
kind: trd
---

# TRD: Smoke — Plan Workflow v5 Sequence Fix

## 1. Executive Summary

This TRD implements PRD `PRD-2026-c7004f12` for a Foreman `plan` workflow smoke test. The smoke verifies that a task of type `plan` executes `create-prd` then `create-trd`, writes both planning artifacts to the exact paths supplied by run context, and only emits or projects `run.complete` after the final required planning phase and artifact gate have completed.

The regression target is premature terminal completion. A successful run proves that Foreman does not mark the run complete after the first planning phase or any intermediate workflow state.

Target artifacts:

- PRD: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`
- TRD: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md`

## 2. Scope

### 2.1 In Scope

- Confirm bundled `plan` workflow selection for task type `plan`.
- Confirm `create-prd` starts and completes before `create-trd` completes.
- Confirm deterministic planning context for run `run-c7004f127c268a96b313fe40e8cb45d2`.
- Confirm `requiredFile` gates enforce `planning.prd_path` and `planning.trd_path`.
- Confirm terminal run completion is sequenced after all required phase completions and gates.
- Confirm operator/debug output exposes enough phase history to diagnose premature completion.

### 2.2 Out of Scope

- Semantic scoring of generated PRD/TRD content.
- Replacing lower-level event-store, projection, or phase executor unit tests.
- Testing all workflow types.
- Testing all Ensemble skill options.
- Changing production workflow behavior beyond sequence/gate fixes needed by this smoke.

## 3. Existing System Assumptions

- Foreman runtime installs bundled workflows/prompts from source via `foreman init --force` when source manifests or prompts change.
- The active bundled `plan` workflow contains two command phases:
  1. `create-prd`
  2. `create-trd`
- `create-prd` invokes `/skill:ensemble-full-create-prd --foreman`.
- `create-trd` invokes `/skill:ensemble-full-create-trd --foreman`.
- Phase gates can require a file path resolved from phase/run context.
- Missing required files fail their phase with `:required_file_missing` and include the resolved path.
- Run terminal completion must be derived from selected workflow completion, not from first successful artifact creation.

## 4. Technical Design

### 4.1 Workflow Contract

The bundled `plan` workflow SHALL define command phases in this order:

| Order | Phase ID | Command | Required file key |
|---:|---|---|---|
| 1 | `create-prd` | `/skill:ensemble-full-create-prd --foreman` | `planning.prd_path` |
| 2 | `create-trd` | `/skill:ensemble-full-create-trd --foreman` | `planning.trd_path` |

The phase executor SHALL not report `create-trd` as completed unless `create-prd` has completed and the PRD required-file gate has passed.

### 4.2 Planning Context

For the smoke run, planning context SHALL be deterministic:

```json
{
  "run_id": "run-c7004f127c268a96b313fe40e8cb45d2",
  "task_id": "foreman-foreman-smoke-plan-seqfix-c-znan",
  "phase_id": "run-c7004f127c268a96b313fe40e8cb45d2-p002",
  "working_directory": "/Users/ldangelo/Development/Fortium/foreman",
  "planning": {
    "correlation_id": "c7004f12",
    "document_year": 2026,
    "slug": "smoke-plan-workflow-v5-seqfix",
    "prd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md",
    "trd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md"
  }
}
```

Path derivation rule:

```text
correlation_id = first 8 hex chars after run- prefix
slug = normalized task title, lowercase, hyphenated
PRD path = docs/PRD/PRD-{year}-{correlation_id}-{slug}.md
TRD path = docs/TRD/TRD-{year}-{correlation_id}-{slug}.md
```

The smoke SHALL use the paths from context as authoritative. It SHALL NOT infer alternate artifact names during validation.

### 4.3 Required File Gates

After each command phase exits successfully, the phase executor SHALL resolve the configured required file path from context and run an existence check.

Success rule:

```elixir
File.regular?(resolved_required_file_path) == true
```

Failure rule:

```elixir
{:error, :required_file_missing,
 %{
   phase_id: phase_id,
   key: planning_key,
   path: resolved_path
 }}
```

Gate mapping:

| Phase | Planning key | Expected path |
|---|---|---|
| `create-prd` | `planning.prd_path` | `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md` |
| `create-trd` | `planning.trd_path` | `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md` |

### 4.4 Terminal Completion Sequencing

Run completion SHALL be evaluated only after the workflow executor has observed all required phases in terminal successful state and their gates have passed.

Completion preconditions:

1. Selected workflow is `plan`.
2. `create-prd` status is complete.
3. PRD required-file gate passed for `planning.prd_path`.
4. `create-trd` status is complete.
5. TRD required-file gate passed for `planning.trd_path`.
6. Terminal run event/projection is emitted after the final phase completion event.

Forbidden states:

- `run.complete` while `create-trd` is pending.
- `run.complete` while `create-trd` is running.
- `run.complete` while `create-trd` is failed, blocked, cancelled, or missing its artifact.
- `run.complete` after `create-prd` only.

### 4.5 Event and Projection Ordering

The event stream and run projection SHALL preserve enough ordering data to verify terminal completion.

Minimum observable sequence:

```text
phase.started(create-prd)
phase.completed(create-prd)
phase.started(create-trd)
phase.completed(create-trd)
run.complete
```

If projection is eventually consistent, validation may compare event timestamps, event indexes, or monotonically increasing sequence numbers. The pass condition is that `run.complete` appears after `phase.completed(create-trd)` in the authoritative ordering source.

### 4.6 Operator-Facing Output

Run/phase inspection SHALL expose enough structured data for first-pass diagnosis:

| Scenario | Required diagnostic fields |
|---|---|
| Success | `run_id`, completed phase ids/names, completion order, PRD path, TRD path |
| Premature completion | `run_id`, `run.complete` order marker, missing/incomplete phase id, expected final phase |
| Missing artifact | `run_id`, `phase_id`, `reason`, `planning_key`, `resolved_path` |
| Failed phase | `run_id`, `phase_id`, phase status, reason, worker/adapter summary when available |

## 5. Implementation Tasks

### Task 1 — Verify bundled plan workflow selection

- Inspect workflow resolution for task type `plan`.
- Confirm task `foreman-foreman-smoke-plan-seqfix-c-znan` resolves to bundled workflow `plan`.
- Confirm runtime workflow copy is current if source workflows changed.

Done when: run uses the bundled `plan` workflow for this task type.

### Task 2 — Verify phase order

- Inspect source workflow manifest for ordered phases.
- Confirm runtime phase history shows `create-prd` before `create-trd`.
- Confirm `create-trd` is not reported complete if `create-prd` fails.

Done when: phase history proves `create-prd` precedes `create-trd`.

### Task 3 — Verify deterministic planning context

- Validate run id, task title, document year, correlation id, slug, and paths.
- Ensure retries reuse the same correlation id and exact paths.
- Ensure phase context includes `planning.trd_path` for `create-trd`.

Done when: run context matches PRD and this TRD exactly.

### Task 4 — Verify PRD required-file gate

- Confirm `create-prd` requires `planning.prd_path`.
- Confirm the PRD exists at the exact supplied path.
- Confirm missing PRD fails with `:required_file_missing` and resolved path.

Done when: `create-prd` cannot complete without the exact PRD artifact.

### Task 5 — Verify TRD required-file gate

- Confirm `create-trd` requires `planning.trd_path`.
- Confirm this TRD exists at the exact supplied path.
- Confirm missing TRD fails with `:required_file_missing` and resolved path.

Done when: `create-trd` cannot complete without the exact TRD artifact.

### Task 6 — Verify terminal completion guard

- Observe run state after `create-prd` completion and before `create-trd` completion.
- Confirm run is not terminal complete in that intermediate state.
- Confirm run reaches complete only after `create-trd` completion and TRD gate success.

Done when: `run.complete` is ordered after `create-trd` completion.

### Task 7 — Verify operator diagnostics

- Inspect run/phase output for phase names and order.
- Confirm missing artifact errors include phase name/key/path.
- Confirm premature completion detection would identify `create-trd` as missing/incomplete.

Done when: sequence failures are diagnosable without raw adapter logs first.

## 6. Acceptance Mapping

| PRD AC | TRD validation |
|---|---|
| AC-001-1 | Task type `plan` resolves to bundled workflow `plan`. |
| AC-001-2 | Phase history shows `create-prd` starts before `create-trd`. |
| AC-001-3 | Failed `create-prd` prevents `create-trd` from being reported complete. |
| AC-002-1 | Planning context includes `correlation_id: c7004f12`. |
| AC-002-2 | Planning context includes `slug: smoke-plan-workflow-v5-seqfix`. |
| AC-002-3 | Planned artifact filenames use `PRD-2026-c7004f12-` and `TRD-2026-c7004f12-` prefixes. |
| AC-003-1 | PRD exists at `planning.prd_path`. |
| AC-003-2 | Missing PRD gate returns `:required_file_missing` and resolved path. |
| AC-003-3 | `create-prd` is visible as completed before `create-trd` starts. |
| AC-004-1 | TRD exists at `planning.trd_path`. |
| AC-004-2 | Missing TRD gate returns `:required_file_missing` and resolved path. |
| AC-004-3 | `create-trd` is visible as completed after its gate passes. |
| AC-005-1 | Run is not complete after `create-prd` alone. |
| AC-005-2 | Run is not complete while `create-trd` is running, blocked, failed, or missing artifact. |
| AC-005-3 | `run.complete` appears after final phase completion and gate success. |
| AC-006-1 | Phase history exposes both phase names and completion order. |
| AC-006-2 | Premature completion failure output identifies `run.complete` before `create-trd`. |
| AC-006-3 | Missing artifact output includes phase name, planning key, and resolved path. |

## 7. Test Plan

### 7.1 Static Checks

- Inspect bundled `plan` workflow manifest for phase order, command strings, and required file keys.
- Inspect installed workflow copy if runtime cache exists.
- Check artifact paths exist after phase completion:

```bash
test -f docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md
test -f docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md
```

### 7.2 Unit/Integration Checks

Recommended ExUnit coverage:

- `Workflow.PlanningContextTest`: path derivation and retry stability.
- `Workflow.RequiredFileGateTest`: success and missing-file failure for PRD/TRD gates.
- `Workflow.PlanSequenceTest`: `create-prd` before `create-trd` and no downstream completion after upstream failure.
- `Workflow.RunCompletionTest`: no `run.complete` until all required phases and gates pass.
- `Workflow.PlanSmokeTest`: full stubbed `plan` run creates both artifacts and completes after final phase.

### 7.3 Manual Smoke Validation

```bash
foreman run foreman-foreman-smoke-plan-seqfix-c-znan --watch
```

Expected result:

```text
create-prd: complete
create-trd: complete
run: complete
```

Expected ordering:

```text
phase.completed(create-prd) < phase.started(create-trd)
phase.completed(create-trd) < run.complete
```

Expected files:

```bash
test -f docs/PRD/PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md
test -f docs/TRD/TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md
```

## 8. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Runtime workflow cache stale | Smoke runs old sequence/gate config | Run `foreman init --force` after workflow/prompt source edits |
| Artifact files from prior attempts mask sequencing bug | False pass | Use unique correlation id `c7004f12`; verify event/projection order, not just file existence |
| Projection ordering differs from event-store ordering | Ambiguous pass/fail | Prefer authoritative event sequence or monotonic event indexes |
| TRD skill writes alternate path | Required file gate fails | Use absolute `planning.trd_path` from context as authoritative |
| Run completes after PRD only | Regression persists | Add explicit intermediate-state assertion before `create-trd` completion |

## 9. Rollout / PR Plan

One small validation PR is sufficient if changes are needed:

1. Update bundled `plan` workflow sequencing/gate config only if it differs from this TRD.
2. Add regression tests for planning context, required file gates, phase order, and terminal completion guard.
3. Update operator docs only if visible commands or output change.
4. Run `foreman init --force` if bundled workflow or prompt source changed.
5. Run targeted ExUnit tests plus the smoke task.

No database migration required.

## 10. Completion Criteria

- PRD file exists at exact planned PRD path.
- This TRD file exists at exact planned TRD path.
- `plan` workflow completes `create-prd` before `create-trd`.
- Both required file gates pass.
- `run.complete` is observed only after `create-trd` completion and TRD required-file gate success.
- Run `run-c7004f127c268a96b313fe40e8cb45d2` can reach complete state without premature terminal projection.

---

*Generated: 2026-08-09 | Document ID: TRD-2026-c7004f12 | Scale: LIGHT | Draft v0.1.0*
