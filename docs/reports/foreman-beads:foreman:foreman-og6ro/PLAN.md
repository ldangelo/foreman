# PLAN — foreman-og6ro: tests with a local bare remote ahead of the checkout

## 1. Verdict

**No code change. Blocked: the behaviour under test does not exist on this branch, and two of the three requested assertions are not implementable anywhere yet.**

Branch `foreman/foreman-og6ro/run-e0942614fb7968e897927fb757b8c7b3`, HEAD `f0f3b083`, merge-base with `origin/main` = `f0f3b083` (branch carries zero commits of its own; tree clean).

Evidence, all run on this worktree:

- `grep -rn "resolve_origin_base\|fetch_origin_base\|base_ref_policy" packages/foreman_server/lib packages/foreman_server/test packages/foreman_cli` → **no matches**. None of the three identifiers the bead presupposes exists here.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4447-4458` `resolve_declared_base/2` ends with `resolve_revision(project_root, "HEAD")` (line 4456). With no declared `base:`, a run worktree is cut from the **local checkout HEAD**. There is no fetch, no `origin/<branch>` read, and therefore nothing that could be asserted to equal the advanced origin tip.
- `grep -n "__resolve_provisioned_base_for_test__" packages/foreman_server/lib packages/foreman_server/test` → **no matches**. The test seam the requested tests would call is absent; a test file calling it fails to compile.
- `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` has no `fetch_base/3` (`grep -n fetch_base` across `lib` hits only `fetch_base_branch/2` in `packages/foreman_server/lib/foreman_server/workflow/repo_pr_context.ex:79`, an unrelated accessor).

Where the behaviour actually lives — all unmerged:

| What the bead assumes | Where it exists | State |
| --- | --- | --- |
| `resolve_origin_base/2` + `fetch_origin_base/3` in `run_executor.ex` (lines 4472, 4485 of that head), `VcsAdapter.Default.fetch_base/3` (line 142), seam `__resolve_provisioned_base_for_test__/2` (line 5964) | PR **#942**, head `43be78e6`, branch `foreman/foreman-ylwq0/run-4c8b40838270b2b29b0aeb44d96e26bc`, base `main` | OPEN, not merged |
| Project setting `base_ref_policy` (`packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:53`, `base_ref_policies/0` at :137) | PR **#943**, branch `foreman/foreman-zv8bi/run-59f7dec0c17ee9867d8c48735ac5416d`, base `main` | OPEN, not merged — **and not wired**: `git grep -n base_ref_policy <that head> -- packages/foreman_server/lib/foreman_server/workflow/` returns nothing, so no base-resolution code reads the setting on any ref |

Two further facts that bound the task:

1. **The "ahead bare origin" test already ships inside #942.** `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs` (+168 lines on `43be78e6`) builds a real bare origin (`git init --bare --initial-branch=main`), a `seed` clone, a `repo` clone that stays behind, and a `peer` clone that pushes `ahead.txt` to `origin/main`, then asserts `base_ref == ctx.origin_tip` and `refute base_ref == ctx.stale_head`. Its six tests are:
   - `"bases the worktree on the fetched origin tip, not the stale checkout HEAD"` (:105)
   - `"the fetch leaves the operator's checkout untouched"` (:114)
   - `"falls back to local HEAD when the remote does not carry the branch"` (:128)
   - `"falls back to local HEAD when no origin remote is configured"` (:139)
   - `"a declared base resolves locally and is never fetched"` (:150)
   - `"a task that names its own source_branch keeps the local base"` (:159)

   Duplicating that file here would be a second copy of one boundary's tests (AGENTS.md 5.7) and would conflict on merge.
2. **"a fetch failure degrades with a warning" contradicts the merged-pending design and this repo's invariants.** On `43be78e6`, `fetch_origin_base/3` returns `{:error, {:origin_fetch_failed, remote, branch, reason}}` (line 4489) with the comment "A fetch that FAILS is a typed error, never a silent fallback to a stale base." Writing a test that asserts a warning-and-continue would assert the opposite of the implementation and of AGENTS.md ("Refuse what cannot be honoured"; §5.2 "A crash beats a lie"). Graceful degradation of that exact path is a **separate open bead, foreman-k9g4n (PR #944)**, which itself reported `Blocked: depends on PR #942`.

## 2. Root cause

Not a product defect. This is a test-coverage bead filed by automated review of run `run-8dec153539dbd49ac86c0a25c6bbc698` against a code path that lives only on an unmerged sibling PR. On the current tree the function it describes (`resolve_origin_base/2`, `run_executor.ex`) does not exist, so there is no behaviour to cover and no seam to call.

## 3. Failing check first

None available, and none should be invented.

- A test asserting `base_ref == origin_tip` cannot fail-then-pass here: `run_executor.ex:4456` returns local `HEAD` and there is no edit in scope that changes it (changing it is PR #942's job, not this bead's).
- A test asserting the current stale-HEAD behaviour would pass immediately and would have to be deleted when #942 lands — it encodes the bug as the contract.

Command that documents the absence (expect no output, exit 1):

```bash
cd packages/foreman_server && grep -rn "resolve_origin_base\|fetch_origin_base\|base_ref_policy" lib test
```

## 4. Edits

**None. Do not create, modify or delete any `.ex`, `.exs`, `.go`, `.yaml` or `.md` file.**

The only artifact this run produces is this `PLAN.md` plus whatever report file the next phase is contracted to write. The implementer's correct action is to write `Blocked: depends on PR #942 (foreman-ylwq0), which adds resolve_origin_base/2 and fetch_origin_base/3; the ahead-origin tests ship in that PR. No code change here.` as the sole content of its report artifact and exit.

Recorded for whoever picks this up **after #942 merges** (do not act on it now):

- The ahead-origin coverage then already exists at `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs`; this bead is satisfied by it and should be closed as duplicate rather than re-implemented.
- Only the `base_ref_policy: checkout` assertion would remain genuinely uncovered, and it is blocked a second time: #943 adds the setting but nothing in `packages/foreman_server/lib/foreman_server/workflow/` reads it, so there is no `checkout` policy behaviour to preserve. Wiring it is a separate change needing its own bead, not a test-only one.
- The fetch-failure assertion belongs to foreman-k9g4n (PR #944), not here.

## 5. Verification

Nothing to verify beyond proving the tree is untouched:

```bash
git status --porcelain          # only docs/reports/foreman-beads:foreman:foreman-og6ro/ paths
git diff --stat $(git merge-base HEAD origin/main)..HEAD   # Markdown only, zero code
```

Success = no file outside `docs/reports/foreman-beads:foreman:foreman-og6ro/` changed, and the suite is untouched. Do **not** run the full suite to "prove" a no-op; there is no code delta to validate.

## 6. Out of scope

- Do **not** implement `resolve_origin_base/2`, `fetch_origin_base/3`, or `VcsAdapter.Default.fetch_base/3`. That is PR #942.
- Do **not** add `__resolve_provisioned_base_for_test__/2` or any other test seam to `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`.
- Do **not** copy `run_executor_origin_base_test.exs` from PR #942 onto this branch (duplicate boundary coverage, guaranteed merge conflict).
- Do **not** add tests that assert a fetch failure warns and continues — that contradicts `{:origin_fetch_failed, ...}` and belongs to foreman-k9g4n.
- Do **not** add the `base_ref_policy` setting, nor read it anywhere. That is PR #943 plus unwritten wiring.
- Do **not** merge, rebase, cherry-pick or fetch sibling branches into this one; do not create, rename or delete branches; do not open or merge a PR (merge gate is operator-only).
- Do **not** edit `AGENTS.md`. Documentation gate: this plan adds, removes and renames **zero** externally visible identifiers (no routes, config keys, env vars, CLI verbs, MCP tools, command/event types), so `CLAUDE.md`, `README.md`, `docs/user-guide.md` and `docs/cli-reference.md` need no edits.
