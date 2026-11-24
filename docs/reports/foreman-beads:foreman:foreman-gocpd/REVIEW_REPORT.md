

Repo-rules review complete.

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-gocpd/REVIEW_REPORT.md` — parser-validated (`ReviewFindings.parse/1` → `{:ok, 7 findings}`; `PrRisk.parse_judgement/1` → `status: "recorded", level: "MEDIUM"`).

**Diff range:** `git diff "$FOREMAN_BASE_BRANCH"...HEAD` (`FOREMAN_BASE_BRANCH=main`, merge-base `f0f3b083`, HEAD `84e9810`), 19 paths. Rules: root `AGENTS.md` (§5 typed boundaries, doc gate, testing) + touched-file idioms.

**Findings (7, source `repo-rules`; 6 fixed, 1 declined):**
- **F1 minor** — 14 scratch files committed at repo root → removed.
- **F2 major** — committed test runners had no `git log` clause → suite crashed `** (FunctionClauseError) no function clause matching in ForemanServer.Workflow.PhasePRTest.runner/3` (13/64 tests) → stub clauses added to `phase_pr_test.exs` + `phase_pr_body_test.exs`.
- **F3 major** — new title precedence shipped untested → 5 tests added (task title wins / conventional-subject fallback / legacy fallback / failing `git log` warns / blank title → `%PhasePR.Error{reason: :task_title_invalid}` before push).
- **F4 minor** — title rule undocumented → `docs/user-guide.md`, `docs/cli-reference.md`, `docs/lessons/phase-execution-and-pr-mechanics.md`.
- **F5 minor** — no CHANGELOG entry → bullet in `packages/foreman_server/CHANGELOG.md` (`## Unreleased` → `### Changed`).
- **F6 major** — failed `git log` silently degraded to "no conventional subject" (§5.2/§5.3) → `Logger.warning` with run/base/head/exit_code metadata, legacy title still opens the PR, module doc + comment updated.
- **F7 minor (declined)** — previous phase `FIX_REPORT.md` truncated; its only claim verified true, and it is another phase's artifact → declined, described in this report instead.

**Verification (exit 0):** `mix format --check-formatted` on 3 touched files; `mix test --warnings-as-errors` on phase_pr/phase_pr_body/auto_pr → 130 passed; whole `test/foreman_server/workflow/` → 1581 passed; doc-gate tests (tool_inventory, docs_per_project_queue, observability/docs) → 14 passed. `CLAUDE.md`/`README.md` needed no edit (no phase-PR title claim; `README.md:287` covers AutoPR only).

**Not committed** (Foreman commits): 14 staged deletions + 7 modified files; untracked = the report only.