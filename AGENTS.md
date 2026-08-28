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

The real mechanism is `ForemanServer.Workflow.AutoPR.maybe_create_pr/1`, called
from `RunExecutor.finalize_run/1` after the task provider confirms completion.
It derives the PR from run state rather than from agent output: the head branch
comes from `state.last_worktree.branch` (retained by
`RunExecutor.remember_worktree/2`), the decision is gated on
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
`phase_lineage_base_ref/2` resolves phase 1's `base_ref` from `HEAD` of that
checkout, so branch name and base commit describe one repository state. It is
latched on key presence, so an operator switching branches mid-run cannot
retarget the PR, and it does not hang off `remember_worktree/2` — a phase
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

`base_ref` is the commit the phase's checkout was created at:
`Worktree.create/1` pins the worktree to it and both
`create_phase_worktree/4` and `create_default_worktree/3` carry it back on the
worktree record, so `capture_planning_document/4` reads it from run state with
no new event. The invariant that makes this deterministic is one the pipeline
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

`plan.yaml` declares no `worktree:` block, so each phase gets the default-on
worktree. `create_default_worktree/3` resolves that worktree's base through
`phase_lineage_base_ref/2` (`run_executor.ex:1391`, called at `:1307`): the base
is the PREVIOUS phase's branch tip, taken from the `state.last_worktree` that
`remember_worktree/2` already retains for AutoPR, and it falls back to `HEAD`
only when there is no predecessor — the first phase of a run. A predecessor
branch that will not resolve fails
`{:phase_lineage_branch_unresolvable, branch, reason}` (`:1402`) rather than
degrading to `HEAD`, because a silent fall back to the base branch is precisely
the "plausible-looking success" that produces a phase 2 built on the wrong tree.
That is the mechanism, verified in code.

Keep three tiers of proof distinct here, because collapsing them in either
direction is how this section's worst errors were made. **Proven by code:** the
base selection above. **Proven by test against real git, no filesystem or git
mocks:** the artifact reaches the next phase's checkout, and the next phase's
discovery gate scopes to its own document. `run_executor_test.exs` drives the
real `RunExecutor` through a two-phase default-worktree run: phase 2's own
scripted agent calls `File.regular?` on phase 1's committed PRD from inside
phase 2's worktree (`:1151`) and the test asserts it true (`:1197`), asserts
phase 2's `FOREMAN_SOURCE_REVISION` is phase 1's branch tip and refutes it being
the run base (`:1194-1195`), and asserts phase 1's worktree directory is gone
while its branch tip survives (`:1204-1205`).
`run_executor_phase_lineage_test.exs:121-128` pins the subtlest part, which is
exactly where a silent regression would hide: against the chained base,
`discover_document(wt2, "docs/TRD", lineage)` returns the TRD while
`discover_document(wt2, "docs/PRD", lineage)` returns
`{:planning_document_absent, …}` — the inherited PRD correctly does NOT read as
new in phase 2 — yet against the RUN's base the same PRD call returns `{:ok,
prd}`. That contrast is the proof that `base_ref` must chain along with the
checkout or the gate mis-reports. **Not proven:** a live end-to-end plan run. No
dispatch has executed since the fix.

Do not collapse those tiers. Reading "proven by code" as "works in production"
is the `FOREMAN_ARTIFACT_PATH` error one paragraph above — computation proven,
delivery assumed. Reading "proven by test against real git" as "unproven" is the
same loss of information in the opposite direction. The STOP-on-missing rule
above is what keeps a failure here loud, naming the absent path instead of
producing a silently mis-sourced TRD.

An earlier version of this paragraph claimed `cleanup_phase_worktree/4`
"force-deletes its branch". **That was wrong when it was written, not merely
stale**, and the rest of the paragraph should be read with that in mind.
`cleanup_phase_worktree/4` (`run_executor.ex:1659`) reclaims disk only, via
`Worktree.clean/1` -> `VcsAdapter.Default.clean_worktree/2`, whose entire git
surface is `git worktree remove` (`default.ex:193`) followed by
`git worktree prune` (`:199`) — no ref is written or deleted anywhere in it.
`delete_branch/1` is private to `worktree.ex` (`:269`, `:281`) and its
only caller is `Worktree.clean_for_run/1` (`:228`), which `Dispatcher` invokes
solely on `RunDeleted` (`dispatcher.ex:163`) — after the run is already
terminated. Empirically, too: phase 1's branch from the failed
run-d75304aca144c15409087ed744e2a7dc is still at `b9c93aa7` and still carries
`docs/PRD/PRD-2026-6a25501b-durable-run-log-store.md` — the one document new
against that run's base `df20a77e` — long after the run's cleanup ran. Disk is
reclaimed at each phase boundary; the branch is not.

That distinction matters for anyone deciding whether cleanup is safe to change:
branch retention is a PRE-EXISTING invariant, not something the lineage change
introduced. The lineage merely started depending on it. The real defect was
purely base selection — phase 1's branch was always there to chain onto, and
`create_default_worktree/3` was simply resolving `HEAD` instead of it. So a
future change that makes phase cleanup delete branches would silently break the
lineage, and nothing in `cleanup_phase_worktree/4` would look wrong at the call
site.

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
The Go CLI (`foreman`) defaults to `http://127.0.0.1:4000` — set `FOREMAN_API_URL` to override:

```bash
FOREMAN_API_URL=http://127.0.0.1:4766 foreman task list
```

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

Tasks are created via the API (the `foreman task create` CLI wrapper doesn't support `workflow_type`/`trd_path`):

```bash
FOREMAN_API_URL=http://127.0.0.1:4766
curl -s -X POST $FOREMAN_API_URL/api/commands \
  -H "Content-Type: application/json" \
  -d '{
    "type": "task.create",
    "payload": {
      "task_id": "<unique-id>",
      "project_id": "foreman",
      "title": "<title>",
      "description": "<description>",
      "task_type": "task",
      "workflow_type": "implement-trd-beads",
      "priority": 2,
      "trd_path": "docs/TRD/<trd-file>.md"
    }
  }'
```

**Fields:**

- `task_id`: Required. A unique string identifier for the task.
- `project_id`: Required. Must be a registered project (e.g., `foreman`).
- `task_type`: Required. One of: `task`, `bug`, `feature`, `epic`, `chore`, `docs`, `question`.
- `workflow_type`: Optional. Selects the workflow manifest (e.g., `implement-trd-beads`, `implement-trd`, `plan`).
- `priority`: Optional. Integer 0–4 (default: `nil`). Beads validates this as a Beads priority, so `implement-trd-beads` tasks need `0–4`.
- `trd_path`: Optional. Path to a tracked git blob. Required for `implement-trd*` workflows. Must be committed before approval.

#### 2. Approve a task

Approval transitions `open` → `ready` and triggers workflow dispatch:

```bash
curl -s -X POST $FOREMAN_API_URL/api/commands \
  -H "Content-Type: application/json" \
  -d '{
    "type": "task.approve",
    "payload": {
      "task_id": "<task-id>",
      "approved_by": "operator"
    }
  }'
```

**Prerequisites:**

- The `trd_path` (if specified) must be a committed git blob at `HEAD`.
- The project must exist and have a valid `task_provider` configuration.

#### 3. Monitor a task

```bash
# Get task status
curl -s $FOREMAN_API_URL/api/tasks/<task-id>

# List all tasks
curl -s $FOREMAN_API_URL/api/tasks

# Get run status
curl -s $FOREMAN_API_URL/api/runs/<run-id>
```

Task statuses: `open` (created), `ready` (approved, waiting for dispatch), `in_progress` (running), `completed`, `failed`, `cancelled`.

#### 4. Cancel a task/run

```bash
# Via the run
foreman run cancel --id <run-id> --reason "reason"
foreman run remove --id <run-id>
foreman run reset --id <run-id>
```

### Go CLI Commands

```bash
foreman task get <id>       # Fetch task projection
foreman run list            # List run projections
foreman run get <id>        # Fetch run projection
foreman run remove --id <id> # Remove run and clean worktree/branch
foreman run reset --id <id>  # Clear failed/stuck run projection
foreman project list        # List projects
foreman project get <id>    # Fetch project

# Workflow install (one-time bootstrap per machine)
foreman workflow install
```

### Workflows

Bundled workflows live in `packages/foreman_server/priv/defaults/workflows/`:

| Workflow | Select via | Description |
| --- | --- | --- |
| `implement-trd-beads` | `--workflow-type implement-trd-beads` | Implement a TRD using Beads-backed ensemble skill with Kata/pi agent |
| `implement-trd` | `--workflow-type implement-trd` | Implement a TRD using the ensemble skill |
| `plan` | `--workflow-type plan` | Run the plan workflow (create-prd → create-trd) |

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
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

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
| `RunReserved` | `Run.handle_command/2` | Implementation key reservation |
| `RunStarted` | `Run.handle_command/2` | Creates run projection, spawns worker |
| `RunCancelled` | `Run.handle_command/2` | Marks run cancelled |
| `RunDeleted` | `Run.handle_command/2` | Marks run removed and triggers cleanup fan-out |
| `RunReset` | `Run.handle_command/2` | Clears failed/stuck run projection state for fresh submission |
| `RunCompleted` | `Run.handle_command/2` | Marks run terminal success |
| `RunFailed` | `Run.handle_command/2` | Marks run terminal failure |
| `RunFlaggedStuck` | `StuckDetector` | Flags run as stuck |
| `WorktreeCreated` | `Run.handle_command/2` | Worktree created |
| `WorktreeCleaned` | `Run.handle_command/2` | Worktree cleaned |
| `WorktreeCreateOrphanRecorded` | `Run.handle_command/2` | Records orphan worktree at creation |
| `WorktreeCreateOrphanResolved` | `Run.handle_command/2` | Resolves orphan worktree |
| `PrAssociated` | `PrAssociation.handle_command/2` | Records the PR URL on the run projection and in the `pr_associations` map |
| `PrMerged` | `Run.handle_command/2` | Marks run merged |
| `PhaseStarted` | `Phase.handle_command/2` | Updates run phase |
| `PhaseCompleted` | `Phase.handle_command/2` | Updates run phase |
| `WorkerHeartbeat` | `worker.event` command | Updates worker projection |
| `ToolCallApproved` | `ToolCall.handle_command/2` | Records tool call decision |
| `ToolCallDenied` | `ToolCall.handle_command/2` | Records tool call decision |
| `VcsOperationRecorded` | `VcsOperation.handle_command/2` | Records VCS operation |
| `BeadsDbLeaseAcquired` | `BeadsDbLease.handle_command/2` | Holder takes the per-DB Beads lease |
| `BeadsDbLeaseReleased` | `BeadsDbLease.handle_command/2` | Holder releases the lease (no waiters) |
| `BeadsDbLeaseWaiterRegistered` | `BeadsDbLease.handle_command/2` | Runner enqueued behind current holder |
| `BeadsDbLeaseWaiterRemoved` | `BeadsDbLease.handle_command/2` | Cancel-before-promotion of a waiter |
| `BeadsDbLeaseTransferred` | `BeadsDbLease.handle_command/2` | Release + head-waiter promotion in one event |

#### Typed Event Structs

Every domain event is a typed struct in `lib/foreman_server/events/` with `@enforce_keys`
and `@type t`. `%EventData{}` / `%RecordedEvent{}` are persistence envelopes only — they
are not domain types. `EventData.data` / `RecordedEvent.data` holds the serialized domain
struct; on replay, the struct MUST be reconstructed before `apply_event` pattern-matches it.

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
`beads_rust` / `br` CLI). The `KataAdapter` (backed by `kata` CLI) is in progress.

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

### br Commands for Issue Management

```bash
br ready --json                       # Show issues ready to work (no blockers)
br list --status=open --json          # All open issues
br show <id> --json                   # Full issue details with dependencies
br create --title="..." --type=task --priority=2 --json
br update <id> --status=in_progress --json
br close <id> --reason="Completed" --json
br close <id1> <id2> --reason="Completed" --json
br sync --flush-only                  # Export DB to JSONL after Beads mutations
```

### Workflow Pattern

1. **Triage**: Run `bv --robot-triage` to find the highest-impact actionable work
2. **Claim**: Use `br update <id> --status=in_progress --json`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id> --reason="Completed" --json`
5. **Sync**: Run `br sync --flush-only` after Beads mutations so the JSONL export is current

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready --json` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Git Policy

`br` never commits or pushes. Follow this repository's own git instructions before staging, committing, or pushing. If the repository says "commit only when asked," that rule overrides any generic workflow advice.

<!-- end-bv-agent-instructions -->
