# CodeRabbit review — beads:foreman:foreman-d6rth

Run: `run-090f5deed6c91ee5e888f52db133f185` · Phase 3 (`coderabbit-review`) · Base branch: `main`

## Review engine

Command run from the worktree root, twice (one round each):

```console
$ coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

`FOREMAN_BASE_BRANCH` was set to `main` (the branch the run was cut from), so the diff
base is correct and was not substituted. Engine: CodeRabbit CLI `0.9.6`
(`/Users/ldangelo/.local/bin/coderabbit`), the same engine as the GitHub PR bot, run
locally against the working tree. Exit code `0` in both rounds, with the CLI reporting
`status: review_completed`.

Round 1 reviewed 2 files, round 2 reviewed 3 files — the run's report artifacts and
`docs/user-guide.md`. The branch carries no implementation code: `git diff --stat
main...HEAD` is two files under `docs/reports/foreman-beads:foreman:foreman-d6rth/`, so
there was nothing else for the engine to look at.

## Rounds

### Round 1 — 2 findings (1 major, 1 minor)

| # | Severity | File | Finding |
| --- | --- | --- | --- |
| R1-F1 | major | `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:5` | Restore the missing section 3 and "Out of scope" list in PLAN.md |
| R1-F2 | minor | `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:23` | Scope the premise re-check greps so they skip this plan |

Fixed: R1-F1 (restored the phase-1 plan byte-identically from commit `534a5150`), R1-F2
(narrowed the two premise greps with a `:(exclude)docs/reports` pathspec).

### Round 2 — 4 findings (all minor)

| # | Severity | File | Finding |
| --- | --- | --- | --- |
| R2-F1 | minor | `docs/user-guide.md:3018-3020` | Qualify the task-backed body rule |
| R2-F2 | minor | `docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md:82` | Run the intended Go tests |
| R2-F3 | minor | `docs/user-guide.md:3015-3017` | Qualify the meaning of a missing `Artifact:` line |
| R2-F4 | minor | `docs/user-guide.md:3013` | The guide's "committed on the run branch" statement is wrong for `commit: false` phases |

Fixed: all four (R2-F1, R2-F3, R2-F4 as prose corrections to the new
`docs/user-guide.md` paragraph; R2-F2 as a correction to the verification command and
result recorded in `FIX_REPORT.md`).

No round 3 was run: round 2 produced no `Critical` or `Major` finding, which is the
phase's stop condition.

## Fixed

**R1-F1 — `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:5` (major).**
What was wrong: the plan on the branch was 25 lines, not the 154-line plan phase 1 wrote.
Phase 2's commit `cc43eb7e` truncated it, dropping section 3 (the premise re-check
commands and the failing check) and section 6 (the "Out of scope" list). The bullets that
survived referred to content that was no longer in the file — the re-check commands "at
head section 3" and the refusal list naming refused items 2 and 3 — so the plan no longer
carried a stop gate or an explicit refusal, and an implementer reading it could have
documented the `## PR body` convention and the `pr_body_template` setting, which do not
exist. What changed: the plan was restored byte-identically from commit `534a5150`
(`git show "534a5150:docs/reports/.../PLAN.md" > .../PLAN.md`), and the two premise greps
were then narrowed (R1-F2). The "artifact line" complaint is resolved by the restore
itself: the surviving 25-line version carried a `(153 lines)` note that the restored
154-line plan does not, and the restored plan has no such line to fix.

**R1-F2 — `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:23` (minor).**
What was wrong: the plan's premise re-check greps were `git grep -- "## PR body"` and
`git grep pr_body_template`, unscoped. Both strings appear in the plan itself, so once
the plan is committed an unscoped `git grep` matches the plan's own lines and the stop
condition fires on a self-reference instead of on a real code change. What changed: both
greps now carry a `:(exclude)docs/reports` pathspec
(`git grep -- "## PR body" -- ':(exclude)docs/reports'`), and the plan says why.

**R2-F1 — `docs/user-guide.md:3018-3020` (minor).**
What was wrong: the new paragraph said "Task-backed final AutoPR bodies are the task
description verbatim and carry no `Artifact:` line either way", which is not what the code
does in every case. `AutoPr.pr_content/1` uses the task description as the body only when
the task has one; a task with a title but no description falls back to the generated body,
which does carry the `Artifact:` line. And because the body is the description verbatim, a
description that contains its own `Artifact:` line brings it with it — Foreman appends
nothing. What changed: the closing sentences now read "A task-backed final AutoPR uses
the task description verbatim as its body and adds no `Artifact:` line of its own — a
description that carries one brings its own — while a task with a title but no description
falls back to a generated body, which does carry the line."

**R2-F2 — `docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md:82` (minor).**
What was wrong: my own verification table recorded the Go filter as
`-run 'TestUserGuide\|TestUsageDrift'`. Inside single quotes the backslash reaches Go's
regexp engine, where `\|` is a literal pipe, so the pattern matched **no** test and the
exit code `0` proved nothing. `TestUsageDrift` does not exist either — the usage-drift
tests are named `TestUsageAdvertisesExactlyTheDispatchedVerbs`,
`TestCLIReferenceDocumentsEveryDispatchedVerb`, `TestAgentCommandSpecsRouteToDispatchedVerbs`
and `TestCLIReferenceNotImplementedClaimsAreAccurate`. What changed: the report now
records the unescaped alternation plus `-v`, so the six named tests appear as `PASS` in the
output, and the report says plainly that the earlier command matched nothing.

**R2-F3 — `docs/user-guide.md:3015-3017` (minor).**
What was wrong: the paragraph claimed a missing `Artifact:` line means the path was
outside the repository. `PrBodyPath.artifact_line/2` returns `""` for two different
reasons: a `nil` artifact path, and a path outside the repository root. What changed: the
sentence now reads "An artifact that cannot be expressed relative to the repository root
gets **no** `Artifact:` line at all, rather than an absolute one — and neither does a
phase that recorded no artifact path, so a missing line means one of those two, not that
the phase produced nothing."

**R2-F4 — `docs/user-guide.md:3013` (minor).**
What was wrong: the paragraph said the artifact "is committed on the run branch, so the
relative form … resolves on GitHub". That holds for a phase that commits, but a phase that
declares `commit: false` has its commit step deferred
(`Workflow.Lowering.commit_step/4` sets `defer?: true`), so `RunExecutor.phase_finish/5`
reaches `maybe_record_phase_pr/5` — and therefore the phase PR — while the artifact is
still uncommitted in the worktree. The pushed branch does not carry the file yet, so the
relative path names a file GitHub cannot serve. What changed: the paragraph now states
"A phase that defers its commit (`commit: false`) can open its PR before that commit, so
its `Artifact:` line names a file the pushed branch does not carry yet — the path resolves
once a later commit on the run branch adds the file, and never if no later commit does."

## Declined

None. All six findings were real and were fixed.

## Verification

```console
$ cd packages/foreman_cli && go test ./cmd/foreman/ -run 'TestUserGuide|TestUsageAdvertisesExactlyTheDispatchedVerbs|TestCLIReferenceDocumentsEveryDispatchedVerb|TestAgentCommandSpecsRouteToDispatchedVerbs|TestCLIReferenceNotImplementedClaimsAreAccurate' -v
# exit 0 — 6 tests PASS; ok github.com/fortium/foreman/packages/foreman_cli/cmd/foreman 0.166s

$ devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs'
# exit 0 — Result: 3 passed

$ git grep -- "## PR body" -- ':(exclude)docs/reports'
# exit 1 (no match)

$ git grep "pr_body_template" -- ':(exclude)docs/reports'
# exit 1 (no match)

$ grep -n "Artifact:" docs/user-guide.md docs/cli-reference.md README.md CLAUDE.md
# exit 0 — four hits, all in docs/user-guide.md (lines 3012, 3015, 3018, 3022), i.e. the
#          new paragraph; the same grep over docs/cli-reference.md README.md CLAUDE.md
#          alone exits 1. Before this change the rule was documented in none of the four.
```

The first three commands are the plan's premise re-check. Before the change all of them
were silent — `## PR body` and `pr_body_template` matched nothing outside `docs/reports/`,
and `Artifact:` matched nothing at all — which is what made the one real gap visible. After
the change the third one matches the new paragraph by design: the gap is closed.

The first Elixir invocation needed `devbox run -- bash -c 'cd packages/foreman_server &&
mix deps.get'` (the fresh worktree had no `deps/`); after that the command above boots
and passes. Only noise in its output: `[error] idempotency store is not durable: no repo
is configured (ETS fallback)`. No formatter applies — the diff touches no `.ex`/`.exs`
file.

## Changes this phase left uncommitted

Foreman commits this phase's work; the following were left in the worktree for that commit,
and Foreman's phase 3 commit has since committed them onto the run branch. That same commit
then replaced this file with a 19-line prose summary with no `##` sections and neither
machine-readable block; phase 4 restored this version and corrected the table below, which
had claimed the files were still pending.

| File | Diff | What |
| --- | --- | --- |
| `docs/user-guide.md` | +16 / -0 | The new "A generated PR body carries no absolute host path." paragraph (lines 3010-3024) |
| `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md` | +150 / -18 | Phase-1 plan restored byte-identically from `534a5150`, plus the narrowed premise greps |
| `docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md` | +117 / -1 | Truthful fix report replacing phase 2's tool-error fragment, corrected after R2-F2 |
| `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md` | new | This report |

Two things this phase did on its own initiative, outside the review findings, and says so
plainly rather than hiding inside the JSON block:

- The bead's deliverable — the `docs/user-guide.md` paragraph — had not been written.
  Phase 2 (`fix`) produced only a 153-byte tool-error fragment as `FIX_REPORT.md` and
  truncated the plan, and the workflow has no later implementation phase, so the
  paragraph was implemented here from the phase-1 plan (its own wording, narrowed by the
  round-2 findings). Without this the bead would have closed undocumented.
- `PLAN.md` and `FIX_REPORT.md` were repaired, because the review engine reads them and a
  truncated plan misleads every later reader.

The documentation gate for this change: no externally visible identifier was added,
removed or renamed — the diff is prose only, and the `## PR body` convention and the
`pr_body_template` setting it mentions in the *plan* do not exist in the codebase and are
documented nowhere as features. `CLAUDE.md:1216`, `README.md:288` and
`docs/cli-reference.md:622` already carry the engineering statement of the same rule and
needed no edit. `AGENTS.md`, `docs/PRD/*` and `docs/TRD/*` are point-in-time and were left
alone.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md", "line": 5, "description": "The committed plan had been truncated to 25 lines, dropping section 3 and the \"Out of scope\" list, so it carried neither the premise re-check commands nor the refusal list.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md", "line": 23, "description": "The plan's premise re-check greps were unscoped and matched the plan's own quoted strings, which would trip the stop condition on a self-reference.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3018, "description": "The task-backed AutoPR body rule was stated as unconditional, but a title-only task falls back to a generated body and Foreman appends no `Artifact:` line of its own to a verbatim task description.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md", "line": 82, "description": "The recorded Go test filter escaped the alternation pipe, so it matched no test and its exit code 0 proved nothing.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3015, "description": "A missing `Artifact:` line was documented as meaning only that the path was outside the repository, ignoring the nil-artifact-path case.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3013, "description": "The guide claimed the artifact is committed on the run branch, which is wrong for a `commit: false` phase whose PR opens before its artifact is committed.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The change is documentation prose plus repair of two run-report artifacts; no runtime code, command, route or setting is touched. The new paragraph states only behaviour verified against the source (PrBodyPath.artifact_line/2, AutoPr.pr_content/1, the deferred commit step), and both verification commands pass."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
