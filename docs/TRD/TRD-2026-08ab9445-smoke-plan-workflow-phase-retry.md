---
document_id: TRD-2026-08ab9445
label: trd-smoke-plan-workflow-phase-retry
version: 0.1.0
status: Draft
date: 2026-08-09
prd_reference: PRD-2026-08ab9445
prd_label: prd-smoke-plan-workflow-phase-retry
scale_depth: LIGHT
total_requirements: 6
total_acceptance_criteria: 18
design_readiness_score: 3.8
readiness_score: 3.8
total_tasks: 12
kind: trd
---

# TRD: Smoke — Plan Workflow Phase Retry

## 1. Executive Summary

This TRD implements PRD `PRD-2026-08ab9445` for a Foreman `plan` workflow smoke test. The smoke verifies that a task of type `plan` executes `create-prd` then `create-trd`, forwards the Ensemble slash commands unchanged at byte zero, honors the extended 600-second phase timeout, and only marks a phase complete after its required artifact exists at the exact path in planning context.

The smoke is intentionally narrow. It validates workflow/runtime contract, not PRD/TRD content quality.

Target artifacts:

- PRD: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md`
- TRD: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md`

## 2. Scope

### 2.1 In Scope

- Confirm bundled `plan` workflow phase order.
- Confirm deterministic planning context for run `run-08ab944587c983489434fc648cf3eb5f`.
- Confirm `requiredFile` gates enforce `planning.prd_path` and `planning.trd_path`.
- Confirm 600-second timeout is visible and effective for planning phases.
- Confirm operator/debug output exposes phase, reason, run id, planning key, and resolved path on failure.

### 2.2 Out of Scope

- Semantic scoring of generated PRD/TRD content.
- Replacing phase executor unit tests.
- Testing all Ensemble skill options.
- Changing the `plan` workflow beyond timeout/policy configuration needed by the smoke.

## 3. Existing System Assumptions

- Foreman runtime installs bundled workflows/prompts from source via `foreman init --force` when source manifests or prompts change.
- The active `plan` workflow contains two command phases:
  1. `create-prd`
  2. `create-trd`
- `create-prd` invokes `/skill:ensemble-full-create-prd --foreman`.
- `create-trd` invokes `/skill:ensemble-full-create-trd --foreman`.
- Phase gates can require a file path resolved from phase context.
- Missing required file fails the phase with `:required_file_missing`.
- Pi adapter command phases must receive slash commands at byte zero.

## 4. Technical Design

### 4.1 Workflow Contract

The bundled `plan` workflow SHALL define command phases in this order:

| Order | Phase ID | Command | Required file key |
|---:|---|---|---|
| 1 | `create-prd` | `/skill:ensemble-full-create-prd --foreman` | `planning.prd_path` |
| 2 | `create-trd` | `/skill:ensemble-full-create-trd --foreman` | `planning.trd_path` |

The phase executor SHALL not start `create-trd` until `create-prd` completes and its file gate passes.

### 4.2 Planning Context

For the smoke run, planning context SHALL be deterministic:

```json
{
  "run_id": "run-08ab944587c983489434fc648cf3eb5f",
  "task_id": "foreman-smoke-plan-retry-2bek",
  "planning": {
    "correlation_id": "08ab9445",
    "document_year": 2026,
    "slug": "smoke-plan-workflow-phase-retry",
    "prd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md",
    "trd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md"
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

### 4.3 Command Forwarding

For each command phase, the worker request body sent to the Pi adapter SHALL begin with the slash command at byte zero:

```text
/skill:ensemble-full-create-prd --foreman
```

or

```text
/skill:ensemble-full-create-trd --foreman
```

Context may follow after the command, but no whitespace, markdown fence, prompt prefix, or explanatory text may precede it.

### 4.4 Required File Gate

After a command phase exits, the phase executor SHALL resolve the configured required file path from context and run an existence check.

Success rule:

```elixir
File.regular?(resolved_required_file_path) == true
```

Failure rule:

```elixir
{:error, :required_file_missing, %{phase_id: phase_id, key: planning_key, path: resolved_path}}
```

The gate SHALL be evaluated after every retry attempt. If a previous attempt created the artifact but failed before recording success, a retry may pass the gate without manual metadata edits.

### 4.5 Timeout Policy

The smoke SHALL configure each planning command phase with an effective timeout of 600 seconds / 600,000 milliseconds.

Expected behavior:

- A planning worker still active before 600 seconds is not failed solely due to timeout.
- A planning worker exceeding 600 seconds is cancelled/terminated via existing worker policy.
- Timeout failures record phase id, run id, worker id where available, and timeout value.
- Debug/telemetry surfaces the effective timeout value.

### 4.6 Operator-Facing Output

Run/phase inspection SHALL expose enough structured data for first-pass diagnosis:

| Failure | Required diagnostic fields |
|---|---|
| Missing artifact | `run_id`, `phase_id`, `reason`, `planning_key`, `resolved_path` |
| Timeout | `run_id`, `phase_id`, `reason`, `timeout_ms`, `worker_id` when known |
| Success | `run_id`, completed phases, planning artifact paths |

## 5. Implementation Tasks

### Task 1 — Verify bundled plan workflow manifest

- Inspect source workflow manifest for `plan`.
- Confirm phase ids, command strings, order, and required file keys.
- If edited, run `foreman init --force` before runtime validation.

Done when: source and installed runtime manifest agree on `create-prd` then `create-trd`.

### Task 2 — Verify command request formatting

- Add or run coverage proving command bodies start with slash command at byte zero.
- Ensure no adapter wrapper prepends human text before slash commands.

Done when: byte-zero assertion exists or current smoke logs prove exact forwarding.

### Task 3 — Verify deterministic planning paths

- Validate run id, task title, year, slug, and path derivation.
- Ensure retries reuse the same correlation id and paths.

Done when: run context matches paths in PRD and this TRD.

### Task 4 — Verify required file gates

- Confirm `create-prd` requires `planning.prd_path`.
- Confirm `create-trd` requires `planning.trd_path`.
- Confirm missing file produces `:required_file_missing` with path.

Done when: both phase gate configs are present and failure payload includes resolved path.

### Task 5 — Verify timeout policy

- Confirm phase failure policy timeout is 600 seconds.
- Confirm debug/telemetry displays 600s/600000ms.

Done when: effective timeout is visible for both planning phases.

### Task 6 — Run smoke

- Execute/observe task `foreman-smoke-plan-retry-2bek`.
- Confirm `create-prd` terminal status is complete.
- Confirm `create-trd` terminal status is complete.
- Confirm run terminal status is complete.

Done when: run completes and both artifacts exist at exact planned paths.

## 6. Acceptance Mapping

| PRD AC | TRD validation |
|---|---|
| AC-001-1 | Task type `plan` resolves to bundled `plan` workflow. |
| AC-001-2 | Phase ordering assertion/log shows `create-prd` before `create-trd`. |
| AC-001-3 | Run projection exposes failing phase and reason. |
| AC-002-1 | Planning context includes `correlation_id: 08ab9445`. |
| AC-002-2 | Planning context includes `slug: smoke-plan-workflow-phase-retry`. |
| AC-002-3 | Planned paths use `docs/PRD` and `docs/TRD` with `2026-08ab9445` prefix. |
| AC-003-1 | PRD exists at `planning.prd_path`. |
| AC-003-2 | Missing PRD gate returns `:required_file_missing` and path. |
| AC-003-3 | Retry gate can pass once PRD exists. |
| AC-004-1 | TRD exists at `planning.trd_path`. |
| AC-004-2 | Missing TRD gate returns `:required_file_missing` and path. |
| AC-004-3 | Both artifacts existing allows run completion. |
| AC-005-1 | No timeout before 600 seconds. |
| AC-005-2 | Timeout after 600 seconds uses existing worker cancellation policy. |
| AC-005-3 | Debug/telemetry shows 600s/600000ms. |
| AC-006-1 | Missing artifact output includes phase, key, path. |
| AC-006-2 | Timeout output includes phase, timeout, worker/run id. |
| AC-006-3 | Success output exposes or derives PRD/TRD paths. |

## 7. Test Plan

### 7.1 Static Checks

- Inspect workflow manifest for command strings and required file keys.
- Inspect installed workflow copy if runtime cache exists.
- Check artifact paths exist after phase completion.

### 7.2 Unit/Integration Checks

Recommended ExUnit coverage:

- `Workflow.PlanningContextTest`: path derivation and retry stability.
- `Workflow.CommandPhaseTest`: slash command byte-zero forwarding.
- `Workflow.RequiredFileGateTest`: success, missing-file failure, retry after file exists.
- `Workflow.TimeoutPolicyTest`: effective timeout set to 600,000 ms.
- `Workflow.PlanSmokeTest`: phase order and run completion with stubbed command worker creating files.

### 7.3 Manual Smoke Validation

```bash
foreman run foreman-smoke-plan-retry-2bek --watch
```

Expected result:

```text
create-prd: complete
create-trd: complete
run: complete
```

Expected files:

```bash
test -f docs/PRD/PRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md
test -f docs/TRD/TRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md
```

## 8. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Runtime workflow cache stale | Smoke runs old timeout or old gate config | Run `foreman init --force` after workflow/prompt edits |
| Agent takes longer than 600s | Smoke fails by timeout | Keep smoke content light; record timeout clearly |
| Artifact path mismatch | Required file gate fails | Use absolute paths from planning context; do not infer alternate paths inside skills |
| Command prefix inserted before slash command | Pi adapter may not invoke skill | Assert byte-zero command forwarding |

## 9. Rollout / PR Plan

One small validation PR is sufficient if changes are needed:

1. Update bundled `plan` workflow timeout/gate config if it differs from this TRD.
2. Add regression tests for planning context, command byte-zero forwarding, required file gates, and timeout policy.
3. Update operator docs only if displayed behavior or commands changed.
4. Run `foreman init --force` if bundled workflow/prompt source changed.
5. Run targeted ExUnit tests plus smoke task.

No database migration required.

## 10. Completion Criteria

- PRD file exists at exact planned PRD path.
- This TRD file exists at exact planned TRD path.
- `plan` workflow completes `create-prd` before `create-trd`.
- Both required file gates pass.
- Effective timeout is 600 seconds.
- Run `run-08ab944587c983489434fc648cf3eb5f` can reach complete state.

---

*Generated: 2026-08-09 | Document ID: TRD-2026-08ab9445 | Scale: LIGHT | Draft v0.1.0*
