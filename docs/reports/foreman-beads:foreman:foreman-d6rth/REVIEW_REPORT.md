# Review report — repository rules

## Review engine

Repository-rules reviewer: the Foreman `fix` workflow's `repo-rules-review` phase agent
(phase 4 of run `run-090f5deed6c91ee5e888f52db133f185`, task `beads:foreman:foreman-d6rth`).

Diff range reviewed: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with
`$FOREMAN_BASE_BRANCH=main` (set, non-empty) — merge-base `39303e89`, branch `HEAD`
`aa96d402`, i.e. `main...HEAD`. That range is 4 files:

- `docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md` (+117)
- `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md` (+158)
- `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md` (+19 at HEAD)
- `docs/user-guide.md` (+16)

The repository-rules applied are this repo's own `AGENTS.md` (working rules, §5 typed
boundaries, invariants, documentation gate, testing/safety) plus
`packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md` (the phase
contract: sections in order, findings block keys, risk-judgement block last, marker lines
outside code fences, fixes left uncommitted).

The previous phase's artifact `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md`
was read and **has a readable findings block** (6 entries, all `source: "coderabbit"`); all 6
are carried forward below with their `source` kept. Its judgement block was **not** copied.

Note on `main`: `git rev-list --left-right --count main...HEAD` = `14  5`, so `main` carries
14 commits that post-date the merge-base and that are **not** part of this run's diff. Where
this report compares the branch against upstream `main`, that is stated explicitly.

## Findings

Received from the previous phase (`REVIEW_CODERABBIT_REPORT.md`, `source: coderabbit`) and
re-verified against the code as it is now — all six are **fixed** (the fixes are already in
the branch's committed history):

1. `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:5` (major) — the plan had been
   truncated to 25 lines. **Fixed.**
2. `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:23` (minor) — the plan's
   unscoped greps matched their own report output. **Fixed.**
3. `docs/user-guide.md:3018` (minor) — the task-backed PR-body rule was stated
   unconditionally. **Fixed.**
4. `docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md:82` (minor) — the recorded
   `go test -run` filter contained a non-existent test name. **Fixed.**
5. `docs/user-guide.md:3015` (minor) — the missing `Artifact:` line was described as having a
   single cause. **Fixed.**
6. `docs/user-guide.md:3013` (minor) — the `commit: false` phase case was not covered. **Fixed.**

Found by this phase (`source: repo-rules`) — one fixed, one fixed, two declined:

7. `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md` (major) —
   the phase-3 commit `aa96d402` replaced the contract-compliant report with a 19-line prose
   summary that has no `##` sections and neither machine-readable block, while its own text
   claimed "JSON blocks validated". Foreman reads this artifact through
   `ForemanServer.Workflow.ReviewFindings.parse/1` and `ForemanServer.PrRisk.parse_judgement/1`,
   so the phase-3 report was unreadable to the operator. **Fixed.**
8. `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md:126` (minor) — the verification
   command recorded in the plan named the non-existent Go test `TestUsageDrift`; `go test -run`
   matches by regexp, so the recorded exit code proved nothing. **Fixed.**
9. `docs/user-guide.md` (minor) — the bead premise asks for a `## PR body` convention and a
   project body-template setting to be documented. Neither is carried by this branch, and the
   setting is already implemented and documented upstream. **Declined.**
10. `docs/user-guide.md:3021` (nitpick) — the new paragraph's cross-reference to "the
    `## Review findings (the review agent's report)` section above". **Declined** (the
    reference resolves to real prose).

## Fixed

- **File:** `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md`
  **What was wrong:** the committed version (phase-3 commit `aa96d402`) was a 19-line prose
  summary — no `## Review engine` / `## Rounds` / `## Fixed` / `## Declined` /
  `## Verification` headings, and no findings block and no risk-judgement block — so
  `ForemanServer.Workflow.ReviewFindings.parse/1` and
  `ForemanServer.PrRisk.parse_judgement/1` could not read it and the operator saw no findings.
  The phase-3 report also claimed the JSON blocks had been validated, which the artifact it
  committed did not contain.
  **What changed:** restored the contract-compliant version from commit `77e4e158`. The diff
  against `77e4e158` is exactly one hunk — the intro paragraph of
  `## Changes this phase left uncommitted` — rewritten so it states the committed truth
  (Foreman's phase-3 commit committed those files, and that same commit replaced this file
  with the prose summary) instead of the stale "still pending" claim; every other byte is
  identical to `77e4e158`. The restored file is 195 lines: sections in the contract order,
  findings block at lines 190-192 and risk-judgement block at lines 193-195, both raw JSON
  between marker lines that stand alone at column 0 outside any code fence.

- **File:** `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md`
  **What was wrong:** §5's verification command was
  `go test ./cmd/foreman/ -run 'TestUserGuide|TestUsageDrift'`. No Go test named
  `TestUsageDrift` exists, and `go test -run` selects by regexp, so the filter matched only
  the `TestUserGuide*` tests and the recorded exit code 0 proved nothing about the rest.
  **What changed:** §5 now names the six tests that actually exist and are relevant to the
  doc gate: `TestUserGuideUsageExampleExecutesAgainstCLI`,
  `TestUserGuideProjectExamplesExecuteAgainstCLI`,
  `TestUsageAdvertisesExactlyTheDispatchedVerbs`,
  `TestCLIReferenceDocumentsEveryDispatchedVerb`,
  `TestAgentCommandSpecsRouteToDispatchedVerbs`,
  `TestCLIReferenceNotImplementedClaimsAreAccurate`. Nothing else in the plan changed.

## Declined

- **File:** `docs/user-guide.md` — **finding:** the bead premise asks that the new PR title
  rule, the `## PR body` convention the worker prompts already instruct agents to write, and
  the new project body-template setting be documented.
  **Reason:** the premise does not hold for this branch. `git grep "## PR body"` over the
  repository (and over `packages/foreman_server/priv/defaults/`) returns no hit, so no worker
  prompt instructs an agent to write that section and no code reads it — documenting it would
  describe behaviour that does not exist. The body-template setting does exist, but only
  upstream: `main` has `packages/foreman_server/lib/foreman_server/workflow/pr_body.ex` and
  `:pr_body_headings` in `ForemanServer.Aggregates.Project.Settings`, while `HEAD` has
  neither (`git cat-file -e HEAD:.../pr_body.ex` → path does not exist). Upstream `main`
  already documents that setting itself (`docs/user-guide.md:736`, `**Pull-request body
  template.**` at :744, `README.md:290-291`, `docs/cli-reference.md:330` and :624), and that
  upstream work is outside this run's diff (`main...HEAD` = 4 doc/report files). Adding a
  setting description to this branch would describe code the branch does not carry. The
  PR-title rule is already documented for the surface that owns it
  (`docs/cli-reference.md:622`). Recorded in the run's own plan and fix report as
  out-of-scope follow-up work for its own bead.

- **File:** `docs/user-guide.md:3021` — **finding:** the new paragraph's cross-reference to
  "the `## Review findings (the review agent's report)` section above" could be read as a
  dangling reference to a section the guide does not have.
  **Reason:** stale as a finding — `docs/user-guide.md:2974-2999` does contain that section
  of guide prose, so the reference resolves. No change.

## Verification

Commands run from the run worktree
(`/Users/ldangelo/.foreman/worktrees/foreman/foreman-d6rth/run-090f5deed6c91ee5e888f52db133f185/workspace`):

| Command | Exit | Result |
| --- | --- | --- |
| `cd packages/foreman_cli && go test ./cmd/foreman/ -run 'TestUserGuideUsageExampleExecutesAgainstCLI\|TestUserGuideProjectExamplesExecuteAgainstCLI\|TestUsageAdvertisesExactlyTheDispatchedVerbs\|TestCLIReferenceDocumentsEveryDispatchedVerb\|TestAgentCommandSpecsRouteToDispatchedVerbs\|TestCLIReferenceNotImplementedClaimsAreAccurate' -v` | 0 | 6 tests `--- PASS`; `ok github.com/fortium/foreman/packages/foreman_cli/cmd/foreman` |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs'` | 0 | `Result: 3 passed` (only noise: the idempotency-store ETS-fallback error line and `ProjectionLeakGuard: judged 0 of 0 modules`) |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=… MIX_ENV=test mix run <probe>'` (Foreman's own parsers, `ForemanServer.Workflow.ReviewFindings.parse/1` + `ForemanServer.PrRisk.parse_judgement/1` on the restored coderabbit report) | 0 | findings `{:recorded, %ReviewFindings.Record{findings: [6 findings]}}`, all six with `source: "coderabbit"`, `disposition: :fixed`; risk `%{status: "recorded", level: "LOW", defect: nil}` |
| `git diff main...HEAD` (re-read after the fixes) | 0 | 4 files, documentation and run reports only; no runtime code, route, command, config key or env var added, removed or renamed |
| `git status --porcelain` | 0 | `M docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md`, `M docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md` — this phase's two fixes, left **uncommitted** for Foreman to commit |

No formatter was run: this phase touched no `.ex`/`.exs` file (`mix format` has nothing to
check here, and `PLAN.md` §5 says the same). The full `AGENTS.md` suite was not run: the
change is documentation prose only, and `PLAN.md` §5 records that the repository's own
conventions call for the narrow doc-gate tests, which pass.

Re-read of the diff after the fixes introduced no new violation: the only changed lines are
the one plan hunk and the one report paragraph, both inside the run's own report directory,
both prose, and the restored report parses with Foreman's own readers.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md", "line": 5, "description": "The plan document had been truncated to 25 lines, losing the premise, the edits and the verification steps.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md", "line": 23, "description": "The plan's verification greps were unscoped and matched their own report output, so they could not fail as intended.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3018, "description": "The task-backed PR body rule was stated unconditionally although it only applies when the project sets no pr_body_headings.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md", "line": 82, "description": "The recorded go test -run filter named a non-existent test (TestUsageDrift), so the recorded exit code proved nothing about the other tests.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3015, "description": "The missing Artifact line was described as having a single cause although it has two distinct causes.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3013, "description": "The case of a phase that defers its commit and therefore opens its PR before the artifact is committed was not documented.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md", "line": 190, "description": "The committed phase-3 artifact was a 19-line prose summary with no section headings and neither machine-readable block, so Foreman's own ReviewFindings and PrRisk parsers could not read the report the operator sees.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md", "line": 126, "description": "The plan's verification command filtered on a Go test name that does not exist, so the recorded exit code proved nothing.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": null, "description": "The bead premise's ## PR body convention exists nowhere in the repository and its body-template setting is carried only by upstream main, which already documents it, so documenting either in this branch would describe code the branch does not carry.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "docs/user-guide.md", "line": 3021, "description": "The new paragraph's cross-reference to the review findings section above could be read as a dangling reference.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The change is documentation prose plus a repair of two run-report artifacts: no runtime code, command, route, config key or env var is added, removed or renamed. Every behavioural claim in the new user-guide paragraph was checked against the source (PrBodyPath.artifact_line/2, AutoPr.pr_content/1, the deferred commit step) and against upstream main's PrBody implementation, and the restored phase-3 report parses with Foreman's own ReviewFindings and PrRisk readers."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
