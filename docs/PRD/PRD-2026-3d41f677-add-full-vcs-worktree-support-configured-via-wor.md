---
document_id: PRD-2026-3d41f677
label: prd-add-full-vcs-worktree-support-configured-via-wor
version: 1.1.0
status: Draft
date: 2026-08-12
scale_depth: STANDARD
total_requirements: 18
readiness_score: 4.5
---

# PRD: Workflow-Configured VCS Worktree Support -- Foreman-Managed Execution



## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 14 |
| Should | 4 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 18/18 (100%) |
| Risk flags | 9 |
| Dependencies | 11 |
| Open ambiguity markers | 0 |
| TRD decisions required | 7 |

## Addendum: Foreman-Managed Execution Contract

This revision (v1.1.0) extends the original PRD with the boundary,
contexts, and atomicity rules that govern who owns the worktree and
how `ensemble-full-implement-trd` / `ensemble-full-implement-trd-beads`
are placed into managed mode. The original 12 requirements (REQ-001
through REQ-012) remain in force; v1.1.0 adds REQ-013 through
REQ-018 (six new requirements) which all describe the same execution
contract from different layers.

### A1. Ownership

Foreman owns the worktree lifecycle for implementation phases. It
chooses the pinned base revision, creates a unique branch and
worktree before the command phase, sets the phase cwd, records durable
lifecycle events, removes clean worktrees, and reconciles interrupted
cleanup after restart. Both implementation skills gain `--foreman` as a
managed-execution contract. The flag does not create a worktree; it
tells the skill that Foreman already provisioned the branch and
worktree, so the skill must verify the trusted cwd and branch markers
and must not create, switch, append, or stack branches itself.

### A2. Frozen implementation context

At approval time Foreman builds a worktree-reproducible context that
includes the normalized project-relative `trd_path`, the JSON-quoted
shell argument that is passed to the skill, the absolute project root,
the exact source revision resolved from `git rev-parse HEAD`, and
`implementation_key = SHA256(project_id <> "\0" <> normalized_trd_path)`.
For `implement-trd-beads` the absolute `task_provider.config.database_path`
obtained from `TaskProvider.Registry` is also frozen. These fields are
reserved server-derived approval fields. Operator payload values cannot
override them, and phase YAML context cannot shadow them. Idempotent
re-approval reuses the persisted snapshot even if HEAD, the manifest,
or the controller checkout later changes.

### A3. Atomic same-TRD exclusion

Distinct TRDs may execute concurrently. The same normalized
project/TRD is single-flight. `ProjectRunReserved` and the project
state track an optional `implementation_key`. Reservations with the
same active key in the same project are rejected with
`{:implementation_already_active, implementation_key, existing_run_id}`
before any worktree side effect. Terminal or rejected runs release the
key so a later retry can implement the TRD. Reservations without a
key retain the existing behaviour.

### A4. Trusted cwd and environment

Foreman sets the worker cwd to the absolute worktree path only after
`WorktreeCreated` persists. Operator-supplied phase context cannot
override worktree cwd. Foreman also injects `FOREMAN_WORKTREE=1`,
`FOREMAN_RUN_ID`, `FOREMAN_WORKTREE_PATH`, `FOREMAN_EXPECTED_BRANCH`,
`FOREMAN_SOURCE_REVISION`, and `FOREMAN_IMPLEMENTATION_KEY` into the
managed-execution environment. In Beads mode Foreman additionally
injects `BEADS_DB`. Managed-mode skills must require all of these
markers, verify `pwd` resolves to `FOREMAN_WORKTREE_PATH`, verify a
non-detached `git branch --show-current` equals `FOREMAN_EXPECTED_BRANCH`,
and verify `git rev-parse HEAD` descends from `FOREMAN_SOURCE_REVISION`.
Any mismatch halts before edits.

### A5. Tracked TRD requirement

A TRD must be committed and reachable from the registered project
repository at approval. Foreman rejects untracked or only-working-copy
TRDs. Supporting uncommitted documents requires a separate
immutable-content import design.

### A6. Two-repository rollout

Ensemble support for `--foreman` must be released and installed before
Foreman enables manifests that pass the flag. If an atomic rollout is
unavailable, land Ensemble first and gate the Foreman manifests on the
minimum compatible Ensemble package version.

### A7. Documentation completeness

Foreman/Skill ownership, task/workflow separation, tracked-TRD
requirement, unique branch/path behaviour, same-TRD rejection, Beads
scope/DB rules, clean-versus-dirty cleanup, recovery, and the warning
that concurrent PRs can still conflict semantically are documented in
`docs/user-guide.md`, `docs/cli-reference.md`, and `CLAUDE.md`.


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
2. **Cleanup durability:** cleanup is recorded as durable `WorktreeCreated`/`WorktreeCleaned` events. The unresolved-worktree projection is built by replaying the event store and survives a BEAM restart. `BootReconciliation` scans unresolved worktrees for terminal/orphaned runs and retries only safe clean removal. A dirty worktree is NEVER force-removed; it remains in the unresolved projection with operator guidance.
3. **Base ref:** the worktree base ref MUST equal the frozen `source_revision = git rev-parse HEAD` recorded in the implementation context at approval. The PRD does NOT permit a fallback to a project default branch or to `HEAD` at worktree creation time. Any `phase.worktree.base` override is rejected unless it equals the recorded `source_revision`. Branch names, tags, and SHAs are accepted so long as they resolve to the recorded revision.
4. **Failure semantics:** worktree create failure fails the phase/run; no fallback to main checkout. If the event append fails after `git worktree add` succeeds, compensate by removing only the clean, just-created worktree and recording the failed attempt. Never fabricate `WorktreeCreated`.
5. **Concurrency:** isolate by path under `~/.foreman/worktrees/<project>/<run>/<phase_slug>` unless workflow supplies a relative suffix; never share worktrees across runs. Same normalized project/TRD is single-flight via atomic `implementation_key` reservation; distinct TRDs may run concurrently.
6. **Implementation context:** the normalized project-relative `trd_path`, the JSON-quoted shell argument, the absolute project root, the exact `source_revision`, and `implementation_key = SHA256(project_id <> "\0" <> normalized_trd_path)` are frozen at approval. For `implement-trd-beads` the absolute `task_provider.config.database_path` is also frozen. Operator payload and phase YAML context cannot override these fields.
7. **Foreman / skill ownership:** Foreman owns the worktree lifecycle (create/clean, branch, base, path, cwd). The skills only verify the trusted cwd and branch markers and must not create, switch, append, or stack branches. `--foreman` is a managed-execution contract, not a worktree-creation flag.

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
- AC-004-4: Given create fails after `git worktree add` succeeded but the event append failed, then Foreman compensates by removing only the just-created CLEAN worktree and records the failed attempt. No `WorktreeCreated` event is fabricated. A dirty worktree is NEVER force-removed and remains in the unresolved-worktree projection for operator recovery.

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

### REQ-013: Must | Critical | Foreman owns the worktree lifecycle

Foreman MUST be the sole owner of worktree create/clean side effects. The two implementation skills MUST gain a `--foreman` flag that switches them into managed-execution mode. The flag MUST NOT create, switch, append, or stack branches; it MUST verify the trusted cwd and branch markers and MUST fail closed on mismatch.

- AC-013-1: Given `--foreman` is present, then the direct skill skips `git town hack`/`git switch -c` and the Beads skill skips `git switch`, `git town append`, stacked-PR, and per-phase PR paths.
- AC-013-2: Given `--foreman` is present, then the skill verifies `pwd == FOREMAN_WORKTREE_PATH`, `git branch --show-current == FOREMAN_EXPECTED_BRANCH`, and `git rev-parse HEAD` is a descendant of `FOREMAN_SOURCE_REVISION`. Any mismatch halts before edits.
- AC-013-3: Given `--foreman` is present, then the skill rejects `--branch`, `--use-current-branch`, or stacked-branch flags instead of guessing precedence.
- AC-013-4: Given `--foreman` is present, then the skill MUST NOT remove the Foreman-managed worktree.

### REQ-014: Must | Critical | Frozen implementation context at approval

Foreman MUST build a worktree-reproducible context at approval time and persist it. The context MUST include the normalized project-relative `trd_path`, the JSON-quoted shell argument, the absolute project root, the exact `source_revision` resolved from `git rev-parse HEAD`, and `implementation_key = SHA256(project_id <> "\0" <> normalized_trd_path)`. For `implement-trd-beads` it MUST also include the absolute `task_provider.config.database_path`. Operator payload values and phase YAML context MUST NOT override these fields.

- AC-014-1: Given a project root and TRD path, when `Workflow.ImplementationContext.build/1` runs, then it returns a frozen struct with normalized `trd_path`, `trd_path_argument`, `project_root`, `source_revision`, and `implementation_key`.
- AC-014-2: Given an absolute or `..` traversing `trd_path`, when build runs, then it rejects with a tagged error and does not write a snapshot.
- AC-014-3: Given a TRD path that escapes via symlink, when build runs, then it rejects with a tagged error.
- AC-014-4: Given HEAD changes between two approvals of the same task, when re-approval runs, then the persisted snapshot is reused and not re-fetched.
- AC-014-5: Given a TRD path is not a tracked blob at `source_revision:<path>`, when build runs, then it rejects.

### REQ-015: Must | Critical | Atomic same-TRD exclusion

Distinct TRDs MUST be allowed to run concurrently. The same normalized project/TRD MUST be single-flight. `ProjectRunReserved` and `Aggregates.Project.State` MUST track an optional `implementation_key`. Same-key concurrent reservations MUST be rejected with `{:implementation_already_active, implementation_key, existing_run_id}` before any worktree side effect. Terminal/rejection events MUST release the key.

- AC-015-1: Given two `run.start` commands for the same implementation_key in the same project, when both arrive, then exactly one succeeds and the loser receives `{:implementation_already_active, _}` before any worktree operation.
- AC-015-2: Given two distinct implementation_keys in the same project, when both arrive, then both reservations coexist up to the configured project run limit.
- AC-015-3: Given a run reaches terminal, when another `run.start` arrives for the same key, then the key is released and the new reservation succeeds.
- AC-015-4: Given a reservation has no `implementation_key`, then existing behavior is preserved.

### REQ-016: Must | Critical | Trusted cwd and environment handoff

Foreman MUST set the worker cwd to the absolute worktree path ONLY after `WorktreeCreated` persists. Operator-supplied phase context MUST NOT override worktree cwd. Foreman MUST inject `FOREMAN_WORKTREE=1`, `FOREMAN_RUN_ID`, `FOREMAN_WORKTREE_PATH`, `FOREMAN_EXPECTED_BRANCH`, `FOREMAN_SOURCE_REVISION`, and `FOREMAN_IMPLEMENTATION_KEY` into the managed-execution environment. For `implement-trd-beads` Foreman MUST additionally inject `BEADS_DB`.

- AC-016-1: Given a managed implementation phase, when the worker is invoked, then the environment map contains all six `FOREMAN_*` keys with the correct values.
- AC-016-2: Given a Beads workflow, when the worker is invoked, then `BEADS_DB` is set to the frozen absolute `task_provider.config.database_path`.
- AC-016-3: Given phase YAML context contains a `working_directory` override, when the managed phase is invoked, then the worktree path wins.
- AC-016-4: Given a path is included in telemetry metadata, when it is captured, then it is scrubbed to its basename to match existing task-provider path handling.

### REQ-017: Must | Critical | Beads workflow pass-through is scoped and DB-frozen

In managed Beads mode the skill MUST pass the frozen `BEADS_DB` explicitly to every `br` and `bv` invocation. It MUST derive `TRD_SCOPE = <trd-slug>-<first-12-of-FOREMAN_IMPLEMENTATION_KEY>` and use that scope as a `[trd:<TRD_SCOPE>]` prefix on every scaffolded bead title. It MUST filter every resume/status/ready/robot-plan candidate by the exact `TRD_SCOPE` before extracting `TRD-NNN` IDs.

- AC-017-1: Given a global `bv --robot-plan` result that contains two TRDs, when the managed skill selects the next bead, then only candidates matching the current `TRD_SCOPE` are considered.
- AC-017-2: Given two TRD paths with the same basename, when the skill scans candidates, then the `implementation_key` scoping separates them.
- AC-017-3: Given any `br` or `bv` call, when it runs, then the call uses the frozen `BEADS_DB` and never rediscovers `.beads` from the worktree.

### REQ-018: Should | Medium | Bundled manifests and operator documentation

Foreman MUST bundle one-phase `implement-trd.yaml` and `implement-trd-beads.yaml` manifests that pass `--foreman` and declare the worktree config. Foreman MUST update `docs/user-guide.md`, `docs/cli-reference.md`, and `CLAUDE.md` alongside the behavior change. Strict approval rendering MUST cover the `command` field and the worktree `base` field, persisting concrete rendered values in the snapshot.

- AC-018-1: Given a fresh install, when `foreman init --force` runs, then both manifests are installed and `Workflow.Catalog` reloads them.
- AC-018-2: Given the manifests are installed, when an approval is rendered, then `command` and `worktree.base` use concrete values and `branch`/`path` retain runtime placeholders until run/phase IDs exist.
- AC-018-3: Given `docs/user-guide.md`, when reviewed, then it documents task/workflow separation, tracked-TRD requirement, Foreman/skill ownership, unique branch/path behavior, same-TRD rejection, Beads scope/DB rules, clean-vs-dirty cleanup, and recovery.
- AC-018-4: Given `docs/cli-reference.md`, when reviewed, then it documents the new `--workflow-type` and `--trd-path` task flags and the absence of any direct worktree CLI command.
- AC-018-5: Given `CLAUDE.md`, when reviewed, then it documents the same operator expectations at the contributor level.


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
| REQ-013 | REQ-001, REQ-003, REQ-004, REQ-005 | Foreman owns create/clean; skills only verify |
| REQ-014 | REQ-013 | Frozen context precedes worktree create |
| REQ-015 | REQ-013, REQ-014 | Atomic admission uses the frozen key |
| REQ-016 | REQ-004, REQ-013, REQ-014 | Trusted cwd/env bound to durable worktree |
| REQ-017 | REQ-013, REQ-016 | Beads mode extends the trusted env |
| REQ-018 | REQ-013, REQ-014, REQ-016, REQ-017 | Bundled manifests and docs |

The original implementation cluster (REQ-001, REQ-003, REQ-004, REQ-005,
REQ-006, REQ-007, REQ-008, REQ-009) is now joined by the
Foreman-managed execution cluster (REQ-013..REQ-018). No circular
dependencies remain.

## 8. Acceptance Criteria Summary

| ID | Acceptance criterion |
|---|---|
| AC-1 | Given a workflow YAML declaring `worktree.enabled: true` on phase 1, when the run starts, then `RunExecutor` dispatches worktree create and the phase worker operates inside the new worktree directory, verified by worker cwd capture. |
| AC-2 | Given a worktree phase reaches terminal, when the next phase starts or the run ends, then cleanup runs and `git worktree list` no longer shows the entry. |
| AC-3 | Given a workflow without a worktree field, when the run starts, then it executes unchanged against the main checkout/current task working directory. |
| AC-4 | Given worktree creation fails, when dispatched, then lifecycle failure is recorded, the run is failed, and no orphan worktree remains. |
| AC-5 | Given cleanup fails, when dispatched, then telemetry/logs capture failure, run processing does not crash, and run-terminal cleanup retries. |
| AC-6 | Given two `run.start` admissions for the same normalized project/TRD, when both arrive, then exactly one succeeds and no worktree call occurs for the loser. |
| AC-7 | Given two distinct TRD paths in the same project, when both arrive, then both reservations coexist up to the configured project run limit. |
| AC-8 | Given a managed implementation phase, when the worker is invoked, then the environment map contains all six `FOREMAN_*` keys and (for Beads) `BEADS_DB`. The cwd is the worktree path and trusted env overrides phase context. |
| AC-9 | Given a managed Beads run, when the skill scaffolds and dispatches beads, then every `br`/`bv` call uses the frozen DB and every title is prefixed with `[trd:<TRD_SCOPE>]` where the scope includes the first 12 chars of `FOREMAN_IMPLEMENTATION_KEY`. |
| AC-10 | Given the bundled manifests, when `foreman init --force` runs, then both manifests are installed and `Workflow.Catalog` reloads them. |

## 9. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Worker cwd is only context-driven | High | Reuse Pi adapter's existing `context["working_directory"]` cwd contract and test via pwd capture. |
| Orphaned worktrees after failures | High | Durable `WorktreeCreated`/`WorktreeCleaned` events with typed metadata build an unresolved-worktree projection that survives BEAM restart. `BootReconciliation` re-reads unresolved worktrees and retries only safe clean removal. A dirty worktree is NEVER force-removed; it remains in the unresolved projection with operator guidance. |
| Existing workflows drift | High | Feature is opt-in only; add regression tests for no-worktree flows. |
| Unsafe shell argument handling | Medium | Use `System.cmd/3` argv lists, not string splitting, for new Git operations and touch shared helpers only as needed. |
| Parser cannot support deep YAML structures | Medium | Use one-level nested `worktree` map for v1; defer lists/deep schemas. |
| Bucket C leakage | Critical | No HTTP/CLI/MCP surface; inventory and policy doc reaffirm internal-only commands. |
| Concurrent path collision | High | Include project id, run id, and phase slug in default path. |
| Skill-owned worktree race | Critical | Foreman is the sole owner of the worktree; `--foreman` only switches skills into verified managed mode. |
| TRD not committed at approval | High | `ImplementationContext.build/1` requires a tracked blob at `source_revision:<relative_path>`; reject untracked/working-copy paths. |
| Skill rediscovers `.beads` | High | Managed mode passes the frozen `BEADS_DB` to every `br`/`bv` invocation; never cwd-scans. |
| Same-TRD concurrent runs | High | Atomic `implementation_key` reservation rejects same-key concurrent runs before any worktree side effect. |
| Two-repo rollout ordering | Medium | Land Ensemble `--foreman` support first; gate Foreman manifests on the minimum compatible Ensemble package version. |



## 10. Documentation Deliverables

- `docs/user-guide.md`: workflow author section with full phase worktree example, task/workflow separation, tracked-TRD requirement, Foreman/skill ownership, unique branch/path behavior, same-TRD rejection, Beads scope/DB rules, clean-vs-dirty cleanup, and recovery.
- `docs/cli-reference.md`: document the new `--workflow-type` and `--trd-path` task flags and reaffirm that no direct worktree CLI command exists.
- `docs/workflow-yaml-reference.md` if present/created in this repo: exact `worktree` schema and defaults, plus the reserved server-derived approval fields.
- `docs/architecture/ADR-2026-3d41f677-phase-worktrees.md` if maintainers choose to record the phase-level vs workflow-level decision as an ADR.
- `README.md`/`CLAUDE.md`: only if implementation changes operator/developer expectations beyond the workflow docs. v1.1.0 requires `CLAUDE.md` updates covering the same Foreman-managed execution contract.

## 11. Readiness

This PRD v1.1.0 is ready for TRD design. The TRD must formalize the
command inventory, the YAML schema, lifecycle hooks, the frozen
`ImplementationContext`, the atomic same-TRD exclusion, the
trusted cwd/env handoff, the Beads scoped DB pass-through, the bundled
manifests, and the migration safety before implementation starts.

## 12. Cross-Repository Rollout

Foreman and Ensemble ship together to make `--foreman` end-to-end.
The order is:

1. Release and install Ensemble `--foreman` support for both
   `implement-trd` and `implement-trd-beads`.
2. Land Foreman v1.1.0 with the bundled manifests gated on the
   minimum compatible Ensemble package version.
3. Run the parallel end-to-end smoke scenario described in the
   TRD verification section.

If atomic rollout is unavailable, land Ensemble first and gate
Foreman manifests on the minimum compatible Ensemble package
version recorded in the Foreman-aligned manifest metadata.

