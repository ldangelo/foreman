# Repository-rules review — `beads:foreman:foreman-gocpd`

## Review engine

- **Reviewer:** the repository-rules review phase agent (`repo-rules`), phase 4 of the `fix` workflow, run `run-bf31fff2bba135166d4e4cc111d51be8`.
- **Diff range reviewed:** `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with `FOREMAN_BASE_BRANCH=main` — merge-base `f0f3b0839bfba157a568378500c7db9105e88d2a`, HEAD `84e981075090683f97619ee8b7c96971a14244ec`, 19 changed paths. The uncommitted fixes made by this phase were re-read once after fixing (`git diff main...HEAD` plus `git diff` of the working tree) to confirm they introduced no new violation.
- **Rules applied:** the repository's own `AGENTS.md` at the workspace root (§5 typed boundaries and loud failures, the documentation gate, testing and safety), plus the established patterns of the files the diff touches (`Workflow.PhasePR`, `Workflow.RunExecutor`, the PhasePR test files, `docs/`, `packages/foreman_server/CHANGELOG.md`).
- **Previous phase:** `docs/reports/foreman-beads:foreman:foreman-gocpd/REVIEW_CODERABBIT_REPORT.md` exists (225 bytes) but contains **no machine-readable findings block** — there was nothing to carry forward in the required form. Its prose lists three intended fixes — "(1) add `git log` clauses to the 3 test runners so the suite is green, (2) add title-precedence tests, (3) distinguish failed history read from absent subject" — which are the same three problems this phase independently found as F2, F3 and F6, and all three are fixed here. `docs/reports/foreman-beads:foreman:foreman-gocpd/FIX_REPORT.md` (86 bytes) is truncated to one sentence; recorded as F7 and declined.
- **Could not be reviewed:** nothing in the diff range. The repository's own `docs/` and `CLAUDE.md`/`README.md` were checked for every identifier the diff touches (see the documentation gate in **Fixed**).
- **Progress notes:** `foreman_inbox_send` and `foreman_task_add_comment` are not exposed to this phase, so no operator progress note and no task Work Log comment could be sent.

## Findings

| # | Source | Severity | Location | Finding | Disposition |
| --- | --- | --- | --- | --- | --- |
| F1 | repo-rules | minor | `.gocpd_db.log` (and 13 sibling root files) | Fourteen scratch files were committed at the repository root. | fixed |
| F2 | repo-rules | major | `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs:507` | The committed test runners have no `git log` clause, so the branch's own suite crashes. | fixed |
| F3 | repo-rules | major | `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs` | The new PR-title precedence shipped with no test. | fixed |
| F4 | repo-rules | minor | `docs/user-guide.md` | The user-visible change to the phase PR title was undocumented. | fixed |
| F5 | repo-rules | minor | `packages/foreman_server/CHANGELOG.md` | The user-visible phase PR title change has no CHANGELOG entry. | fixed |
| F6 | repo-rules | major | `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:385` | A failed `git log` was silently treated as "no conventional subject". | fixed |
| F7 | repo-rules | minor | `docs/reports/foreman-beads:foreman:foreman-gocpd/FIX_REPORT.md` | The previous phase's report is truncated and documents nothing. | declined |

## Fixed

**F1 — scratch files committed at the repository root.**
- *File:* repository root — `.gocpd_db.log`, `.gocpd_msg.txt`, `.gocpd_narrow.log`, `.gocpd_narrow2.sh`, `.gocpd_push.log`, `.gocpd_push.sh`, `.gocpd_test.log`, `.gocpd_verify.sh`, `.r_fails.txt`, `.rev_narrow1.log`, `.rev_narrow2.log`, `.review_code.diff`, `.review_stat.txt`, `.review_test.diff` (14 files added by the branch).
- *What was wrong:* the branch committed fourteen throwaway probe/log/diff artifacts into the repository root, where they would merge with the product change. They are not covered by any ignore rule and carry no product meaning.
- *What changed:* all fourteen were removed (`git rm`); `git ls-files --others --exclude-standard` now lists nothing except this report, and the probe files this review itself created were deleted as well.

**F2 — the branch's own test suite crashes: no `git log` clause in the test runners.**
- *File:* `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs:507-513`, `packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs:24-39` and `:106-121`.
- *What was wrong:* the branch's `PhasePR.first_conventional_subject/1` calls `git log`, but neither committed test runner stub matches it — HEAD's clauses cover `git rev-list`, `git rev-parse`, `git ls-remote`, `git push` and `gh pr list`/`gh pr create` only. Every test that reaches the title fallback died with `** (FunctionClauseError) no function clause matching in ForemanServer.Workflow.PhasePRTest.runner/3` (13 of the 64 tests in that file failed). Under `AGENTS.md` ("a failing test is a failed build") the branch was unmergeable as it stood.
- *What changed:* a `git log` clause was added to both runners (`defp runner("git", ["log" | _], _opts), do: {"", 0}`), so the stub still yields no conventional subject and every pre-existing test keeps its legacy `feat(phase): <phase>` title. The shared `test/support/pr_delivery_world.ex` and `test/support/effect_world.ex` worlds needed no change: they forward `git` to a real `System.cmd` git.

**F3 — the new title precedence shipped untested.**
- *File:* `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs` (new `describe "the title of the opened PR"`).
- *What was wrong:* the branch changed the operator-visible PR title, and no test asserted any part of the new contract (task title wins, conventional-subject fallback, legacy fallback, unusable task title). A later change could have silently inverted the precedence.
- *What changed:* five tests were added: the task title wins over everything else; the first conventional-commit subject is used when the run has no task title; the legacy `feat(phase): <phase>` form is used when neither is available; a `git log` that fails still opens the PR with the legacy title (and warns — F6); and a blank task title returns `%PhasePR.Error{reason: :task_title_invalid}` before anything is pushed. Helpers `title_runner/1` and `title_arg/1` extract the title from the captured `gh pr create` arguments.

**F4 — the user-visible title rule was undocumented.**
- *File:* `docs/user-guide.md`, `docs/cli-reference.md`, `docs/lessons/phase-execution-and-pr-mechanics.md`.
- *What was wrong:* the diff changes the title of every phase PR, and none of the repository's documentation said so. `AGENTS.md`'s documentation gate requires the behavior to be reconciled across the files this repository uses.
- *What changed:* `docs/user-guide.md` gained a "**A phase PR's title is the run's task title.**" paragraph stating the three-step precedence and the blank-title error; `docs/cli-reference.md` gained the matching one-sentence rule; `docs/lessons/phase-execution-and-pr-mechanics.md` now records that a phase PR's title starts from the same source as the final AutoPR title (the run's task title) but falls back differently (first conventional-commit subject among the run's own commits, else the legacy `feat(phase): <phase>` form). `README.md` and `CLAUDE.md` were checked and needed no edit: `README.md:287` documents the AutoPR title and is unaffected by this change, and neither file makes a phase-PR title claim. The only externally visible identifier this diff adds is the optional `Workflow.PhasePR.Request` field `task_title` — an internal struct field, not a route, config key, env var, CLI verb or MCP tool — and it is recorded in `packages/foreman_server/CHANGELOG.md`.

**F5 — no CHANGELOG entry for the user-visible change.**
- *File:* `packages/foreman_server/CHANGELOG.md` (`## Unreleased` → `### Changed`).
- *What was wrong:* the repository keeps a per-change CHANGELOG (recent commits `c209f8b4`, `176546c1`, `796c888c`, `0fd6e54b` all touch it), and this user-visible title rule was missing from it.
- *What changed:* one bullet was added under the first `### Changed` list, covering the three-step title precedence, the new optional `task_title` field, and the fact that a failing `git log` only costs the subject fallback. The sibling run branches were compared first (`foreman-okend`, `foreman-qdt14`, `foreman-i3qol`): none of them adds a CHANGELOG entry for this change, so the text collides with nothing.

**F6 — a failed history read was silently downgraded to "no conventional subject".**
- *File:* `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:385-397` (`first_conventional_subject/1`).
- *What was wrong:* the non-zero exit of `git log` was matched by `{_output, _exit_code} -> nil`, i.e. a failure to read the history was indistinguishable from a history without a conventional subject, and the phase PR opened with the legacy `feat(phase): <phase>` title with no signal. `AGENTS.md` §5.2 ("never degrade to a plausible-looking success") and §5.3 ("absent ≠ malformed") both forbid that.
- *What changed:* the non-zero branch now logs a warning in the module's existing metadata style (`Logger.warning("PhasePR.run_id=… could not read commit subjects for … (git log exited #{exit_code}: …); using the phase title", run_id:, base_branch:, head_branch:, operation: "phase_pr.title", outcome: "history_unreadable", exit_code:)`) and only then returns `nil`. The PR still opens with the legacy title — the run must not be blocked by an unreadable history — but the failure is no longer silent. The module doc and the comment above `pr_title/1` were updated to say so, and the "a `git log` that fails does not lose the PR: the legacy title, warned" test now asserts the warning.

## Declined

**F7 — the previous phase's `FIX_REPORT.md` is truncated.**
- *File:* `docs/reports/foreman-beads:foreman:foreman-gocpd/FIX_REPORT.md`.
- *Finding:* the file is 86 bytes and contains only "Work is committed and pushed (`b95213d3`). Now writing the report from verified facts." — it documents nothing about the implemented change.
- *Reason for declining:* its single factual claim is true and verified (`git merge-base --is-ancestor b95213d3 HEAD` succeeds), so there is no false claim to correct in place; and `FIX_REPORT.md` is the fix phase's own artifact, while this phase's contract writes `REVIEW_REPORT.md`. Rewriting another phase's artifact would put unreviewed content into the pull request. The implemented change is described in this report instead.

## Verification

Commands run from `packages/foreman_server` (Elixir 1.20.4 / OTP 28 via devbox, `MIX_ENV=test`):

| Command | Result |
| --- | --- |
| `mix format --check-formatted lib/foreman_server/workflow/phase_pr.ex test/foreman_server/workflow/phase_pr_test.exs test/foreman_server/workflow/phase_pr_body_test.exs` | exit 0 |
| `mix test --warnings-as-errors test/foreman_server/workflow/phase_pr_test.exs test/foreman_server/workflow/phase_pr_body_test.exs test/foreman_server/workflow/auto_pr_test.exs` | exit 0 — "Result: 130 passed", "ProjectionLeakGuard: judged 2 of 2 modules, no run left behind" |
| `mix test --warnings-as-errors test/foreman_server/workflow/` | exit 0 — "Result: 1581 passed", "ProjectionLeakGuard: judged 68 of 84 modules, no run left behind" |
| `mix test --warnings-as-errors test/foreman_server/mcp/tool_inventory_test.exs test/foreman_server/mcp/docs_per_project_queue_test.exs test/foreman_server/observability/docs_test.exs` | exit 0 — 14 passed (documentation gate) |
| `git diff main...HEAD` (re-read after the fixes) | no new violation found |

Documentation gate: the identifiers this diff adds or changes are `Workflow.PhasePR.Request`'s optional `task_title` field and the phase PR title rule. `grep` over `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` and `packages/foreman_server/CHANGELOG.md` found the old `feat(phase): <phase>` form only in `README.md`'s AutoPR section (unaffected) and in the lines this phase edited; no stale reference remains, and no identifier was removed or renamed.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": ".gocpd_db.log", "line": null, "description": "Fourteen scratch files (logs, probe scripts and diff dumps) were committed at the repository root and are removed from the diff.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs", "line": 507, "description": "The committed test runners have no `git log` clause, so the branch's own suite crashed with `** (FunctionClauseError) no function clause matching in ForemanServer.Workflow.PhasePRTest.runner/3`.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs", "line": null, "description": "The new PR-title precedence (task title, conventional-subject fallback, legacy fallback, unusable task title) shipped with no test.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 2966, "description": "The user-visible change to the phase PR title was not documented in the user guide, the CLI reference or the lessons doc.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/CHANGELOG.md", "line": 68, "description": "The user-visible phase PR title change had no CHANGELOG entry under Unreleased.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex", "line": 385, "description": "A `git log` exiting non-zero was silently treated as \"no conventional subject\", degrading to the legacy title with no signal.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-gocpd/FIX_REPORT.md", "line": 1, "description": "The previous phase's FIX_REPORT.md is truncated to one sentence and documents nothing about the implemented change.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change adds a `git log` subprocess to the phase-PR path and changes an operator-visible PR title. The failure modes are bounded and covered by tests: an unusable task title is a typed error raised before any push, an unreadable history warns and falls back to the legacy title, and the whole workflow suite is green. Residual risk is that a phase PR's title now depends on the run's task metadata being populated and on git history being readable in the run's worktree."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
