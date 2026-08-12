---
document_id: PRD-2026-3d41f677
label: prd-add-full-vcs-worktree-support-configured-via-wor
version: 1.0.0
status: Draft
date: 2026-08-12
scale_depth: STANDARD
total_requirements: 12
readiness_score: 4.3
---

# PRD: Workflow-Configured VCS Worktree Support

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 2 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 12/12 (100%) |
| Risk flags | 7 |
| Dependencies | 8 |
| Open ambiguity markers | 0 |
| TRD decisions required | 5 |

## 1. Executive Summary

Foreman needs first-class Git worktree lifecycle support declared in workflow YAML. A workflow author must be able to opt a phase into an isolated worktree, have Foreman create it before the phase worker starts, run the worker from that directory, and clean it up automatically after the phase reaches a terminal state.

Today the `ForemanServer.Aggregates.VcsOperation` aggregate already recognizes worktree and merge command types, but production code does not call them. `ForemanServer.VcsAdapter.Default` only implements `clone/2`, `branch/2`, and `create_pr/2`; it has no `git worktree add` or `git worktree remove --force` adapter shims. The product gap is a concrete wire-through from workflow YAML to adapter execution to phase runtime cwd and cleanup.

The v1 scope is Git-only, phase-scoped worktrees, internal-only VCS commands, no HTTP/CLI worktree surface, and no behavior change for workflows that omit the new field.

## 2. Background and Evidence

### Product prompt

Task `foreman-nr1j` requests full VCS worktree support configured via workflows.

### Current code facts

- `packages/foreman_server/lib/foreman_server/aggregates/vcs_operation.ex` handles `vcs.worktree.create`, `vcs.worktree.clean`, `vcs.merge.request`, `vcs.pr.observe`, `vcs.pr.merge`, `vcs.merge.fail`, `vcs.merge.block`, and generic adapter lifecycle commands `vcs_operation.start|complete|fail`.
- `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` implements only `clone/2`, `branch/2`, `create_pr/2`, and emits `vcs_operation.start|complete|fail` via `CommandGateway.dispatch_system/1`.
- `packages/foreman_server/lib/foreman_server/vcs_adapter.ex` behaviour only declares `clone/2`, `branch/2`, and `create_pr/2` callbacks.
- `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex` validates phase actions and currently allows `prompt`, `command`, and `bash` as action fields.
- `packages/foreman_server/lib/foreman_server/workflow/catalog.ex` normalizes loaded workflow fields before snapshots are used by runs.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` emits phase lifecycle events, calls `AgentRuntime.execute/3`, and builds a context map containing `working_directory`.
- `packages/foreman_server/lib/foreman_server/agent_runtime/adapters/pi_adapter.ex` requires `context["working_directory"]` and shells through `cd <working_directory> && exec pi ...`, so setting the phase context cwd is the current worker handoff mechanism.

### Policy context

Per the MCP exposure plan, `vcs.worktree.*`, `vcs.merge.*`, and generic `vcs_operation.*` lifecycle commands remain Bucket C: system-internal, never exposed directly over MCP, HTTP, or CLI. Workflow YAML may request worktree behavior, but only Foreman runtime code dispatches the underlying system commands.

## 3. Personas

### 3.1 Workflow author

Writes Foreman workflow YAML and needs phase-level isolation without custom shell preambles or manual cleanup.

### 3.2 Foreman operator

Runs workflows concurrently and needs predictable worktree paths, reliable cleanup, and no surprise changes to legacy workflows.

### 3.3 Foreman maintainer

Needs the implementation to reuse existing aggregate, adapter, workflow catalog, run executor, telemetry, and test patterns without inventing a new VCS API surface.

## 4. Goals and Non-Goals

### Goals

- Add Git worktree create/clean support to `VcsAdapter.Default`.
- Add a declarative YAML shape for phase-scoped worktrees.
- Normalize and validate the new field through `Workflow.Interpreter` and `Workflow.Catalog`.
- Create worktrees before phase worker execution and clean them after phase terminal.
- Make phase workers execute inside the worktree directory through the existing `working_directory` context contract.
- Emit VCS lifecycle events and worktree telemetry.
- Preserve zero behavior change for workflows without `worktree`.
- Keep all `vcs.*` commands Bucket C/system-internal.

### Non-Goals

- No HTTP route exposing `vcs.*`.
- No Go CLI subcommand for worktrees.
- No MCP tool for worktrees or merge internals.
- No multi-VCS abstraction in this slice; Git only.
- No Jujutsu workspace support in this slice.
- No redesign of existing `clone`, `branch`, or `create_pr` behavior except shared helper cleanup needed for safe argument handling.
- No top-level workflow PR or merge redesign.

## 5. Product Decisions Required by the TRD

The paired TRD must record these decisions explicitly:

1. **Declaration location:** phase-level worktree declaration for v1, with workflow-level considered and rejected.
2. **Cleanup timing:** default cleanup after every phase terminal; best-effort and idempotent; retry at run terminal after cleanup failure.
3. **Base ref:** default to project default branch or current checkout `HEAD` when unknown; allow workflow override by named ref.
4. **Failure semantics:** worktree create failure fails the phase/run; no fallback to main checkout.
5. **Concurrency:** isolate by path under `~/.foreman/worktrees/<project>/<run>/<phase>` unless workflow supplies a relative suffix; never share worktrees across runs.

## 6. Requirements

### REQ-001: Must | Critical | Default VCS adapter supports Git worktrees

`ForemanServer.VcsAdapter.Default` MUST expose `create_worktree/3` and `clean_worktree/2` functions, and the behaviour MUST declare matching callbacks.

- AC-001-1: Given a Git repository path, target worktree path, and options, when `create_worktree/3` is called, then it shells out to `git -C <repo> worktree add <path> <ref_or_branch>` using argv-safe arguments.
- AC-001-2: Given an existing worktree path, when `clean_worktree/2` is called, then it shells out to `git worktree remove --force <path>` and prunes stale metadata when appropriate.
- AC-001-3: Given either operation starts, completes, or fails, then `vcs_operation.start`, `vcs_operation.complete`, or `vcs_operation.fail` is dispatched via `CommandGateway.dispatch_system/1` with operation type and target.
- AC-001-4: Given a command fails, then stdout/stderr or combined command output is captured in the error payload without logging secrets.

### REQ-002: Must | High | Optional merge shim is supported if workflow cleanup needs it

If implementation uses merge completion from the worktree lifecycle, the adapter MUST add `merge_into_base/2` and the behaviour MUST declare it. If not used in v1, the TRD MUST explicitly defer it while preserving aggregate test coverage for merge commands.

- AC-002-1: Given merge is in v1 implementation scope, when `merge_into_base/2` runs, then it emits lifecycle events and maps Git failure to `vcs.merge.fail` semantics.
- AC-002-2: Given merge is not used by worktree lifecycle, when the TRD is reviewed, then it states no merge adapter shim is needed for this slice and tests still cover existing merge aggregate commands.

### REQ-003: Must | Critical | Workflow YAML supports phase worktree declaration

Workflow YAML MUST allow an optional phase-level `worktree` object.

Required v1 shape:

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

- AC-003-1: Given a phase contains `worktree.enabled: true`, when the workflow is parsed, then the normalized phase includes a worktree config with defaults applied.
- AC-003-2: Given a phase omits `worktree`, when parsed, then the normalized phase is equivalent to current behavior.
- AC-003-3: Given invalid values for `enabled`, `base`, `branch`, `path`, or `cleanup`, then `Workflow.Interpreter` rejects the manifest with an actionable validation error.
- AC-003-4: Given docs are reviewed, then the user guide includes one full workflow example using the chosen shape.

### REQ-004: Must | Critical | RunExecutor creates worktree before worker start

`RunExecutor` MUST dispatch worktree creation before executing a phase worker when that phase declares worktree support.

- AC-004-1: Given phase 1 declares `worktree.enabled: true`, when the phase starts, then `vcs.worktree.create` and adapter create logic run before `AgentRuntime.execute/3`.
- AC-004-2: Given create succeeds, when the worker starts, then `context["working_directory"]` points at the worktree path and the Pi adapter runs from that directory.
- AC-004-3: Given create fails, when the phase is evaluated, then the phase and run fail; Foreman does not silently continue in the main checkout.
- AC-004-4: Given create fails after partially creating a directory, then cleanup is attempted before terminal failure is recorded.

### REQ-005: Must | Critical | RunExecutor cleans worktree after phase terminal

`RunExecutor` MUST dispatch cleanup after a worktree phase reaches terminal state.

- AC-005-1: Given a worktree phase completes, fails, or blocks, when terminal handling runs, then `vcs.worktree.clean` and adapter cleanup run.
- AC-005-2: Given cleanup succeeds, when `git worktree list` is inspected, then the worktree entry is gone.
- AC-005-3: Given cleanup fails, then the cleanup failure is logged and telemetry is emitted, but cleanup failure does not mask the phase's original terminal reason.
- AC-005-4: Given cleanup failed earlier, then run-terminal cleanup retries outstanding worktrees once.

### REQ-006: Must | High | Migration safety preserves existing workflows

Workflows without `worktree` MUST continue to execute against their current `working_directory` resolution with no behavior change.

- AC-006-1: Given an existing workflow YAML without `worktree`, when a run executes, then no `vcs.worktree.*` or worktree adapter calls occur.
- AC-006-2: Given an existing task has `working_directory`, when no worktree is declared, then that path remains the worker cwd.
- AC-006-3: Given no task `working_directory` exists, when no worktree is declared, then existing fallback to `$HOME` remains unchanged.

### REQ-007: Must | Critical | Bucket C classification is recorded and enforced

The worktree feature MUST keep VCS commands system-internal.

- AC-007-1: Given the TRD inventory is reviewed, then `vcs.worktree.*`, `vcs.merge.*`, `vcs.pr.*`, and `vcs_operation.*` are classified as Bucket C.
- AC-007-2: Given HTTP, CLI, and MCP surfaces are reviewed, then no direct worktree command is added.
- AC-007-3: Given a workflow author declares worktree YAML, then Foreman runtime dispatches internal commands; users cannot submit raw `vcs.*` commands through public APIs.

### REQ-008: Must | High | Telemetry covers worktree lifecycle

Foreman MUST emit worktree telemetry for create/clean success and failure.

- AC-008-1: Given create starts and succeeds, telemetry includes `[:foreman_server, :vcs, :worktree, :create]`.
- AC-008-2: Given clean starts and succeeds, telemetry includes `[:foreman_server, :vcs, :worktree, :clean]`.
- AC-008-3: Given create fails, telemetry includes `[:foreman_server, :vcs, :worktree, :create_failed]`.
- AC-008-4: Given clean fails, telemetry includes `[:foreman_server, :vcs, :worktree, :clean_failed]`.

### REQ-009: Must | High | Test coverage spans adapter, aggregate, executor, and YAML parsing

The implementation MUST add concrete tests for all layers touched by the worktree lifecycle.

- AC-009-1: Unit tests cover `VcsAdapter.Default` create/clean against a temporary Git repo.
- AC-009-2: Aggregate tests cover `vcs.worktree.clean`, `vcs.merge.request`, `vcs.merge.fail`, terminal validation, and generic lifecycle event mapping beyond current coverage.
- AC-009-3: Integration tests prove `RunExecutor` creates and cleans a worktree across a real run and passes the worktree cwd to the phase worker.
- AC-009-4: YAML fixture tests prove parsing/normalization for valid and invalid worktree declarations.

### REQ-010: Should | Medium | Worktree paths are deterministic and safe

Worktree path generation SHOULD be deterministic, isolated, and safe for concurrent runs.

- AC-010-1: Given no explicit path is configured, then the path is under `~/.foreman/worktrees/<project_id>/<run_id>/<phase_name_or_index>`.
- AC-010-2: Given two runs execute the same workflow concurrently, then they resolve different worktree paths.
- AC-010-3: Given phase names contain spaces or unsafe characters, then path segments are slugged.

### REQ-011: Should | Medium | Documentation explains workflow author behavior

Docs SHOULD explain how and when to use phase worktrees.

- AC-011-1: Given docs are reviewed, then `docs/user-guide.md` describes the phase-level `worktree` field and includes a full example.
- AC-011-2: Given `docs/cli-reference.md` is reviewed, then it states there is no new worktree CLI command and workflow install remains the entry point.
- AC-011-3: Given architecture docs are reviewed, then an ADR is present if maintainers judge the phase-level vs workflow-level decision significant enough to preserve.

### REQ-012: Must | Medium | Worktree cleanup is idempotent

Cleanup MUST be safe to retry.

- AC-012-1: Given the worktree path is already absent, when cleanup runs, then it returns success or a tagged no-op result.
- AC-012-2: Given Git metadata has a stale worktree record, when cleanup runs, then it attempts `git worktree prune` and records the result.
- AC-012-3: Given cleanup is called twice for the same operation id, then no duplicate terminal state corrupts the run.

## 7. Dependency Map

| Requirement | Depends On | Notes |
|---|---|---|
| REQ-001 | none | Adapter foundation |
| REQ-002 | REQ-001 | Only if merge enters v1 execution path |
| REQ-003 | none | Schema/API to workflow authors |
| REQ-004 | REQ-001, REQ-003 | Executor needs adapter + normalized config |
| REQ-005 | REQ-001, REQ-004 | Cleanup follows creation |
| REQ-006 | REQ-003, REQ-004 | Must prove no behavior drift |
| REQ-007 | REQ-003, REQ-004 | Internal runtime dispatch only |
| REQ-008 | REQ-001, REQ-004, REQ-005 | Lifecycle instrumentation |
| REQ-009 | REQ-001..REQ-008 | Verification |
| REQ-010 | REQ-004 | Deterministic path resolver |
| REQ-011 | REQ-003, REQ-006 | Docs reflect real behavior |
| REQ-012 | REQ-005 | Retry-safe cleanup |

No circular dependencies identified. The minimum implementation cluster is REQ-001, REQ-003, REQ-004, REQ-005, REQ-006, REQ-007, REQ-008, and REQ-009.

## 8. Acceptance Criteria Summary

| ID | Acceptance criterion |
|---|---|
| AC-1 | Given a workflow YAML declaring `worktree.enabled: true` on phase 1, when the run starts, then `RunExecutor` dispatches worktree create and the phase worker operates inside the new worktree directory, verified by worker cwd capture. |
| AC-2 | Given a worktree phase reaches terminal, when the next phase starts or the run ends, then cleanup runs and `git worktree list` no longer shows the entry. |
| AC-3 | Given a workflow without a worktree field, when the run starts, then it executes unchanged against the main checkout/current task working directory. |
| AC-4 | Given worktree creation fails, when dispatched, then lifecycle failure is recorded, the run is failed, and no orphan worktree remains. |
| AC-5 | Given cleanup fails, when dispatched, then telemetry/logs capture failure, run processing does not crash, and run-terminal cleanup retries. |

## 9. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Worker cwd is only context-driven | High | Reuse Pi adapter's existing `context["working_directory"]` cwd contract and test via pwd capture. |
| Orphaned worktrees after failures | High | Best-effort cleanup on create failure, phase terminal cleanup, run terminal retry, idempotent cleaner. |
| Existing workflows drift | High | Feature is opt-in only; add regression tests for no-worktree flows. |
| Unsafe shell argument handling | Medium | Use `System.cmd/3` argv lists, not string splitting, for new Git operations and touch shared helpers only as needed. |
| Parser cannot support deep YAML structures | Medium | Use one-level nested `worktree` map for v1; defer lists/deep schemas. |
| Bucket C leakage | Critical | No HTTP/CLI/MCP surface; inventory and policy doc reaffirm internal-only commands. |
| Concurrent path collision | High | Include project id, run id, and phase slug in default path. |

## 10. Documentation Deliverables

- `docs/user-guide.md`: workflow author section with full phase worktree example.
- `docs/cli-reference.md`: note that worktrees are configured through workflow YAML; no new CLI command.
- `docs/workflow-yaml-reference.md` if present/created in this repo: exact `worktree` schema and defaults.
- `docs/architecture/ADR-2026-3d41f677-phase-worktrees.md` if maintainers choose to record the phase-vs-workflow decision as an ADR.
- `README.md`/`CLAUDE.md` only if implementation changes operator/developer expectations beyond the workflow docs.

## 11. Readiness

This PRD is ready for TRD design. The TRD must formalize command inventory, selected YAML schema, lifecycle hooks, failure semantics, tests, docs, and migration safety before implementation starts.
