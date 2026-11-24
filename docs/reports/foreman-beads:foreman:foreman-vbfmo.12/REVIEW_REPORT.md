# Repo-Rules Review Report — beads:foreman:foreman-vbfmo.12

Run `run-8b082d394baee424caa1ed9299ff2022` · phase 4 (`repo-rules-review`) · branch
`foreman/foreman-vbfmo.12/run-8b082d394baee424caa1ed9299ff2022`.

## Review engine

Reviewer: this phase (no external review CLI — the phase contract is one pass against this
repository's own rules). Rules source: `AGENTS.md` (repo root) — Working Rules, Documentation
Gate, §5 Typed Boundaries/Loud Failures, Testing and Safety — plus the repository's own CI
gates in `.github/workflows/ci.yml` and the established idioms in the touched files.

Diff range reviewed: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH` = `main`, resolved to
`546e1d57`; merge-base `0988b071`; HEAD `a7b31744`). The three-dot range is the run's own
work — 5 files, 173 insertions, 1 deletion:

- `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md` (new, 3 lines)
- `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/PLAN.md` (new, 145 lines)
- `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md` (new, 15 lines)
- `packages/foreman_server/lib/foreman_server/coordinator/context.ex` (+8 / −1)
- `packages/foreman_server/test/foreman_server/coordinator/context_test.exs` (+3)

**Previous phase's findings could not be carried forward in machine-readable form.**
`docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md` (phase 3) is
15 lines of prose with **no** `FOREMAN_REVIEW_FINDINGS` block and **no**
`FOREMAN_RISK_JUDGEMENT` block, so there is no `findings` array to copy. Its three findings are
recorded in prose there (2 Round-1 minors on `context.ex:138` / `context_test.exs:363`, 1
Round-2 minor on a stale "active threads now" claim in its own report) and it states all three
were fixed. I re-verified each against the code as it now stands and they are indeed resolved;
I list them below under Findings with `source: "coderabbit"` rather than dropping them.

## Findings

| # | Severity | Where | Finding | Disposition | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | major | `packages/foreman_server/test/foreman_server/coordinator/context_test.exs` | New asserts are not `mix format`-clean; CI's format gate would fail. | **fixed** | repo-rules |
| 2 | minor | `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md` | The fix phase's declared artifact holds captured tool output, not a report. | declined | repo-rules |
| 3 | minor | `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md` | Phase-3 report ships without the machine-readable findings/risk blocks. | declined | repo-rules |
| 4 | nitpick | `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/PLAN.md` | Plan prescribes two more status assertions (`stuck`, `needs_recovery`) than the test implements. | declined | repo-rules |
| 5 | nitpick | branch vs `main` | Branch is 3 commits behind `main`. | declined | repo-rules |
| 6 | minor | `packages/foreman_server/lib/foreman_server/coordinator/context.ex:138` | `cancelled` had no clause of its own, so it fell through to `:idle`, and to `:ready_for_review` once a `last_report` existed (that clause sits above the status clauses), which also exempted it from `drop_order/1` card eviction. | fixed (by phase 3) | coderabbit |
| 7 | minor | `packages/foreman_server/test/foreman_server/coordinator/context_test.exs:363` | The test asserted the `:idle` fallback instead of the required disposition. | fixed (by phase 3) | coderabbit |
| 8 | minor | `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md` | Round-2 claim that cancelled threads still inflate "active threads now" was stale. | fixed (by phase 3) | coderabbit |

## Fixed

**`packages/foreman_server/test/foreman_server/coordinator/context_test.exs`** (finding 1).
`mix format --check-formatted` failed on this file — the only unformatted file in
`packages/foreman_server`, and CI runs that exact check
(`.github/workflows/ci.yml:136-138`, "Format check"), so the branch as committed would have
red-lined the build. Cause: the two asserts the earlier phases added inside the existing
`"card states follow the thread's disposition and status"` test were inserted without the blank
lines the formatter requires around a multi-line assertion. Fix: ran the repo's own formatter —
`cd packages/foreman_server && mix format test/foreman_server/coordinator/context_test.exs` —
which inserted exactly two blank lines (after `assert Context.card_state(thread(1, "cancelled")) == :resolved`
and after the `:resolved` continuation line). No assertion, no expectation, no other line
changed; `main`'s copy of this file was already format-clean, so the violation came from this
branch. Re-running the package-wide check now exits 0.

No other change was warranted. The code fix itself is already idiomatic and matches the
established style of the clause list it sits in (`card_state/1` is a flat list of heads over
`%Thread{}` patterns, `context.ex:135-152`); the new clause is ordered **above** the
`last_report` clause, which is what makes it actually win; the `@doc`/`@spec` atom set
(`:waiting_on_you | :ready_for_review | :working | :idle | :resolved`) is unchanged, so there is
no spec drift; the terminal grouping matches `Overview.Group.classify/1`
(`overview/group.ex:121,139` — `@cancelled ~w(cancelled deleted removed)` →
`{:resolved, :cancelled}`), so the two surfaces now agree. Per AGENTS.md §5 there is no untyped
map, no catch-all success arm, and no absent-is-malformed conflation introduced. The
`drop_order/1` eviction list (`context.ex:219`, "Cards cut first: resolved then idle") and
`limits_section/1` (`context.ex:440`, counts only `:working`/`:waiting_on_you`) mean the
operator-visible consequences the bead named — the bogus waiting card and the inflated "active
threads now" count — are both closed by this one clause; nothing else needed to change.
`card_state/1` is referenced only from `context.ex` and `context_test.exs` repo-wide, and no
other coordinator test pins `cancelled` (only `reporter_test.exs:285` and
`harness_usage_test.exs:56-57`, which concern `RunCancelled` reporting), so no other test was
left asserting the old behaviour.

**Documentation gate (AGENTS.md):** every externally visible identifier in the diff was checked.
None added, removed or renamed — no command/event type, MCP tool, HTTP route, CLI verb, env var,
config key or workflow/prompt name. Grepping `CLAUDE.md`, `README.md`, `docs/user-guide.md` and
`docs/cli-reference.md` for `card_state`, "coordinator card" and "waiting card" → 0 hits. The
`waiting_on_you` / `ready_for_review` hits that do exist (`CLAUDE.md:1157`,
`docs/cli-reference.md:860`, `docs/user-guide.md:422`, `:1451`, `:1454-1458`, `:1475`, `:3420`)
all describe `Overview.Group.classify/1` / the Overview MCP grouping, which this diff does not
touch and which already groups `cancelled` as resolved. `docs/user-guide.md:2806` only says the
coordinator turn renders "thread cards", without documenting the status→state mapping. So **none
of the four documentation files needed an edit** (reason: no operator-visible identifier or
documented behaviour changed); the same reasoning applies to `CHANGELOG.md` — the last four
commits touching `coordinator/context.ex` on `main` (`e1e9c191`, `3c9ac829`, `74182c18`,
`988122ca`) added no CHANGELOG entry, so adding one would deviate from the repo's own norm.

## Declined

**`docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md`** (finding 2). The file is
the fix phase's declared artifact (`packages/foreman_server/priv/defaults/workflows/fix.yaml:51
artifact: "{task.projectReportsDir}/FIX_REPORT.md"`), and its committed content is not a report —
169 bytes of captured tool output: "No session holds `foreman_test` now (only my psql). lock
likely transaction-advisory lock; let me read `claim_database!` see whether stale lock
remains." That violates AGENTS.md's scratch rule (captured command output never gets committed).
Declined anyway, for two reasons. First, it is another phase's record: rewriting it here would
put words in that phase's mouth, which is exactly the falsification AGENTS.md warns against.
Second, there is no correct content to restore: the 143-line original does exist in git
(`git show 91fc4f8f:docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md`) but it
describes a different code lineage — it asserts against `Context.summary/1`, `groups.done` and
`groups.needs_attention`, none of which exist in this version of `Context`, and it, too, ends in
a pasted `CODE_REVIEW_REPORT.md` tool-error fragment. Restoring it would trade junk for
confidently wrong. Actionable by the operator, not by this phase: the fix phase's artifact needs
to be regenerated by that phase (note that commit `df38cb84` is what replaced the 143-line
version with the 169-byte one).

**`docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md`** (finding 3).
Its findings and risk claim are prose-only, so Foreman cannot read them and the operator sees
neither the 3 findings nor the `LOW` claim. Declined because that artifact belongs to phase 3;
only this phase's own artifact is attached to the pull request, and the block written there
carries all 3 findings (rows 6-8 above), so nothing is lost to the operator. The gap is a
phase-contract observation, not a defect in the run's code.

**`docs/reports/foreman-beads:foreman:foreman-vbfmo.12/PLAN.md`** (finding 4). §4 Edit 2 proposed
also asserting `stuck` and `needs_recovery` → `:waiting_on_you`; the test asserts
`blocked`/`failed`/`cancelled`. Declined: the bead's Done clause asks for "each status" for the
cancelled/failed distinction, AGENTS.md forbids scope growth beyond the request ("Surgical
changes", "No speculative features"), and the two dropped statuses are unchanged by this diff —
they stay in the `~w(blocked stuck needs_recovery paused failed)` guard at `context.ex:143-144`.
Adding them would be a plan-completeness nicety, not a rules violation.

**Branch behind `main`** (finding 5). `main` (`546e1d57`) is 3 commits ahead of the merge-base
and added `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex` plus changes to
`phase_pr.ex`, `auto_pr.ex`, `run_executor.ex`, `review_findings.ex`, `CHANGELOG.md` and three
docs files. Declined as out of scope: that is not this run's diff (the three-dot range excludes
it), AGENTS.md forbids unrelated changes here, and there is no conflict risk — `git diff
0988b071 main -- packages/foreman_server/lib/foreman_server/coordinator/context.ex` is empty, so
`main`'s `card_state/1` guard is still the pre-fix one and this run's change applies cleanly.
Rebasing/syncing is the operator's call, not a review fix.

## Verification

Run in `packages/foreman_server` with `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test
MIX_ENV=test` (the docker `foreman-postgres` container; `devbox` was also usable but plain `mix`
with that env is equivalent here).

| Command | Exit |
| --- | --- |
| `mix format --check-formatted` (before fix, package-wide) | 1 — `context_test.exs` unformatted |
| `git show main:…/context_test.exs` + `mix format --check-formatted` on that copy | 0 — `main` was clean, so the violation is this branch's |
| `mix format test/foreman_server/coordinator/context_test.exs` | 0 |
| `mix format --check-formatted` (after fix, package-wide) | 0 |
| `mix compile --warnings-as-errors` | 0 |
| `mix test test/foreman_server/coordinator/context_test.exs test/foreman_server/overview/group_test.exs` | 0 — 87 passed (1 property, 86 tests) |
| `git diff main...HEAD` re-read after the fix | 0 — only the two blank lines added; no new violation |

The narrowest command the repo's own tooling provides for the touched file is the second row's
`mix test` pair; the full suite was not run (AGENTS.md: use the narrowest affected files, and the
full suite is neither fast nor known-reliable here). Only log noise appeared: "idempotency store
is not durable: no repo is configured (ETS fallback)" — a known config warning, not a failure.
The formatter fix is left uncommitted for Foreman to commit, per the phase contract.

`ask_advisor` was attempted and is unusable in this environment (Anthropic oauth refresh returns
400 `invalid_grant` / "Refresh token expired"), so this review carries no Advisor consultation;
the operator needs to re-auth.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/coordinator/context_test.exs", "line": 363, "description": "The newly added card_state assertions are not mix format-clean, so CI's own format gate (.github/workflows/ci.yml:136-138) would fail on this branch.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md", "line": 1, "description": "The fix phase's declared artifact contains 169 bytes of captured tool output instead of a fix report.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The phase-3 review report has no machine-readable findings or risk-judgement block, so Foreman cannot read its three findings or its risk claim.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "docs/reports/foreman-beads:foreman:foreman-vbfmo.12/PLAN.md", "line": 1, "description": "PLAN.md prescribes asserting stuck and needs_recovery map to :waiting_on_you, which the implemented test omits.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/coordinator/context.ex", "line": 141, "description": "The branch is 3 commits behind main, which has since added workflow/pr_body_path.ex and changed phase_pr.ex, auto_pr.ex and run_executor.ex.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/coordinator/context.ex", "line": 138, "description": "A cancelled thread had no clause of its own, so it classified :idle, or :ready_for_review once it had a last_report, which also exempted it from drop_order/1 card eviction.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/test/foreman_server/coordinator/context_test.exs", "line": 363, "description": "The cancelled case asserted the :idle fallback instead of the disposition the task requires.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "Round-2 claim that cancelled threads still inflate the active threads now count was stale; limits_section/1 counts only :working and :waiting_on_you.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "Production change is one clause in card_state/1 that short-circuits cancelled threads to :resolved above the last_report clause, plus two test assertions; the terminal atom set and every other status mapping are untouched, and it matches what Overview.Group.classify/1 already does. Re-verified with compile --warnings-as-errors, 87 passing tests over the coordinator and Overview grouping, and a now-clean package-wide format check, so the only defect this phase found was CI formatting. Residual risk is behavioural, not mechanical: cancelled cards are now evicted first by drop_order/1, so a cancelled thread disappears from the coordinator prompt sooner."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
