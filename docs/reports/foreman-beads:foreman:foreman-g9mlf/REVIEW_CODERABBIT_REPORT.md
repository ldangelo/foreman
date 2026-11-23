Phase 2 (`coderabbit-review`) complete.

## Review engine
`coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (`FOREMAN_BASE_BRANCH=main`, merge-base `4099cce4`, HEAD `c77b40d2`) — 2 successful rounds, 1 finding each.

## Finding (1 major, fixed)
`packages/foreman_server/priv/defaults/workflows/fix.yaml:35` invoked `/enseble:merge-pr --foreman` — misspelled namespace **and** a command that doesn't exist anywhere in the ensemble repo. Real command: `ensemble:pr-merge` (`packages/git/commands/pr-merge.yaml`, `argument_hint` accepts `--foreman`).

**Fix (uncommitted, 1 line):** `command: "/ensemble:pr-merge --foreman"`

Colon form chosen over `/skill:ensemble-pr-merge` because a workflow `command:` value is agent prompt text, not a shell command, and `validator.ex` `@known_skills` lacks `ensemble-pr-merge` (the skill form would need a Validator change). It matches the sibling phase's `/ensemble:fix-issue` and Foreman's `ensemble:<cmd>` vocabulary. CodeRabbit's other suggestion (restore prompt-based review phases) declined — a rebase decision, not review-phase scope.

## Root cause of the 3 red workflow tests (established in phase 3)
At the time of this phase the 3 failures were attributed to "pre-existing" divergence between this branch and main's newer prompt-based `fix.yaml` (`e89fa4da`). Phase 3 disproved that attribution: the failures were caused by **this branch's own** command-phase `fix.yaml` (the `dd0c239b` rewrite), not by main's manifest. Restoring the merge-base manifest (`4099cce4`) makes the same suite pass 1564/1564, and because the restored file is byte-identical to the merge base, the branch contributes no change to it when merged — main's version wins and the `plan` phase stays in production.

## Verification
- `bundled_workflow_skills_test.exs` + `bundled_workflow_models_test.exs` → **4 passed**, exit 0, `--warnings-as-errors` clean (loads every bundled workflow through `Interpreter.load!/1` + `Validator.validate/1`).
- `test/foreman_server/workflow/` → at the time of this phase **1561/1564** with 3 failures (CatalogTest, PromptInboxProgressTest, FullWorkflowLifecycleTest). Phase 3 re-ran the same directory after restoring the merge-base `fix.yaml`: **1564 passed**, exit 0, `--warnings-as-errors` clean.
- Doc gate: no hits for `enseble`/`merge-pr`/`pr-merge` in CLAUDE.md, README.md, docs/user-guide.md, docs/cli-reference.md → no doc edits.

## Artifact
`docs/reports/foreman-beads:foreman:foreman-g9mlf/REVIEW_CODERABBIT_REPORT.md` — the two machine-read blocks were **missing** when this phase committed, so this artifact's original "both machine-read blocks confirmed parseable" claim was false. Phase 3 added the blocks below (and corrected that claim): `ReviewFindings.read/1` → `:recorded` (2 findings), `PrRisk.parse_judgement/1` → `LOW`.

## Escalations for the operator
- **The task's actual 5-point objective is unimplemented** — no `PI_SUBAGENT_CHILD=1` launch guard, no effective-model assertion, no model surfacing, no fake-extension test, no `stopReason=length` handling. This branch carries zero implementation code; phase 1 stopped because the dispatched `fix` workflow had no plan phase producing `PLAN.md`. Phase 3 confirmed `PI_SUBAGENT_CHILD` has zero hits under `packages/`.
- The 3 red workflow tests are **fixed** in phase 3 (merge-base manifest restored) — no rebase decision is needed for that file.
- `ask_advisor` unavailable (Anthropic `invalid_grant` / "Refresh token expired") — no advisor review obtained.

Inbox note and task Work Log comment both sent. Kata issue `23j3` created, claimed and closed with test evidence.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 35, "description": "Phase 2 (CodeRabbit) finding: the bundled fix workflow invoked `/enseble:merge-pr --foreman` - a misspelled namespace naming a command that does not exist anywhere in the ensemble repo (real command: `ensemble:pr-merge`).", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 26, "description": "Phase 3 finding: the branch's command-driven two-phase fix.yaml rewrite (`dd0c239b`) dropped the bundled `coderabbit-review` and `repo-rules-review` phases, broke the repository's own workflow tests (CatalogTest, PromptInboxProgressTest, FullWorkflowLifecycleTest: 1561/1564), and used `/ensemble:` command forms that bypass the Validator's `/skill:` allowlist.", "disposition": "fixed", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The reviewed diff carries no production code: it adds two phase report artifacts and restores the bundled fix workflow manifest to the upstream merge-base version, which makes the repository's own workflow suite pass 1564/1564 and leaves main's plan phase in place on merge. The one major CodeRabbit finding (the `/enseble:` namespace typo) is gone, and the two `/ensemble:` command phases that bypassed the skill allowlist are removed with the manifest. Residual risk is low: no runtime code, no new external identifiers, and no operator-facing surface changed. The task's 5-point objective remains unimplemented, which is an open delivery gap for the operator to re-dispatch, not a risk in this diff."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
