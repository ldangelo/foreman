Phase complete.

**What happened**

CodeRabbit review ran locally against the working tree (`coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"`, v0.9.6, exit 0) in 4 sessions — 12:20, 14:27, 14:39, 15:02. Round 1 only saw the plan (implementation wasn't written yet); later sessions reviewed the implementation + fixes.

**5 findings, all fixed, 0 declined, 0 open** (all minor):
1. `PLAN.md:40` — test command re-entered `packages/foreman_server` → prose now says "run from the repository root".
2. `review_findings.ex` — containment checked by string prefix (sibling dir accepted) → now per-path-component (`Path.expand`/`Path.split`).
3. `phase_pr_body_test.exs` — link existence only asserted → now asserts text + target.
4. `review_findings.ex` — unknown location became basename link `[review.md](review.md)` → rendered as inert text (`{:unknown, path}`).
5. `review_findings.ex` — `docs/reports/` suffix extracted before containment → containment first, suffix kept as fallback for the run-worktree layout.

**Verification** — narrow suite 136 passed (exit 0); full `MIX_ENV=test mix test --warnings-as-errors` 9256 passed / 11 excluded / 0 failures / no warnings; `mix format --check-formatted` exit 0. Doc gate: `CLAUDE.md` + `docs/user-guide.md` updated; `README.md` + `docs/cli-reference.md` have no review-findings reference → no edit.

**State** — fixes left uncommitted; scratch `.cr_round*.log` deleted; report at `docs/reports/foreman-beads:foreman:foreman-4oodz/REVIEW_CODERABBIT_REPORT.md` — this prose summary plus the machine-read findings block (5 fixed) and risk block (`MEDIUM`) appended below; the tracked `.deps_get.log` was removed by the later repo-rules review phase. Kata `0czz` closed with the full-suite command as evidence.
<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-4oodz/PLAN.md", "line": 40, "description": "The plan's test command re-entered packages/foreman_server, contradicting the instruction to run it from the repository root.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/review_findings.ex", "line": null, "description": "Artifact containment was checked by string prefix, so a sibling directory sharing that prefix counted as inside the repository.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs", "line": null, "description": "The test asserted only that the review-report link existed, not its text or its target.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/review_findings.ex", "line": null, "description": "An unknown report location was rendered as a basename Markdown link pointing at a file that does not exist.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/review_findings.ex", "line": null, "description": "The docs/reports/ suffix was extracted before containment was checked, letting a path outside the repository be reported as repository-relative.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change is confined to the review-report rendering path: one nested typed Context struct, one shared pr_section/2 implementation and two call sites, plus narrow tests and two documentation sentences. It adds no command, event, config key or CLI surface and touches no user data path. The residual risk is that operator-visible PR body text gains a report link in the two non-recorded review states, which the narrow suite pins."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
