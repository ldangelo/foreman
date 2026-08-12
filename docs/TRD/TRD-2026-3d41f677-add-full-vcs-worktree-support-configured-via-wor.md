---
document_id: TRD-2026-3d41f677
label: trd-add-full-vcs-worktree-support-configured-via-wor
prd: docs/PRD/PRD-2026-3d41f677-add-full-vcs-worktree-support-configured-via-wor.md
version: 1.1.0
status: Draft
date: 2026-08-12
design_readiness_score: 4.6
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

### Decision 2 — Cleanup durability: durable events, never force-remove dirty worktrees

Worktree lifecycle is recorded as durable domain events, not retry markers.
`RunExecutor` dispatches `WorktreeCreated` on create success and `WorktreeCleaned`
on clean success. The projection store maintains an unresolved-worktree map
built by replaying the event stream; it survives BEAM restart and powers
`BootReconciliation`. Boot reconciliation re-reads unresolved worktrees on
startup and retries only safe removal (clean tree, no uncommitted changes,
no active workers).

A dirty worktree is NEVER force-removed. Foreman's recovery model prefers
operator visibility: an unresolved dirty worktree stays in the projection
with operator guidance, surfaces via `foreman doctor`, and requires
`foreman worktree recover --worktree-id <id> --keep | --discard` after the
operator inspects the working copy.

Default `cleanup` value is `always`. Supported v1 values:

- `always` — default; emit `WorktreeCleaned` after every worktree phase
  terminal state. On clean failure the worktree stays in the unresolved
  projection.
- `never` — allowed only for debug workflows if explicitly accepted by
  validation/config; not recommended and must be documented as leaving
  worktrees behind.

Rejected for v1: `on_run_terminal`. It implies a workflow-level worktree
retention model and cross-phase sharing semantics.


### Decision 3 — Base ref: frozen `source_revision = git rev-parse HEAD`

The worktree base ref MUST equal the frozen `source_revision` recorded by
`ForemanServer.Workflow.ImplementationContext.build/1` at approval.
`ImplementationContext` runs `git rev-parse HEAD` against the project root
once at approval and persists the resolved SHA in the approval snapshot.

Resolution order at worktree creation time:

1. Reject if `phase.worktree.base` is set and does NOT equal the recorded
   `source_revision`.
2. Use the recorded `source_revision` as the base ref.
3. There is no fallback to project default branch or live `HEAD` at create
   time. Re-resolving `HEAD` at create time would silently shift the base
   ref between approval and execution and is rejected.

Pinned SHAs, branch names, and tags are accepted as `phase.worktree.base`
values so long as they resolve to the recorded revision. `git worktree add
<path> <sha>` is valid; the schema calls the field `base` rather than
`base_branch` to allow branch names, tags, and SHAs.

The worktree branch name is resolved from `phase.worktree.branch` or
default `foreman/{run_id}/{phase}`. Template variables are expanded from
run/project/phase context.

### Decision 4 — Failure semantics: fail closed, side-effect-then-event durability

If worktree creation fails, the phase fails and the run fails. Foreman must
not fall back to the main checkout.

Ordering rule for the create pipeline: `git worktree add` MUST succeed
before `WorktreeCreated` is appended to the event stream. If the event
append fails after `git worktree add` succeeds, `RunExecutor` branches
on the worktree state observed at decision time:

- CLEAN worktree: `RunExecutor` calls `git worktree remove` (no
  `--force`) as compensation. The compensation is itself side-effect
  followed by a projection record: on success `create_compensated`
  telemetry is emitted; on failure
  (`create_compensation_failed`) `RunExecutor` falls through to the
  DIRTY branch below because the worktree is now in an unknown state.
  A TOCTOU race is possible: if the worktree becomes dirty between
  the CLEAN check and the remove, git refuses to remove without
  `--force` and the compensation is reported as failed. The phase is
  reported failed with the original dispatch error attached in all
  cases. No `WorktreeCreated` event is fabricated.
- DIRTY worktree, OR compensation just failed: `RunExecutor` does NOT
  remove the worktree. It dispatches
  `vcs.worktree.create.orphan_record` through `CommandRouter` to
  append `WorktreeCreateOrphanRecorded`, which is the durable view of
  the orphan. The unresolved-worktree projection (keyed by
  `WorktreeCreated`) MUST NOT be claimed as a fallback for this case;
  the orphan-record projection is the source of truth. If the
  orphan-record dispatch itself fails, `create_orphan_unrecorded`
  telemetry carries the path and correlation IDs, and the case
  degrades to operator-only visibility.

Reason: fallback to the main checkout would violate isolation
expectations and could mutate the controller checkout. Fabricating
`WorktreeCreated` would cause BootReconciliation to attempt cleanup on
a worktree the projection never actually owned.

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

### Decision 6 — Frozen implementation context at approval

At approval time, `ForemanServer.Workflow.ImplementationContext.build/1`
captures and freezes a context struct that downstream phases MUST consume
verbatim:

```elixir
@type t :: %__MODULE__{
  project_id: String.t(),
  project_root: String.t(),        # absolute project root, frozen
  trd_path: String.t(),            # normalized project-relative POSIX path
  trd_path_argument: String.t(),   # JSON-encoded string, safe to embed in argv
  source_revision: String.t(),     # git rev-parse HEAD at approval
  implementation_key: String.t(),  # SHA256(project_id <> "\0" <> normalized_trd_path)
  beads_database_path: String.t() | nil,
  frozen_at: DateTime.t()
}
```

Resolution rules:

1. `project_id` is the operator-registered project identifier.
2. `project_root` is the absolute filesystem path to the project root,
   resolved once at approval and recorded verbatim.
3. `trd_path` MUST be a tracked blob at `source_revision:<relative_path>`.
   Untracked, working-copy, or `..`-escaping paths are rejected with
   `{:error, {:untracked_trd, path}}` / `{:error, {:path_traversal, path}}`.
4. `trd_path_argument` is `Jason.encode!(trd_path)` so it can be passed to
   `System.cmd/3` as a single argv element without interpolation risk.
5. `source_revision` is the SHA returned by `git rev-parse HEAD` run
   against `project_root` exactly once at approval.
6. `implementation_key = SHA256(project_id <> "\0" <> normalized_trd_path)`.
7. For `implement-trd-beads`, `beads_database_path` is the absolute
   `task_provider.config.database_path` resolved at approval.

Re-approval reuses the persisted snapshot. The implementation context is
NEVER re-resolved at run start; otherwise the operator could accidentally
shift the base between approval and execution.

### Decision 7 — Atomic same-TRD exclusion via `implementation_key`

`ForemanServer.Aggregates.Project.handle_command/2` rejects same-key
concurrent run reservations before any worktree side effect.

Reservation lifecycle:

- `ProjectRunReserved` event carries `:implementation_key`.
- `Project.State.active_run_reservations` is keyed by `implementation_key`.
- `project.reserve_run` rejects with
  `{:implementation_already_active, key, run_id}` when the key is already
  reserved by a non-terminal run.
- `ProjectRunReleased` releases the reservation on terminal run (success,
  failure, blocked) and on `RunRejected`.

Two reservations with distinct TRDs MAY run concurrently. The atomicity
is per `(project, normalized_trd_path)`, not per project.

### Decision 8 — Isolation IDs: deterministic `wt-<run_id>-<phase_id>`

Every worktree event carries the full correlation tuple. The fields are
`@enforce_keys` on the typed event structs.

| Event | Correlation fields |
|---|---|
| `WorktreeCreated` | `operation_id`, `project_id`, `run_id`, `phase_id` |
| `WorktreeCleaned` | `operation_id`, `project_id`, `run_id`, `phase_id` |
| `WorktreeCreateOrphanRecorded` | `operation_id`, `project_id`, `run_id`, `phase_id`, `worktree_path` |
| `VcsOperationStarted` / `Completed` / `Failed` | `operation_id`, `project_id`, `run_id`, `phase_id` |

`operation_id = "wt-" <> run_id <> "-" <> phase_id`. The id is
deterministic and derived from the immutable run/phase identifiers; it is
NOT a fresh UUID per attempt. This guarantees replay determinism:
re-attempting a worktree create on a reloaded actor re-emits the same
`operation_id` and finds the same projection slot.

### Decision 9 — Trusted cwd and environment handoff

When a managed phase launches, `AgentRuntime` reads the frozen
implementation context and sets:

- `cwd`: the absolute path to the worktree on disk (NOT the controller
  working directory). The Pi adapter's existing
  `context["working_directory"]` contract is reused and tested via pwd
  capture.
- `environment`: an explicit map injected via `Port.open` for managed
  phases. The map includes only the trusted keys:

  | Variable | Value |
  |---|---|
  | `FOREMAN_WORKTREE` | `"1"` — managed-mode sentinel for the skill |
  | `FOREMAN_RUN_ID` | run id |
  | `FOREMAN_WORKTREE_PATH` | absolute path to the worktree |
  | `FOREMAN_EXPECTED_BRANCH` | `foreman/{run_id}/{phase_slug}` |
  | `FOREMAN_SOURCE_REVISION` | frozen SHA |
  | `FOREMAN_IMPLEMENTATION_KEY` | SHA256 hex |
  | `BEADS_DB` | absolute path (only in Beads workflow) |

  Telemetry metadata MUST scrub paths to the worktree's basename
  (`Path.basename/1`) to match the task-provider convention.

The skill verifies the cwd and the expected branch markers and aborts
with a fail-closed error if any marker is missing. Skills MUST NOT
create, switch, append, or stack branches; branch management is owned by
Foreman.

### Decision 10 — Beads workflow pass-through is scoped and DB-frozen

For `implement-trd-beads` only:

- The frozen `BEADS_DB` path is exported as `BEADS_DB` env to the skill.
- Every `br` and `bv` invocation uses `BEADS_DB` as `--db`; the skill
  refuses to run without it.
- `TRD_SCOPE = "<trd-slug>-<first-12-of-implementation_key>"` is exported
  to the skill. Bead titles are prefixed `[trd:<TRD_SCOPE>]`.
- The skill never scans the cwd for `.beads/`. Discovery is fully
  encoded in the frozen DB path.
- The frozen `task_provider.config.database_path` is resolved at
  approval and MUST equal the `BEADS_DB` at run start. Drift is rejected
  with `{:beads_database_drift, expected, actual}`.
### Decision 11 — Bundled manifests and operator documentation

Foreman bundles two workflow manifests in
`packages/foreman_server/priv/defaults/workflows/`:

- `implement-trd.yaml`
- `implement-trd-beads.yaml`

Both manifests declare the worktree schema, register with
`ForemanServer.WorkflowTemplate.Installer` (`@template_names`), and are
deployed by `foreman init --force`. Strict approval rendering MUST
materialize the `command` field and the `worktree.base` field so the
human review surfaces the exact Git command and base ref that Foreman
will execute; branch and path placeholders remain runtime-resolved.

Operator documentation lives in `docs/user-guide.md` (workflow author
section), `docs/cli-reference.md` (`--workflow-type`, `--trd-path`
flags), and `CLAUDE.md` (Foreman-managed worktree contract).

## Command Inventory and Bucket Classification


| Command type | Event | Stream | Bucket | Rationale |
|---|---|---|---|---|
| `vcs.worktree.create` | `WorktreeCreated` | `vcs:<operation_id>` | C | Internal runtime declares worktree state; external callers could fake phase cwd setup. |
| `vcs.worktree.create.orphan_record` | `WorktreeCreateOrphanRecorded` | `vcs:<operation_id>` | C | Append-only durable record of a worktree whose create command's dispatch failed AFTER the Git side effect succeeded. Distinct from `WorktreeCreated` so the orphan-record projection is independent. |
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
| `base` | non-empty string | yes | recorded `source_revision` from `ImplementationContext` | The override MUST equal the frozen source revision; rejected otherwise. Branch, tag, or SHA accepted so long as it resolves to the recorded revision. |
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

The adapter takes its inputs from the frozen `ImplementationContext` —
there are no default fallbacks for `operation_id` or `base`:

```elixir
def create_worktree(repo_path, worktree_path, opts) do
  operation_id = Keyword.fetch!(opts, :operation_id)
  base = Keyword.fetch!(opts, :base)            # pinned source_revision
  branch = Keyword.fetch!(opts, :branch)        # nil allowed for detached
  project_id = Keyword.fetch!(opts, :project_id)
  run_id = Keyword.fetch!(opts, :run_id)
  phase_id = Keyword.fetch!(opts, :phase_id)
  target = "#{repo_path}:#{worktree_path}:#{base}"

  emit_started(operation_id, "worktree_create", target,
    %{project_id: project_id, run_id: run_id, phase_id: phase_id})

  args = ["-C", repo_path, "worktree", "add"] ++ branch_args(branch) ++ [worktree_path, base]

  case System.cmd("git", args, stderr_to_stdout: true) do
    {output, 0} ->
      result = %{path: worktree_path, base: base, branch: branch, output: output}
      emit_completed(operation_id, "worktree_create", target, result,
        %{project_id: project_id, run_id: run_id, phase_id: phase_id})
      {:ok, result}

    {output, code} ->
      reason = {:git_worktree_create_failed, code, output}
      emit_failed(operation_id, "worktree_create", target, reason, 0,
        %{project_id: project_id, run_id: run_id, phase_id: phase_id})
      {:error, reason}
  end
end
```

Branch args:

- If `branch` is nil: `[]` (detached worktree).
- If set: `["-b", branch]`.

Add cleanup. Cleanup MUST NOT use `--force`. A dirty worktree is removed
by the operator after inspection — never by the adapter:

```elixir
def clean_worktree(worktree_path, opts) do
  operation_id = Keyword.fetch!(opts, :operation_id)
  repo_path = Keyword.fetch!(opts, :repo_path)
  project_id = Keyword.fetch!(opts, :project_id)
  run_id = Keyword.fetch!(opts, :run_id)
  phase_id = Keyword.fetch!(opts, :phase_id)
  target = "#{repo_path}:#{worktree_path}"

  emit_started(operation_id, "worktree_clean", target,
    %{project_id: project_id, run_id: run_id, phase_id: phase_id})

  cond do
    not File.exists?(worktree_path) ->
      result = %{path: worktree_path, cleaned?: true, noop?: true}
      emit_completed(operation_id, "worktree_clean", target, result,
        %{project_id: project_id, run_id: run_id, phase_id: phase_id})
      {:ok, result}

    true ->
      case System.cmd("git", ["-C", repo_path, "worktree", "remove", worktree_path], stderr_to_stdout: true) do
        {output, 0} ->
          System.cmd("git", ["-C", repo_path, "worktree", "prune"], stderr_to_stdout: true)
          result = %{path: worktree_path, cleaned?: true, noop?: false, output: output}
          emit_completed(operation_id, "worktree_clean", target, result,
            %{project_id: project_id, run_id: run_id, phase_id: phase_id})
          {:ok, result}

        {output, code} ->
          reason = {:git_worktree_clean_failed, code, output}
          emit_failed(operation_id, "worktree_clean", target, reason, 0,
            %{project_id: project_id, run_id: run_id, phase_id: phase_id})
          {:error, reason}
      end
  end
end
```

Implementation notes:

- Use argv lists only; do not build a command string and split it.
- Capture stderr via `stderr_to_stdout: true`.
- `operation_id`, `base`, `repo_path`, `project_id`, `run_id`, `phase_id`
  are required and fetched via `Keyword.fetch!/2`. There are no defaults.
- Telemetry metadata MUST scrub `repo_path` and `worktree_path` to
  `Path.basename/1` to match the task-provider convention.
- On clean failure (`{:error, _}`) the adapter emits
  `[:foreman_server, :vcs, :worktree, :clean_failed]` and returns the
  error. `RunExecutor` records the failure and leaves the worktree in
  the unresolved projection; the adapter never force-removes.
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
2. Resolve repo path from the frozen `ImplementationContext.project_root`
   (NOT the task working directory).
3. Resolve the worktree path under
   `~/.foreman/worktrees/<project_id>/<run_id>/<phase_slug>` from the
   frozen context.
4. Use the frozen `source_revision` as `base`. Reject
   `phase.worktree.base` if it does not equal the recorded revision.
5. Compute `operation_id = "wt-" <> run_id <> "-" <> phase_id`. Pass it
   through `opts`; `VcsAdapter.Default` does NOT default this field.
6. Call `VcsAdapter.Default.create_worktree(repo_path, worktree_path,
   opts)`. The adapter runs `git worktree add` and emits
   `vcs_operation.start|complete|fail` adapter lifecycle telemetry.
7. On adapter success, `RunExecutor` dispatches `vcs.worktree.create`
   through `CommandRouter.dispatch_system/1`. The aggregate emits
   `WorktreeCreated` only after the command is appended. On adapter
   failure, `RunExecutor` does NOT dispatch and NO `WorktreeCreated`
   event is appended.
8. Return `%{working_directory: worktree_path, worktree_path:
   worktree_path, operation_id: operation_id, implementation_key:
   context.implementation_key}`.
7b. If the `vcs.worktree.create` dispatch through `CommandRouter` fails
    AFTER `git worktree add` succeeded, branch on the worktree state
    observed at decision time (see Decision 4 for the full contract):
    - CLEAN worktree: `RunExecutor` removes only the just-created
      worktree (no `--force`). On success `create_compensated` is
      emitted; on failure (filesystem state changed, git error, or
      TOCTOU race) `create_compensation_failed` is emitted and the
      branch falls through to the DIRTY path. The phase is reported
      failed with the original dispatch error attached. NO
      `WorktreeCreated` event is appended.
    - DIRTY worktree, OR compensation just failed: `RunExecutor` does
      NOT remove the worktree. It dispatches
      `vcs.worktree.create.orphan_record` through `CommandRouter` to
      append `WorktreeCreateOrphanRecorded`, which is the durable view
      of the orphan. The unresolved-worktree projection (keyed by
      `WorktreeCreated`) MUST NOT be claimed as a fallback for this
      case; the orphan-record projection is the source of truth. If
      the orphan-record dispatch itself fails, `create_orphan_unrecorded`
      telemetry carries the path and correlation IDs, and the case
      degrades to operator-only visibility.

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

`cleanup_after_phase_terminal/3` enforces side-effect→event ordering
that mirrors the create pipeline:

1. If no worktree context or `cleanup: never`, no-op.
2. Call `VcsAdapter.Default.clean_worktree(worktree_path, opts)` where
   `opts = [operation_id: ..., repo_path: ..., project_id: ...,
   run_id: ..., phase_id: ...]`. `operation_id` is deterministic
   (`wt-<run_id>-<phase_id>`) and equal to the create `operation_id`,
   so `WorktreeCleaned` is keyed by the same id and the projection is
   symmetric.
3. `VcsAdapter.Default` runs `git worktree remove` (no `--force`) and
   returns `{:ok, ...}` only when the shell command exits zero. The
   adapter does NOT append domain events; per the project architecture,
   `CommandRouter` is the sole domain-event append point.
4. On adapter success, `RunExecutor` dispatches `vcs.worktree.clean`
   through `CommandRouter.dispatch_system/1`. The aggregate emits
   `WorktreeCleaned` only after the command is appended. On adapter
   failure, `RunExecutor` does NOT dispatch and NO `WorktreeCleaned`
   event is appended.
5. Emit `[:foreman_server, :vcs, :worktree, :clean]` on success or
   `[:foreman_server, :vcs, :worktree, :clean_failed]` on failure. The
   failure telemetry and the absent `WorktreeCleaned` together keep the
   worktree in the unresolved-worktree projection.
6. `RunExecutor` does NOT retry cleanup inline. The unresolved worktree
   is resolved only by `BootReconciliation` after operator visibility.

`BootReconciliation` runs at supervisor boot. It re-reads the
unresolved-worktree projection and for every entry whose run is
terminal, attempts `clean_worktree` again. The attempt only proceeds
when the worktree is clean (no uncommitted changes, no active workers).
A worktree that remains dirty across a boot reconciliation cycle is
left in the projection with generic operator guidance surfaced via
telemetry metadata.

### 6. Telemetry

Emit these events:

| Event | When | Measurements | Metadata |
|---|---|---|---|
| `[:foreman_server, :vcs, :worktree, :create]` | create success | `%{duration_ms: non_neg_integer}` | `run_id`, `phase_id`, `operation_id`, `repo_path`, `worktree_path`, `base`, `branch` |
| `[:foreman_server, :vcs, :worktree, :clean]` | clean success | `%{duration_ms: non_neg_integer}` | `run_id`, `phase_id`, `operation_id`, `worktree_path`, `noop?` |
| `[:foreman_server, :vcs, :worktree, :create_failed]` | create failure | `%{duration_ms: non_neg_integer}` | success metadata plus classified reason |
| `[:foreman_server, :vcs, :worktree, :clean_failed]` | clean failure | `%{duration_ms: non_neg_integer}` | success metadata plus classified reason |
| `[:foreman_server, :vcs, :worktree, :create_compensated]` | compensation success | `%{duration_ms: non_neg_integer}` | success metadata |
| `[:foreman_server, :vcs, :worktree, :create_compensation_failed]` | compensation failure (e.g. TOCTOU dirtied worktree) | `%{duration_ms: non_neg_integer}` | success metadata plus classified reason |
| `[:foreman_server, :vcs, :worktree, :create_orphan_unrecorded]` | fallback when even orphan-record dispatch fails | `%{}` | `run_id`, `phase_id`, `operation_id`, `worktree_path` |

Avoid including full command output in telemetry metadata; event payload can carry output for event store if existing conventions permit, but telemetry/logs should use summarized reason.

## Acceptance Criteria Mapping

| PRD AC | Design element | Verification |
|---|---|---|
| AC-1 | Phase `worktree` schema + `RunExecutor.maybe_create_worktree` + cwd override | Integration test captures pwd from worker/adapter in worktree. |
| AC-2 | Phase-terminal cleanup + `clean_worktree/2` | Integration test checks `git worktree list` no longer includes path. |
| AC-3 | No-op behavior when `worktree` absent | Existing workflow regression test asserts no VCS calls and unchanged cwd. |
| AC-4 | Fail-closed create semantics + append-failure compensation | Adapter stub/temp repo failure test asserts phase/run failed and cleanup attempted. A separate dispatch-failure test asserts: when `git worktree add` succeeds but `vcs.worktree.create` dispatch through `CommandRouter` fails, `RunExecutor` removes only the just-created CLEAN worktree (no `--force`), emits `create_compensated`, no `WorktreeCreated` is appended, and the phase fails with the original dispatch error. A second test asserts the compensation-failure case: when the compensation `git worktree remove` fails (for example, TOCTOU race that dirtied the worktree), `create_compensation_failed` is emitted and the orphan-record path takes over. A dirty worktree is left in place and emits `WorktreeCreateOrphanRecorded` via the orphan-record projection; if even that dispatch fails, the case degrades to `create_orphan_unrecorded` telemetry. |
| AC-5 | Durable unresolved-projection contract | Stub failure test asserts clean_failed telemetry is emitted, NO `WorktreeCleaned` is appended, and the projection still records the worktree as unresolved. `BootReconciliation` test verifies a clean second attempt at boot removes the entry. |

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

4. `cleanup failure leaves unresolved-projection entry and emits clean_failed`
   - Stub cleaner to fail; assert `clean_failed` telemetry and the
     `WorktreeCreated` entry remains in the unresolved-worktree
     projection. `RunExecutor` does NOT retry inline.
4b. `boot reconciliation removes a clean unresolved worktree`
   - Stub cleaner to fail first then succeed; restart the supervisor;
     assert the unresolved-projection entry is resolved and
     `WorktreeCleaned` is appended exactly once.
4c. `append-failure compensation removes only the just-created CLEAN worktree`
   - Stub `git worktree add` to succeed and `CommandRouter.dispatch`
     to fail; assert `create_compensated` telemetry, the worktree
     directory absent, NO `WorktreeCreated` appended, and the phase
     fails with the original dispatch error attached.
4d. `append-failure records the orphan via WorktreeCreateOrphanRecorded
    when the worktree is dirty (and surfaces it durably)`
   - Stub the worktree path to start dirty (added uncommitted file).
   - Stub `CommandRouter.dispatch` so the first `vcs.worktree.create`
     fails.
   - RunExecutor dispatches `vcs.worktree.create.orphan_record` (a
     dedicated command whose only effect is to append
     `WorktreeCreateOrphanRecorded`); the projection captures the
     orphan path keyed by `operation_id`.
   - If that orphan-record dispatch also fails, the failure is
     emitted via `[:foreman_server, :vcs, :worktree,
     :create_orphan_unrecorded]` telemetry with the worktree path
     and correlation IDs; the case degrades to operator-only
     visibility. The unresolved-worktree projection MUST NOT be
     claimed as a fallback for this path.
   - `BootReconciliation` scans the orphan-record projection and
     attempts a clean (no `--force`) removal only when the worktree
     is clean, mirroring the same dirty-skip rule as the rest of
     reconciliation.
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
