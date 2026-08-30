---
document_id: TRD-2026-8066e22d
label: trd-smoke-run-after-closed-issue-schema-fix
version: 0.1.0
status: Draft
date: 2026-08-09
prd_reference: PRD-2026-8066e22d
prd_label: prd-smoke-run-after-closed-issue-schema-fix
scale_depth: LIGHT
total_requirements: 6
total_acceptance_criteria: 18
design_readiness_score: 3.8
readiness_score: 3.8
total_tasks: 8
kind: trd
---

# TRD: Smoke — Run After Closed-Issue Schema Fix

## 1. Executive Summary

This TRD implements PRD `PRD-2026-8066e22d` for a Foreman smoke run after the Beads closed-issue schema fix. The smoke verifies that a `type: plan` task selects the bundled `plan` workflow, writes deterministic planning artifacts, and reaches terminal completion only after Beads provider close handling accepts a schema-valid `br close --json` acknowledgement.

The regression target is provider completion after `BeadsAdapter.complete/3` began validating close acknowledgements with `JsonSchemaCache.validate(:closed_issue, payload)`. A passing run proves Foreman closes task `foreman-foreman-smoke-closchema-l8wb` through `br close`, validates the closed issue payload, checks exact id and `status: closed`, and records task execution completion only after provider success or idempotent already-terminal acknowledgement.

Target artifacts:

- PRD: `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`
- TRD: `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`

## 2. Scope

### 2.1 In Scope

- Validate task type `plan` selects the bundled `plan` workflow.
- Validate phase order: `create-prd` then `create-trd`.
- Validate deterministic planning context for run `run-8066e22db819f69002468779cafeee11`.
- Validate required-file gates use exact `planning.prd_path` and `planning.trd_path` values.
- Validate terminal completion invokes `br close foreman-foreman-smoke-closchema-l8wb --json`.
- Validate `br close --json` payload is checked with the cached `:closed_issue` schema.
- Validate wrong schema, wrong id, or non-closed status fails provider completion and prevents false terminal success.

### 2.2 Out of Scope

- Semantic scoring of generated PRD/TRD quality.
- Exhaustive Beads CLI command coverage.
- Replacing targeted unit tests for `BeadsAdapter.complete/3` or `JsonSchemaCache`.
- Validating non-Beads providers.
- Retrying unrelated workflow, Pi adapter, or Beads infrastructure failures.

## 3. Existing System Assumptions

- Active Foreman runtime has bundled workflows installed from `packages/foreman_server/priv/defaults/workflows`.
- `packages/foreman_server/priv/defaults/workflows/plan.yaml` maps the `plan` workflow to two command phases:
  1. `create-prd` with command `/skill:ensemble-full-create-prd --foreman` and required file `planning.prd_path`.
  2. `create-trd` with command `/skill:ensemble-full-create-trd --foreman` and required file `planning.trd_path`.
- `Catalog.load("plan.yaml")` preserves both command phases and required-file keys.
- `ForemanServer.Workflow.PlanContext` derives `working_directory`, `task`, and `planning` blocks from server-owned task, project, run, and approval data.
- `RunExecutor` enforces required files after command execution and before phase completion.
- `RunExecutor` finalization calls the registered provider close path before dispatching `TaskExecutionCompleted`.
- Beads provider close uses `BrRunner` request `{:close, %{id: task_id}}`, translated to `br close --db <database> <task-id> --json`.
- `JsonSchemaCache` exposes a pinned `:closed_issue` schema requiring `id`, `title`, and `status: closed` for close acknowledgements.

## 4. Technical Design

### 4.1 Workflow Selection Contract

Foreman SHALL select workflow `plan` when the task projection has normalized type `plan`.

Selection inputs:

| Field | Expected value |
|---|---|
| Task id | `foreman-foreman-smoke-closchema-l8wb` |
| Task title | `Smoke run after closed-issue schema fix` |
| Task type | `plan` |
| Expected workflow | `plan` |

Rules:

1. Selection MUST use task type, not title text.
2. Selection MUST not require a CLI workflow override.
3. Run details SHOULD expose task id, task type, selected workflow, and phase ids.

Failure behavior:

```text
workflow_selection_failed(task_id: "foreman-foreman-smoke-closchema-l8wb", task_type: "plan")
```

### 4.2 Plan Workflow Phase Contract

The active workflow SHALL resolve this ordered phase list:

| Order | Phase name | Command | Required file key |
|---:|---|---|---|
| 1 | `create-prd` | `/skill:ensemble-full-create-prd --foreman` | `planning.prd_path` |
| 2 | `create-trd` | `/skill:ensemble-full-create-trd --foreman` | `planning.trd_path` |

`create-trd` SHALL start only after `create-prd` command execution succeeds and the PRD required-file gate passes.

### 4.3 Deterministic Planning Context

The phase context SHALL be materialized as:

```json
{
  "run_id": "run-8066e22db819f69002468779cafeee11",
  "phase_id": "run-8066e22db819f69002468779cafeee11-p002",
  "task_id": "foreman-foreman-smoke-closchema-l8wb",
  "working_directory": "/Users/ldangelo/Development/Fortium/foreman",
  "task": {
    "id": "foreman-foreman-smoke-closchema-l8wb",
    "project_id": "foreman",
    "type": "plan",
    "title": "Smoke run after closed-issue schema fix",
    "description": ""
  },
  "planning": {
    "correlation_id": "8066e22d",
    "document_year": 2026,
    "slug": "smoke-run-after-closed-issue-schema-fix",
    "prd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md",
    "trd_path": "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md"
  }
}
```

The supplied context paths are authoritative. No alternate filename or existing artifact may satisfy a required-file gate.

### 4.4 Required-File Gate Design

After each command phase exits successfully, `RunExecutor.enforce_required_file/3` SHALL:

1. Traverse the merged runtime context using the phase `required_file` key.
2. Require the resolved value to be a string path.
3. Assert `File.regular?(path)`.
4. Fail the phase before `PhaseCompleted` when the file is missing.

PRD pass condition:

```elixir
File.regular?("/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md") == true
```

TRD pass condition:

```elixir
File.regular?("/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md") == true
```

Missing-file failure shape:

```elixir
{:error, {:required_file_missing, "planning.trd_path", "/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md"}}
```

### 4.5 Beads Completion Invocation

After both phase gates pass, terminal run finalization SHALL execute provider completion for task `foreman-foreman-smoke-closchema-l8wb`.

Expected runner request:

```elixir
{:close, %{id: "foreman-foreman-smoke-closchema-l8wb"}}
```

Expected command shape:

```bash
br close foreman-foreman-smoke-closchema-l8wb --json
```

When a configured Beads database path exists, `SystemBrRunner` may include the cached database argument:

```bash
br close --db <database_path> foreman-foreman-smoke-closchema-l8wb --json
```

Forbidden substitute:

```bash
br update foreman-foreman-smoke-closchema-l8wb --status closed
```

### 4.6 Closed-Issue Schema Validation

`BeadsAdapter.complete/3` SHALL parse `br close --json` stdout and validate the decoded close acknowledgement before returning success.

Accepted payload shape:

```json
{
  "id": "foreman-foreman-smoke-closchema-l8wb",
  "title": "Smoke run after closed-issue schema fix",
  "status": "closed",
  "closed_at": "2026-08-09T00:00:00Z",
  "close_reason": null
}
```

Validation sequence:

1. Decode stdout as JSON.
2. Accept a JSON object, or a singleton JSON array containing one object.
3. Call `JsonSchemaCache.validate(:closed_issue, payload)`.
4. Require `id == "foreman-foreman-smoke-closchema-l8wb"`.
5. Require `status == "closed"`.
6. Convert to `%ForemanServer.TaskProvider.Issue{status: "closed"}`.
7. Return `{:ok, issue}`.

The pinned closed issue schema requires:

| Field | Requirement |
|---|---|
| `id` | string |
| `title` | string |
| `status` | string enum `closed` |
| `closed_at` | optional string |
| `close_reason` | optional string or null |

### 4.7 Provider Failure Semantics

Provider close failures SHALL not dispatch task execution completion.

Failure mapping:

| Condition | Expected provider code | Terminal task completion? |
|---|---|---|
| Missing schema-required field such as `title` | `SCHEMA_VALIDATION_FAILED` | No |
| Payload id differs from requested task id | `BR_CONTRACT_MISMATCH` | No |
| Payload status is not `closed` | `BR_CONTRACT_MISMATCH` | No |
| Empty or malformed JSON stdout | `BR_PARSE_ERROR` | No |
| `br` reports already terminal/closed | `ALREADY_TERMINAL` mapped to `{:ok, :already_terminal}` | Idempotent success, no duplicate completion event |

Diagnostics MUST include bounded context:

- command family: `br close`
- task id: `foreman-foreman-smoke-closchema-l8wb`
- provider error code
- exit code or schema missing fields when available
- no unsafe raw side-channel leakage

### 4.8 Terminal Completion Ordering

`RunExecutor` SHALL record terminal success in this order:

1. `create-prd` phase starts.
2. PRD command exits successfully.
3. PRD required-file gate passes.
4. `PhaseCompleted` is recorded for `create-prd`.
5. `create-trd` phase starts.
6. TRD command exits successfully.
7. TRD required-file gate passes.
8. `PhaseCompleted` is recorded for `create-trd`.
9. Run finalization begins.
10. Beads provider completion runs `br close`.
11. Closed issue schema, id, and status validation pass.
12. `TaskExecutionCompleted` is dispatched.
13. `RunCompleted` is recorded.

Provider validation failure stops at step 11 and records a failure associated with Beads close handling.

## 5. Requirement Mapping

| PRD requirement | Design coverage |
|---|---|
| REQ-001 Plan task dispatch remains intact | Sections 4.1, 4.2 |
| REQ-002 Planning context is deterministic | Section 4.3 |
| REQ-003 Required planning artifacts gate phase success | Section 4.4 |
| REQ-004 Beads completion validates the closed issue schema | Sections 4.6, 4.7 |
| REQ-005 Terminal run completion records successful provider close | Sections 4.5, 4.8 |
| REQ-006 Smoke output is operator-friendly | Sections 4.1, 4.4, 4.7, 8 |

## 6. Implementation Tasks

| Task | Description | Files / areas | Done criteria |
|---:|---|---|---|
| T1 | Confirm active workflow source has two command phases with required-file keys | `packages/foreman_server/priv/defaults/workflows/plan.yaml` | `create-prd` and `create-trd` match expected commands and keys |
| T2 | Confirm runtime workflow catalog preserves phase order and required files | `packages/foreman_server/test/foreman_server/workflow/catalog_test.exs` | Catalog test covers `plan.yaml` command phases |
| T3 | Confirm deterministic plan context for supplied run/task | `packages/foreman_server/lib/foreman_server/workflow/plan_context.ex` | Context contains exact correlation id, slug, year, PRD path, TRD path |
| T4 | Confirm required-file gates run before phase completion | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | Missing artifact fails with `required_file_missing` and path context |
| T5 | Confirm provider finalization uses close path | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | `complete/4` resolves provider `:close` and calls `provider_module.complete/3` |
| T6 | Confirm `BeadsAdapter.complete/3` validates `:closed_issue` | `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex`, `json_schema_cache.ex` | Schema, id, and status failures map to expected provider codes |
| T7 | Run targeted provider tests | `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_complete_test.exs` | Happy path, schema failure, contract mismatch, idempotent already-closed tests pass |
| T8 | Run smoke workflow | Foreman CLI/runtime | Run completes only after PRD gate, TRD gate, `br close`, and provider acknowledgement validation |

## 7. Test Plan

### 7.1 Static / Unit Verification

Run from `packages/foreman_server`:

```bash
mix test test/foreman_server/task_providers/beads_adapter_complete_test.exs
mix test test/foreman_server/workflow/catalog_test.exs
mix test test/foreman_server/workflow/run_executor_command_test.exs
mix test test/foreman_server/workflow/run_executor_test.exs
```

Expected evidence:

- `beads_adapter_complete_test.exs` proves:
  - `br close` request shape is `{:close, %{id: task_id}}`.
  - schema-valid closed payload returns `%Issue{status: "closed"}`.
  - singleton array payload is accepted when valid.
  - missing `title` returns `SCHEMA_VALIDATION_FAILED`.
  - non-closed status returns `BR_CONTRACT_MISMATCH`.
  - already closed maps to idempotent terminal success.
- Workflow tests prove plan command phases and required-file keys are preserved.
- Run executor tests prove provider completion happens before task execution completion and no duplicate completion event is emitted for idempotent already-terminal close.

### 7.2 Smoke Execution Verification

Run the Foreman smoke for task `foreman-foreman-smoke-closchema-l8wb` with runtime context from PRD `PRD-2026-8066e22d`.

Required observations:

1. Run id is `run-8066e22db819f69002468779cafeee11`.
2. Task type is `plan`.
3. Selected workflow is `plan`.
4. Phase order is `create-prd`, then `create-trd`.
5. PRD exists at the exact `planning.prd_path`.
6. TRD exists at the exact `planning.trd_path`.
7. Provider completion invokes `br close ... --json`.
8. Close acknowledgement validates against `:closed_issue`.
9. Close acknowledgement id equals `foreman-foreman-smoke-closchema-l8wb`.
10. Close acknowledgement status is `closed`.
11. Task execution completion is recorded only after provider completion success or idempotent already-terminal response.

### 7.3 Negative Verification

Use targeted tests or controlled mock responses to verify failures:

| Negative case | Expected result |
|---|---|
| TRD file missing after command exit | Phase failure with `required_file_missing` and resolved TRD path |
| Close payload missing `title` | Provider error `SCHEMA_VALIDATION_FAILED`, no terminal task completion |
| Close payload id differs | Provider error `BR_CONTRACT_MISMATCH`, no terminal task completion |
| Close payload status is `open` | Provider error `BR_CONTRACT_MISMATCH`, no terminal task completion |
| Close stdout malformed | Provider error `BR_PARSE_ERROR`, no terminal task completion |

## 8. Operator Diagnostics

Minimum operator-visible fields for this smoke:

| Diagnostic | Purpose |
|---|---|
| task id | Confirms provider close target |
| task type | Confirms workflow dispatch input |
| selected workflow | Confirms `plan` routing |
| phase id/name | Localizes artifact gate failure |
| required-file key | Shows which context key failed |
| resolved artifact path | Shows exact missing or accepted file |
| provider command | Confirms `br close`, not status update fallback |
| provider code | Distinguishes schema, contract, parse, and already-terminal outcomes |

Provider errors SHOULD expose safe bounded context only. Raw stderr/stdout side-channel content remains scrubbed except byte counts or sanitized fields already accepted by provider error mapping.

## 9. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Runtime workflow copy is stale | Smoke selects wrong phase shape | Run build/init refresh before dispatch when workflow source changed |
| Existing artifacts mask gate failures | False pass | Unique correlation id `8066e22d` and exact artifact paths |
| Beads CLI close payload drifts | Provider completion fails | Pinned `:closed_issue` schema surfaces `SCHEMA_VALIDATION_FAILED` or `BR_CONTRACT_MISMATCH` |
| Already closed task is retried | Duplicate completion event | Treat `ALREADY_TERMINAL` as idempotent success and verify no duplicate `TaskExecutionCompleted` |
| Unsafe provider output leaks into operator view | Security / noise | Use provider code map and scrubbed side-channel context |

## 10. Rollback / Recovery

If the smoke fails:

1. Do not mark the Beads task complete manually unless the failure is confirmed unrelated to provider close handling.
2. Capture run id, phase id, provider error code, and artifact paths.
3. If failure is artifact-related, inspect required-file path and command output.
4. If failure is provider-related, inspect `BeadsAdapter.complete/3`, `JsonSchemaCache.validate(:closed_issue, payload)`, and `br close --json` output shape.
5. If runtime workflow assets are stale after source changes, run the required build/init refresh before retry.

## 11. Acceptance Checklist

- [ ] Task `foreman-foreman-smoke-closchema-l8wb` selected workflow `plan` from `type: plan`.
- [ ] `create-prd` ran before `create-trd`.
- [ ] PRD exists at `/Users/ldangelo/Development/Fortium/foreman/docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`.
- [ ] TRD exists at `/Users/ldangelo/Development/Fortium/foreman/docs/TRD/TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`.
- [ ] Terminal provider close invoked `br close foreman-foreman-smoke-closchema-l8wb --json` or equivalent with `--db`.
- [ ] Close acknowledgement validated through `JsonSchemaCache.validate(:closed_issue, payload)`.
- [ ] Close acknowledgement id matched `foreman-foreman-smoke-closchema-l8wb`.
- [ ] Close acknowledgement status was `closed`.
- [ ] Schema or contract failures did not silently mark the task complete.
- [ ] Operator diagnostics included phase/artifact/provider context.

## 12. Evidence References

- PRD: `docs/PRD/PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md`
- Workflow source: `packages/foreman_server/priv/defaults/workflows/plan.yaml`
- Workflow catalog tests: `packages/foreman_server/test/foreman_server/workflow/catalog_test.exs`
- Plan context builder: `packages/foreman_server/lib/foreman_server/workflow/plan_context.ex`
- Run executor: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
- Beads adapter: `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex`
- Closed issue schema cache: `packages/foreman_server/lib/foreman_server/task_providers/json_schema_cache.ex`
- Provider completion tests: `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_complete_test.exs`

---

*Generated: 2026-08-09 | Document ID: TRD-2026-8066e22d | PRD Reference: PRD-2026-8066e22d | Scale: LIGHT | Draft v0.1.0*
