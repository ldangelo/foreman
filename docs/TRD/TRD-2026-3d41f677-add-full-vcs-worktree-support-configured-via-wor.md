---
document_id: TRD-2026-3d41f677
label: trd-add-full-vcs-worktree-support-configured-via-wor
prd: docs/PRD/PRD-2026-3d41f677-add-full-vcs-worktree-support-configured-via-wor.md
version: 1.0.0
status: Draft
date: 2026-08-12
design_readiness_score: 4.5
kind: trd
---

# TRD: Workflow-Configured VCS Worktree Support

## Document Purpose

Define the technical design for adding Git worktree lifecycle support to Foreman workflows. The implementation extends the default VCS adapter, workflow YAML schema, catalog normalization, run executor phase lifecycle, telemetry, tests, and docs while keeping all VCS commands system-internal Bucket C.

## PRD Validation Summary

| Check | Result |
|---|---|
| Source PRD | `docs/PRD/PRD-2026-3d41f677-add-full-vcs-worktree-support-configured-via-wor.md` |
| PRD status | Draft |
| Requirement coverage | REQ-001 through REQ-012 mapped below |
| Must requirements | Covered by architecture, tests, and docs slices |
| Existing aggregate source | `packages/foreman_server/lib/foreman_server/aggregates/vcs_operation.ex` |
| Existing adapter source | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` |
| Executor integration source | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` |
| Bucket policy | VCS worktree/merge/pr commands remain Bucket C system-internal |

Validation commands used for reconnaissance:

```text
rg -n "vcs\.worktree|vcs\.merge|vcs\.pr|vcs_operation" packages/foreman_server/lib/foreman_server
rg -n "def execute|working_directory" packages/foreman_server/lib/foreman_server/agent_runtime
```

Current production gap: scanning the Foreman server lib tree returns the `VcsOperation` aggregate and adapter lifecycle emitters, but no RunExecutor or workflow caller for `vcs.worktree.*`.

## Architecture Decisions

### Decision 1 — Declaration location: phase-level worktree

Use a phase-level `worktree:` map for v1.

```yaml
phases:
  - name: implement
    prompt: implement.md
    worktree:
      enabled: true
      base: main
      branch: foreman/{run_id}/{phase}
      cleanup: always
```

Reason:

- Matches the phase lifecycle hook Foreman already owns: `phase.start`, worker execution, `phase.complete|fail`.
- Provides stronger isolation between planning/implementation/review phases.
- Allows cleanup immediately after each terminal phase, reducing orphan lifetime.
- Fits the current YAML parser's one-level nested map support.
- Avoids sharing mutable state across phases without explicit design for conflict/merge semantics.

Rejected: workflow-level worktree reused across phases. It is cheaper and reduces Git worktree churn, but it creates cross-phase state sharing, ambiguous cleanup timing, and harder failure semantics. It can be added later as `workflow.worktree` only after phase-level semantics are proven.

### Decision 2 — Cleanup timing: phase-terminal always, retry at run-terminal

Default `cleanup` is `always`, meaning cleanup after every worktree phase terminal state: completed, failed, or blocked.

Supported v1 values:

- `always` — default; clean at phase terminal and retry at run terminal on prior cleanup failure.
- `never` — allowed only for debug workflows if explicitly accepted by validation/config; not recommended and must be documented as leaving worktrees behind.

Rejected for v1: `on_run_terminal`. It implies a workflow-level worktree retention model and cross-phase sharing semantics. The product prompt requested cleanup after phase terminal; implement that first.

Cleanup is best-effort and idempotent. Cleanup failure never masks the original phase terminal reason; it emits telemetry and leaves a retry marker in executor state for run-terminal retry.

### Decision 3 — Base ref: explicit phase override, project default, else HEAD

Base resolution order:

1. `phase.worktree.base` if set.
2. Project default branch from task/project projection if available.
3. `HEAD` in the task `working_directory` repository.

The worktree branch name is resolved from `phase.worktree.branch` or default `foreman/{run_id}/{phase}`. Template variables are expanded from run/project/phase context.

Pinned SHAs are accepted as `base` values because `git worktree add <path> <sha>` is valid. The schema calls the field `base` rather than `base_branch` to allow branch names, tags, and SHAs.

### Decision 4 — Failure semantics: fail closed

If worktree creation fails, the phase fails and the run fails. Foreman must not fall back to the main checkout.

Reason: fallback would violate isolation expectations and could mutate the controller checkout. Create failure must emit lifecycle failure, worktree telemetry, and best-effort cleanup for partial artifacts.

### Decision 5 — Concurrency: never share worktrees across runs

Default path:

```text
~/.foreman/worktrees/<project_id>/<run_id>/<phase_slug>
```

Rules:

- Each run/phase gets a unique path.
- Phase names are slugged; if absent, use `phase-<index>`.
- Relative configured paths resolve under `~/.foreman/worktrees/<project_id>/<run_id>/`.
- Absolute configured paths are rejected unless a future explicit unsafe/debug flag is added.
- Two phases in the same run may not share a worktree in v1.
- Two runs never share a worktree path.
- Cross-project sharing is forbidden.

## Command Inventory and Bucket Classification

All command types handled by `ForemanServer.Aggregates.VcsOperation.handle_command/2` are system-internal. They are reachable only from Foreman's OTP runtime and workflow executor integration, never from public HTTP, CLI, or MCP dispatch.

| Command type | Event | Stream | Bucket | Rationale |
|---|---|---|---|---|
| `vcs.worktree.create` | `WorktreeCreated` | `vcs:<operation_id>` | C | Internal runtime declares worktree state; external callers could fake phase cwd setup. |
| `vcs.worktree.clean` | `WorktreeCleaned` | `vcs:<operation_id>` | C | Cleanup is supervisor-owned and tied to phase/run terminal handling. |
| `vcs.merge.request` | `VcsMergeRequested` | `vcs:<operation_id>` | C | Merge sequencing belongs to workflow/runtime policy, not public mutation. |
| `vcs.pr.observe` | `PrGateObserved` | `vcs:<operation_id>` | C | PR gate observation is internal bookkeeping. |
| `vcs.pr.merge` | `PrMerged` | `vcs:<operation_id>` | C | Merge completion must not be externally faked. |
| `vcs.merge.fail` | `MergeFailed` | `vcs:<operation_id>` | C | Failure state is runtime-owned. |
| `vcs.merge.block` | `MergeBlocked` | `vcs:<operation_id>` | C | Blocked state is runtime-owned. |
| `vcs_operation.start` | `VcsOperationStarted` | `vcs_operation:<operation_id>` | C | Adapter lifecycle event emitted by system adapter. |
| `vcs_operation.complete` | `VcsOperationCompleted` | `vcs_operation:<operation_id>` | C | Adapter lifecycle event emitted by system adapter. |
| `vcs_operation.fail` | `VcsOperationFailed` | `vcs_operation:<operation_id>` | C | Adapter lifecycle event emitted by system adapter. |

Policy reaffirmation: no new HTTP route, Go CLI command, or MCP tool will dispatch these raw command types. Workflow YAML is declarative input; `RunExecutor` converts it to internal system commands.

## Proposed YAML Schema

### Phase shape

```yaml
name: isolated-implementation
phases:
  - name: implement
    prompt: implement.md
    worktree:
      enabled: true
      base: main
      branch: foreman/{run_id}/{phase}
      path: implement
      cleanup: always
```

### Fields

| Field | Type | Required | Default | Notes |
|---|---|---:|---|---|
| `enabled` | boolean/string boolean | no | `true` when `worktree` map exists | `false` disables without removing block. |
| `base` | non-empty string | no | project default branch, else `HEAD` | Branch, tag, or SHA. |
| `branch` | non-empty string template | no | `foreman/{run_id}/{phase}` | Branch/worktree ref created for the phase. |
| `path` | relative string template | no | `<phase_slug>` under default root | Absolute paths rejected in v1. |
| `cleanup` | enum | no | `always` | `always` or `never` in v1. |

### Template variables

Supported in `branch` and `path`:

- `{project_id}`
- `{run_id}`
- `{task_id}`
- `{phase}` — slugged phase name or `phase-<index>`
- `{phase_index}` — 1-based phase index

### Full user-guide example

```yaml
name: isolated-plan-implement
phases:
  - name: plan
    command: /skill:ensemble-full-create-prd --foreman
    requiredFile: planning.prd_path

  - name: implement
    prompt: implement.md
    requiredFile: implementation.diff_path
    worktree:
      enabled: true
      base: main
      branch: foreman/{run_id}/implement
      path: implement
      cleanup: always
```

Behavior: the `plan` phase runs as it does today. The `implement` phase creates a Git worktree under `~/.foreman/worktrees/<project>/<run>/implement`, starts Pi from that directory through `context["working_directory"]`, writes artifacts normally, and removes the worktree after terminal.

## Component Design

### 1. `ForemanServer.VcsAdapter` behaviour

Target file: `packages/foreman_server/lib/foreman_server/vcs_adapter.ex`

Add callbacks:

```elixir
@callback create_worktree(repo_path :: String.t(), worktree_path :: String.t(), opts :: keyword()) ::
            {:ok, %{path: String.t(), ref: String.t(), branch: String.t() | nil}} | {:error, term()}

@callback clean_worktree(worktree_path :: String.t(), opts :: keyword()) ::
            {:ok, %{path: String.t(), cleaned?: boolean(), noop?: boolean()}} | {:error, term()}
```

Extend retry wrapper accepted function atoms:

```elixir
:create_worktree | :clean_worktree
```

Do not add `merge_into_base/2` for v1 execution. Merge is not required to create/clean phase worktrees and is already modeled at aggregate level. Add aggregate test coverage for merge commands per this TRD. If a future slice adds merge execution, add a separate adapter callback then.

### 2. `ForemanServer.VcsAdapter.Default`

Target file: `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex`

Add:

```elixir
def create_worktree(repo_path, worktree_path, opts) do
  operation_id = Keyword.get(opts, :operation_id, "worktree-create-...")
  base = Keyword.get(opts, :base, "HEAD")
  branch = Keyword.get(opts, :branch)
  target = "#{repo_path}:#{worktree_path}:#{base}"

  emit_started(operation_id, "worktree_create", target)

  args = ["-C", repo_path, "worktree", "add"] ++ branch_args(branch) ++ [worktree_path, base]

  case System.cmd("git", args, stderr_to_stdout: true) do
    {output, 0} ->
      result = %{path: worktree_path, base: base, branch: branch, output: output}
      emit_completed(operation_id, "worktree_create", target, result)
      {:ok, result}

    {output, code} ->
      reason = {:git_worktree_create_failed, code, output}
      emit_failed(operation_id, "worktree_create", target, reason, 0)
      {:error, reason}
  end
end
```

Branch args:

- If `branch` is nil/empty: `[]`.
- If set: `["-b", branch]`.

Add cleanup:

```elixir
def clean_worktree(worktree_path, opts) do
  operation_id = Keyword.get(opts, :operation_id, "worktree-clean-...")
  repo_path = Keyword.fetch!(opts, :repo_path)
  target = "#{repo_path}:#{worktree_path}"

  emit_started(operation_id, "worktree_clean", target)

  cond do
    not File.exists?(worktree_path) ->
      result = %{path: worktree_path, cleaned?: true, noop?: true}
      emit_completed(operation_id, "worktree_clean", target, result)
      {:ok, result}

    true ->
      case System.cmd("git", ["-C", repo_path, "worktree", "remove", "--force", worktree_path], stderr_to_stdout: true) do
        {output, 0} ->
          System.cmd("git", ["-C", repo_path, "worktree", "prune"], stderr_to_stdout: true)
          result = %{path: worktree_path, cleaned?: true, noop?: false, output: output}
          emit_completed(operation_id, "worktree_clean", target, result)
          {:ok, result}

        {output, code} ->
          reason = {:git_worktree_clean_failed, code, output}
          emit_failed(operation_id, "worktree_clean", target, reason, 0)
          {:error, reason}
      end
  end
end
```

Implementation notes:

- Use argv lists only; do not build a command string and split it.
- Capture stderr via `stderr_to_stdout: true`.
- Keep existing `clone/2`, `branch/2`, `create_pr/2` behavior unchanged except optional shared helper extraction.
- Emit telemetry from adapter or a thin executor wrapper as defined below.

### 3. Workflow interpreter validation

Target file: `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex`

Add phase validation for optional `worktree` map:

- Accept only map values.
- Treat absent as disabled.
- Treat map with no `enabled` as enabled.
- `enabled` accepts boolean `true|false` and YAML scalar strings `"true"|"false"` if current parser returns strings.
- `base`, `branch`, `path` must be non-empty strings when present.
- `path` must be relative and must not contain `..` path traversal.
- `cleanup` must be `always` or `never`.

Parser limitation: current custom YAML parser supports one-level nested maps at phase indent. The chosen schema uses exactly one nested map and avoids arrays.

### 4. Workflow catalog normalization

Target file: `packages/foreman_server/lib/foreman_server/workflow/catalog.ex`

Normalize phase `worktree` into atom-keyed form consumed by `RunExecutor`:

```elixir
%{
  enabled: true,
  base: "main" | nil,
  branch: "foreman/{run_id}/{phase}",
  path: nil | "implement",
  cleanup: "always"
}
```

Rules:

- If omitted or disabled, either omit the normalized field or set `%{enabled: false}`; executor must treat both as no-op.
- Preserve legacy normalized phase fields exactly.
- Include the normalized worktree in workflow snapshot digest so changing worktree config changes task/run snapshots.

### 5. RunExecutor worktree lifecycle

Target file: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`

Add a small internal lifecycle wrapper around phase execution.

Proposed flow:

```elixir
defp run_single_phase(state, phase_spec, index) do
  phase_index = phase_number(phase_spec, index)

  with {:ok, _} <- validate_phase_action(phase_spec, phase_index),
       {:ok, _} <- emit_phase_start(state, phase_spec, phase_index),
       {:ok, worktree_ctx, state} <- maybe_create_worktree(state, phase_spec, phase_index),
       {:ok, output} <- execute_agent(state, phase_spec, index, worktree_ctx),
       {:ok, artifact_path} <- ArtifactTemplate.write(...),
       {:ok, _required_file} <- enforce_required_file(...),
       {:ok, artifact} <- ArtifactTemplate.describe(artifact_path),
       {:ok, _} <- emit_phase_complete(state, phase_index, artifact) do
    cleanup_after_phase_terminal(state, worktree_ctx, :completed)
    advance
  else
    {:error, reason} ->
      cleanup_after_phase_terminal(state, worktree_ctx_if_any, {:failed, reason})
      emit_phase_failure(...)
  end
end
```

Implementation must be careful in Elixir to retain worktree context in failure branches. A practical shape is to split into `run_phase_body/4` returning `{result, worktree_ctx}` or use `try/after`-style helper.

#### Worktree create details

`maybe_create_worktree/3`:

1. If no enabled worktree config: return `%{}` no-op context.
2. Resolve repo path from current task working directory.
3. Resolve project/run/phase-safe worktree path.
4. Resolve base and branch templates.
5. Dispatch logical `vcs.worktree.create` via `CommandGateway.dispatch_system/1` with aggregate id `vcs:<operation_id>`.
6. Call `VcsAdapter.Default.create_worktree(repo_path, worktree_path, opts)`.
7. Emit telemetry success/failure.
8. Return `%{working_directory: worktree_path, worktree_path: worktree_path, operation_id: operation_id}`.

The logical aggregate event and generic adapter lifecycle events intentionally both exist:

- `vcs.worktree.create` records domain worktree state.
- `vcs_operation.start|complete|fail` records shell adapter lifecycle.

#### Worker cwd handoff

`base_context/3` currently sets `"working_directory"` from the task. Add an execution override so worktree phases set:

```elixir
"working_directory" => worktree_path
```

Because `PiAdapter` reads `context["working_directory"]`, validates the directory exists, and shells via `cd <dir> && exec pi ...`, this is sufficient for the current Pi backend. Tests must verify the worker sees the worktree cwd via a pwd capture or adapter stub.

Do not use phase `context` to override this value after worktree resolution. Worktree cwd must win over user-supplied phase context for enabled worktree phases, or the isolation guarantee can be bypassed accidentally.

#### Cleanup details

`cleanup_after_phase_terminal/3`:

1. If no worktree context or `cleanup: never`, no-op.
2. Dispatch logical `vcs.worktree.clean` via `CommandGateway.dispatch_system/1`.
3. Call `VcsAdapter.Default.clean_worktree(worktree_path, repo_path: repo_path, operation_id: clean_operation_id)`.
4. Emit success/failure telemetry.
5. On failure, log and record the worktree in executor state `pending_worktree_cleanups` for run-terminal retry.

Run-terminal retry occurs in `finalize_run/1` before or after `dispatch_run_complete/1`; prefer before run complete so final logs can reflect cleanup status. Failure remains non-fatal to the run completion path.

### 6. Telemetry

Emit these events:

| Event | When | Measurements | Metadata |
|---|---|---|---|
| `[:foreman_server, :vcs, :worktree, :create]` | create success | `%{duration_ms: non_neg_integer}` | `run_id`, `phase_id`, `operation_id`, `repo_path`, `worktree_path`, `base`, `branch` |
| `[:foreman_server, :vcs, :worktree, :clean]` | clean success | `%{duration_ms: non_neg_integer}` | `run_id`, `phase_id`, `operation_id`, `worktree_path`, `noop?` |
| `[:foreman_server, :vcs, :worktree, :create_failed]` | create failure | `%{duration_ms: non_neg_integer}` | success metadata plus classified reason |
| `[:foreman_server, :vcs, :worktree, :clean_failed]` | clean failure | `%{duration_ms: non_neg_integer}` | success metadata plus classified reason |

Avoid including full command output in telemetry metadata; event payload can carry output for event store if existing conventions permit, but telemetry/logs should use summarized reason.

## Acceptance Criteria Mapping

| PRD AC | Design element | Verification |
|---|---|---|
| AC-1 | Phase `worktree` schema + `RunExecutor.maybe_create_worktree` + cwd override | Integration test captures pwd from worker/adapter in worktree. |
| AC-2 | Phase-terminal cleanup + `clean_worktree/2` | Integration test checks `git worktree list` no longer includes path. |
| AC-3 | No-op behavior when `worktree` absent | Existing workflow regression test asserts no VCS calls and unchanged cwd. |
| AC-4 | Fail-closed create semantics | Adapter stub/temp repo failure test asserts phase/run failed and cleanup attempted. |
| AC-5 | Best-effort cleanup failure handling | Stub failure test asserts telemetry/log and run-terminal retry marker. |

## Test Plan

### Unit: VCS adapter

Target file: `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs`

Add tests:

1. `create_worktree/3 creates a git worktree from a tmp repo`
   - Initialize tmp repo.
   - Commit a file.
   - Call `Default.create_worktree(repo, worktree, base: "HEAD", branch: "test-worktree")`.
   - Assert `{:ok, %{path: ^worktree}}`.
   - Assert file exists under worktree.
   - Assert `git -C repo worktree list` includes path.

2. `clean_worktree/2 removes an existing worktree`
   - Create via adapter.
   - Call `Default.clean_worktree(worktree, repo_path: repo)`.
   - Assert path removed.
   - Assert `git worktree list` excludes path.

3. `clean_worktree/2 is idempotent when path is absent`
   - Call cleanup for absent path.
   - Assert `{:ok, %{noop?: true}}`.

4. `create_worktree/3 emits lifecycle failure on git error`
   - Use invalid repo path or conflicting branch.
   - Assert `{:error, _}` and event dispatch test helper observed `vcs_operation.fail`.

### Aggregate: VcsOperation

Target file: `packages/foreman_server/test/foreman_server/aggregates/vcs_operation_test.exs`

Add/extend tests:

1. `vcs.worktree.clean requires existing operation`.
2. `vcs.worktree.create then vcs.worktree.clean reaches terminal cleaned`.
3. `vcs.merge.request creates merge_requested state`.
4. `vcs.merge.fail reaches terminal failed`.
5. `terminal validation rejects command after cleaned/failed/blocked/merged`.
6. `vcs_operation.start/complete/fail validate operation_id and map streams`.

### YAML parsing and catalog normalization

Targets:

- `packages/foreman_server/test/foreman_server/workflow/interpreter_test.exs`
- `packages/foreman_server/test/foreman_server/workflow/catalog_test.exs`
- fixture under `packages/foreman_server/test/fixtures/workflows/worktree_phase.yaml` or `packages/foreman_server/priv/defaults/workflows/worktree-example.yaml` if bundled.

Add tests:

1. Valid phase-level `worktree` map parses.
2. Missing `worktree` leaves phase unchanged.
3. Invalid cleanup enum rejected.
4. Absolute/path traversal path rejected.
5. Catalog normalizes string keys to atom keys/defaults.
6. Snapshot digest changes when worktree config changes.

### Integration: RunExecutor

Target file: `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs` or new `run_executor_worktree_test.exs`.

Add tests:

1. `RunExecutor creates worktree and executes phase from it`
   - Set task `working_directory` to tmp Git repo.
   - Phase declares worktree enabled.
   - Stub or real Pi adapter returns cwd/pwd evidence from `context["working_directory"]`.
   - Assert worktree path exists during execution.
   - Assert phase artifact captures worktree cwd.

2. `RunExecutor cleans worktree after completed phase`
   - After run terminal, assert `git worktree list` excludes worktree path.

3. `RunExecutor fails phase on create failure and does not fallback`
   - Configure conflicting branch or invalid base.
   - Assert phase fail/run fail.
   - Assert worker adapter not invoked.

4. `cleanup failure is best-effort and retried at run terminal`
   - Stub cleaner to fail first, succeed second.
   - Assert telemetry/log and retry.

5. `workflow without worktree unchanged`
   - Existing phase with task `working_directory`.
   - Assert no VCS adapter calls and context cwd equals original task path.

### Commands to run

```bash
cd packages/foreman_server
mix test test/foreman_server/vcs_adapter_default_test.exs
mix test test/foreman_server/aggregates/vcs_operation_test.exs
mix test test/foreman_server/workflow/interpreter_test.exs test/foreman_server/workflow/catalog_test.exs
mix test test/foreman_server/workflow/run_executor_worktree_test.exs
mix test
```

## Documentation Plan

### `docs/user-guide.md`

Add a workflow author subsection:

- Why use phase worktrees.
- `worktree` field schema.
- Full YAML example.
- Cleanup semantics.
- Failure semantics: create failure fails the run; cleanup failure logs/retries.
- Default path location.

### `docs/cli-reference.md`

Add a note under workflow install/run docs:

- No new CLI command exists for worktrees.
- Worktrees are configured in workflow YAML and activated when the installed workflow runs.
- `foreman workflow install` remains the CLI path for shipping workflow YAML changes.

### `docs/workflow-yaml-reference.md` if present or created

Add exact schema table and validation rules.

### Architecture ADR

Create `docs/architecture/ADR-2026-3d41f677-phase-scoped-worktrees.md` if the repo is maintaining ADRs for workflow semantics. The ADR should record the phase-level vs workflow-level decision and rejected alternatives.

## Migration and Rollout

1. Add adapter callbacks/functions and unit tests.
2. Add workflow parser/catalog validation and fixture tests.
3. Add RunExecutor lifecycle behind opt-in `worktree.enabled` only.
4. Add telemetry and integration tests.
5. Update docs.
6. Run full `packages/foreman_server` test suite.
7. Because source workflows/prompts may be edited for examples, run `foreman init --force` before validating installed runtime workflows, per repo memory.

Migration invariant: workflows without `worktree` execute unchanged. No database migration is required because workflow snapshots already carry arbitrary normalized phase maps. If projections enforce schemas elsewhere, extend them in-place with optional field handling only.

## Implementation Notes and Edge Cases

- `PiAdapter` already requires and uses `context["working_directory"]`; executor worktree cwd must be placed there before the adapter call.
- Phase-level `context` must not override worktree cwd after resolution.
- `git worktree add -b <branch> <path> <base>` fails if branch already exists. That is acceptable and should fail closed.
- Cleanup should tolerate missing paths as success/no-op.
- Cleanup should call `git worktree prune` after remove success or stale metadata detection.
- Operation ids should be deterministic enough for logs and idempotency, e.g. `#{run_id}:#{phase_id}:worktree:create` and `#{run_id}:#{phase_id}:worktree:clean`.
- Avoid logging full stdout/stderr at info level; include command output in tagged error for tests/debug where existing patterns allow.
- Do not add top-level workflow `merge:` or `pr:` fields. Existing repo instruction says PR/merge behavior uses phase-level `checkpointPr: true` and explicit phases.

## Requirement Traceability

| PRD requirement | TRD section |
|---|---|
| REQ-001 Adapter supports worktrees | Component Design 1-2, Test Plan Unit |
| REQ-002 Merge shim decision | Component Design 1, Command Inventory |
| REQ-003 YAML declaration | Proposed YAML Schema, Component Design 3-4 |
| REQ-004 Executor create | Component Design 5 |
| REQ-005 Executor clean | Component Design 5 |
| REQ-006 Migration safety | Migration and Rollout, Integration tests |
| REQ-007 Bucket C classification | Command Inventory and Bucket Classification |
| REQ-008 Telemetry | Telemetry |
| REQ-009 Tests | Test Plan |
| REQ-010 Safe deterministic paths | Decision 5, YAML fields |
| REQ-011 Docs | Documentation Plan |
| REQ-012 Idempotent cleanup | Component Design 2 and 5, Test Plan |

## Deliverables Checklist

- [x] Inventory of all `vcs.*` types currently in `VcsOperation.handle_command/2`.
- [x] Decision recorded on phase-level vs workflow-level worktree with rationale.
- [x] `VcsAdapter.Default` extension specified: functions, signatures, telemetry/lifecycle events.
- [x] `Workflow.Interpreter` / `Workflow.Catalog` extension specified: field names, defaults, validation.
- [x] `RunExecutor` integration plan with phase-boundary hooks.
- [x] Migration path documented: workflows without worktree continue working.
- [x] Test plan with concrete file paths and AC-1..AC-5 mapping.
- [x] Documentation updates listed: user guide, CLI reference, workflow YAML reference/ADR as applicable.

## Open Risks

| Risk | Status | Owner action |
|---|---|---|
| Existing custom YAML parser may coerce booleans as strings | Known | Validation should accept both booleans and string booleans or normalize parser output. |
| RunExecutor failure branch needs access to created worktree ctx | Known | Structure code so cleanup context is retained even after body errors. |
| Event store duplicate terminal validation may reject repeated cleanup command | Known | Make adapter cleanup idempotent; dispatch logical clean once per phase, and use distinct retry operation id or no-op handling for run-terminal retry. |
| `cleanup: never` can leave worktrees | Known | Document and consider gating behind dev/test config if product wants no debug escape hatch. |

## Design Readiness

This TRD is scope-complete for implementation. It selects phase-scoped Git worktrees, specifies adapter/schema/executor/test/docs changes, records VCS Bucket C inventory, and preserves migration safety for existing workflows.
