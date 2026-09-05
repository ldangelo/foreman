# Foreman — Agent Context

## Documentation Discipline

Every fix or feature must consider documentation before finalization. Update `CLAUDE.md`, `AGENTS.md`, `README.md`, the Foreman User Guide (`docs/user-guide.md`), and the CLI Reference (`docs/cli-reference.md`) when behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations change. Keep edits surgical; document only real behavior.

**This is a gate, not a suggestion — it blocks calling the task done, same as
running the tests.** "Consider documentation" was tried and failed: an entire
work-dispatch unification (new command type, retired command type, renamed
MCP tools, changed CLI envelope) shipped with all five doc files unedited,
caught only because the user asked afterward. The fix is mechanical, not a
reminder to be more careful:

1. Before treating any change as complete, list every externally-visible
   identifier your diff added, removed, or renamed — command/event types
   (`"foo.bar"` strings), MCP tool names (`foreman_*`), HTTP routes, CLI
   flags/verbs, env vars, config keys, workflow/prompt names.
2. `grep` each removed or renamed identifier across `CLAUDE.md`, `AGENTS.md`,
   `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`. A hit is a
   stale reference — fix or explicitly annotate it as historical (see below),
   never leave it silently wrong.
3. `grep` each added identifier's *replaced* counterpart (the old name/route
   it supersedes) the same way, so the replacement gets documented in the
   same place the old one was.
4. State which of the five files needed edits and which didn't, and why —
   "no operator-visible change" is a valid reason; silence is not. This
   statement is part of the deliverable, not optional narration.

`docs/PRD/*` and `docs/TRD/*` are point-in-time design specs, not living docs —
leave their historical claims as written even after the code they describe
changes; a short forward-pointer note (as done elsewhere in this file) is
the right fix, never rewriting them to match later reality.

Runtime prompt/workflow safety: after editing bundled source workflows or prompts, run `foreman init --force`. Dispatch paths (`foreman run`, `foreman run --watch`, and direct worker startup) fail fast when installed runtime prompts/workflows are stale.

Verify a CLI command against the Go source or a fresh `go build ./cmd/foreman`, never against whichever `./foreman` binary happens to be on disk. The checked-in root binary is a build artifact and goes stale, so a real command reads as nonexistent: `foreman init --force` is registered at `packages/foreman_cli/cmd/foreman/main.go:94` and covered by `init_test.go`, yet the stale root binary's help omits it entirely and `./foreman init` answers `unknown command "init"`. Do not document a command as missing, or replace it with a substitute, on that evidence — believing a stale artifact over the source is the same error as the `FOREMAN_ARTIFACT_PATH` claim in section 4.

**The same error runs in the opposite direction, and `docs/cli-reference.md` is
where it lives.** That file documented 30 top-level verbs; the Go CLI dispatches
five. Twenty-six — `abandon`, `attach`, `board`, `clean-state`, `debug`,
`doctor`, `import`, `inbox`, `issue`, `logs`, `merge`, `metrics`, `monitor`,
`plan`, `pr`, `purge`, `recover`, `reset`, `retry`, `sentinel`, `server`,
`sling`, `status`, `stop`, `watch`, `worktree` — had full sections with flag
tables, examples and behavioral prose, and none of them route. So did a
fabricated `foreman --help` domain-grouping and deprecated-alias table (`main.go`
has no alias machinery whatsoever), `foreman init -n`/`--wizard` (`init.go`
declares one flag, `--force`), four `*_projections` tables (the repository has
two migrations), and `devbox run dev:up`/`db:up` (not among the 22 scripts in
`devbox.json`). Believing the stale *document* over the source is the identical
failure to believing the stale binary, and it is the more dangerous one, because
a reference file is what an operator or agent reaches for first. It is not
hypothetical: REQ-007 of `PRD-2026-d306444f-phase-commit-control.md` was
specified against the documented `foreman inbox` surface as though it worked and
had to be dropped once the aggregate behind it proved unreachable.

Those sections are annotated, not deleted — they read as a record of intended
design, and one apparent duplicate turned out to carry a command the other did
not (`foreman issue webhook`), so deleting on a glance would have lost content.
The annotations are also the reason the file is now trustworthy about what is
real, which it was not: it still has no section for `task approve`, `task get`,
`task retry`, `run get`, `run cancel`, `run reset`, `workflow install` or
`workflow remove`, all of which exist. To re-verify any of this, read the
`switch` in `main.go` and the `case` lists in `runProject`/`runTask`/`runRun`/
`runWorkflow` — that is the whole surface, and it takes one grep.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 1.5 Be concise

Just the facts and findings, you can skip the discovery and detailed explaination.  Be BRIEF!

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

Workflow note — PR behavior (corrected 2026-08-26): this file previously said
PR/merge is controlled by phase-level `checkpointPr: true` plus explicit
`create-pr`, `pr-wait`, and `merge` phases. **This codebase implements none of
that.** No module reads `checkpointPr`, and nothing dispatches a `builtin: true`
phase — zero matches across `packages/foreman_server` and `packages/foreman_cli`.

That syntax *does* appear in stale workflows sitting in the installed runtime
catalog (`~/.foreman/workflows/`: `default.yaml`, `feature.yaml`, `task.yaml`,
`epic.yaml`, `bug.yaml`), left over from an earlier implementation. They are not
executable here: `Workflow.Validator.validate_phase/2` requires every phase to
declare `command`, `prompt`, or `bash`, and those `builtin: true` phases declare
none, so loading one fails with `{:missing_phase_action, index}`. Presence in
that directory is not evidence a mechanism works — the supported set is
`packages/foreman_server/priv/defaults/workflows/`. Do not author `builtin`,
`checkpointPr`, `create-pr`, `pr-wait`, or `merge` phases, and do not dispatch
those stale workflows.

**`commit:`, `stack_pr:`, and `timeout_minutes:` are phase-level fields; top-level PR/merge tags
remain unsupported.** `commit: true` (the default when the key is absent)
commits the phase's work when the phase completes; `commit: false` DEFERS it,
leaving the changes in the worktree for a later phase's commit to absorb, which
is how several phases are batched into one commit. `stack_pr: true` requests a
phase PR record after that phase's commit decision, targeting the recorded run
base branch from the same Foreman run branch. Absent or false preserves default
final-AutoPR behavior. `PhaseSpec.@fields` plus `commit`/`stack_pr`, plus the
workflow-level `worktree:` block (`enabled`/`base`/`branch`/`path`/`cleanup`),
is the complete declarable vocabulary. `timeout_minutes:` (alias `timeoutMinutes:`) is a positive integer
phase execution timeout in minutes; absent means fall back to app-config
`failure_policies` / `default_timeout_ms`. `Interpreter` and `PhaseSpec` still
contain zero top-level `pr`, `merge`, or `checkpoint` keys.

**Deferral is rejected at LOAD time in exactly ONE case — the one the manifest
alone makes unsatisfiable — and warned about at run terminal in the case whose
consequence is merely invisible.** `Interpreter.validate_commit_cleanup!/3`
refuses a manifest whose work no phase will ever commit when
`worktree.cleanup` is `always` or `on_success`: both modes delete the run's
worktree, so the deferred changes are destroyed with no branch and nothing for
`AutoPR` to propose. Absent `cleanup:` is `never`, matching
`RunExecutor.worktree_cleanup/1` — reading it as `always` would refuse nearly
every deferring manifest, since most declare no `worktree:` block at all.

Under `cleanup: never` the same manifest LOADS, and `RunExecutor`'s
`warn_uncommitted_work/1` logs at run terminal instead, naming the deferring
phase. It reads the phases that actually EXECUTED, not the manifest, so a run
that fails before the absorbing phase still warns — an end-of-manifest check
would see a committing phase that never ran and report no problem.

**This passage previously described TWO load-time refusals; both claims are
now wrong, and the way they were wrong is the point.**

1. **A `requiredFile:` phase reached with work pending** was refused because
   `PlanContext.discover_document/3` unions "committed since `base_ref`" with
   "uncommitted in the working tree", so a non-committing predecessor's files
   read as the successor's own new document — the gate passes while attributing
   one phase's document to another. That hazard is REAL and still exists. The
   refusal was the wrong response to it: it made deferral and discovery mutually
   exclusive, so the phase immediately before a gated phase could never defer —
   exactly the batching the tag exists to provide, and the shape `plan` and
   `prd` want. Mis-attribution is a property of what discovery SCOPES; a
   load-time veto on manifest shape cannot fix it, and the PRD excludes the
   mechanism by Non-Goal.
2. **Work still pending after the last phase** was refused unconditionally.
   `AutoPR` genuinely counts commits only, so such a run produces no PR — but
   that is a reason to make the absence attributable, not to forbid the
   manifest. The unconditional raise could not distinguish an operator mistake
   from a workflow that deliberately stages changes in a retained worktree for
   human review, and so made the latter inexpressible.

The general rule both corrections express is the PRD's design principle:
**refuse what cannot be honoured, warn where the consequence would merely be
invisible.** Do not re-add a load-time veto on a manifest that a retained
worktree makes perfectly satisfiable.

`CommitDeferral.pending_phase/1` (manifest string keys) and
`pending_phase_spec/1` (normalized `PhaseSpec` atom keys) are two entry points
over one shared fold. That is deliberate, not duplication: the loader and the
executor genuinely hold different shapes, and a
`Map.get(m, :commit) || Map.get(m, "commit")` hedge would leave neither
boundary owning the convention (§5.4). The shared fold is what guarantees the
refusal and the warning cannot disagree about what "pending" means. The pending
flag CLEARS on a committing phase rather than latching, so
`false → true → requiredFile` is valid; among consecutive deferrals it reports
the EARLIEST index, because the operator needs where the uncommitted run begins.

`RunExecutor.phase_commits?/1` matches `true | false | nil` totally rather than
testing truthiness, so a value that somehow bypassed
`validate_commit_value!/3` raises instead of being coerced — the string
`"false"` is truthy and would otherwise commit while the manifest said not to.

Ensemble-skill stacked branches remain separate from Foreman's one-run-branch
model. `stack_pr: true` does **not** create per-phase head branches or a true PR
stack: every tagged phase uses the same run head/base pair, so GitHub usually
has one open PR that later tagged phases reuse and whose diff is cumulative from
the run base. Closed matching PRs are typed failures. No-op phase PR records
(`head` not ahead of `base`) do not suppress final AutoPR; created/reused phase
PR records do. `TRD-2026-3d41f677` is still explicit: "Do not add top-level
workflow `merge:` or `pr:` fields."

`auto_pr/1` is still final-run behavior from `finalize_run/1`; it is skipped
when durable phase PR records already represent the run. `AutoPR.maybe_create_pr/1`
takes a fixed context (`run_id`, `base_branch`, `head_branch`, `artifact_path`,
`cwd`) and derives title and body itself; there is no declarable title, body,
draft, reviewer, or label. Foreman commits with a fixed message, its own author
identity, and `--no-verify`; only WHETHER a phase commits and whether it asks
for a phase PR record are declarable.

The real mechanism is `ForemanServer.Workflow.AutoPR.maybe_create_pr/1`, called
from `RunExecutor.finalize_run/1` after the task provider confirms completion.
It derives the PR from run state rather than from agent output: the head branch
comes from `state.last_worktree.branch` (retained by
`RunExecutor.remember_worktree/2`), which since the move to one worktree per run
is the run's single branch `foreman/<run_id>` rather than the last of N
per-phase branches. The decision is gated on
`git rev-list --count base..head > 0`, the branch is published with
`git push -u origin <head>`, and only then does it shell out to `gh pr create`.
A `FOREMAN_BRANCH=<branch>` marker in the final artifact is still honoured as
an override. Failures log at `error`.

This replaced a design that **could never land a PR**: it required a
`FOREMAN_COMPLETE=true` handoff marker that nothing in the repository emitted,
so `maybe_create_pr` always returned `:noop` at `info` level while the run
reported success, with zero test coverage. Deriving the handoff from run state
is strictly more robust than depending on an agent to print exact lines.

**The PR base is the branch the run's work was cut from, and there is no
default.** `RunExecutor.remember_run_base_branch/1` records it once, when the
run's FIRST phase starts, as `git symbolic-ref --quiet --short HEAD` of
`vcs_working_directory/1` — the same checkout AutoPR later runs `git rev-list`,
`git push`, and `gh pr create` in, read at the same moment
`resolve_run_base/2` reads that same checkout's `HEAD` to give the run worktree
its `base_ref` (the worktree is PINNED to that commit; it does not supply it),
so branch name and base commit describe one repository state. It
is latched on key presence, so an operator switching branches mid-run cannot
retarget the PR, and it does not hang off `remember_worktree/2` — a workflow
declaring `worktree: enabled: false` provisions no worktree yet can still land
a PR through the `FOREMAN_BRANCH` override. `symbolic-ref` is deliberate:
`rev-parse --abbrev-ref HEAD` prints the literal `HEAD` on a detached checkout,
which `gh pr create --base` would accept as a ref name.

`plan_base_branch/1` used to answer this by reading
`plan_context["base_branch"]` and falling back to `"main"`. **Nothing writes
that key** — `PlanContext.build/1` does not produce it, and the `base_branch`
`work.submit` accepts is captured at the protocol level only — so every run
targeted `main`. The first `plan` run to complete end-to-end,
run-776527010ea5d3568b742adbd25ab872, was cut from `feat/mcp-run-details` and
opened PR #420 against `main`: the diff carried an entire unrelated session of
commits instead of the two documents the run produced. An undeterminable base is
now `{:auto_pr_base_branch_unresolved, reason}` and no PR, never a guess —
`{:run_base_branch_unrecorded, run_id}` for absent (no phase started) and
`{:checkout_branch_unresolvable, path, :detached_head | detail}` for malformed
(AGENTS.md 5.3). The `rev-list` gate reads that same base, so it now counts only
the commits the run added on top of its own starting point; against the default
branch it also counted everything the run's base branch already carried, which
is how a run that produced nothing could still look like it had work to propose.

This is the "registered checkout HEAD" tier of
`docs/TRD/TRD-2026-80ba0665-branch-parent-resolution.md`, reached without its
`PlanContext`/`Dispatcher` plumbing: resolving in `PlanContext.build/1` as that
TRD proposes would leave `work.submit` runs — whose `build/1` returns
`:not_applicable`, so they carry no plan context at all — with no base. An
explicit `--base-branch` override is still NOT consumed server-side. (The
`work.*` command ingress described in this passage was retired in favor of
the unified task path — see "Unify Foreman work dispatch onto the task
path" — but the `--base-branch` non-consumption caveat carries over
unchanged to `task.create`.)

**Artifact path is a two-repo contract.** `ArtifactTemplate` expects the phase
artifact at `<artifact_base>/<run_id>/phase-<index>.md` when the phase declares
no `artifact:`. `RunExecutor.foreman_env/3` exports that computed path as
`FOREMAN_ARTIFACT_PATH` on both its non-worktree and worktree clauses
(`run_executor.ex:1647` and `:1653`). The consumer is the `--foreman` path of
the ensemble command YAMLs (`Sunstone/ensemble`,
`packages/development/commands/*.yaml`), which write the phase report to that
exact path in addition to any repo-local report. Absent the variable, ensemble
behavior is unchanged, so the two repos deploy in either order.

**That export was dead from the day it was written until c739e8c9, and this
file claimed it worked the entire time.** `Overwatch.start_phase/2` forwarded
the computed env map to the adapter as `:env_map`, but
`Overwatch.Adapters.JidoHarnessWorker.init/1` read only
`:provider`/`:prompt`/`:driver_opts`/`:result_recipient`, never `:env_map`, and
`run_agent/3` called `Driver.run(provider, prompt, driver_opts)`. Nothing past
Overwatch read the map, so NO variable Foreman exported ever reached a
dispatched agent: `FOREMAN_ARTIFACT_PATH`, `FOREMAN_RUN_ID`, `BEADS_DB`,
`TRD_SCOPE`, `FOREMAN_WORKTREE*`, and every project-configured
`WorkerEnvironment` variable were all unset at the agent. c739e8c9 added the
missing hop: `init/1` folds `:env_map` into `driver_opts` as `env:` (overlay),
and a non-map raises rather than degrading to no env
(`jido_harness_worker.ex:90-105`).

**`JidoHarnessWorker.init/1` is the single hop every phase env var depends on.**
When a variable "is exported but has no effect", read that function FIRST. An
export in `foreman_env/3` proves only that Foreman computed the value; it is not
evidence that any agent received it.

**Jido Harness provider/model selection is explicit.**
`ForemanServer.AgentRuntime.JidoHarness` is the source of truth for supported
providers (`:pi`, `:claude`, `:litellm`) and normalizes string provider keys
from workflow context. `RunExecutor` maps phase `models.default` to
`context.model` / `FOREMAN_MODEL`, and `JidoHarnessAdapter` forwards that model
to the selected provider. Never infer provider from model name.

The corrected consequence: no dispatched run had ever recorded an artifact, and
the cause was this dropped env map — not agents ignoring the contract. The
previous version of this passage instead blamed an inferred agent convention
(`docs/reports/<project>-<task-id>/IMPLEMENT_REPORT.md`) for the missing
artifacts. That was wrong, and because the claim lived here it was re-derived as
established fact and drove repeated misdiagnosis of agent behavior across a
whole session. The decisive evidence is the agent's own probe from inside the
dispatched process: run-d6cdefe69706087e6bce5b1a10b95384's pi transcript runs
`test -n "$FOREMAN_PRD_PATH" && … || echo 'FOREMAN_PRD_PATH unset/empty'` at msg
#45 and gets `unset/empty` back at msg #47.

**A `command:` phase has no in-prompt channel at all.** `dispatch_agent/5`
substitutes the rendered command string for the rendered prompt
(`run_executor.ex:470-477`); `request.prompt` survives only as the fallback for
a command that renders to nil, so for any real command phase it is discarded.
Anything such a phase must know — the artifact path, and the task subject
itself — therefore travels by env or does not travel. With neither, the agent
reconstructs a subject from repository reconnaissance: three live runs
dispatched with three different descriptions all produced a PRD about the same
unrelated "curated ensemble workflows" topic, because that is what greps of this
repo return. This is why `assert_plan_subject/3` refuses to dispatch any
discovery-gated phase whose env carries no `FOREMAN_TASK_TITLE`.

**Planning documents are DISCOVERED, not mandated.** Foreman does not tell a
plan agent what to name its PRD or TRD and does not gate on a name it computed.
`RunExecutor.enforce_required_file/4` routes `requiredFile: planning.prd_path` /
`planning.trd_path` to `PlanContext.discover_document/3`, which takes the
documents NEW IN THE PHASE as the union of two scans in the phase's working
directory, deduplicated:

1. `git diff --name-only -z --diff-filter=A --find-renames <base_ref> HEAD --
   docs/PRD` — what the agent COMMITTED. `--find-renames` is explicit so an
   operator's `diff.renames=false` cannot turn a committed rename into an
   apparent addition.
2. `git status --porcelain -z --untracked-files=all -- docs/PRD` — what the
   agent left untracked or added in the working tree.

`base_ref` is the commit the phase's checkout stood at when the phase started.
On the run's FIRST phase that is where `Worktree.create/1` pinned the worktree,
carried back on the record by `create_run_worktree/2`; on every later phase it is
the shared checkout's current `HEAD`, refreshed by `reuse_run_worktree/2` (it
used to come from the deleted `create_phase_worktree/4` /
`create_default_worktree/3` pair, one worktree per phase). Either way
`capture_planning_document/4` reads it from run state with no new event.
The invariant that makes this deterministic is one the pipeline
already enforces — the tree is clean when a phase starts, a dirty worktree
HALTs — so it is not a heuristic: no newest-mtime, no name matching. Renames
and edits of documents that already existed at `base_ref` are not candidates;
the gate proves a NEW document exists. Each outcome is its own error (AGENTS.md
5.3): one candidate captures, `:planning_document_absent` means the agent
produced nothing, `:planning_document_ambiguous` names every candidate rather
than picking one, `:planning_document_scan_failed` means git could not read the
directory or the base at all, and `:planning_document_base_unknown` means
Foreman has no base for the phase (a phase configured with
`worktree: enabled: false`) — never a silent fall back to the working-tree scan.

The committed half is not an edge case: it is what the ensemble skills do. The
working-tree-only gate failed run-9ff0f0ffc7e5845265d0cdcf8eb0ac2d with
`{:planning_document_absent, "docs/PRD", …}` 30 seconds after polling had seen
`?? docs/PRD/PRD-2026-96266fc0-durable-run-log-store.md` — the agent had
committed it, so the scan saw a clean tree and reported "produced nothing".

`PlanContext.capture_document/3` writes the captured relative path into the
run's plan context under the same key, so `create-trd` reads the PRD the
`create-prd` agent actually wrote. `RunExecutor` joins it onto the phase cwd in
one place, `resolve_phase_path/3` — do not reintroduce a second computation;
rooting planning paths at the project root at build time was half of an earlier
failure, because the agent's cwd is the worktree. Capturing the PRD also
re-keys `planning.correlation_id` off the captured filename: PRD<->TRD pairing
rides on that id, and the run-derived one belongs to a document that was never
written. A filename carrying no id drops the key rather than keeping a
plausible-looking wrong answer.

Why the mandate was abandoned: `foreman_env/3` used to export
`FOREMAN_PRD_PATH`/`FOREMAN_TRD_PATH` and the gate required that exact file.
It failed in three consecutive live runs
(run-d6cdefe69706087e6bce5b1a10b95384, run-dda353905d237cfd2557a706dd930bdd,
run-3da49f9ed1ae01f932092b31335b5623), each with a different task description
and each producing a PRD about the same unrelated subject. Two independent
causes, and neither was "the agent disobeyed":

1. **The variable was never delivered.** The dropped `:env_map` documented
   above: until c739e8c9 no `FOREMAN_*` export reached any agent, so the gate
   required a path the agent could not read.
2. **The subject was never delivered either.** With no title or description in
   env and none in the prompt (a `command:` phase's prompt is literally the
   command string, see above), the agent reconstructed a topic from repository
   reconnaissance — the same transcript greps the repo for
   `curated|ensemble|workflow dispatch` by msg #8. The filename gate was
   catching that by accident. Discovery would not, so `foreman_env/3` now
   exports `FOREMAN_TASK_TITLE`/`FOREMAN_TASK_DESCRIPTION` and
   `assert_plan_subject/3` refuses to dispatch any discovery-gated phase whose
   env carries no `FOREMAN_TASK_TITLE`, failing `{:plan_subject_missing, …}`
   before a worker starts. Accepting whatever an uninformed agent wrote is the
   plausible-looking success this file exists to forbid.

`FOREMAN_SOURCE_PRD_PATH` carries the captured PRD forward as an INPUT: absent
on the phase that produces it, present for every phase after, so `create-trd`
consumes a named document instead of globbing `docs/PRD`. It is deliberately
not the old name — `FOREMAN_PRD_PATH` meant "write here", it is deleted, and
recycling the name for "read here" would leave two contradictory meanings in
circulation. Its consumers are `create-trd.yaml` and `create-trd-foreman.yaml`,
which STOP when it is set and missing rather than falling back.

**A run has exactly ONE worktree, the whole workflow executes in it, and the
`worktree:` block is declared at the WORKFLOW level.** The block sits at the top
of the manifest beside `name:` and `phases:`, never on a phase — a run has one
worktree, so a phase has nothing to decide about it. `WorktreeSpec.normalize/1`
is the only normalizer; `RunExecutor.extract_worktree_spec/1` reads the block off
the frozen `workflow_snapshot` into `state.worktree_spec`.

Fields, all optional: `enabled` (default true; `false` opts the whole workflow
out), `base`, `branch` (default `foreman/{task_id}/{run_id}`), `path` (leaf directory,
default `workspace`), `cleanup` (default `never`). `{task_id}` and `{run_id}`
are template placeholders. `{phase}` was dropped with the move: it named a
per-phase branch and directory that no longer exist.

`create_run_worktree/2` is the single provisioning path. Absent a `worktree:`
block it provisions one directory
(`~/.foreman/worktrees/<project_id>/<run_id>/workspace`) on one branch
(`foreman/<task-id>/<run-id>`) — both DEFAULTS, overridable by the workflow's `path:` and
`branch:` — and every later phase reuses that record via
`ensure_run_worktree/2` -> `reuse_run_worktree/2`, reading its predecessors'
output as ordinary files. `remember_run_worktree/2` latches the record on key
presence, so the first phase provisions and the rest reuse.

Whether the base is pinned is a property of the RUN, not of the declaration.
`resolve_run_base/2` detects an ImplementationContext by the presence of the
values it freezes: with one, `project_root`/`source_revision` come from plan
context, a declared `base` must resolve to that same revision
(`assert_base_matches/3`, TRD Decisions 3/5), and
`implementation_key`/`trd_scope` ride on the record; without one, the root is the
project's registered path and the base is that checkout's `HEAD`. A
partially-populated plan context is a hard error, never a silent fall back to
`HEAD`.

A reused worktree carries exactly one per-phase value: `base_ref`, refreshed to
the shared checkout's current `HEAD`. That is what keeps the discovery gate
scoped per phase — `capture_planning_document/4` diffs `<base_ref>..HEAD` for
documents NEW IN THE PHASE, and `commit_phase_worktree/4` commits at each phase
boundary, so `HEAD` at phase N's start is exactly what phases 1..N-1 produced.
Phase 1's PRD therefore correctly does not read as new in phase 2. A worktree
that has vanished mid-run is `{:run_worktree_vanished, path}` and an
unresolvable `HEAD` is `{:run_worktree_head_unresolvable, path, reason}` — never
a silent re-provision, which would run the phase against the wrong tree.

This replaced a per-phase design on both axes, and the second axis is the
subtler one. Each phase used to create its own worktree and branch, cut from the
predecessor's branch tip by `phase_lineage_base_ref/2`, destroyed at the phase
boundary by `cleanup_phase_worktree/4`; both functions are **deleted**. And each
phase used to carry its own `worktree:` block, which for a run-scoped resource
meant N declarations could contradict each other while only the first could
possibly be honored.

Worse, the phase-level block selected between two non-interchangeable
provisioning functions — declaring it routed the run through
`create_phase_worktree/4`, which required an ImplementationContext. So
`worktree: {enabled: true}` on `prd.yaml` or `fix.yaml` did not restate the
default; it changed the code path and failed provisioning on the first phase.
An earlier version of this section documented that as a rule to work around
("only `implement-trd*.yaml` may declare the block") instead of a defect to fix.
Documenting a trap is not the same as removing it: there is now one provisioning
path and the block is legal on every workflow. Do not reintroduce
`phase_lineage_base_ref/2`, `cleanup_phase_worktree/4`, `create_phase_worktree/4`,
`create_default_worktree/3`, or a phase-level `worktree:` key.

Three normalizers for this one block existed at once: `PhaseSpec`,
`Catalog.normalize_worktree/1`, and the executor's own reads — and the catalog's
injected defaults DISAGREED with the executor's (`branch:
"foreman/{run_id}/{phase}"`, `cleanup: "always"`). `Catalog` now carries the
block verbatim and injects nothing, precisely so "declared nothing" stays
distinguishable from "declared the default"; that difference is load-bearing for
`enabled`. Normalize once, at the executor boundary (AGENTS.md §5.4).

The `Interpreter` validates the block once at workflow level, so its error
messages no longer carry a phase index. Supporting a top-level `worktree:` also
required teaching `parse_root_entries/3` that a top-level key with no inline
value introduces a nested mapping — only `phases:` had been allowed to nest, so
`worktree:` parsed as the empty string and left its own indented lines
unconsumed. That surfaced as `no case clause matching` with the whole token list
inspected into the message, because `parse_root!/2`'s leftover clause matched
only a SINGLE unparsed line; it now matches with a tail and names the offending
line.

**Worktree cleanup is run-level, declared as `cleanup: always | never |
on_success`, default `never`.** `never` never reclaims here; `always` reclaims on
success and on failure; `on_success` reclaims only on success, so a failed run's
checkout survives for forensics. `cleanup_run_worktree/2` takes the outcome —
`finalize_run/1` passes `:success` after AutoPR (the worktree is the checkout
AutoPR pushes from, so anything earlier deletes the work before it can be
proposed) and `finalize_terminal_and_stop/2` passes `:failure`. `RunDeleted` still
fans out to `Worktree.clean_for_run/1` for runs that end another way.
`worktree_cleanup/1` returns `{:error, {:worktree_cleanup_invalid, other}}` for
any other value rather than defaulting, so a misspelled `cleanup: allways` cannot
read as a working declaration.

`on_success` is the sharpest instance of this file's core failure mode. The
`Interpreter` validated it as legal from the day the block was introduced, and
`ManifestWriter` round-tripped it with test coverage, while `worktree_cleanup/1`
matched `"never"` and sent everything else — `on_success` included — to
`:always`. A manifest asking to KEEP the checkout on failure had it deleted, on
exactly the path where the evidence mattered. Nothing failed, because the schema
and the writer agreed with each other and only the consumer disagreed. When a
validator accepts an enum value, grep for a reader of every variant before
trusting that the value does anything.

An in-flight attempt at the cleanup fix introduced a second key,
`clean_worktree`, and stopped reading `:cleanup` entirely. It silently orphaned
the `cleanup: never` already declared by both `implement-trd*.yaml`, and escaped
notice only because the new default happened to agree with the orphaned
declaration. `clean_worktree` is NOT and never was a manifest key — it is the
`VcsAdapter` operation name for removing a worktree
(`VcsAdapter.Default.clean_worktree/2`). It was also added to
`PhaseSpec.@worktree_fields`, where it normalized a key no module read. Both are
removed.

**Foreman owns the commit.** `commit_phase_worktree/4` stages and commits
whatever the phase produced, so an agent that writes files without committing
still leaves the run a proposable branch. Emptiness is decided by
`git status --porcelain --untracked-files=all`, never by `git commit`'s exit
code: after `git add -A` a clean tree and a genuine failure both exit 1, and git
prints "nothing to commit" to stdout rather than staying silent, so the first
implementation's "exit 1 with empty output means clean" test matched the failure
case and reported real errors as a clean tree. A clean tree is
`{:ok, :nothing_to_commit}` and creates no commit, preserving the invariant that
AutoPR proposes only real work. Every git failure is `{:error, …}`; the first
implementation returned `{:ok, :skipped_no_worktree}` for a failed `git add`, a
missing `project_root`, a non-zero `git commit`, and an unrecognized exit code
alike, so a phase whose work was never committed completed as a success (AGENTS.md
5.2). The commit uses `-c user.name` / `-c user.email` overrides so it cannot
fail on a checkout with no identity configured, and `--no-verify` so a repository
pre-commit hook cannot fail the phase or rewrite the agent's output.

Keep three tiers of proof distinct here, because collapsing them in either
direction is how this section's worst errors were made. **Proven by code:** the
base selection above. **Proven by test against real git, no filesystem or git
mocks:** every phase runs in one checkout, and each phase's discovery gate
scopes to its own document. `run_executor_test.exs` drives the real
`RunExecutor` through a two-phase default-worktree run: phase 1's scripted agent
writes a PRD and does NOT commit it, phase 2's agent calls `File.regular?` on it
from the shared worktree and the test asserts it true, asserts both phases were
handed the same `FOREMAN_WORKTREE_PATH` and the same
`FOREMAN_EXPECTED_BRANCH`, asserts phase 2's `FOREMAN_SOURCE_REVISION` advanced
to the commit Foreman made on phase 1's behalf while refuting it is the run
base, and asserts the worktree survives run completion with the run branch
carrying the PRD.
`run_executor_run_worktree_test.exs` pins the subtlest part, which is exactly
where a silent regression would hide: against the refreshed base,
`discover_document(wt, "docs/TRD", phase2.base_ref)` returns the TRD while
`discover_document(wt, "docs/PRD", phase2.base_ref)` returns
`{:planning_document_absent, …}` — the inherited PRD correctly does NOT read as
new in phase 2 — yet against the RUN's base the same PRD call returns
`{:ok, prd}`. That contrast is the proof that `base_ref` must advance with the
shared checkout or the gate mis-reports. The same file pins the commit path
against real git: a checkout with `user.email`/`user.name` unset still commits,
an untracked-only file counts as work, a clean tree creates no commit, and a
directory git cannot read is an `{:error, …}` rather than a skip.
**Not proven:** a live end-to-end plan run. No dispatch has executed since the
fix.

Do not collapse those tiers. Reading "proven by code" as "works in production"
is the `FOREMAN_ARTIFACT_PATH` error one paragraph above — computation proven,
delivery assumed. Reading "proven by test against real git" as "unproven" is the
same loss of information in the opposite direction. The STOP-on-missing rule
above is what keeps a failure here loud, naming the absent path instead of
producing a silently mis-sourced TRD.

`cleanup_phase_worktree/4` is **deleted** — worktree reclamation is now
run-level (`cleanup_run_worktree/2` from `finalize_run/1`). The paragraphs
below described its behavior and are kept because the reasoning error they
record is the transferable part.

An earlier version claimed `cleanup_phase_worktree/4` "force-deletes its
branch". **That was wrong when it was written, not merely stale.** It reclaimed
disk only, via `Worktree.clean/1` -> `VcsAdapter.Default.clean_worktree/2`,
whose entire git surface is `git worktree remove` (`default.ex:193`) followed by
`git worktree prune` (`:199`) — no ref is written or deleted anywhere in it.
`delete_branch/1` is private to `worktree.ex` (`:269`, `:281`) and its
only caller is `Worktree.clean_for_run/1` (`:228`), which `Dispatcher` invokes
solely on `RunDeleted` (`dispatcher.ex:163`) — after the run is already
terminated. That is still true of `clean_worktree/2` today, and it is why
run-level cleanup reclaims the directory without touching the run branch AutoPR
has already pushed.

Empirically, too: phase 1's branch from the failed
run-d75304aca144c15409087ed744e2a7dc is still at `b9c93aa7` and still carries
`docs/PRD/PRD-2026-6a25501b-durable-run-log-store.md` long after that run's
cleanup ran.

How that error was made is worth more than the correction: the claim came from
the function's NAME and its presence in the cleanup path, never from its call
graph. It then travelled into a design question posed to the user as though it
were established. Before asserting that a function does something destructive,
read its callers — same class as concluding from a stale binary's surface
instead of the source (see Documentation Discipline).

When changing that contract, change both sides. A Foreman-side export with no
consumer is dead plumbing — an earlier attempt at exactly this was reverted for
that reason. Note also that only a command YAML's `mission.summary` is emitted
by *every* ensemble generator: `constraints` and `parameters[].description` are
dropped by the codex generator, so a rule authored only there is invisible to a
codex-backed agent.

Prompt rendering itself is NOT the problem, despite what
`docs/reports/foreman-foreman-dispatch-fix-verify-rdrq/IMPLEMENT_REPORT.md`
claims. `prompt_renderer_test.exs` renders the bundled `implement.md` with
`artifact_path` in the assigns and passes. That report's agent was on a
`command:` phase, so it never received a Foreman prompt at all; it read the
checked-in template at `priv/defaults/workflows/prompts/implement.md`, which
legitimately contains an unrendered `{{artifact_path}}` because it is the
source template. Do not re-chase it as a rendering defect.

## 5. Typed Boundaries, Loud Failures

**Make the compiler catch it. If it can't, fail loudly. Never degrade to a plausible-looking success.**

Six stacked MCP defects shipped undetected because every one of them failed
quietly — a permissive catch-all turned each into either a successful-looking
response or a misleading "unknown tool". These rules exist to prevent that
class, not just that instance.

### 5.1 Typed returns — no bare maps as result or error payloads

A function's failure payload MUST be a struct with `@enforce_keys` and
`@type t`, never an anonymous map:

```elixir
# WRONG — a typo'd or renamed key silently stops matching downstream.
{:error, %{code: "NOT_FOUND", message: "Run not found"}}

# RIGHT
{:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
```

Maps stay legitimate for genuinely open nested data (event payloads, config
blobs, `phase_status`). They are not acceptable as the contract itself. This is
the same rule already enforced for aggregate state (see **Aggregate State
Design**) and domain events (see **Typed Event Structs**) — it applies to every
internal API boundary.

### 5.2 Result handling MUST be total, with no permissive fallback

Match exactly the documented return shapes and nothing else. A catch-all that
wraps an unrecognized value into a success response is prohibited:

```elixir
# WRONG — an unmatched error is reported to the caller as a SUCCESS.
defp wrap(other, frame) do
  {:reply, %Response{content: [text(inspect(other))], isError: false}, frame}
end

# RIGHT — total over the contract; anything else raises FunctionClauseError.
defp wrap({:ok, data}, frame), do: {:reply, ..., frame}
defp wrap({:error, %ToolError{} = e}, frame), do: {:error, ..., frame}
```

A crash beats a lie. `rescue`/`catch` around a call you do not understand, or
an `_ -> :ok` fallback, converts a defect into corrupt state.

### 5.3 Distinguish "absent" from "malformed"

One catch-all serving both is a debugging tax. Give each cause its own code:

| Cause | Response |
| --- | --- |
| Unknown name / id | `METHOD_NOT_FOUND` / `NOT_FOUND` |
| Known name, missing required argument | `INVALID_PARAMS`, naming the argument |
| Known name, wrong key type (caller bypassed the boundary) | **raise** — programming error |

`foreman_queue_status` was advertised for its entire life with no
implementation, and every call returned `METHOD_NOT_FOUND — Unknown tool`,
indistinguishable from a client typo.

**Update 2026-09-01: `InboxThread` is now implemented.** Per `foreman-q5bm`:

- `CommandRouter.aggregate_module_for/1` has `"inbox:"` clause → routes to InboxThread
- Event structs `InboxMessageAppended` / `InboxDeliveryUpdated` under `lib/foreman_server/events/`
- `ProjectionStore` handles both events; exposes `inbox_thread/1` and `list_inbox_threads/0`
- MCP tool `foreman_inbox_get` added (`foreman inbox get <run_id>`); `inbox.send` and `inbox.delivery.update` are internal command types dispatched via `dispatch_system`

The per-run operator inbox is now functional. `dispatch_system` has no allowlist restriction (trusted OTP), so internal callers use that path for `inbox.send` / `inbox.delivery.update`.

`task.block` was in the same class: a handler existed in `task.ex` gated behind
`require_blockable/1` which no operator path triggered; `CrashLoopDetector`
was the sole caller via `dispatch_system`, and `TaskBlocked` had no
`ProjectionStore` handler so the blocked state was invisible to the read model.
`OperatorTimeout` also dispatched it on operator timeout expiry. All four
(`require_blockable/1`, the `task.block` handler, `TaskBlocked` event, and the
`OperatorTimeout` dispatch) have been deleted. `blocked_reason` aggregate field
was written but never read; removed from the `State` struct. PR #432.

### 5.4 Typed parameters — one key convention, normalized once

Pick one key convention per boundary (atoms internally), convert at the single
entry point, and never pattern-match both:

```elixir
# WRONG — invites permanent drift; one of the two clauses is always dead.
backend = Map.get(args, :backend) || Map.get(args, "backend")

# RIGHT — the transport normalized schema-declared keys already.
backend = Map.get(args, :backend)
```

Only convert keys the schema declares, so caller input can never mint atoms.
A string key arriving past that boundary is a programming error: raise.

### 5.4b Normalize parameters — whitelist known keys, drop unknowns

Every caller-facing function that accepts a map parameter MUST normalize its
input at the entry point before delegating downstream:

1. **Declare the whitelist** of accepted keys (atoms, internally).
2. **Fold only whitelisted keys** into the canonical output map.
3. **Never insert `nil`** for an absent key — callers that pattern-match
   `%{key: "present"}` will crash when `nil` arrives; callers that use
   `|| fallback` misbehave because `nil || fallback` returns `fallback`
   but `false || fallback` also returns `fallback` (lost signal).

```elixir
# WRONG — caller can pass any key; nil-literal keys silently drift.
def handle(%{key: value}) when is_binary(value), do: ...
def handle(%{key: nil}), do: ...

# RIGHT — whitelist known keys at the boundary.
@known_keys [:key, "key"]
def normalize(raw) do
  Enum.reduce(@known_keys, %{}, &put_field(&1, raw, &2))
end
```

The rule is sound; the example originally attached to it was not. It claimed a
"YAML-driven `:clean_worktree` key was silently dropped because it wasn't in the
normalization whitelist". `clean_worktree` is not a YAML key and never was — it
is the `VcsAdapter` operation name for removing a worktree — and the whitelist
entry added for it normalized a key no module read.

The real defect of this class, in the same change, was the reverse: the manifest
key `cleanup:` stayed in the whitelist and kept normalizing correctly, while its
only consumer (`worktree_cleanup/1`) was rewritten to read a different key. The
declaration in two bundled workflows kept parsing and controlled nothing. So
normalization whitelisting is necessary but not sufficient: a key is live only
when something reads it, and the reader is where a rename has to be checked.
The second half of the original claim does hold on its own — inserting `nil` for
an absent key poisons callers written as `value || fallback`, which is why
`PhaseSpec.put_worktree_field/3` drops absent keys instead.

### 5.5 Prefer compile-time enforcement over runtime discovery

When a registry and its implementations must agree, **generate the dispatch
from the registry** so disagreement cannot compile:

```elixir
for schema <- @tools do
  impl = :"tool_#{schema.name}"
  def call_tool(unquote(schema.name), args), do: unquote(impl)(args)
end
```

A missing implementation is now `undefined function tool_foreman_queue_status/1`
at compile time instead of a runtime "unknown tool". Apply the same reasoning to
workflow phases, event codecs, provider callbacks, and CLI subcommands: derive
one side from the other rather than maintaining two hand-written lists.

**A compile warning about an undefined module or function is a defect report,
not noise.** `run_executor.ex` was missing
`alias ForemanServer.Workflow.StepSequencer`, so
`StepSequencer.propagate_terminal/2` resolved to a non-existent top-level
module. Every multi-phase run — `plan.yaml` included —
crashed the executor on the phase 1 -> phase 2 transition instead of advancing,
which means `create-trd` had never once executed. The compiler emitted the
warning on every build for the entire life of the bug and nothing failed on it,
so the crash was repeatedly re-diagnosed as a workflow or agent problem. The
alias now carries a comment saying exactly this (`run_executor.ex:43-47`).
Treat `undefined module`, `undefined function`, and unused-alias warnings as
build failures to be read, not scrolled past: this section's whole point is that
the compiler already knew.

### 5.6 Verify third-party contracts against dep source, and pin them with a test

Every MCP defect was an assumption about `anubis_mcp` that the library
contradicted (`handler: nil` required for dispatch; `validate_input: nil`
silently discards arguments; `Anubis.Server.Response` ≠ `Anubis.MCP.Response`;
`Frame.get_assign/2` does not exist; auth lives at `frame.context`, not
`frame.transport_context`). Read `deps/<lib>/lib/**` and confirm before coding,
then add a test asserting the invariant so an upgrade cannot silently break it.

### 5.7 Never duplicate a boundary across transports or adapters

`ForemanServer.MCP` and `ForemanServer.MCP.Stdio` were ~85% byte-identical, so
three defects existed twice and the stdio copy was missed on the first fix.
Put the shared behavior in one module (`ForemanServer.MCP.Dispatch`) and let
each variant implement only its genuine difference. When two implementations
must behave identically, add a test that exercises **both** through the same
assertions.

---

## Devbox — single entry point for the full dev environment

A new dev cloning this repo should be productive with `devbox` alone. The
`devbox.json` at the repo root declares Nix packages (elixir/erlang/postgres/
redis/docker-client/jq/openssl/python3/git/gh/watch/direnv) and a script
catalog that orchestrates the Langfuse stack + otel-collector + the foreman
app from one place.

Prereqs: [Devbox](https://www.jetpack.io/devbox/) (which installs Nix on
macOS/Linux). Once devbox is on PATH, every script below is one
`devbox run X` invocation from the repo root.

The Langfuse/litellm observability stack itself lives in a separate repo
(`~/Development/Sunstone/litellm-langfuse-stack/`). Override that path via
`export LITELLM_LANGFUSE_STACK=/path/to/stack` if yours is elsewhere. The
default works for `~/Development/<org>/<repo>` side-by-side checkouts.

### Common dev workflows

```bash
# ONE-TIME bootstrap (after cloning):
devbox run setup            # copy .env, install mix deps, ensure stack .env

# DAILY:
devbox run up               # bring up Langfuse stack + otel-collector
devbox run server           # start the Phoenix server (foreground)
devbox run iex              # start with iex for interactivity
devbox run ps               # show all services across both repos
devbox run logs             # tail otel-collector logs
devbox run logs:stack       # tail litellm-langfuse stack logs

# TEAR DOWN (preserves volumes):
devbox run down

# FULL RESET (DROPS all data — will prompt):
devbox run reset

# TESTING:
devbox run test             # all tests
devbox run test:langfuse    # only :langfuse-tagged (the OTel+Langfuse e2e path)
devbox run test:unit        # everything except :langfuse

# DATABASE:
devbox run db:migrate
devbox run db:reset
devbox run db:console       # psql on foreman-postgres

# QUICK REFERENCE:
devbox run info             # all commands + status summary
devbox run env:list         # current env vars + endpoints
```

### What `devbox run up` does

1. Sources the litellm-langfuse-stack's `.env` so it can find
   `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`.
2. `cd $LITELLM_LANGFUSE_STACK && docker compose up -d --build` — brings up
   litellm + langfuse-web + langfuse-worker + headroom + postgres + redis
   - clickhouse + minio. (Host ports already pre-remapped in the stack repo
   to avoid analytics-postgres on 5432 and analytics-redis on 6379.)
3. Waits up to 60 s for `http://127.0.0.1:3000/api/public/health`.
4. `cd $DEVBOX_PROJECT_ROOT && docker compose -f ops/otel-collector/docker-compose.yml up -d --build`
   — brings up the in-repo OTel collector (Foreman -> collector -> Langfuse).
5. `devbox run ps` — final status.

### What the otel-collector does

The collector at `ops/otel-collector/` is the bridge between Foreman's OTLP
exporter (`packages/foreman_server/config/config.exs`,
`packages/foreman_server/config/prod.exs`) and Langfuse v3's OTLP ingest
endpoint. Foreman exports to `http://127.0.0.1:4318`; the collector batches,
retries, and forwards to `http://langfuse-web:3000/api/public/otel/v1/traces`
with HTTP Basic auth (`base64(public:secret)`).

Why this exists:

- Langfuse v3's OTLP ingest requires Basic auth with both the public AND
  secret keys — Bearer-with-public-only returns 403. Earlier this session
  shipped that broken shape against real Langfuse; `prod.exs` was patched
  (commit 5296992).
- In dev, Foreman points at the collector; prod deployment points
  directly at the Langfuse ingest URL via the same `OTEL_EXPORTER_OTLP_ENDPOINT`
  env var (see `packages/foreman_server/config/prod.exs`).

### Lint warning

`devbox.json` is in legacy format (the warning at every `devbox run`).
Running `devbox update` rewrites it to the modern `{packages: [{name: ...}]}`
shape; safe but cosmetic. Will be addressed in a follow-up.

---

### Known environmental workarounds in devbox.json

Two `init_hook` lines in `devbox.json` carry interim workarounds for
environmental problems that block `devbox run test:langfuse`:

1. **`SHELL` export** — `erlexec` (transitive dep) starts an `:exec` port
   driver at app boot that requires `SHELL` in env. Defaulted to
   `/bin/sh` if unset.
2. **Elixir 1.18.4 PATH override** — `devbox-search` resolves
   `elixir_1_18@latest` to 1.18.1, which has a deterministic
   `Module.ParallelChecker.cache_module/2` crash on `telemetry_metrics`
   compile. The hook scans `/nix/store/*-elixir-1.18.4` and prepends
   the first match to PATH, falling through to the broken 1.18.1
   default on a fresh clone (where this would need a follow-up).
   Tracked in beads issue `foreman-w4b`. Remove the workaround once
   devbox pins 1.18.4 natively or `br close foreman-w4b`.

---

## Operator Reference

### Starting the Phoenix Server

```bash
# From packages/foreman_server/
cd packages/foreman_server
mix phx.server
```

The server listens on `http://127.0.0.1:4766` (configured in `config/dev.exs`).
The Go CLI (`foreman`) defaults to `http://127.0.0.1:4766` — set `FOREMAN_API_URL` to override:

```bash
FOREMAN_API_URL=http://127.0.0.1:4766 foreman task list
```

### Registering Beads-backed Projects

`foreman project create` / `foreman project update` require
`--task-provider-database-path <absolute-path>` when
`--task-provider=beads`; the CLI writes this as
`task_provider.config.database_path`.

### Stopping the Server

```bash
# Find the iex/mix process and kill it
ps aux | grep 'mix phx' | grep -v grep
kill <pid>
```

Or use `Ctrl+C` in the terminal running the server.

### Task Lifecycle

Tasks go through: `open` → `ready` → `in_progress` → `completed`/`failed`.

#### 1. Create a task

`foreman task create` supports `--workflow-type` and `--trd-path` directly
(`packages/foreman_cli/cmd/foreman/task.go:68-130`); prefer it over raw curl:

```bash
FOREMAN_API_URL=http://127.0.0.1:4766 foreman task create \
  --project foreman \
  --title "<title>" \
  --description "<description>" \
  --task-type task \
  --workflow-type implement-trd-beads \
  --trd-path docs/TRD/<trd-file>.md
```

**Flags:** `--project` and `--title` are required; `--id` is optional
(auto-generated via the task provider when omitted). `--workflow-type`
selects the workflow manifest (e.g. `implement-trd-beads`,
`implement-trd`, `plan`). `--trd-path` is a project-relative path to a
tracked git blob, required by the CLI when `--workflow-type` is
`implement-trd` or `implement-trd-beads`, and must be committed before
approval. The CLI has no `--priority` flag; set it via a raw
`POST /api/commands` `task.create` payload (`priority`, integer 0-4) if
needed — Beads validates it as a Beads priority for
`implement-trd-beads` tasks. The MCP `foreman_task_create` helper requires
`description` for `FOREMAN_TASK_DESCRIPTION`, passes `prompt` separately for
`:prompt`-action phases, and defaults `auto_approve: true`.

#### 2. Approve a task

Approval transitions `open` → `ready` and triggers workflow dispatch:

```bash
foreman task approve --id <task-id> --approved-by operator
```

**Prerequisites (verified against `aggregates/task.ex` and
`command_gateway.ex`):**

- The task must exist (`command_gateway.ex`'s `task.approve` clause of
  `validate_aggregate_id/1` looks it up via
  `ProjectionStore.task_projection/1`) and be `open`
  (`Task.require_approvable/1`, `task.ex:427`) — anything else,
  e.g. already `ready`/`in_progress`, is rejected as
  `:task_not_approvable`.
- The `trd_path` (if the task carries one) must be a committed git blob
  at `HEAD`.
- Every task id in the task's `dependencies` list must be a task whose
  status is `closed` (`CommandGateway.require_dependencies_satisfied/2`).
  Anything else is rejected as
  `{:task_dependencies_unsatisfied, [{id, reason}]}`, listing EVERY
  unsatisfied dependency in declaration order with its reason — a status
  string, `:not_found` for an id with no task, or `:malformed` for a
  non-binary id **or an empty string**. Note `failed` does NOT satisfy: it
  is terminal but did not produce the work the dependent task needs.

  An idempotent approval retry is exempt: when the task projection already
  records `approval_id == command_id`, the guard returns `:ok` without
  reading dependencies at all. The module docstring promises a re-sent
  command succeeds "even if the assets have since changed", and a
  dependency's status is such an asset — approve while it is `closed`, let
  `task.retry` return it to `open`, re-send the original command, and a
  guard that judged the retry would report a failure that never happened.
  The approval is already committed and the dispatch is deduplicated by
  `command_id` downstream, so there is no second event to prevent. The
  guard governs NEW approvals only.

  The `dependencies` value itself must be a list. `task.create` refuses a
  present non-list as `{:invalid_envelope, :invalid_dependencies}`; absence
  is still fine, since absent and malformed are different (§5.3). A
  malformed value already in the store from before that validation existed
  refuses the APPROVAL as `{:task_dependencies_malformed, value}` rather
  than raising in the read model: `ProjectionStore.init/1` rebuilds
  projections from the event log, so raising would turn one bad historical
  event into an application boot failure — the `WorkerStdout` failure in
  "Durable Run Logs" below, repeated.

  This mattered concretely. The read model first carried the field as
  `event.dependencies || []`, which is the shape §5.4b names explicitly:
  `false || []` yields `[]` exactly as `nil || []` does. A `task.create`
  carrying `dependencies: false` returned `{:ok, ...}`, stored `false` on
  the event, projected `[]`, and approved and dispatched with no dependency
  check at all — the same inertness this guard closes, re-entered through
  malformed input. Verified by probe before and after, not reasoned about.
  The projection now PRESERVES a non-list so the guard can refuse it;
  flattening bad data into a valid-looking default is what caused this.

  This check did not exist until it was added deliberately, and the way
  it was missing is instructive. `task.create` accepted `dependencies`
  (`task.ex:93`), `CommandGateway` defaulted it (the `task.create` clause
  of `enrich_operator_command/1`),
  the aggregate stored it (`task.ex:37,69`) and `TaskCreated` carried it
  (`task_created.ex:37`) — but `Task.require_dispatchable/1`
  (`task.ex:461-470`) reads only `status`, `run_id` and `approval_id`, and
  `ProjectionStore`'s `TaskCreated` handler dropped the field entirely. So
  the whole path existed except the read, and a task declaring
  dependencies dispatched immediately regardless of them. Do not treat the
  presence of a field on a command, an aggregate and an event as evidence
  that anything consumes it — the same lesson as `FOREMAN_ARTIFACT_PATH`
  and `foreman_queue_status`.

  It is a GUARD, not a dependency DAG: no ordering, no cycle detection,
  and no automatic dispatch when the last dependency closes. The operator
  re-approves. It lives in `CommandGateway` rather than the aggregate
  because it is inherently cross-aggregate — `Task` can see only its own
  state — and `ProjectionStore` is the read model built for that, which
  the `task.create` clause already uses for `project_projection/1`.
  Relatedly, `Task.apply_event/2` has a `TaskDependencyAdded` clause
  (`task.ex:150`) that NOTHING emits: only eight `task.*` commands are
  handled and none produces that event, so dependencies can be set at
  creation and never afterwards. Left in place rather than deleted, but do
  not read it as a working mutation path.
- Approval does **not** re-check the project's archived status —
  unlike `task.create` (`command_gateway.ex:236-239`,
  `task.ex:512-518`), no project-archived check runs on the
  `task.approve` path. No `task_provider` configuration is required
  either; that block only matters for provider-tracked (Beads-linked)
  tasks, and ad-hoc tasks approve without one.

#### 3. Monitor a task

```bash
foreman task get <task-id>
foreman run get <run-id>
foreman run list
```

Task statuses: `open` (created), `ready` (approved, waiting for dispatch), `in_progress` (running), `completed`, `failed`, `cancelled`.

#### 4. Cancel a task/run

```bash
foreman run cancel --id <run-id> --reason "reason"
foreman run remove --id <run-id>
foreman run reset --id <run-id>
foreman task retry --id <task-id> --reason "safe to rerun"  # once the bound run is terminal
```

### Go CLI Commands

```bash
foreman task create --project <id> --title <title> [--workflow-type ...] [--trd-path ...]
foreman task approve --id <task-id> [--approved-by <name>]
foreman task retry --id <task-id> [--reason <text>]
foreman task get <id>        # Fetch task projection
foreman run list             # List run projections
foreman run get <id>         # Fetch run projection
foreman run cancel --id <id> --reason <text>
foreman run remove --id <id> # Remove run and clean worktree/branch
foreman run reset --id <id>  # Clear failed/stuck run projection
foreman project list         # List projects
foreman project get <id>     # Fetch project

# Workflow install (one-time bootstrap per machine)
foreman workflow install
```

### Workflows

Bundled workflows live in `packages/foreman_server/priv/defaults/workflows/`:

| Workflow | Select via | Description |
| --- | --- | --- |
| `assess` | `--workflow-type assess` | Analyze impact, constraints, and risks before implementation begins. |
| `discover` | `--workflow-type discover` | Scope the request and collect the repository context needed for execution. |
| `fix` | `--workflow-type fix` | Fix an issue via the ensemble fix workflow. |
| `implement` | `--workflow-type implement` | Generate and refine the code changes required for the task. |
| `implement-trd` | `--workflow-type implement-trd` | Implement a TRD using the ensemble skill. |
| `implement-trd-beads` | `--workflow-type implement-trd-beads` | Implement a TRD using Beads-backed ensemble skill with Kata/pi agent. |
| `plan` | `--workflow-type plan` | Run the plan workflow (create-prd → create-trd). |
| `prd` | `--workflow-type prd` | Full ensemble chain: create-prd, refine-prd, create-trd, refine-trd, implement-trd. |
| `release` | `--workflow-type release` | Finalize outputs, publish deliverables, and complete release steps. |
| `trd` | `--workflow-type trd` | Create a TRD from a PRD and implement it via the ensemble chain. |
| `verify` | `--workflow-type verify` | Run validation, testing, and quality checks for the completed work. |

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL (exits 0 even when it exports nothing)
br sync --status      # Check sync status — the ONLY place COVERAGE DRIFT is reported
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Run the **Session Protocol** block as a single fail-closed script
   (`set -euo pipefail`), not as separate steps — the flush alone reports
   success while exporting a fraction of the DB, and a FAILED flush leaves an
   older certified JSONL that still passes the gate, which compares row counts
   rather than content. Stage `.beads/issues.jsonl` after the flush, never
   before: `br` rewrites it on every mutation.

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
set -euo pipefail       # a failed flush MUST stop the session, not fall through to the gate
git status              # Check what changed
br sync --flush-only    # Export beads changes to JSONL — WRITES .beads/issues.jsonl
br sync --status --json | jq -e '.coverage_drift == false'   # REQUIRED gate, see below
git add <files> .beads/issues.jsonl                         # Stage AFTER the flush, never before
git commit -m "..."     # Commit everything
git push                # Push to remote
```

**Two ordering rules, both learned the hard way in this repo.**

*Stage after flushing.* `br` writes `.beads/issues.jsonl` — not only on an
explicit flush but on EVERY mutation, since auto-flush is on by default
(`--no-auto-flush` opts out). Staging before the flush therefore commits code
while leaving the export unstaged, which happened repeatedly across this
session's commits and had to be corrected by hand each time.

*Fail closed on the flush.* The two commands are independent, so without
`set -euo pipefail` a FAILED flush falls straight through to a gate that can
still pass — because `coverage_drift` compares COUNTS
(`db_exportable_issues` vs `jsonl_unique_ids`), not content. An older export
with all the right ids but stale bodies satisfies it. The gate catches MISSING
ROWS, which is the 23%-export failure below; it cannot catch a stale row, so
the flush actually has to succeed.

One caveat on verifying that, because it bit the check itself: `set -e` is
DISABLED inside a compound command that forms part of a `&&`/`||` list, so
`( set -euo pipefail; br sync --flush-only; ... ) || echo failed` silently
runs the gate anyway. Confirmed both ways — as a real script the failing flush
aborts at exit 1 and the gate never runs; wrapped in `|| true` the following
line executes regardless. Run the block as a script, not as a `||`-guarded
subshell.

**`br sync --flush-only` is not self-verifying, and the coverage gate is not
optional.** The flush prints `Nothing to export (no dirty issues)` and exits
**0** whenever the JSONL's certified hash matches the file on disk — even when
that certified file holds a fraction of the database. `br` tracks the export in
`metadata` (`needs_flush`, `jsonl_content_hash`, `jsonl_size`), so once a
partial JSONL is certified, every later flush is a successful-looking no-op and
the shortfall is invisible to the one command this protocol used to mandate.

This is not hypothetical and it is not a small margin. In this workspace
`issues.jsonl` — the git-tracked source of truth — carried **174 of 752 issues
and 268 of 1122 dependencies**, and had done so across at least the last 8
commits that touched it, while `br sync --flush-only` reported success every
time. Reproduced deliberately in a sandbox: certify a 100-row JSONL against a
754-issue DB and the flush answers "Nothing to export" at exit 0, leaving 654
issues unexported indefinitely.

The danger is that the JSONL is what a rebuild reads. `br sync --merge
--force-jsonl` (and `--import-only --rebuild`) treat it as authoritative, so
running the documented recovery against a silently-partial export DESTROYS
every issue missing from it — here that would have been ~580 issues, ~39 of
them open. Always compare row counts before any JSONL-authoritative recovery;
see `skill://beads-corrupt-db-recovery-safe`.

Detection exists, but in commands the protocol never told you to run:
`br sync --status` prints `COVERAGE DRIFT — JSONL has N unique ids but the
database holds M exportable issues` (exit **0** — do not gate on its status
code), `br sync --status --json` exposes `coverage_drift` plus
`coverage.db_exportable_issues` / `coverage.jsonl_unique_ids`, and `br doctor`
reports `degraded` and exits **1**. The `--json` form is the gate to automate
on because it is the only one that is both machine-readable and specific to
this failure.

On drift, reconcile — do NOT reflexively `--force`:

```bash
br sync --reconcile --dry-run   # lossless preview of what each side holds
br sync --flush-only --force    # DB-authoritative: only after confirming the DB is complete
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session — and verify the export covered the DB, because a flush that exported nothing still exits 0

---

## Architecture

### Stack

- **ForemanServer.Aggregate**: behaviour defining `initial_state/0`,
  `handle_command/2`, `apply_event/2` callbacks
- **ForemanServer.Aggregate.Actor**: supervised GenServer holding in-memory
  aggregate state and stream version; routes commands through `CommandRouter`
- **CommandRouter**: single append point for all domain events
- **EventStore** (via Commanded adapter): event persistence
- **Postgrex**: Postgres driver
- **Phoenix**: HTTP API boundary for Go CLI

### Command Flow

```
Go CLI
    │
    ▼
Phoenix POST /api/commands
    │
    ▼
CommandRouter.dispatch(command)  ◄── CommandRouter.dispatch/1
    │
    ▼
Aggregator.start_aggregate(module, id)  ◄── starts Actor if not running
    │
    ▼
Actor.handle_call(:command, cmd)  ◄── Actor calls aggregate directly
    │
    ▼
aggregate.handle_command(state, cmd)  ◄── handle_command/2 returns event spec
    │
    ▼
Actor sends event spec to CommandRouter  ◄── send CommandRouter, {:append, ...}
    │
    ▼
EventStore.append_to_stream  ◄── CommandRouter is sole append point
    │
    ▼
CommandRouter sends {:append_ok, count} back to Actor  ◄── append confirmed
    │
    ▼
Actor calls aggregate_module.apply_event/2  ◄── state updated after confirm
```

### Actor Lifecycle

`Aggregator` manages actors with `restart: :permanent`:

- **Startup**: `Actor.init` calls `Aggregate.load/2` which replays the event stream
  via `apply_event` before processing any command.
- **Normal operation**: actor receives command, calls `handle_command`, sends event spec
  to `CommandRouter`, awaits append confirmation, then calls `apply_event` to update state.
- **Conflict recovery (bounded retry)**: on `{:error, :wrong_expected_version}` the actor
  reloads state via `Aggregate.load/2`, re-decides via `handle_command/2`, and retries the
  append with the new `expected_stream_version`. Retry is bounded by
  `@max_conflict_retries` (default 3). On exhaustion the actor returns
  `{:telemetry, {:error, :wrong_expected_version}, %{append_latency_ms: latency}}` and
  leaves state unchanged. A re-decision that returns `{:error, _}` (e.g.
  `:phase_terminal`) terminates the retry without appending.
- **Crash + eager restart**: `Aggregator` supervisor restarts the actor immediately
  (`restart: :permanent`). Restarted actor rehydrates via `Aggregate.load/2` before
  processing the next command.

### Aggregate State Design

**Every aggregate's fixed top-level state MUST be a dedicated `%Aggregate.State{}`
struct. Maps are permitted only as nested genuinely dynamic values.**

```elixir
defmodule ForemanServer.Aggregates.Run do
  defmodule State do
    defstruct [:exists?, :run_id, :status, :terminal?,
               phase_status: %{}, worker_status: %{}, retry_history: []]
  end

  @impl true
  def initial_state, do: %State{exists?: false, run_id: nil, status: nil, ...}
end
```

**Why:** Plain maps (`%{exists?: false, ...}`) admit atom/string key drift and
silently accept unknown fields. `Map.merge(state, payload)` in `apply_event`
can add undeclared keys with no warning, causing silent schema drift across
replay. Struct-update syntax (`%State{state | field: value}`) rejects
undeclared fields at compile time (literal unknown atoms) or runtime (`KeyError`
for unknown variable fields). `struct/2` silently ignores unknown keys and
MUST NOT be used.

**Maps for dynamic collections are fine.** Fields like `phase_status`,
`worker_status`, `config`, or `retry_history` — where the shape is genuinely
open or comes from heterogeneous event payloads — may remain maps.

**Status: complete.** Every aggregate under `lib/foreman_server/aggregates/`
declares its own `State` struct and updates it with `%State{state | ...}`. This
is now a standing rule for new aggregates, not outstanding migration work — do
not add an aggregate whose state is a plain map.

**Enforcement rules:**

- `apply_event` uses `%State{state | field: value}` — not `Map.merge(state, payload)`,
  not `struct(state, field: value)`.
- Explicit per-event field mapping: `event_type → state field` is written out
  per event type.
- `initial_state/0` returns the State struct with required fields set to defaults.
- **`handle_command` enforces domain invariants.** Struct construction alone does
  not validate state preconditions or valid transitions.

### Phoenix Is the Sole HTTP Ingress

Phoenix receives all HTTP commands from Go CLI via `POST /api/commands`.
Phoenix dispatches to `CommandRouter.dispatch/1`. No other module (worker, Go CLI,
or other Elixir code) writes to the event store directly. All mutations route
through Phoenix → CommandRouter.

### Architecture Test

An ExUnit architecture test (`EventStore.Enforcement`) scans all `.ex` source files
under `lib/foreman_server/` for direct operational calls to `append_to_stream` or
adapter dispatch functions. Module declarations (`defmodule … do; use EventStore`,
`otp_app:` config) are allowed. Any match causes the test to fail.

### CQRS Invariant

- **Commands** mutate state via `CommandRouter`. All state mutations go through
  Phoenix → CommandRouter.
- **Queries** read from the projection store (read model). No writes on the query path.

### Workflow Catalog Hot-Reload

`ForemanServer.Workflow.Catalog` is a supervised GenServer that owns every
parsed workflow manifest and prompt body in memory and keeps them in sync
with the on-disk root.

- **Auto-install** — `init/1` calls
  `ForemanServer.WorkflowTemplate.Installer` only when the configured root
  contains no `*.yaml` manifests. A populated `prompts/` directory does
  **not** suppress the install; the installer uses `File.cp/2` and
  `File.write/2` and will overwrite any same-named prompt already on
  disk. Keep custom templates under their own filenames.
- **Synchronous load** — every manifest is parsed via
  `ForemanServer.Workflow.Interpreter.load/1` during `init/1` so the first
  command after boot finds the catalog ready. Every `*.md` under
  `prompts/` is loaded the same way.
- **Hot reload** — a periodic poll (default 2s, override via
  `Application.put_env(:foreman_server, :workflow_catalog_poll_ms, ms)`)
  re-hashes every manifest and prompt and replaces any entry whose content
  or mtime changed. Files that vanish are removed from the catalog.
- **Prompt read API** — `Catalog.read_prompt/1` returns the latest prompt
  body. `RunExecutor.read_phase_prompt/2` reads through the catalog so a
  prompt edit is picked up on the next phase.

Telemetry:
`[:foreman_server, :workflow, :installed]`,
`[:foreman_server, :workflow, :manifest, :loaded | :reload, :ok | :reload, :error | :removed]`,
`[:foreman_server, :workflow, :prompt, :loaded | :reload, :ok | :reload, :error | :removed]`.

---

## Domain Events

All authoritative state transitions are domain events persisted in `foreman_events`.
Every event is emitted by an aggregate `handle_command/2` function routed through
`CommandRouter` — no module emits events directly.

**Source of truth: `lib/foreman_server/events/`.** `ForemanServer.EventCodec`
derives its registry from that directory at compile time, so
`EventCodec.registered/0` always lists every event. The table below is a
**curated subset** for orientation, not an inventory — it is deliberately not
exhaustive (there are currently 66 event structs). Do not treat a missing row
as "this event does not exist", and do not try to keep the table in one-to-one
sync; per **§5.5**, a hand-maintained second list is the defect, not the fix.

| Event | Emitted by | Effects |
| --- | --- | --- |
| `ProjectRegistered` | `Project.handle_command/2` | Creates project projection |
| `ProjectUpdated` | `Project.handle_command/2` | Updates project projection |
| `ProjectArchived` | `Project.handle_command/2` | Archives project projection |
| `TaskCreated` | `Task.handle_command/2` | Creates task projection |
| `TaskApproved` | `Task.handle_command/2` | Transitions task to ready, triggers dispatch |
| `TaskRetried` | `Task.handle_command/2` | Resets task for retry |
| `TaskRunTerminated` | `Task.handle_command/2` | Marks task run-level terminal |
| `TaskDispatched` | `Dispatcher` | Records dispatch on task |
| `ProjectRunReserved` | `Project.handle_command/2` | Implementation key reservation |
| `RunStarted` | `Run.handle_command/2` | Creates run projection, spawns worker |
| `RunCancelled` | `Run.handle_command/2` | Marks run cancelled |
| `RunDeleted`\* | `Run.handle_command/2` | Marks run removed and triggers cleanup fan-out |
| `RunReset`\* | `Run.handle_command/2` | Clears failed/stuck run projection state for fresh submission |
| `RunCompleted` | `Run.handle_command/2` | Marks run terminal success |
| `RunFailed` | `Run.handle_command/2` | Marks run terminal failure |
| `RunFlaggedStuck` | `StuckDetector` | Flags run as stuck |
| `WorktreeCreated` | `Run.handle_command/2` | Worktree created |
| `WorktreeCleaned` | `Run.handle_command/2` | Worktree cleaned |
| `WorktreeCreateOrphanRecorded` | `Run.handle_command/2` | Records orphan worktree at creation |
| `WorktreeCreateOrphanResolved` | `Run.handle_command/2` | Resolves orphan worktree |
| `PrAssociated` | `PrAssociation.handle_command/2` | Records the PR URL on the run projection and in the `pr_associations` map |
| `PrMerged`\* | `Run.handle_command/2` | Aggregate replay only (no `ProjectionStore` handler found) — treat as unverified read-model effect |
| `PhaseStarted` | `Phase.handle_command/2` | Updates run phase |
| `PhaseCompleted` | `Phase.handle_command/2` | Updates run phase |
| `WorkerHeartbeat` | `worker.event` command | Updates worker projection |
| `ToolCallFinished` | `ToolCall.handle_command/2` | Records the tool-call decision (approve/deny in one event) |
| `VcsOperationStarted` / `VcsOperationCompleted` / `VcsOperationFailed` | `VcsOperation.handle_command/2` | Records VCS operation lifecycle (three events, not one) |
| `BeadsDbLeaseAcquired` | `BeadsDbLease.handle_command/2` | Holder takes the per-DB Beads lease |
| `BeadsDbLeaseReleased` | `BeadsDbLease.handle_command/2` | Holder releases the lease (no waiters) |
| `BeadsDbLeaseWaiterRegistered` | `BeadsDbLease.handle_command/2` | Runner enqueued behind current holder |
| `BeadsDbLeaseWaiterRemoved` | `BeadsDbLease.handle_command/2` | Cancel-before-promotion of a waiter |
| `BeadsDbLeaseTransferred` | `BeadsDbLease.handle_command/2` | Release + head-waiter promotion in one event |

\* `RunDeleted` and `RunReset` (and `PrMerged` above) have no corresponding
struct file under `lib/foreman_server/events/` — `grep -rn "defmodule.*RunDeleted\|defmodule.*RunReset\|defmodule.*PrMerged" lib/`
returns nothing. They are emitted as raw `%{event_type: "RunDeleted", ...}`
maps and consumed by `Run.apply_event/2`'s and `ProjectionStore`'s string-keyed
`case`/`apply_event_by_type` clauses, not via `EventCodec`. This contradicts
the "every event is a typed struct" claim directly below — do not assume it
holds for every row in this table; verify against `lib/foreman_server/events/`
before relying on it.

#### Typed Event Structs

Every domain event *should* be a typed struct in `lib/foreman_server/events/`
with `@enforce_keys` and `@type t`, decoded via `EventCodec.decode!/2` before
`apply_event` pattern-matches it — this is the contract for external
decode/replay paths that go through `EventCodec` (e.g. `ProjectionStore`
rebuild from a cold projection). It is **not** universally true internally:
`Aggregate.load/2` (`aggregate.ex:180-193`) calls `module.apply_event(state,
event)` directly on raw event-store maps with no `EventCodec.decode!` call at
all, so an aggregate's own `apply_event/2` can — and in `Run`'s case, for
`RunDeleted`/`RunReset`/`PrMerged`, does — pattern-match untyped `event_type`
strings that have no registered struct. `%EventData{}` / `%RecordedEvent{}`
are persistence envelopes only — they are not domain types. `EventData.data`
/ `RecordedEvent.data` holds the serialized domain struct where one exists.

Canonical event struct (`@derive` before `defstruct`):

```elixir
defmodule ForemanServer.Events.RunCompleted do
  @enforce_keys [:run_id, :sequence]
  @type t :: %__MODULE__{run_id: String.t(), sequence: non_neg_integer(), status: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:run_id, :sequence, status: nil]
end
```

`apply_event` pattern-matches the typed struct directly:

```elixir
def apply_event(state, %RunCompleted{run_id: run_id, sequence: seq}) do
  %State{state | status: "completed", terminal?: true, run_id: run_id, last_sequence: seq}
end
```

`EventCodec.decode!/2` is the replay contract. It reconstructs typed structs from
deserialized data with uniform API `decode!(event_type, data)`: typed structs pass through,
JSON maps are validated and rebuilt. Both paths reject a struct whose module does not
match the `event_type` string. Maps are reserved for genuinely open nested data inside
the event. They MUST NOT replace the typed event struct itself.

**Registration is automatic — never hand-maintained.** `EventCodec` builds both
its `event_type → module` registry and its enforced-key lookup at compile time
by scanning `lib/foreman_server/events/`. Adding a struct file registers the
event; deleting the file removes it. Each source is an `@external_resource`, and
`__mix_recompile__?/0` forces a rebuild when a file is added or removed, so the
registry can never go stale.

Adding a new event is therefore one file and no registry edits:

```elixir
defmodule ForemanServer.Events.ThingHappened do
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{run_id: String.t(), detail: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:run_id, detail: nil]
end
```

This replaced two parallel hand-written maps that had already drifted: 15 of 66
event structs — `ProjectRegistered`, `ProjectUpdated`, `ProjectArchived`,
`PrAssociated`, `MergeGate*`, `ScheduledFire*`, `SchedulerIntentStale`,
`RunAlreadyCompleted`, `RunRecoveryEvent`, and all three `VcsOperation*` — were
present on disk but absent from the registry, so decoding them raised
"unregistered event_type" even though the struct existed and was documented.
Do not reintroduce a second list.

---

## Idempotency and Concurrency

**Idempotency**: `CommandRouter` deduplicates by `command_id`. Duplicate commands
produce no additional events. Domain idempotency (e.g. rejecting a second
`run.complete` on an already-completed run) is implemented in each aggregate's
`handle_command/2`.

**Optimistic Concurrency**: Every append uses `expected_stream_version`. If the
stream has moved past the expected version, append fails with `{:error, :wrong_expected_version}`.
The Actor's bounded retry path intercepts the conflict, reloads the aggregate state via
`Aggregate.load/2`, re-decides via `handle_command/2`, and retries with the new version
(see **Actor lifecycle → Conflict recovery**). On retry exhaustion the actor returns
`{:error, :wrong_expected_version}` and state is unchanged; on a re-decision that
rejects (e.g. `:phase_terminal`) the retry terminates without appending — preserving
exactly-once.

**Per-DB Beads lease (write serialization across processes and restarts)**: SQLite's
single-writer protocol cannot tolerate concurrent br/bv writers or writers running
alongside `bv --robot-plan`. The `BeadsDbLease` aggregate is an event-sourced lock
keyed by the configured absolute Beads DB path passed at acquire time, giving
process-local serialization through the Actor mailbox while surviving Foreman
restarts via persisted events. Required because multi-`run_id` parallelism on the
same DB otherwise deterministically raises
`cannot connect to database: locking protocol (15)`. Callers must pass the same
absolute path on every dispatch — symlink aliasing (e.g. `/tmp/...` vs
`/private/tmp/...`) is NOT collapsed and will register separate lease streams.

- **Stream id**: `beads_db_lease:<db_path>` (literal path; see warning above).
- **Acquire**: `lease.acquire` is atomic — if the DB is free, the run becomes holder;
  if held, the run is enqueued as a waiter and admission returns `:queued`.
- **Release**: `lease.release` and `lease.remove_waiter` are dispatched at run
  terminal time (`RunCancelled`, `RunDeleted`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
  `RunBlocked`) by the Dispatcher. Both are idempotent no-ops when the run_id is not
  bound to the lease.
- **Promotion**: when the holder releases with waiters, the aggregate emits a single
  `BeadsDbLeaseTransferred` event that releases the old holder and promotes the
  head waiter, so cancellation cannot race with promotion. The Dispatcher subscribes
  to this event and re-enters `RunAdmission.start/2` for the promoted run.
- **Fail-closed gating**: `RunAdmission.start/3` reads the lease decision before
  starting the run supervisor. Any uncertainty (acquire error, atom state of
  `:unknown` or `:unexpected`) returns `{:error, ...}` and skips dispatch. A
  `:queued` decision returns without starting the supervisor; the dispatcher picks
  the run up again on `BeadsDbLeaseTransferred`.
- **Compensation**: `lease.release` on admission failure is only emitted for
  definitively non-retryable rejections (`{:missing_or_invalid, …}`,
  `{:implementation_already_active, …}`, `{:command_rejected, …}`). Compensating
  transient errors would break retry semantics.
- **Scope**: different DBs and direct (`foreman run`) workflows remain parallel.
  The lease keys only on the DB path, never on the run_id.
- **Scope limitation (important)**: the lease governs only admission through
  Foreman. External `br` writers and `bv --robot-plan` invocations launched
  outside Foreman are NOT protected — they must observe single-writer
  discipline themselves. `br_bv_lease_concurrency_test.exs` verifies the
  admission contract; upstream concurrency (e.g. an operator running `br`
  directly while Foreman holds) is the operator's responsibility. The lease
  exists to prevent two Foreman-dispatched runs from racing on the same DB,
  not to mediate file-system access against unrelated processes.

- **Universal backstop**: all `br` invocations through `SystemBrRunner.cmd/3` are
  additionally serialized per `database_path` via `:global.trans/2` as a universal
  backstop. This catches every call site (create, list_ready, update, get, reopen,
  set_priority, ready, coordination_status, and any future callers) without requiring
  `with_lease` wrapping at each one. Covered by `system_br_runner_test.exs`
  concurrency serialization regression test.

---

## Go CLI Boundaries

The Go CLI never writes to:

- The event store directly
- The projection store directly
- Any Elixir internal state

The Go CLI only:

- Sends commands via `POST /api/commands`
- Queries read models via `GET /api/...`
- Formats and displays output

---

## Test Architecture

- **Unit tests**: aggregate handlers — `handle_command/2` → event spec, valid transitions
- **Integration tests**: aggregate startup, mailbox serialization, crash/restart/rehydration
- **Architecture tests**: no direct `append_to_stream`/adapter calls in `lib/foreman_server/`
- **Projection tests**: known event sequence → rebuild → verify read model matches

---

## TaskProvider System

The `TaskProvider` behaviour (`ForemanServer.TaskProvider`) defines the contract for
issue tracker adapters. The existing production adapter is `BeadsAdapter` (backed by
`beads_rust` / `br` CLI). A second adapter, `KataAdapter` (backed by the
`kata` CLI), is designed but not yet implemented — no `task_providers/kata_*`
files exist under `lib/`; see `docs/TRD/TRD-2026-8030852f-foreman-kata-task-provider.md`
(status: Draft) for the plan.

### TaskProvider Behaviour Callbacks

```elixir
@callback name() :: String.t()
@callback provider_id() :: atom()
@callback contract_version() :: String.t()
@callback capabilities() :: map()
@callback available?() :: boolean()
@callback list_ready(project_id :: String.t(), opts :: keyword()) :: {:ok, [Issue.t()]} | {:error, ProviderError.t()}
@callback get(issue_id :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback claim(issue_id :: String.t(), actor :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback complete(issue_id :: String.t(), opts :: keyword()) :: {:ok, Issue.t() | :terminal} | {:error, ProviderError.t()}
@callback fail(issue_id :: String.t(), reason :: String.t(), opts :: keyword()) :: {:ok, :reopened} | {:error, ProviderError.t()}
@callback reopen(issue_id :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback annotate(issue_id :: String.t(), body :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback set_priority(issue_id :: String.t(), priority :: 0..4, opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback set_assignee(issue_id :: String.t(), actor :: String.t() | nil, opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback list_dependencies(issue_id :: String.t(), opts :: keyword()) :: {:ok, [String.t()]} | {:error, ProviderError.t()}
@callback add_dependency(issue_id :: String.t(), depends_on :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback remove_dependency(issue_id :: String.t(), depends_on :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback create(attrs :: map(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
```

### Registry

`ForemanServer.TaskProvider.Registry` is a supervised GenServer that owns registered
providers and exposes `routing_snapshot/0` for capability-aware routing.

---

## Implementation Context

`ForemanServer.Workflow.ImplementationContext` freezes deterministic state at approval time:

- `trd_path`: Normalized project-relative path to the TRD blob
- `trd_path_argument`: JSON-quoted shell argument for the skill
- `project_root`: Absolute project root path
- `source_revision`: Exact git SHA resolved from `git rev-parse HEAD`
- `implementation_key`: `SHA256(project_id <> "\0" <> normalized_trd_path)` — used for single-flight enforcement
- `beads_database_path`: For `implement-trd-beads` workflows, the absolute Beads DB path from the TaskProvider registry

These fields are reserved server-derived values. Operator payload and phase YAML context
cannot override them.

---

## Execution Safety Rules

- Before rerunning a task to validate a fix, ensure the fix is durably committed and available on the active branch being tested.
- Treat "implemented" as meaning: relevant tests/build passed and the work has a concrete commit hash on the branch/workspace that will be used for the rerun.
- Do not benchmark or rerun tasks from a dirty or ambiguous controller workspace state.
- If a task reset, branch cleanup, or workspace cleanup is about to happen while important work is only in the working copy, checkpoint it first via commit or patch export.

Task-provider boundary reminder: RunExecutor drives claim/complete/fail;
BootReconciliation drives orphan-reopen.

<!-- bv-agent-instructions-v3 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking and [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) (`bv`) for graph-aware triage. Issues are stored in `.beads/` and tracked in git. Current `br` workspaces normally export `.beads/issues.jsonl`; older `bd`/legacy workspaces may use `.beads/beads.jsonl`. `bv` auto-discovers the supported JSONL files, so agents should use `br`/`bv` commands instead of hard-coding a single filename.
**Foreman owns this repo's task queue.** All task lifecycle — create, approve,
retry, get, cancel — goes through `foreman task *` commands. Beads (`br`/`bv`)
is triage/discovery only. **Never fall back to `br create` when `foreman task create`
fails** — treat Beads corruption as a blocker to resolve, not a bypass signal.
### Using bv as an AI sidecar

bv is a graph-aware triage engine for Beads projects. Instead of parsing .beads/issues.jsonl / .beads/beads.jsonl directly or hallucinating graph traversal, use robot flags for deterministic, dependency-aware outputs with precomputed metrics (PageRank, betweenness, critical path, cycles, HITS, eigenvector, k-core).

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). `br` handles creating, modifying, and closing beads.

**CRITICAL: Use ONLY --robot-* flags. Bare bv launches an interactive TUI that blocks your session.**

#### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns everything you need in one call:

- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command

# Token-optimized output (TOON) for lower LLM context usage:
bv --robot-triage --format toon
```

Before claiming, verify current state with `br show <id> --json` or `br ready --json`. `recommendations` can include graph-important blocked or assigned work; only `quick_ref.top_picks` and non-empty `claim_command` fields represent claimable work.

#### Other bv Commands

| Command | Returns |
| --------- | --------- |
| `--robot-plan` | Parallel execution tracks with unblocks lists |
| `--robot-priority` | Priority misalignment detection with confidence |
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core |
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Hygiene: duplicates, missing deps, label suggestions, cycle breaks |
| `--robot-diff --diff-since <ref>` | Changes since ref: new/closed/modified issues |
| `--robot-graph [--graph-format=json\|dot\|mermaid]` | Dependency graph export |

#### Scoping & Filtering

```bash
bv --robot-plan --label backend              # Scope to label's subgraph
bv --robot-insights --as-of HEAD~30          # Historical point-in-time
bv --recipe actionable --robot-plan          # Pre-filter: ready to work (no blockers)
bv --recipe high-impact --robot-triage       # Pre-filter: top PageRank scores
```

### Task Lifecycle (Foreman)

```bash
foreman task create --project <id> --title <title> [--workflow-type ...] [--trd-path ...]
foreman task approve --id <task-id> [--approved-by <name>]
foreman task retry --id <task-id> [--reason <text>]
foreman task get <id>        # Fetch task projection
foreman run list             # List run projections
foreman run get <id>         # Fetch run projection
foreman run cancel --id <id> --reason <text>
foreman run remove --id <id> # Remove run and clean worktree/branch
foreman run reset --id <id>  # Clear failed/stuck run projection
```

### Triage & Discovery (br/bv)

`br`/`bv` do NOT manage this repo's work queue. Use them only for triage and discovery.

```bash
bv --robot-triage              # Triage: ranked recommendations, blockers, quick wins
bv --robot-next                # Minimal: top pick + claim command
bv --robot-plan                # Parallel execution tracks with unblocks
bv --robot-insights            # Full metrics: PageRank, betweenness, cycles
bv --robot-alerts              # Stale issues, blocking cascades
bv --robot-suggest            # Hygiene: duplicates, missing deps, cycles
bv --robot-diff --diff-since <ref>  # Changes since ref

br ready --json                # Show issues ready to work (no blockers)
br list --status=open --json  # All open issues
br show <id> --json           # Full issue details with dependencies
br sync --flush-only          # Export DB to JSONL after Beads mutations
br sync --status --json       # VERIFY: `coverage_drift` must be false
```

### Workflow Pattern

1. **Triage**: Run `bv --robot-triage` to find the highest-impact actionable work
2. **Claim**: Create via `foreman task create --project <id> --title <title> --workflow-type <type>`
3. **Dispatch**: Use `foreman task approve --id <task-id> --approved-by <name>`
4. **Complete**: Task auto-closes when run completes; retry via `foreman task retry --id <id> --reason "..."` if run was cancelled
5. **Sync**: Run the **Session Protocol** block as a single fail-closed script
   (`set -euo pipefail`), not as separate steps — the coverage gate must run
   ONLY after a flush that actually succeeded, since a failed flush leaves an
   older certified JSONL that still satisfies `coverage_drift == false` (it
   compares row counts, not content). Stage `.beads/issues.jsonl` after the
   flush, never before: `br` rewrites it on every mutation.

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready --json` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Git Policy

`br` never commits or pushes. Follow this repository's own git instructions before staging, committing, or pushing. If the repository says "commit only when asked," that rule overrides any generic workflow advice.

<!-- end-bv-agent-instructions -->

## Durable Run Logs and MCP Run Status

`foreman_run_status` is a bounded DTO built from `ProjectionStore.run/1` and
`ProjectionStore.phases_for_run/1`; do not rebuild it from logs or raw event
streams, and keep `foreman_run_get`'s full projection shape distinct.

`foreman_run_get_logs` is backed by worker events and `ProjectionStore`.
Only `WorkerProtocol.emit(:worker_stdout | :worker_stderr, ...)` may produce
persistent run log entries. Do not copy ordinary server `Logger` output into run
logs, and do not return empty success for an unknown run — that is `NOT_FOUND`.

**`Overwatch.Tracker` folds `"event_type"` into the payload it persists, so a
persisted worker event does NOT round-trip through `EventCodec.decode!/2`.**
`dispatch_lifecycle/3` builds `%{"event_type" => type, "worker_id" => …,
"run_id" => …, "sequence" => …}` and merges it over the caller's payload
(`tracker.ex:314-324`), while no struct under `ForemanServer.Events` declares an
`event_type` field and the codec rejects undeclared keys. The worker handlers
that predate durable logs read those payloads with `get/2` and never decode
them, so nothing had ever hit this. The first typed handler to decode one —
`WorkerStdout` / `WorkerStderr` — raised `ArgumentError` inside
`rebuild_state_from_event_log/1`, which runs in `ProjectionStore.init/1`: the
store failed to start and took the entire application down at boot for any
event store holding a single worker log event. `decode_for_projection/2` now
strips `event_type` alongside the `_projection_*` keys, at that one boundary, so
the next typed handler cannot rediscover it.

The lesson is the one section 5.5 already states: this was not a subtle bug, it
was an unexecuted one. The implementation was written, committed, and reviewed
as complete without the application ever being started against it.

## Known Issues

### Elixir Test Suite Non-Determinism (2026-09-02)

`mix test` produces 38-43 failures on identical `--seed 1234` runs. **Hypothesis:**
shared singleton GenServer state (ProjectionStore, TaskProvider.Registry, RunSlots) mutated via
`:sys.replace_state`/`persistent_term` across async/sync test boundaries. **Ruled out:** cross-run EventStore pollution (EventStore reset in `test_helper.exs` had no effect on flakiness).

Investigation and remediation options:
1. Per-file `setup :reset_singletons` calls for ~20-30 problematic files
2. Disable `async: true` on leaking test files
3. Investigate async/sync interleaving of shared singletons, then implement the required isolation fix
Do NOT run `br sync --force-jsonl` against a drifted workspace — has destroyed issues here before.
See ``skill://beads-corrupt-db-recovery-safe`` for safe recovery procedure.
