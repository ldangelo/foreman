# PLAN — foreman-okend: document `base_ref_policy`, fetch-before-run, base SHA, behind-origin

## 1. Verdict

**No code change. Three of the four subjects are already documented on their own
feature branches; the fourth does not exist in any branch.** Do not edit
`docs/user-guide.md`.

This branch is `foreman/foreman-okend/run-f5db91eef82cb0962b4337d08547a6d8`, HEAD
`f0f3b083`, identical to `main`. None of the four features is in it:

| Subject | In HEAD? | Implemented where | Already documented there? |
| --- | --- | --- | --- |
| `base_ref_policy` setting | No — `grep -rn base_ref_policy .` returns 0 hits | branch `foreman/foreman-zv8bi/run-59f7dec0c17ee9867d8c48735ac5416d`, commit `c489c0f3` (PR #943, open) | **Yes** — `docs/user-guide.md:736`, `docs/cli-reference.md`, `CLAUDE.md:1240` |
| base SHA on `RunBaseBranchRecorded` | No — `events/run_base_branch_recorded.ex:23` is `defstruct [:run_id, :base_branch, :repo_id, :sequence]` | branch `foreman/foreman-i3qol/run-d70bafc603ebda52f09c128e358f5b43` (PR #945, open); its struct is `[:run_id, :base_branch, :base_sha, :repo_id, :sequence]` | **Yes** — `docs/user-guide.md:1366` on that branch |
| `branch.behind_origin` recommendation | No — `projects/recommendations.ex` has 19 `rec(` ids, none of them `branch.behind_origin` | branch `foreman/foreman-qdt14/run-0c30344c74abc80ba7c2b40090d98819`, commit `295155d0` (**no PR open**) | **Yes** — that commit rewrites `docs/user-guide.md:684` "Two further checks" → "Three further checks" |
| fetch-before-run (`git fetch origin <base>` at run start) | No | **nowhere** — `git log --all -S"sync_remote" -- .../workflow/run_executor.ex` is empty | n/a |

Evidence that nothing merged: `git merge-base --is-ancestor c489c0f3 HEAD` → false,
and `... c489c0f3 origin/dev` → false.

The finding came from an automated review of run
`run-8dec153539dbd49ac86c0a25c6bbc698` (bead `foreman-ch78x`). That review's own
`analysis.md` says the diff "carries zero implementation" — `foreman-ch78x` wrote
`Blocked: no plan found` and changed no code. So the review correctly observed
that the four features were undocumented **on the branch it was reading**, and
split the work into five follow-up beads. Four of them (`zv8bi`, `i3qol`,
`qdt14`, `k9g4n`) each carried its own `docs/user-guide.md` edit alongside its
code, which is what Foreman's documentation gate requires. `foreman-okend` is the
fifth, documentation-only bead — and by the time it ran, the doc edits it was
meant to write had already been written by the beads that own the code.

## 2. Root cause

Not a code defect: a task-decomposition artifact. The automated reviewer emitted
a standalone "documentation" bead for four features it had also filed as four
separate implementation beads. Each implementation bead satisfied the
documentation gate itself (`AGENTS.md` → "Documentation Gate"), so this bead has
no remaining work that would be true on this branch.

Writing the documentation here would be worse than doing nothing, on three counts:

1. **It would document absent behaviour.** `base_ref_policy` cannot be set on this
   branch — `Aggregates.Project.Settings.@keys`
   (`packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:47-51`)
   does not list it, so `project update --base-ref-policy origin` is rejected
   `{:unknown_setting, :base_ref_policy}`. A user-guide row promising the flag
   would be a documented feature with no implementation — exactly the
   plausible-looking success `AGENTS.md` §5.2 forbids.
2. **Fetch-before-run does not exist at all.** `resolve_declared_base/2`
   (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4447-4458`)
   resolves `HEAD` of the operator checkout locally and never fetches;
   `Exec.Git.fetch_branch/4` (`exec/git.ex:568`) has exactly one non-test caller,
   `Exec.Worktree.sync_branch/3` (`exec/worktree.ex:147-163`), which is the
   PR-head attach path, not run start. `docs/user-guide.md:566` is currently
   correct and must stay: "A run's base branch is the registered checkout's
   `HEAD` at the moment the run's first phase starts, latched for the run."
3. **It would collide with the owning branches.** PR #943 already adds the
   `base_ref_policy` row immediately after `docs/user-guide.md:735`; PR #945
   already extends the `GET /api/runs/{id}` paragraph at `docs/user-guide.md:1365`
   with `base_sha`. Adding the same prose here produces duplicate rows and
   conflicting edits in the same lines when those PRs merge.

## 3. Failing check first

None. There is no behaviour to pin and nothing to assert; a documentation-only
bead whose documentation is already written elsewhere has no test.

Reproduce the verdict instead — each command must print what is shown:

```bash
# 1. None of the three identifiers exists on this branch (expect: no output).
grep -rn "base_ref_policy\|behind_origin\|base_sha" \
  packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex \
  packages/foreman_server/lib/foreman_server/projects/recommendations.ex \
  packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex

# 2. They DO exist, with their docs, on the feature branches (expect: 1, 1, 1).
git show foreman/foreman-zv8bi/run-59f7dec0c17ee9867d8c48735ac5416d:docs/user-guide.md | grep -c base_ref_policy
git show foreman/foreman-qdt14/run-0c30344c74abc80ba7c2b40090d98819:docs/user-guide.md | grep -c behind_origin
git show foreman/foreman-i3qol/run-d70bafc603ebda52f09c128e358f5b43:docs/user-guide.md | grep -c base_sha

# 3. Nothing merged (expect: all three print "no").
# c489c0f3 = base_ref_policy (zv8bi), 295155d0 = branch.behind_origin (qdt14),
# 887b82a7 = base_sha (i3qol) branch tip.
git merge-base --is-ancestor c489c0f3 HEAD && echo yes || echo no
git merge-base --is-ancestor c489c0f3 origin/dev && echo yes || echo no
git merge-base --is-ancestor 295155d0 HEAD && echo yes || echo no
git merge-base --is-ancestor 295155d0 origin/dev && echo yes || echo no
git merge-base --is-ancestor 887b82a7 origin/dev && echo yes || echo no
```

## 4. Edits

**None.** Do not modify `docs/user-guide.md`, `CLAUDE.md`, `README.md`,
`docs/cli-reference.md`, or any file under `packages/`.

Write `FIX_REPORT.md` in this same directory stating the verdict and the three
reasons in §2, naming PR #943, PR #945 and local branch
`foreman/foreman-qdt14/run-0c30344c74abc80ba7c2b40090d98819`, then stop.

The one thing an operator should act on, recorded here because this bead cannot
do it: **`foreman-qdt14`'s commit `295155d0` has no open PR.** It is the only one
of the three whose work (both the `branch.behind_origin` recommendation and its
user-guide text) exists solely as a local branch, so it is the only one at risk
of being lost. The other two are PR #943 and PR #945.

If the operator decides this bead should instead document the features *after*
those PRs merge, the work is still not this bead's: re-run it on a branch cut
from a `main` that contains them, where a real gap can be measured.

## 5. Verification

No build is required, because no file changes. If the implementer wants proof
the tree is untouched:

```bash
git status --short        # expect: only docs/reports/foreman-beads:foreman:foreman-okend/
```

Success means: `docs/user-guide.md` is byte-identical to `f0f3b083`, and
`FIX_REPORT.md` states the no-change verdict with the branch/PR evidence.

Do **not** run the full suite for this bead; it would prove nothing about a
documentation verdict. (For reference, the project gate is
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`.)

### Documentation gate

Externally visible identifiers added, removed or renamed by this bead: **none**.
`base_ref_policy`, `--base-ref-policy`, `base_sha` and `branch.behind_origin` are
introduced by other beads and documented by them. Greps of `CLAUDE.md`,
`README.md`, `docs/user-guide.md` and `docs/cli-reference.md` on this branch
return zero hits for all four — correctly, since the features are absent here.
No doc file needs an edit.

## 6. Out of scope

- **Do not implement any of the four features.** This is a documentation bead;
  `base_ref_policy` belongs to `foreman-zv8bi`, the base SHA to `foreman-i3qol`,
  the recommendation to `foreman-qdt14`, and fetch-before-run plus its graceful
  degradation to `foreman-ch78x` / `foreman-k9g4n`.
- **Do not cherry-pick, merge or rebase** `c489c0f3`, `295155d0`, or any sibling
  branch into this one.
- **Do not edit `docs/user-guide.md:566`** ("Base branch" paragraph). It
  accurately describes today's checkout-`HEAD` behaviour and only becomes wrong
  when fetch-before-run actually ships.
- **Do not touch** `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`,
  `.../exec/git.ex`, `.../exec/worktree.ex`,
  `.../aggregates/project/settings.ex`, `.../projects/recommendations.ex`,
  `.../events/run_base_branch_recorded.ex`, or `.../projection_store.ex`.
- **Do not open, close or merge a PR**, and do not create or delete branches.
- Do not "document it anyway, marked as planned". A user guide that describes
  unimplemented settings is the failure mode this plan exists to prevent.
