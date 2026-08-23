---
document_id: TRD-2026-branch-parent-resolution
label: trd-branch-parent-resolution
version: 0.1.0
status: Draft
date: 2026-08-22
design_readiness_score: 4.0
kind: trd
---

# TRD: Branch Parent Resolution for Foreman Tasks

## Document Purpose

This document defines the technical design and implementation plan to fix
three coupled gaps in how Foreman resolves the parent branch for new work:

1. The PR base defaults to `main` even when the worktree was branched from
   the operator's current checkout (which may be a feature branch like
   `slices/jido-migration`).
2. There is no operator-facing way to pin a task to a specific parent
   branch. The CLI's `foreman run submit` accepts no branch argument, and
   the `work.submit` envelope carries no `base_branch` field.
3. Multi-phase workflows (e.g. `prd.yaml`) have each phase branch from
   the operator's `HEAD` rather than from the prior phase's branch tip,
   so phase N+1 cannot see the commits made by phase N unless those
   commits have been merged into the operator's checkout.

The first two were exposed by PR #412 (a `fix` workflow against
`slices/jido-migration`). The branch was correctly forked from
`slices/jido-migration` (merge-base = `3cfd0163`), but the PR was opened
against `main` because `plan_base_branch/1` in
`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:825`
falls back to the literal string `"main"` when
`plan_context["base_branch"]` is unset.

The third was exposed by an audit of `RunExecutor.create_default_worktree/3`
at `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:1159`:
each phase's `base_ref` is resolved from `HEAD` of the operator checkout
(line 1163: `resolve_revision(project_root, "HEAD")`), so the 5 phases of
`prd.yaml` produce 5 independent branches all rooted at the operator's
checkout tip.

## Reused Capabilities

| Existing facility | Reuse |
|---|---|
| `ForemanServer.Workflow.PlanContext.build/1` | Extension point — gain a `base_branch` derivation step that resolves from the work payload first, then the operator's registered checkout, then falls back to a per-project default (NOT the literal `"main"`). |
| `ForemanServer.Aggregates.Run` `run.pr.update` field map (run.ex:518) | Already accepts `:base_branch` as a known field; no schema change required. |
| `ForemanServer.Workflow.RunExecutor.plan_base_branch/1` (run_executor.ex:825) | Single edit: stop defaulting to `"main"` and read from the resolved `plan_context["base_branch"]`. |
| `ForemanServer.Workflow.RunExecutor.create_default_worktree/3` (run_executor.ex:1159-1180) | Extend so phase N+1 (N >= 1) uses the prior phase's branch tip when no explicit `worktree.base` block is declared. |
| `ForemanServer.Workflow.AutoPR` (auto_pr.ex:100) | Already takes `base_branch` as a parameter; no edit needed — only its caller passes the wrong default. |
| `foreman run submit` CLI (packages/foreman_cli/cmd/foreman/run.go:82-134) | Add a `--base-branch` flag. |
| `foreman_work_submit` MCP tool (packages/foreman_server/lib/foreman_server/mcp/tools.ex:106-124, 414-455) | Add `base_branch` to the schema and forward it into the `work.submit` payload. |

No external services or new dependencies. The change is surgical: thread
one field (`base_branch`) through three layers (CLI → server payload →
plan_context) and adjust two default-resolution helpers.

## Architecture Decision

### Selected: Resolve base_branch end-to-end from the operator's checkout, with explicit override

Treat the operator's current branch as the default parent branch for every
new task, expose it as an optional override at task-creation time, and
chain phase branches inside multi-phase workflows. Do NOT change the
worktree isolation contract — every phase still gets its own worktree on
its own branch. Only the `base_ref` of each phase changes when the prior
phase's branch is the appropriate parent.

#### Concrete rules

1. **Operator's current branch is the default.** When `work.submit` does not
   include `base_branch`, the server resolves it from the project
   registration's `path` (the registered checkout) using `git -C <path>
   rev-parse --abbrev-ref HEAD`. The result is stamped on `plan_context`
   as `"base_branch"`.

2. **Explicit override wins.** When the CLI passes `--base-branch
   slices/jido-migration`, that exact value is forwarded through
   `work.submit` → `plan_context["base_branch"]` and used verbatim.

3. **Per-phase chain.** For a multi-phase workflow, phase 1's `base_ref` is
   `plan_context["source_revision"]` (frozen at approval time, current
   behavior). Phase N (N >= 2) defaults to the branch created by phase N-1
   when phase N's manifest does not declare an explicit `worktree.base`.
   When phase N's manifest does declare `worktree.base`, the existing
   `assert_base_matches/3` check (run_executor.ex:1314) still applies.

4. **Default cleanup remains `:always`.** This TRD does not change
   cleanup policy. A separate decision is required for cleanup; for now,
   each phase's branch is dropped after the phase. If the parent chain
   needs the prior branch alive at phase N+1 start time, phase N+1's
   worktree provider must preserve it. The simplest implementation: do
   NOT drop the phase-N branch in phase-N cleanup if the next phase is
   going to base on it. This is a follow-on; this TRD does NOT resolve
   it. Phase N+1's worktree creation will detect missing branches and
   fall back to `plan_context["source_revision"]` — losing the chain but
   not breaking the build.

### Alternatives Considered

#### Option A — Add `--branch` to CLI only, leave default as `main`

Smallest patch. Touches only the CLI and the `work.submit` payload schema.
Server-side default resolution stays `"main"`.

- **Pros:** ~20 lines of code; no plan_context edits; one PR.
- **Cons:** does not fix the actual bug (operators on feature branches
  still get PRs targeting `main`); does not address multi-phase chaining.
- **Risk:** rejected because it doesn't fix the demonstrated PR #412
  symptom unless the operator remembers to pass `--branch` every time.

#### Option B — Resolve from the operator's checkout unconditionally, no override

Same as selected, minus the explicit `--base-branch` flag. Server reads
the project's checkout branch every time.

- **Pros:** no CLI flag to maintain; one less user knob.
- **Cons:** breaks when the operator wants to pin to a different branch
  from their current checkout (e.g. opening a follow-up PR against
  `main` from a long-running feature branch). This is a legitimate
  workflow.
- **Risk:** rejected because it removes operator control without need.

#### Option C — Resolve from a per-project default, set at project registration

Add `default_base_branch` to `ForemanServer.Aggregates.Project`. Operators
configure it once at project setup; the server reads it as the default.

- **Pros:** explicit; auditable; survives checkout state changes.
- **Cons:** one more config knob; doesn't help when the operator wants
  to vary it per task; doesn't help when there's no project registration
  (work-request path).
- **Risk:** orthogonal to this TRD. Could be added later as a
  higher-priority default in the resolution chain.

#### Option D — Selected. Operator's current branch as default, with explicit override.

## System Architecture

### Field Flow

```
operator shell
  └─> foreman run submit --workflow prd --base-branch slices/jido-migration --prompt "..."
       (CLI builds payload)
       └─> HTTP POST /api/commands  envelope={type:"work.submit", payload:{..., base_branch:"slices/jido-migration"}}
            (server dispatcher routes)
            └─> handle_work_submitted/2  → PlanContext.build(task_projection)
                                          + merge base_branch from payload
                                          + fall back to registered checkout HEAD
                                          + (optional: per-project default)
            └─> plan_context["base_branch"] = "slices/jido-migration"
                 ├─> RunExecutor.plan_base_branch/1 (run_executor.ex:825)  → used by AutoPR
                 ├─> RunExecutor.create_phase_worktree/4 (run_executor.ex:1096)  → used as base when no explicit worktree.base
                 └─> RunExecutor.create_default_worktree/3 (run_executor.ex:1159) → fallback base_ref for non-plan workflows
```

### Touched Files

| File | Change |
|---|---|
| `packages/foreman_cli/cmd/foreman/run.go` | Add `--base-branch <name>` flag to `runSubmit`. Pass through to envelope payload. |
| `packages/foreman_server/lib/foreman_server/mcp/tools.ex` (lines 106-124, 414-455) | Add `base_branch` to `foreman_work_submit` input schema. Forward in payload to `work.submit` envelope. |
| `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex` (`handle_work_submitted/2`, line 469) | When payload includes `base_branch`, stamp it onto the task projection / plan_context seed. |
| `packages/foreman_server/lib/foreman_server/workflow/plan_context.ex` | Add a `base_branch` derivation step: payload → registered-checkout HEAD → project default. |
| `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (`plan_base_branch/1`, line 825) | Replace the literal `"main"` fallback with `nil`; callers handle `nil` (no PR) or the new default-resolution path. |
| `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (`create_default_worktree/3`, line 1159) | Add a `phase_index > 0` branch that resolves `base_ref` from the prior phase's branch tip (read from `ProjectionStore.worktree/1` keyed by `(run_id, prior_phase_id)`). |
| `docs/cli-reference.md` | Document `foreman run submit --base-branch`. |
| `docs/user-guide.md` | Document the "current branch is the default parent" rule. |
| New tests | `foreman run submit` flag parsing, payload propagation, server-side plan_context resolution, multi-phase base chain. |

### Data Model

No new aggregates or events. The change is to **resolution logic** for an
existing field, not new schema.

`ForemanServer.Aggregates.Run` already supports `:base_branch` as a
field of `run.pr.update` and `run.pr.ready` (run.ex:518-519), so no
schema migration is needed.

`plan_context` gains one key:

```elixir
%{
  "base_branch" => "slices/jido-migration" | nil,  # resolved base for PR + worktree.base
  # ... existing fields ...
}
```

`nil` means "do not auto-create a PR"; the explicit fallback chain is:

1. Payload `base_branch` (explicit CLI flag).
2. Registered checkout HEAD (operator's current branch).
3. Per-project `default_base_branch` configuration (future; not in v1).
4. `nil` — no PR auto-created.

### Failure Modes

| Symptom | Cause | Mitigation |
|---|---|---|
| `git rev-parse --abbrev-ref HEAD` fails (detached HEAD, no git) | operator checkout not on a branch | resolve to `nil`; log a warning; no PR auto-created |
| Payload `base_branch` references a non-existent ref | operator typo | reject at submission with `{:error, {:invalid_base_branch, ref, reason}}` |
| Prior phase's branch does not exist at phase N+1 start | cleanup deleted it before phase N+1 started | phase N+1 falls back to `plan_context["source_revision"]`; chain broken but build proceeds; emit telemetry event `[:foreman_server, :workflow, :phase_chain_fallback]` |
| Per-project default branch not configured | work-request path with no project default | resolve to `nil`; no PR auto-created |

### Backwards Compatibility

- Existing `work.submit` callers that don't pass `base_branch` will see a
  *different* PR base than before (operator's checkout HEAD instead of
  literal `"main"`). For operators whose checkout is already on `main`,
  this is a no-op. For operators on feature branches, this is the bug
  fix.
- AutoPR callers that pass an explicit `--base` flag continue to work
  unchanged because `plan_base_branch/1` reads from `plan_context`, not
  from the AutoPR call site.
- Multi-phase workflows where phase N's branch is dropped before phase
  N+1 starts: phase N+1 falls back to `plan_context["source_revision"]`.
  The chain is broken, but the build does not fail.

## Master Task List

### PR 1: Single-task branch resolution (server-side default + CLI flag)

**Shippable State:** PRs from a `fix` workflow on a feature branch target
the feature branch instead of `main`. Operators can pin to a different
branch via `--base-branch`.

#### TRD-BPR-001 — Server: plan_context derives `base_branch` from registered checkout HEAD (3h)

Edit `ForemanServer.Workflow.PlanContext.build/1` to add a derivation
step. When `task.payload.base_branch` is absent, call
`ForemanServer.ProjectRegistration.head_branch/1` (or inline equivalent)
to resolve from the project's registered checkout path. Return `nil`
when the path is not a git repo or the checkout is detached.

Validates ACs: AC-BPR-001, AC-BPR-002.

Implementation AC:

- Given a task projection whose payload has no `base_branch`, when
  `PlanContext.build/1` runs, then `plan_context["base_branch"]` equals
  the registered checkout's current branch name (or `nil` when not
  resolvable).
- Given a task projection whose payload has `base_branch: "feat/x"`, when
  `PlanContext.build/1` runs, then `plan_context["base_branch"]` equals
  `"feat/x"` — payload wins over checkout.

#### TRD-BPR-001-TEST — Test plan_context base_branch derivation (2h)

Unit tests covering: payload wins, checkout fallback, detached HEAD,
non-git path, missing project registration.

Validates ACs: AC-BPR-001, AC-BPR-002.

#### TRD-BPR-002 — Server: plan_base_branch drops the literal `"main"` fallback (1h)

Replace the `else "main"` branch at `run_executor.ex:828` with `nil`.
Update AutoPR caller to treat `nil` as "skip auto-PR" instead of
defaulting to `main`.

Validates ACs: AC-BPR-003.

Implementation AC:

- Given `plan_context["base_branch"]` is `nil`, when the run finalizes,
  then `AutoPR.maybe_create_pr/4` is called with `base_branch=nil` and
  returns `:noop` (no PR auto-created).

#### TRD-BPR-002-TEST — Test plan_base_branch and AutoPR skip-when-nil (1h)

Validates ACs: AC-BPR-003.

#### TRD-BPR-003 — MCP: foreman_work_submit accepts base_branch (1h)

Add `base_branch` to `@schema_foreman_work_submit` inputSchema as an
optional string. Forward it from `params` into the `work.submit`
envelope payload at `tools.ex:414-455`.

Validates ACs: AC-BPR-004.

Implementation AC:

- Given `foreman_work_submit` is called with `base_branch: "feat/x"`,
  when the handler builds the envelope, then
  `envelope.payload.base_branch == "feat/x"`.
- Given `foreman_work_submit` is called without `base_branch`, when the
  handler builds the envelope, then `envelope.payload` does NOT include
  `base_branch` (key absent, not `nil`).

#### TRD-BPR-003-TEST — Test foreman_work_submit base_branch passthrough (1h)

Validates ACs: AC-BPR-004.

#### TRD-BPR-004 — CLI: foreman run submit --base-branch flag (1h)

Add `--base-branch <name>` to `runSubmit` in
`packages/foreman_cli/cmd/foreman/run.go:82`. Include in the
`Usage:` text. Pass through to the envelope payload.

Validates ACs: AC-BPR-005.

Implementation AC:

- Given `foreman run submit --base-branch feat/x --workflow prd ...`,
  when the CLI posts the envelope, then the JSON body includes
  `"base_branch":"feat/x"`.

#### TRD-BPR-004-TEST — Test runSubmit --base-branch parsing (1h)

Validates ACs: AC-BPR-005.

### PR 2: Default-branch documentation + retarget guidance for PR #412

**Shippable State:** Operators know that the default parent branch is
their current checkout, can pin to a different branch, and have explicit
steps to retarget an existing PR.

#### TRD-BPR-005 — Docs: cli-reference.md updates (1h)

Document `foreman run submit --base-branch` and the new default behavior
in `docs/cli-reference.md`. Update the "Submitting work" section.

Validates ACs: AC-BPR-006.

#### TRD-BPR-006 — Docs: user-guide.md updates (1h)

Document the "current branch is the default parent" rule and how to pin
to a different branch in `docs/user-guide.md`. Add a "Retargeting a PR"
subsection with the `gh pr edit <n> --base <branch>` command.

Validates ACs: AC-BPR-006.

#### TRD-BPR-007 — Apply retargeting + branch-flag docs to PR #412 (30 min)

After PR 1 ships, push a follow-up commit to PR #412 that documents the
new `--base-branch` flag and the "current branch is default" rule in
the PR description. Operator can then re-run the PR base-check via the
GitHub UI to confirm `slices/jido-migration` is the actual base.

Validates ACs: AC-BPR-007.

### PR 3: Multi-phase chain-branch fix

**Shippable State:** A 5-phase `prd.yaml` workflow produces a chain of
phase branches where phase 2 is rooted at phase 1's branch tip, etc.
Phase N+1 sees phase N's commits.

#### TRD-BPR-008 — Server: chain phase branches by default (3h)

Extend `RunExecutor.create_default_worktree/3` at
`run_executor.ex:1159` to resolve `base_ref` from the prior phase's
branch tip when `phase_index >= 1`. The prior phase's branch is read
from `ProjectionStore.worktree/1` keyed by `(run_id, prior_phase_id)`.
When the prior phase's branch no longer exists (cleanup deleted it),
fall back to `plan_context["source_revision"]` and emit a telemetry
event `[:foreman_server, :workflow, :phase_chain_fallback]`.

Validates ACs: AC-BPR-008.

Implementation AC:

- Given a 2-phase workflow completes phase 1 successfully, when phase 2
  starts, then `Worktree.create/1` is invoked with `base_ref` equal to
  phase 1's branch tip (not operator HEAD).
- Given phase 1's branch was cleaned up before phase 2 starts, when
  phase 2 starts, then `Worktree.create/1` is invoked with `base_ref`
  equal to `plan_context["source_revision"]` and the telemetry event is
  emitted.

#### TRD-BPR-008-TEST — Test phase chain resolution (3h)

Integration tests using a 2-phase fixture workflow. Verify phase 2
worktree is created off phase 1's branch tip; verify fallback when phase
1's branch is missing; verify explicit `worktree.base` declaration still
wins over the chain default.

Validates ACs: AC-BPR-008.

## Acceptance Criteria

| AC | Description |
|---|---|
| AC-BPR-001 | `plan_context["base_branch"]` resolves from registered checkout HEAD when payload has no `base_branch`. |
| AC-BPR-002 | Payload `base_branch` wins over checkout HEAD. |
| AC-BPR-003 | `plan_base_branch/1` returns `nil` (not `"main"`) when no resolution path yields a branch. AutoPR treats `nil` as `:noop`. |
| AC-BPR-004 | `foreman_work_submit` accepts and forwards `base_branch`. |
| AC-BPR-005 | `foreman run submit --base-branch <name>` posts the flag in the JSON envelope payload. |
| AC-BPR-006 | `docs/cli-reference.md` and `docs/user-guide.md` document the flag and the new default behavior. |
| AC-BPR-007 | PR #412 includes a doc follow-up referencing the new flag and the `slices/jido-migration` retarget. |
| AC-BPR-008 | A 2+ phase workflow chains phase N+1's `base_ref` from phase N's branch tip (with fallback to `plan_context["source_revision"]`). |

## Verification Strategy

1. **Unit tests** — `mix test packages/foreman_server/test/foreman_server/workflow/plan_context_test.exs`
   (new file), `mix test packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs`
   (extend).
2. **MCP integration test** — exercise `foreman_work_submit` through the
   `MCP` supervision tree with and without `base_branch`.
3. **CLI integration test** — `go test ./cmd/foreman -run TestRunSubmit` (new test).
4. **Live E2E** — submit a `fix` workflow with `--base-branch feat/x` and
   verify the resulting PR targets `feat/x`. Submit without the flag and
   verify the resulting PR targets the operator's current checkout.
5. **Multi-phase E2E** — submit a 2-phase fixture workflow, verify
   phase 2's worktree is created off phase 1's branch tip.

## Out of Scope

- **Cleanup policy** for phase branches. This TRD does not change
  `cleanup: :always`. A follow-on TRD should address when (if ever)
  phase branches should outlive their phase.
- **Per-project `default_base_branch` configuration**. Mentioned in the
  alternatives as Option C; deferred to a future TRD.
- **AutoPR retarget for an existing PR**. Out of scope; covered by
  `gh pr edit <n> --base <branch>` from the command line, documented
  in `docs/user-guide.md`.
- **The Worker aggregate `:worker_terminal` bug**. Unrelated to this
  TRD; addressed in a separate scoped fix.
