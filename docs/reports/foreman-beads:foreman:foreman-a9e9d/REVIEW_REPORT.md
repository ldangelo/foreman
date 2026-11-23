# REVIEW_REPORT — `foreman-a9e9d` (repo-rules review, phase 4)

## Review engine

**Reviewer:** the in-run `repo-rules-review` phase agent (no external CLI; the CodeRabbit pass is
the separate `coderabbit-review` phase at `REVIEW_CODERABBIT_REPORT.md`). Rules applied: root
`AGENTS.md` — Documentation Gate, §5 typed boundaries / loud failures, Invariants, Testing and
Safety — plus this repository's standing rule that a run's report artifacts state what is
verifiably true.

**Exact diff range reviewed:** `git diff main...HEAD`, where `main` is the branch the run was cut
from (`$FOREMAN_BASE_BRANCH=main`): local `main` = `018da6b107d89dd1abb39786ae793eac2b0cd38d`,
`HEAD` = `2475a9fee7cd77cbc7ce8414bcf9e77fc8087443`, merge base =
`c209f8b4fb56c0bf39244c6d136f9d73625ec400`. `git diff --stat main...HEAD` = 3 files, 281
insertions: `FIX_REPORT.md` (+138), `PLAN.md` (+126), `REVIEW_CODERABBIT_REPORT.md` (+17) — all
under `docs/reports/foreman-beads:foreman:foreman-a9e9d/`. No lib, test, config, workflow or
prompt file is touched, so §5 (typed returns, total result handling, boundary normalization), the
closed workflow vocabulary, the PR-base rule, the operator-only merge gate, the retired dispatch
door and the provider-from-model-name rule are not exercised by this diff.

**Nothing was withheld from review.** Full range, full content, zero binary or generated files.

**Line-number convention.** `line` values for findings that were fixed point at the **reviewed
(`HEAD`) version** of the file, since the fix rewrote those lines; for declined findings they point
at the current file.

**Two things found that are not diff defects but change how the diff must be read.** Both were
verified in source, not inferred:

1. `ForemanServer.Workflow.RunExecutor` records a review run by
   `JobsiteGit.commit_all(path, "Foreman run #{run_id} phase #{phase_index}")`
   (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4912`) with no path
   filter, so it re-commits whatever the phase left in the artifact path. No Foreman code writes
   artifact content (`File.write` across `lib/foreman_server` matches
   `workflow/beads_tree_completion.ex:292` — an append — and two unrelated `exec/` files). Every
   artifact in this run was therefore overwritten **by its own author** just before that commit:
   `7aa7a22e` replaced the 138-line `FIX_REPORT.md` with the 33 bytes
   `Acknowledged (compressed history).`, and `2475a9fe` replaced the 146-line
   `REVIEW_CODERABBIT_REPORT.md` with a 17-line stub. This phase's `commit: true` + `artifact_path`
   means the same fate can befall this file; its machine blocks are written so that a truncation is
   loud rather than silent.
2. **There is no pull request for this branch.** `gh pr list --head
   foreman/foreman-a9e9d/run-6446bf4b0c969d12f787a0801b9879ce` returns `[]`, and
   `gh pr list --search a9e9d --state all` returns `[]`. The number `#953` that the phase-2 report
   cited belongs to a different, already-merged PR (`origin/feat/panel-reset-run`).

**Previous phase's findings carried forward.** `REVIEW_CODERABBIT_REPORT.md` at `HEAD` is the
17-line stub and has **no readable findings block**; its own prose still claims "both machine
blocks validated" and "still unresolved", so it is self-contradictory rather than clean. The same
agent's full 146-line report, including its three-finding machine block, exists in commit
`315e3ec3` (the commit that agent made immediately before the stub). That blob was restored into
the working tree; all three of its findings are carried below verbatim with `source: coderabbit`.

**Disclosure about the restored artifact.** The restored blob is byte-identical to history and
therefore still contains the phase-3 risk judgement block (it parses as `recorded`, `LOW`). It was
left intact rather than stripped: the restored file is the previous phase's historical artifact,
and this phase's own risk block is the one at the end of this file. `PrRisk.parse_judgement/1`
(`packages/foreman_server/lib/foreman_server/pr_risk.ex:61`) reads the **last** judgement block in
a given contents string, and Foreman reads the risk judgement from the final phase artifact
(`REVIEW_REPORT.md`), where the judgement below is the only one.

**Documented format deviation, disclosed rather than silently obeyed.** The contract forbids
`line` 0 and requires a positive integer or `null`. Two artifacts were clobbered **at line 1**
(the whole file is the defect), which `ReviewFindings` supports as `line: null`
(`packages/foreman_server/lib/foreman_server/workflow/review_findings.ex:136` — "null means whole
file"), so those findings use `null`; the PR-number defect is anchored to the real line
(`FIX_REPORT.md:4`). This file's own findings use exactly the keys `severity`/`path`/`line`/
`description`/`disposition`/`source` and nothing else. The phase-2 report's §6 block uses
`id`/`summary` and has no `source`, so it is quoted below, never copied into this block.

## Findings

Ten findings: three carried from the CodeRabbit pass, seven raised by this pass.
**Fixed: 6** (one artifact restoration plus five corrected claims; the two `FIX_REPORT.md`
provenance defects share one paragraph rewrite, so the Fixed section lists four edits).
**Declined: 2.** **Still open for a human: 2**, both major — the bead's coverage is still
missing, and this branch still has no PR.

| # | Sev | File | Finding | Disposition |
| --- | --- | --- | --- | --- |
| 1 | minor | `FIX_REPORT.md` | phase 2 clobbered its own report to 33 bytes (carried) | fixed |
| 2 | minor | `PLAN.md` | §1 credits PR #955's test file although §6 says it cannot compile (carried) | declined |
| 3 | **major** | `phase_pr_test.exs` | bead's requested coverage absent; deferred to #955/#957/#959 + `foreman-p0b23` (carried) | open |
| 4 | minor | `FIX_REPORT.md` | cites commit `6169c09c`, which does not exist | fixed |
| 5 | minor | `FIX_REPORT.md` | says "on this branch" for tests that live on `main` | fixed |
| 6 | minor | `REVIEW_CODERABBIT_REPORT.md` | phase-3 artifact clobbered to a 17-line stub with no machine block | fixed (restored) |
| 7 | minor | `FIX_REPORT.md` | cites PR #953, which is not this branch's PR | fixed |
| 8 | minor | `PLAN.md` | mislabels the merge base as "HEAD" | fixed |
| 9 | minor | `FIX_REPORT.md` §6 | findings block is YAML, not a `foreman.review_findings/1` JSON block | declined |
| 10 | **major** | branch | 5 commits / 3 artifacts, no PR ⇒ the `foreman-p0b23` loss pattern is live here | open |

Rows 2 and 9 are the only declines; row 2 is the carried CodeRabbit finding, whose line pointer
(25) is the table's related prose — the #955 row itself is `PLAN.md:16`. The numbers match the
machine block below one-for-one.

## Fixed

**`docs/reports/foreman-beads:foreman:foreman-a9e9d/REVIEW_CODERABBIT_REPORT.md` — the run's own
review evidence was missing from it.**
`main...HEAD` carried the 17-line stub, which has no machine block at all, so
`ReviewFindings.read/1` returns `:absent` — the module's documented meaning is "the review evidence
is missing, which is NOT a clean review" (`review_findings.ex:12-14`), and `pr_section/2`
(`review_findings.ex:254`, called from `run_executor.ex:706` and `:724`) renders "review evidence
missing" into any PR body built from it. The stub's prose also asserts "both machine blocks
validated" for a file that has none. Changed: restored the 146-line version from commit
`315e3ec3` — the artifact its author committed, not a rewritten or summarised copy. Verified
byte-identical to the blob: sha256 of the working-tree file and of
`git show 315e3ec3:docs/reports/foreman-beads:foreman:foreman-a9e9d/REVIEW_CODERABBIT_REPORT.md`
are both
`24e4db622555123341c14a46fec2c16b1afaf6c418b0c961b76e0dd4797a3fe2`. `ReviewFindings.read/1` on it
now returns `{:recorded, …}` with 3 findings (1 major, 2 minor), and
`PrRisk.parse_judgement/1` on it returns `status: "recorded"`, `level: "LOW"`.

**`docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md:4` — cited a PR that is not this
branch's.** Was `· PR #953 · HEAD \`c2666e72\``. `#953` is `origin/feat/panel-reset-run`, merged;
this branch has no PR (re-checked with `gh pr list --head …` → `[]`). `c2666e72` is the plan
commit, not the branch head (`2475a9fe`). Changed to: "no PR yet (none existed at phase 2; still
none at phase 4, checked `gh pr list --head …`) · HEAD `c2666e72` (the plan commit; branch head
when this report was recorded `7aa7a22e`)". The false number was the **only** occurrence of
`#953` in the run's artifacts — verified after the edit: `grep -rn "953" FIX_REPORT.md PLAN.md
REVIEW_CODERABBIT_REPORT.md` → no hits.

**`FIX_REPORT.md` §1 row 5 and the paragraph under it — wrong owner and wrong SHA for the existing
tests.** Two defects: it said `phase_pr_body_test.exs` was "committed at `6169c09c` on this branch"
and listed 5 tests, and row 5 said "**implemented AND tested here** | this branch".
`git cat-file -e 6169c09c` → `fatal: Not a valid object name 6169c09c`; the remote returns 404;
`git log --diff-filter=A -- …/phase_pr_body_test.exs` → `2fcddeef "Add in-run PR review workflow
(#487)"` (2026-11-21). The file is on `main` and contains **9** tests, not 5. Changed: row 5 now
reads "implemented AND tested on `main` | `main` (`phase_pr_body_test.exs`, since #487)"; the
paragraph now names `main` / `2fcddeef` / #487 and lists all nine tests; the §4 pointer at old line
106 now reads "already tested on `main`". The report's substance — target 5 is the only requested
item already covered — is unchanged and still correct.

**`docs/reports/foreman-beads:foreman:foreman-a9e9d/PLAN.md:10` — mislabelled HEAD.** Was
"Evidence, all re-verified at HEAD `c209f8b4` (an ancestor of `origin/main`)". `c209f8b4` is
neither the branch head (`2475a9fe`) nor `main`'s tip (`018da6b1`) — it is the merge base, the
commit this branch was cut from. Every claim in the table was re-checked at the merge base and
remains true, so only the label changed: now "Evidence, all re-verified against the commit this
branch was cut from, `c209f8b4` (an ancestor of `origin/main`, not its tip)". No table row was
touched.

## Declined

Two findings were declined; neither is a change this phase may make.

**`PLAN.md` §1 row for PR #955 (carried finding 2).** The finding: the coverage table counts #955
as an owner with tests although §6 shows its test file cannot compile. Declined, unchanged from
phase 3: the column is headed "**Tests already written**" and #955 really does carry them; §6
discloses the compile failure two lines away; and the branch's own rules forbid editing another
bead's PR from here. "Fixing" it means either dropping a true row or opening #955 from this
worktree — both outside this run's scope.

**`FIX_REPORT.md` §6 findings block is not a `foreman.review_findings/1` JSON block (finding 9).**
Confirmed by running the parser: `ReviewFindings.read/1` on the phase-2 report returns `:absent`
(its fenced YAML uses `id`/`summary` and has no `source`, so the one marker-delimited JSON block the
code accepts is absent). Declined on two grounds. (a) The reader consumes only the **last** phase
artifact (`run_executor.ex:4842-4848`, matching this run's `fix.yaml`, where `repo-rules-review`
is last), so converting phase 2's block would change no rendering. (b) `prompts/fix.md` never asks
the fix phase for a machine block, so rewriting it into a contract that phase was not given is
precisely the unrequested change this phase must not make. The information it holds is accurate and
readable as prose.

## Verification

**Narrowest test command for the source the bead is about — exit code 0, run before any edit:**

```
devbox run -- bash -c 'cd packages/foreman_server && \
  DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test \
  MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/phase_pr_test.exs \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/workflow/auto_pr_test.exs'
```

→ **125 tests, 0 failures** (`Finished in 31.0 seconds (5.3s async, 25.7s sync)`, `Result: 125
passed`, `ProjectionLeakGuard: judged 1 of 2 modules, no run left behind`). This confirms the
phase-2 claim in `FIX_REPORT.md` §2 and closes the gap the bead complained about ("the current
transcript contains no test command at all"). Two environment facts, both pre-existing and neither
a test failure: the run environment exports `DATABASE_URL` on port **55434**, whose server rejects
`postgres/postgres` (`FATAL 28P01 invalid_password`), so the config default **55432 /
foreman_test** (the `foreman-postgres` docker container) is what works; and a fresh run worktree
has no Hex deps, requiring `MIX_ENV=test mix deps.get` first or Mix stops with `Can't continue due
to errors on dependencies` — this worktree already had `deps/` and `_build/`, so this run did not
need it.

**The same three files were re-run after the edits — exit code 0, 125 passed.** The fixes touch no
`.ex`/`.exs` file.

**Parser round-trip on the four artifacts, exit code 0** (run from `packages/foreman_server` with
`MIX_ENV=test`, `mix run --no-start`), `ForemanServer.Workflow.ReviewFindings.read/1`:

| Artifact | Result |
| --- | --- |
| `REVIEW_CODERABBIT_REPORT.md` (restored) | `{:recorded, …}` — 3 findings (minor, minor, major), 1 `open` |
| `REVIEW_REPORT.md` (this file) | `{:recorded, …}` — 10 findings, 2 `open` |
| `FIX_REPORT.md` | `:absent` (documented under finding 9) |
| `PLAN.md` | `:absent` |

**Risk-block validation, exit code 0** —
`ForemanServer.PrRisk.parse_judgement/1` (`packages/foreman_server/lib/foreman_server/pr_risk.ex:61`)
on this file returns `%{status: "recorded", level: "LOW", defect: nil}` with the rationale
unchanged, confirming the block is one counted marker pair with a declared schema and a level in
`LOW|MEDIUM|HIGH`.

**Documentation gate — no finding raised.** This phase adds **no** new externally visible
identifier — no route, command, event type, MCP tool, CLI verb,
env var, config key or workflow/prompt name. The gate for a change that adds nothing is the grep
for removed/renamed identifiers, and this diff renames and removes none. For completeness the
four gate files were grepped for the affected symbols: `CLAUDE.md:1229` already documents
`Workflow.ReviewFindings.extract_block/3` together with the exact marker lines
(`<!-- FOREMAN_REVIEW_FINDINGS_START -->` / `<!-- FOREMAN_REVIEW_FINDINGS_END -->` and the
judgement pair) and the malformed/legacy failure modes, so the format this report uses is the
already-documented one; `README.md`, `docs/user-guide.md` and `docs/cli-reference.md` have no
hit for any of these symbols. No doc file needed an edit, because no operator-visible behaviour
was added, removed or renamed by this diff.

**`git diff main...HEAD` re-read once after the fixes.** The working tree now differs from `HEAD`
by the restored 146-line review report, the corrections listed under Fixed, and this new report
file. `git status --short` lists only paths under
`docs/reports/foreman-beads:foreman:foreman-a9e9d/`; no lib, test, config or workflow path appears
in the diff before or after; no fix introduced a claim the diff does not support. **Per the phase
contract, all fixes are left uncommitted** — Foreman records them at phase end.

**Not available in this phase:** `br`/Beads CLI, `foreman_inbox_send`, `foreman_task_add_comment`
and `kata` are not exposed here, so no progress notes or Beads/kata bookkeeping were sent. The
contract says to continue in that case, which is what happened; the Work Log below stands in for
the task comment.

## Open items for the operator

1. **The bead's own ask is still unimplemented (finding 3, major, carried).** Title fallback,
   `## PR body` extraction, project-setting template headings and absolute-path scrubbing have no
   tests on this branch, and two of the four are not even implemented here:
   `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:345` is still
   `title = "feat(phase): #{request.phase_name}"` (no task-title chain) and
   `ForemanServer.Workflow.PrBody` does not exist in this worktree. This branch cannot test
   another bead's feature, and adding a green test asserting behaviour that is absent at HEAD
   would be the red-suite failure mode AGENTS.md forbids ("A failing test is a failed build,
   full stop").
2. **This branch has no PR and carries five commits of artifacts (finding 10, major).**
   `foreman-p0b23` is the cautionary case already named in this run's reports: 398 lines, unpushed,
   no PR, at risk of loss. `foreman-a9e9d` is in the same position until a PR exists, and this
   phase's `commit: true` + `stack_pr: true` is the last point at which one can be opened. Opening
   and merging are the operator's call — AGENTS.md: the merge gate is operator-only.
3. **PR #955 still cannot compile (minor, open).** Its `pr_body_test.exs:31` calls
   `ForemanServer.Workflow.PrBody.from_artifact/2`, a module absent at its own head `981ce12b1`;
   merging it reds that suite. Owned by `foreman-2uziy`, not this branch.
4. **Two environment defects worth their own bead (neither caused by this run).** The
   `DATABASE_URL` port mismatch above (run env exports 55434, only 55432 works), and the
   phase-artifact truncation mechanism described under Review engine — the latter destroyed
   evidence in two of this run's three phases, which is exactly how a run ends up "passing" with
   no review evidence at all.

## Work Log

Task `beads:foreman:foreman-a9e9d` · run `run-6446bf4b0c969d12f787a0801b9879ce` · phase 4
`repo-rules-review`. Reviewed `main...HEAD` against the root `AGENTS.md`. Restored the clobbered
CodeRabbit artifact from `315e3ec3`; corrected a non-existent commit SHA, a wrong "this branch"
test-ownership claim, a false PR number and a mislabelled HEAD in the phase-2/3 report and the
plan; confirmed 125 tests green in the three files the bead names; ran the documentation gate.
Carried 3 CodeRabbit findings, raised 7 more: 6 fixed, 2 declined, 2 still open for a human.
Fixes left uncommitted. `foreman_inbox_send` / `foreman_task_add_comment` unavailable — this
section stands in for the comment.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema":"foreman.review_findings/1","reviewed":true,"findings":[{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md","line":null,"description":"The phase-2 commit replaced the whole 138-line FIX_REPORT with the 33-byte string \"Acknowledged (compressed history).\", dropping the verdict, the mix test invocation and result, the environment facts and the operator actions.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/PLAN.md","line":25,"description":"The §1 coverage table counts PR #955 as an implemented-with-tests owner although §6 of the same plan shows that PR's test file cannot compile.","disposition":"declined","source":"coderabbit"},{"severity":"major","path":"packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs","line":null,"description":"The bead's requested coverage (title fallback chain, `## PR body` extraction, template headings, absolute-path scrubbing) is still absent from this branch; phase 2 deliberately deferred it to the owning PRs #955/#957/#959 and the unpushed foreman-p0b23 branch.","disposition":"open","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md","line":28,"description":"The report cites commit 6169c09c as the provenance of phase_pr_body_test.exs, but no such object exists in this repository or on the remote (git cat-file and the remote API both fail); the file actually arrived on main in 2fcddeef (#487).","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md","line":25,"description":"Table row 5 says the review-findings PR-body coverage is \"implemented AND tested here\" on \"this branch\", and the paragraph below calls those 298 lines committed on this branch, when the file is present in main and this branch adds no tests to it.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/REVIEW_CODERABBIT_REPORT.md","line":null,"description":"The run's own CodeRabbit report was truncated to a 17-line stub carrying no foreman.review_findings/1 block while its prose asserts \"both machine blocks validated\", so ReviewFindings.read/1 returns :absent (review evidence missing, not a clean review) even though the full 146-line version with its machine block exists in commit 315e3ec3.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md","line":4,"description":"The report header presented PR #953 as this run's pull request, but #953 is the merged feat/panel-reset-run PR and gh reports no pull request for branch foreman/foreman-a9e9d/run-6446bf4b0c969d12f787a0801b9879ce.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/PLAN.md","line":10,"description":"The §1 evidence line says \"all re-verified at HEAD c209f8b4\", but c209f8b4 is neither the branch head 2475a9fe nor the tip of main 018da6b1 — it is the merge base this branch was cut from.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/FIX_REPORT.md","line":132,"description":"§6 presents its findings as fenced YAML with id and summary keys rather than the foreman.review_findings/1 JSON block between the marker comments, so ReviewFindings.read/1 on this phase's artifact returns :absent instead of a record.","disposition":"declined","source":"repo-rules"},{"severity":"major","path":"docs/reports/foreman-beads:foreman:foreman-a9e9d/PLAN.md","line":null,"description":"This branch holds five commits of report artifacts with no pull request open, so, exactly as foreman-p0b23's unpushed 398 lines are described in FIX_REPORT.md §5, nothing outside this worktree retains the run's work if the worktree is reclaimed.","disposition":"open","source":"repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema":"foreman.risk_judgement/1","level":"LOW","rationale":"No production code is changed by this phase: it restores a destroyed run artifact from commit 315e3ec3 byte-for-byte and corrects four verifiably false statements in reports that no code imports, with the 125 tests over phase_pr, phase_pr_body and auto_pr unchanged at 0 failures. The real risk is not in this diff — it is that the bead's test coverage remains unwritten across four other beads' branches and this branch still has no PR, both recorded as open findings."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
