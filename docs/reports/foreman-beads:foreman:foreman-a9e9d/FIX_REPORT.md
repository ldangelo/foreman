# FIX_REPORT — beads:foreman:foreman-a9e9d (fix workflow, phase 2)

Run `run-6446bf4b0c969d12f787a0801b9879ce` · branch
`foreman/foreman-a9e9d/run-6446bf4b0c969d12f787a0801b9879ce` · PR #953 · HEAD `c2666e72`

**Changed in this phase: the report file only. No source or test file edited.** Per
PLAN.md §6 (the plan this phase executes, committed at HEAD), the behaviours the bead asks
to test are owned by four *other* open PRs / unmerged branches, and adding their tests to
`phase_pr_test.exs`, `phase_pr_body_test.exs` or `auto_pr_test.exs` on this branch would
assert against implementation that does not exist here.

## 1. Verdict carried from PLAN.md §2

Four of the five requested test targets are not absent — they already have tests on a
sibling unmerged branch. A fifth has no implementation anywhere. Writing them here would
add tests for four other beads' features to a PR whose diff is exactly two files
(`review_findings.ex`, `phase_pr.ex`) plus this report.

| # | Requested behaviour | State on this branch | Owner of the tests |
| --- | --- | --- | --- |
| 1 | Title falls back to task title | implemented, no test | `foreman/foreman-gocpd/…` (PR #957, OPEN) |
| 2 | `## PR body` section verbatim → next level-2 heading | no implementation | `foreman/foreman-2uziy/…` (PR #955, OPEN, does not compile) |
| 3 | Template headings from a project setting | no implementation | `foreman/foreman-p0b23/…` (unpushed, no PR) |
| 4 | Absolute paths absent from body | implemented, no test | `foreman/foreman-txkmy/…` (PR #959, OPEN) |
| 5 | Review section carries link + findings | **implemented AND tested here** | this branch |

Target 5 is covered by the 298-line `packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs`
committed at `6169c09c` on this branch (5 tests: unresolved-findings rendering, declined
critical vs declined minor, `AutoPR`/`PhasePR` section equality across five artifact kinds,
inert agent-written description, inert hostile path + "N more" line, absent-block
"review evidence missing"). That is the one part of the requested scope this branch may
truthfully claim, and it is already green.

## 2. Test command actually run, and its result

Both target files exist on this branch, so the plan's §4 verification was executed rather
than reported as unprovable:

```
devbox run -- bash -c 'cd packages/foreman_server && \
  DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test \
  MIX_ENV=test mix test --warnings-as-errors \
    test/foreman_server/workflow/phase_pr_test.exs \
    test/foreman_server/workflow/phase_pr_body_test.exs \
    test/foreman_server/workflow/auto_pr_test.exs'
```

Result: **`125 tests, 0 failures` (19.9s), no warnings.**

Two environment corrections were needed to reach that line; neither is a defect in the
branch:

1. **A fresh Foreman run worktree has no Hex deps** — `mix test` stops with
   `the dependency is not available, run "mix deps.get"`. Fixed by
   `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix deps.get'`
   (1m27s). This contradicts the note in `docs/lessons/` that a run worktree cannot run
   Mix at all: `deps.get` does work here.
2. **The exported `DATABASE_URL` points at a port nothing listens on.** The run
   environment exports `DATABASE_URL=postgres://postgres:postgres@localhost:55434/foreman_dev`;
   55434 has no listener, so `mix test` died in `mix.exs:203` (`claim_database!/2`) with
   `(UndefinedMatchErrorError) no match of right hand side value: {:error, :badmatch}`.
   The live server is docker container `foreman-postgres` on **55432**
   (`docker ps`: `0.0.0.0:55432->5432/tcp, 0.0.0.0:55433->5432/tcp`). Overriding to
   `…@localhost:55432/foreman_test` ran the suite. `foreman_test`/`foreman_dev` were
   created and migrated against 55432 as part of this; `foreman_test` is a scratch DB and
   nothing was written to `foreman_dev`.

The full-suite invocation the task prompt names (`mix test --warnings-as-errors` with no
file list) was not run: it needs the whole Postgres-backed projection suite and takes many
minutes; the three files named are the narrowest affected set and are the ones the finding
is about.

## 3. Work performed in this phase

- Read the plan (126 lines at HEAD; the working-tree copy is the 34-line summary version
  left by the plan phase — same conclusion, not restored, it is not this phase's artifact).
- Re-verified every claim in PLAN.md §1 against the live repo rather than repeating it:
  `gh pr list --state all` still lists #955 (2uziy), #957 (gocpd), #959 (txkmy) as OPEN;
  `foreman/foreman-p0b23/run-1d5bb343dcae0b4d55f102b84a26ad14` still exists as a local ref
  with **no remote tracking ref**; `git grep -c "pr_body_headings"` on that branch → 46
  hits, all under `lib/` + `test/foreman_server_web/` (settings LiveView), **zero** in
  `test/foreman_server/workflow/`; `git grep "from_artifact"` on PR #955's head → only the
  test's own alias/call and an unrelated `from_artifacts/1` clause in `review_findings.ex`.
- Confirmed by grep that this branch's tests contain **no** assertion for any of the four
  foreign behaviours (`pr_body_headings` → 0 hits anywhere in `test/`; `## PR body` → 0;
  task-title fallback → only in `auto_pr_test.exs`'s *own* feature `task_metadata[:title]`,
  which is a different field from the PR-title chain #957 owns). The one near-hit,
  `auto_pr_test.exs:334` `assert body =~ "Artifact: #{artifact}"`, asserts the current
  raw-absolute-path shape at `auto_pr.ex:720` — i.e. it *pins the pre-scrub behaviour*, and
  will need updating in txkmy's PR, not here.
- Ran the §4 test command (after the two env fixes) and recorded the outcome above.
- Documentation gate: this phase adds/removes/renames no externally visible identifier —
  no route, config key, env var, CLI verb, MCP tool, command or event type. Grepping
  `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` for
  `pr_body_headings`, `## PR body`, `PrBodyPath`, `task_title` returned no hits, so there
  is no stale reference to fix and nothing to add. Those identifiers are documented by
  bead `foreman-d6rth` (still OPEN), which owns that edit. **No edit to any of the four
  gate files.**

## 4. Status: the finding is not addressed by this branch — by design

The review finding ("this diff adds no tests for the requested behaviour", severity major,
dimension tests) is **accurate about this diff** and is **deliberately not fixed here**.
The correct disposition is a scope decision the plan made and this phase honoured: this
bead's actual subject (review-evidence completeness in the PR body) is implemented and
tested at `6169c09c`; the other four items belong to their own branches. Closing the
finding requires the operator action in §5, not an edit on this branch.

## 5. Follow-ups / operator actions (none is this run's work)

1. **PR #955 (`foreman-2uziy`) cannot compile.** Its
   `packages/foreman_server/test/foreman_server/workflow/pr_body_test.exs` calls
   `ForemanServer.Workflow.PrBody.from_artifact/2`, a module defined nowhere on that
   branch. Merging it reds the suite. Needs `PrBody.from_artifact/2` implemented or the
   test removed.
2. **`foreman-p0b23` is at risk of loss: 398 lines, unpushed, no PR, no tests.** Push it
   and open a PR before anything reclaims that worktree.
3. **Re-scope or close `foreman-a9e9d` against #955/#957/#959.** `git merge-tree` reports
   conflicts in `phase_pr.ex:339-352` and `phase_pr_test.exs`; whichever of these merges
   first changes what the others diff to.
4. **`auto_pr_test.exs:334`** pins `"Artifact: #{artifact}"` (absolute) and must change in
   the same PR as the scrubbing, or #959 will fail its own suite.
5. **Environment defects worth their own bead** (found here, not caused by this branch):
   the exported `DATABASE_URL` port 55434 has no listener, and a fresh run worktree needs
   `mix deps.get` before any Mix task.

## 6. Findings block

```yaml
findings:
  - id: a9e9d-1
    disposition: open
    severity: major
    summary: >
      The bead's four foreign test targets remain untested on this branch by plan decision
      (PLAN.md §6). Finding is accurate about the diff and is resolved by operator scope
      action on PRs #955/#957/#959 and branch foreman-p0b23, not by an edit here.
```
