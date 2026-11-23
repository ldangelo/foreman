# FIX_REPORT foreman-og6ro: tests with a local bare remote ahead of the checkout

Blocked: no plan found — the plan artifact read at phase start was not a plan.

## What happened

Phase contract: read `PLAN.md` in this report's directory; if it is not a plan, stop and change no code.

At phase start, `docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md` in the working tree contained
18 lines — a copy of phase 1's **summary**, not the 84-line plan. `git diff --stat` confirmed the plan file
was modified (`18 insertions(+), 71 deletions(-)`) relative to commit `912dd597` ("[pi] Phase 1 done. Plan
written, no code touched."). Taken literally, the contract's fallback applies: no plan → `Blocked: no plan found`.

## Root cause

Not a product defect and not a missing test. Phase 1's verdict (from the committed plan,
`git show HEAD:docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md`) is that the behaviour the bead
asks us to test does not exist on this branch, so a test file would not even compile:

- `grep -rn "resolve_origin_base\|fetch_origin_base\|base_ref_policy\|__resolve_provisioned_base_for_test__" packages/foreman_server/lib packages/foreman_server/test` → **zero matches** (re-verified this phase).
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4447-4458` — `resolve_declared_base/2` still ends in `resolve_revision(project_root, "HEAD")` (line 4456): the run worktree is cut from **local checkout HEAD**, with no fetch and no `origin/<base_branch>` read to assert against.
- `grep -rn "fetch_base" packages/foreman_server/lib` → only the unrelated accessor `fetch_base_branch/2` at `packages/foreman_server/lib/foreman_server/workflow/repo_pr_context.ex:79,83`. `VcsAdapter.Default` has no `fetch_base/3`.
- `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs` does not exist on this branch.

The requested behaviour lives only on **unmerged** sibling branches:

| Bead assumption | Location | State |
| --- | --- | --- |
| `resolve_origin_base/2` (:4472), `fetch_origin_base/3` (:4485), seam `__resolve_provisioned_base_for_test__/2` (:5964), `VcsAdapter.Default.fetch_base/3` (`default.ex:142`) | PR #942, branch `foreman/foreman-ylwq0/run-4c8b40838270b2b29b0aeb44d96e26bc`, head `43be78e6` | OPEN |
| `base_ref_policy` setting (`aggregates/project/settings.ex:53`, `base_ref_policies/0` :137) | PR #943, branch `foreman/foreman-zv8bi/run-59f7dec0c17ee9867d8c48735ac5416d` | OPEN and **unwired** — nothing under `packages/foreman_server/lib/foreman_server/workflow/` reads it, so there is no `checkout` policy behaviour to preserve |

Two further reasons not to re-implement here:

1. PR #942 **already ships** `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs` (+168 lines, 6 tests) covering exactly this scenario: bare `--initial-branch=main` origin, seed/repo/peer clones, peer pushes `ahead.txt` to `origin/main`, then `assert base_ref == origin_tip` / `refute base_ref == stale_head`, plus checkout-untouched, two HEAD-fallback cases, declared-base-never-fetched, and `source_branch` keeps local base. Copying it would duplicate one boundary's coverage (AGENTS.md §5.7) and guarantee a merge conflict.
2. The bead's "a fetch failure degrades with a warning" **contradicts** #942's design and this repo's invariants: `fetch_origin_base/3` returns `{:error, {:origin_fetch_failed, remote, branch, reason}}` (`run_executor.ex:4489`) with the comment that a failing fetch is a typed error, never a silent fallback to a stale base. A test asserting warn-and-continue would assert the opposite of AGENTS.md ("Refuse what cannot be honoured"; §5.2 "A crash beats a lie"). That graceful-degradation path is the separate open bead `foreman-k9g4n` (PR #944), which itself reported being blocked on #942.

## Change

None. No `.ex`, `.exs`, `.go`, `.yaml` or `.md` file outside this report directory was created, modified or
deleted. `PLAN.md` was neither edited nor committed — it was left exactly as found at phase start (the
overwritten 18-line version) so the operator can restore it with
`git show HEAD:docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md`.

## Deviations from the plan

Cannot be evaluated as written: the plan file in the tree at phase start was phase 1's summary, not the plan.
The committed plan in git (`912dd597`) prescribes "no code change, write a Blocked report", which is what this
report does — so the outcome is identical under either reading. No edits were attempted.

## Tests

No failing check exists on this branch to run, and none was invented (the plan's §3 says the same). Any test
asserting `base_ref == origin_tip` would fail here for the wrong reason — `run_executor.ex:4456` returns local
`HEAD` — and could not be made to pass without implementing PR #942's code, which is out of scope.

## Local verification

- `grep -rn "resolve_origin_base\|fetch_origin_base\|base_ref_policy\|__resolve_provisioned_base_for_test__" packages/foreman_server/lib packages/foreman_server/test` → no matches.
- `sed -n '4447,4460p' packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` → confirms `resolve_revision(project_root, "HEAD")` fallback at :4456.
- `grep -rn "fetch_base" packages/foreman_server/lib` → only `fetch_base_branch/2` in `repo_pr_context.ex`.
- `ls packages/foreman_server/test/foreman_server/workflow/ | grep -i origin_base` → no such file.
- `git status --porcelain` → only `M docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md` (pre-existing from phase 1's commit) plus this untracked report.
- `git diff --stat` → `1 file changed, 18 insertions(+), 71 deletions(-)`, markdown only, zero code.

No test suite was run: there is zero code delta to validate.

## Follow-ups

1. **Fix the plan artifact** (or re-run phase 1) so phase 2 can read the real plan: the committed version at
   `912dd597` is intact, but the working-tree copy was reduced to the phase-1 summary.
2. **After #942 merges**, this bead is a duplicate of the coverage already in
   `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs` — close as dup, or
   re-scope.
3. The only genuinely uncovered assertion is `base_ref_policy: checkout` preserving the old behaviour, and it is
   doubly blocked: #943 adds the setting but nothing in `lib/foreman_server/workflow/` reads it, so the wiring is
   a separate (non-test-only) change needing its own bead.
4. The fetch-failure-degrades-with-warning assertion belongs to `foreman-k9g4n` (PR #944), not here.
5. kata `5q3f` remains open and labelled `needs-review` for the operator's call.

## Note on progress reporting

`foreman_inbox_send` and `foreman_task_add_comment` are not exposed in this phase, so no operator progress notes
could be sent. `ask` is disallowed in headless mode and `ask_advisor` is unavailable (Anthropic oauth refresh
`400 invalid_grant`, refresh token expired — needs operator re-auth).

## Documentation gate

Zero externally visible identifiers added, removed or renamed: no routes, config keys, env vars, CLI verbs,
MCP tools, command/event types or workflow names. Greps of `CLAUDE.md`, `README.md`, `docs/user-guide.md` and
`docs/cli-reference.md` for `resolve_origin_base`, `fetch_origin_base` and `base_ref_policy` produced no hits in
phase 1, so none of the four files needed edits — there was nothing new to document and nothing stale to fix.
