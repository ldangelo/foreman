Phase 2 (`coderabbit-review`) complete.

## Review engine
`coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (`FOREMAN_BASE_BRANCH=main`, merge-base `4099cce4`, HEAD `c77b40d2`) — 2 successful rounds, 1 finding each.

## Finding (1 major, fixed)
`packages/foreman_server/priv/defaults/workflows/fix.yaml:35` invoked `/enseble:merge-pr --foreman` — misspelled namespace **and** a command that doesn't exist anywhere in the ensemble repo. Real command: `ensemble:pr-merge` (`packages/git/commands/pr-merge.yaml`, `argument_hint` accepts `--foreman`).

**Fix (uncommitted, 1 line):** `command: "/ensemble:pr-merge --foreman"`

Colon form chosen over `/skill:ensemble-pr-merge` because a workflow `command:` value is agent prompt text, not a shell command, and `validator.ex` `@known_skills` lacks `ensemble-pr-merge` (the skill form would need a Validator change). It matches the sibling phase's `/ensemble:fix-issue` and Foreman's `ensemble:<cmd>` vocabulary. CodeRabbit's other suggestion (restore prompt-based review phases) declined — a rebase decision, not review-phase scope.

## Verification
- `bundled_workflow_skills_test.exs` + `bundled_workflow_models_test.exs` → **4 passed**, exit 0, `--warnings-as-errors` clean (loads every bundled workflow through `Interpreter.load!/1` + `Validator.validate/1`).
- `test/foreman_server/workflow/` → **1561/1564**. The 3 failures (CatalogTest, PromptInboxProgressTest, FullWorkflowLifecycleTest) all assert `fix.yaml` phases are *prompt*-driven and reproduce identically with my change stashed (39/42, same 3) → pre-existing: this branch's command-phase revert `dd0c239b` vs main's newer prompt-based `fix.yaml` `e89fa4da`.
- Doc gate: no hits for `enseble`/`merge-pr`/`pr-merge` in CLAUDE.md, README.md, docs/user-guide.md, docs/cli-reference.md → no doc edits.

## Artifact
`docs/reports/foreman-beads:foreman:foreman-g9mlf/REVIEW_CODERABBIT_REPORT.md` — both machine-read blocks confirmed parseable (`ReviewFindings.read/1` → `:recorded`, 1 major/`fixed`; `PrRisk.parse_judgement/1` → `LOW`, rationale 972 chars).

## Escalations for the operator
- **The task's actual 5-point objective is unimplemented** — no `PI_SUBAGENT_CHILD=1` launch guard, no effective-model assertion, no model surfacing, no fake-extension test, no `stopReason=length` handling. This branch carries zero implementation code; phase 1 stopped because the dispatched `fix` workflow has no plan phase producing `PLAN.md`.
- 3 red workflow tests are owned by the branch-vs-main `fix.yaml` rebase decision.
- `ask_advisor` unavailable (Anthropic `invalid_grant` / "Refresh token expired") — no advisor review obtained.

Inbox note and task Work Log comment both sent. Kata issue `23j3` created, claimed and closed with test evidence.