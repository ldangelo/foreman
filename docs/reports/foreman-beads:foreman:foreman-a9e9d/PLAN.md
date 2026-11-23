# PLAN — foreman-a9e9d: tests for title, PR-body extraction, template headings, path scrubbing

## 1. Verdict

**No code change on this branch.** Four of the five behaviours the bead wants tested do not
exist in this worktree, and three of them already carry their own tests on their own
unmerged branches. Writing the tests here would mean implementing four sibling beads'
features first — exactly the duplication the per-bead split was created to avoid.

Evidence, all re-verified against the commit this branch was cut from, `c209f8b4` (an ancestor of `origin/main`, not its tip):

| Behaviour | At HEAD | Owner bead / branch | Tests already written there |
| --- | --- | --- | --- |
| Title: task-title → first conventional subject → `feat(phase)` | absent — `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:345` is still `title = "feat(phase): #{request.phase_name}"`; `grep -c task_title` in that file = 0 | `foreman-gocpd` (CLOSED), PR **#957** OPEN | yes — 5 tests added to `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs` (task title; first conventional subject; legacy fallback; `git log` failure keeps the PR; `:task_title_invalid` before any push) |
| Absolute paths absent from the body | absent — `phase_pr.ex:349` and `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:720` both emit `"\nArtifact: #{artifact_path}\n"` verbatim | `foreman-txkmy` (CLOSED), PR **#959** OPEN | yes — new `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex` plus 24 tests in `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs`, and `auto_pr_test.exs:334` changed to `assert body =~ "Artifact: #{Path.basename(artifact)}"` |
| `## PR body` section verbatim, stopped at the next level-2 heading | absent — `git grep '## PR body' packages/foreman_server/lib` = no hits | `foreman-2uziy` (CLOSED), PR **#955** OPEN | tests exist (11 in `packages/foreman_server/test/foreman_server/workflow/pr_body_test.exs`) **but that PR cannot compile** — see §6 |
| Template headings from a project setting | absent — `git grep pr_body_template\|pr_body_headings` over the whole repo at HEAD = no hits | `foreman-p0b23` (**OPEN**), branch `foreman/foreman-p0b23/run-1d5bb343dcae0b4d55f102b84a26ad14` is **local only, never pushed, no PR** | no tests on that branch |
| Review section carries a link when findings are absent | absent — `ForemanServer.Workflow.ReviewFindings.pr_section/2` (`.../review_findings.ex:253`, called from `phase_pr.ex:607`) emits only the missing-evidence notice; `grep -n "link\|blob"` finds no link rendering | `foreman-4oodz` (**IN_PROGRESS**), branch `foreman/foreman-4oodz/run-4aa2a5bd128541f2dd0e001e40a8e366` is **local only, never pushed**, and contains **no code at all** (only `PLAN.md`, a stub `FIX_REPORT.md` and a stray `.deps_get.log`) | no tests anywhere |

None of #955, #957, #959 is merged (`git merge-base --is-ancestor <branch> origin/main` → false for
all three).

So: the two gaps that are genuinely untested — template headings and the review-section link —
are blocked on code that is unwritten (4oodz) or unpushed and uncalled (p0b23). The three that
are implemented already ship their tests inside the PR that implements them, which is where
Foreman wants them.

## 2. Root cause

Not a product defect. The original review of `run-a9ee2749eb92b7d7896ed91d3155995d`
(bead `foreman-uvzfs`, PR #939, now CLOSED) filed one gap per behaviour **plus** this
separate tests-only gap. Because every implementation bead carries its own tests, the
tests-only bead arrives with its subject matter already covered on sibling branches and
absent from its own branch — the same split-bead pattern recorded for the doc-only bead
`foreman-okend`.

## 3. Failing check first

There is none to write. A test of `pr_title/1`, `PrBody.from_artifact/2`,
`PrBodyPath`, `pr_body_headings` or a linked review section on this branch fails at
**compile** time (undefined function/module), not as a meaningful red test — the code is on
another branch. A compile error is not the failing-first signal this gate asks for.

What was run instead, to prove the three named files are green at HEAD and that no
regression is being hidden:

```
devbox run -- bash -c 'cd packages/foreman_server && \
  DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test \
  MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/phase_pr_test.exs \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/workflow/auto_pr_test.exs'
```

Result: **`Result: 125 passed`, exit 0**, 33.7 s. Record this verbatim in `FIX_REPORT.md` —
the bead explicitly asks for a real invocation and result, and the uvzfs transcript had none.

Two environment facts the implementer needs (neither is a test failure):

1. A fresh run worktree has no Hex deps. Run
   `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix deps.get'` first,
   or `mix test` stops with `** (Mix) Can't continue due to errors on dependencies`.
2. The run environment exports `DATABASE_URL=postgres://postgres:postgres@localhost:55434/foreman_dev`;
   that server rejects `postgres/postgres` (`FATAL 28P01 invalid_password`) and `mix test` dies in
   `mix.exs:203 claim_database!/2`. The config default (`:55432`, container `foreman-postgres`)
   accepts it — hence the explicit `DATABASE_URL` above.

## 4. Edits

**None.** Do not add, change or delete any source or test file.

The only file this run writes is its own report,
`docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md`, which must state:

1. the verdict above, with the §1 table;
2. the test command from §3 and its `Result: 125 passed` / exit 0 outcome;
3. the two environment facts from §3;
4. the operator actions in §6.

## 5. Verification

The command in §3, unchanged, re-run after the report is written: it must still print
`Result: 125 passed` with exit 0. No formatter or Credo run is needed — no `.ex`/`.exs`
file is touched.

**Documentation gate:** the diff adds, removes and renames no externally visible identifier
(no route, config key, env var, CLI verb, MCP tool, command or event type). Grepping the four
gate files for the identifiers this bead names — `pr_body_headings`, `PrBodyPath`,
`## PR body`, `task_title` — returns no hits in `CLAUDE.md`, `README.md`,
`docs/user-guide.md` or `docs/cli-reference.md`, so there is no stale reference to fix and
nothing to document. Those identifiers are documented by `foreman-d6rth`
("Document new PR title/body behaviour and settings in docs/user-guide.md", still OPEN),
which owns that edit. **No edit to any of the four files.**

## 6. Out of scope — and operator actions

Do **not**:

- implement the PR title fallback, `## PR body` extraction, `pr_body_headings` or path
  scrubbing here; each is another bead's branch (§1) and re-implementing it conflicts with
  the open PR;
- add tests for any of those behaviours to `phase_pr_test.exs`, `phase_pr_body_test.exs`,
  `pr_body_test.exs` or `auto_pr_test.exs` on this branch;
- edit, cherry-pick, rebase or push any of the gocpd/txkmy/2uziy/p0b23/4oodz branches;
- touch `review_findings.ex`, `phase_pr.ex`, `auto_pr.ex` or `run_executor.ex`;
- commit the `deps/` directory or any `.log`/`.deps_get*.log` scratch file the dep fetch
  leaves behind (`git status` must be clean apart from the report).

Operator actions, for the report — none is this run's work:

1. **PR #955 (`foreman-2uziy`) cannot compile.** Its new
   `packages/foreman_server/test/foreman_server/workflow/pr_body_test.exs` aliases and calls
   `ForemanServer.Workflow.PrBody.from_artifact/2`, but that module is defined nowhere in
   `packages/foreman_server/lib` on that branch (`git grep "def from_artifact" <branch> --
   packages/foreman_server/lib` → no hits); the branch only adds
   `ReviewFindings.unfenced_lines/1`. Merging it reds the suite.
2. **Two branches are unpushed with no PR — work at risk of loss.**
   `foreman/foreman-p0b23/...` holds 398 lines of real code (`pr_body_headings` validation in
   `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex` and a new
   `packages/foreman_server/lib/foreman_server/run/pr_body.ex`) with **no tests and no
   callers** — `Run.PrBody` is referenced from nothing in `lib`.
   `foreman/foreman-4oodz/...` holds no code.
3. **Re-scope `foreman-a9e9d` after #955/#957/#959 merge.** The only coverage that will then
   still be missing is template headings (p0b23) and the review-section link (4oodz), and each
   belongs in its own bead's PR. Closing a9e9d as superseded is the cheaper option.
