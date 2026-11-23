# CodeRabbit review — `beads:foreman:foreman-uvzfs`

Phase: `fix :: coderabbit-review` (phase index 2) · Run: `run-a9ee2749eb92b7d7896ed91d3155995d`
Base branch: `$FOREMAN_BASE_BRANCH=main` (set and non-empty — no block condition)

## 1. Review engine

- Engine: the CodeRabbit CLI, the same engine as the GitHub PR bot, run locally against the run's worktree.
- Command run for every round, from the worktree root:
  `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (with `FOREMAN_BASE_BRANCH=main`).
- Round 1 aborted with a transport failure before any finding was produced:
  `{"type":"error","errorType":"connection","message":"Connection failed: WebSocket closed","recoverable":true,"details":{"cause":{"name":"TRPCWebSocketClosedError"},"name":"TRPCClientError"}}`
  followed by `Error: An unexpected error occurred.` → 0 findings; the engine (not the code) had failed, so the round was repeated.
- Round 2 completed: `{"type":"complete","status":"review_completed","findings":1,"reviewedFiles":["docs/reports/foreman-beads:foreman:foreman-uvzfs/FIX_REPORT.md","packages/foreman_server/priv/defaults/workflows/fix.yaml"],"outcome":"completed"}`.
- Round 3 completed (run after the round-2 fix): `{"type":"complete","status":"review_completed","findings":1,"outcome":"completed"}`, over the 9 changed paths (report artifact, `docs/user-guide.md`, the bundled workflow, its two prompts and the four workflow test files).

Scope note: the run's own task (PR title/body generation, `PhasePR.maybe_create` / `RunExecutor.maybe_record_phase_pr` / `AutoPR` / project settings) was **not** implemented on this branch — phase 1 stopped with `Blocked: no plan found` (see `FIX_REPORT.md`). The branch's committed delta against `main` is therefore only two files: the phase-1 report artifact and `packages/foreman_server/priv/defaults/workflows/fix.yaml`. This review covers that delta plus the phase's own fixes.

## 2. Rounds

| Round | Findings received | Fixed | Declined |
| --- | --- | --- | --- |
| 1 | 0 (engine transport failure: WebSocket closed) | 0 | 0 |
| 2 | 1 (major) | 1 | 0 |
| 3 | 1 (major) | 0 | 1 |

Round 2 finding: `packages/foreman_server/priv/defaults/workflows/fix.yaml:35` — "Correct the `enseble` namespace in the `pr-review` phase."
Round 3 finding: `packages/foreman_server/priv/defaults/workflows/prompts/fix.md:22` — "Create the planned regression test before running it."
Stopped after round 3 (3-round cap).

## 3. Fixed

### F1 — major — `packages/foreman_server/priv/defaults/workflows/fix.yaml:35`

**What was wrong.** The branch's committed `fix.yaml` replaced main's prompt-driven phases with two `command:` phases:

- line 29: `command: "/ensemble:fix-issue --foreman {{input.prompt}}"`
- line 35: `command: "/enseble:merge-pr --foreman"`

`enseble` is a typo of `ensemble`, and no `merge-pr` command exists in the ensemble plugin (it registers `pr-merge`, skill-backed by `packages/git/skills/ensemble-pr-merge/SKILL.md`), so the phase ran a command that cannot resolve. The same swap dropped main's `plan`, `coderabbit-review` and `repo-rules-review` phases and turned the review phase into an agent-run PR merge, which the operator-only merge gate forbids. The missing `plan` phase is why this run's phase 1 wrote `Blocked: no plan found`.

**Changed.** Restored the bundled workflow to main's prompt-driven shape:

- `packages/foreman_server/priv/defaults/workflows/fix.yaml` → main's version: phases `plan` (prompt `fix-plan.md`, artifact `PLAN.md`, `commit: false`) → `fix` (prompt `fix.md`, artifact `FIX_REPORT.md`, `commit: true`) → `coderabbit-review` (prompt `review-coderabbit.md`, artifact `REVIEW_CODERABBIT_REPORT.md`, `commit: true`) → `repo-rules-review` (prompt `review-repo-rules.md`, artifact `REVIEW_REPORT.md`, `commit: true`, `stack_pr: true`). No `command:` phase, no `enseble`/`ensemble` namespace, no PR-merging phase, and the `plan` phase is back.
- `packages/foreman_server/priv/defaults/workflows/prompts/fix.md` → main's version (the implementation agent that consumes `PLAN.md`; the branch copy was the older Task-Prompt variant, mismatched with the restored workflow).
- `packages/foreman_server/priv/defaults/workflows/prompts/fix-plan.md` → added from main (the bundle had no plan prompt, so the restored `plan` phase had nothing to run).
- `packages/foreman_server/test/foreman_server/workflow/{bundled_workflow_models_test.exs,catalog_test.exs,full_workflow_lifecycle_test.exs,interpreter_test.exs}` → main's expectations for the four-phase workflow (the fork's copies asserted the older 3-phase shape and no model pins, so they failed against the restored workflow).
- `docs/user-guide.md` §7.3 → the restored workflow pins `litellm-stack/anthropic/claude-opus-5` (plan) and `litellm-stack/qwen-flash-next` (fix); the paragraph documenting that exception and the allowed-pin list in `bundled_workflow_models_test.exs` was restored from main.
- `foreman init --force` refreshed the installed copies; `diff -rq ~/.foreman/workflows packages/foreman_server/priv/defaults/workflows` reports no drift.

**Why not just repair the typo.** The finding's own instruction ("use the registered merge slash command in the ensemble namespace; first confirm the command's registered name instead of guessing") resolves to `/ensemble:pr-merge`, which merges a PR — an agent-performed merge, forbidden by the operator-only merge gate. Upstream replaced this command-driven shape in e89fa4da (#920, "plan the fix on a strong model, implement it on a fast one"), which is already in `main`; restoring main's file removes the typo, the merge attempt and the missing plan phase in one change, and leaves `git diff main -- packages/foreman_server/priv/defaults/workflows/` empty.

## 4. Declined

### D1 — major — `packages/foreman_server/priv/defaults/workflows/prompts/fix.md:22`

**Finding.** "Create the planned regression test before running it." — step 2 of the prompt tells the fix agent to run the plan's "Failing check first" command before the test file exists, while step 4 asks it to add the regression test afterwards, so a plan that specifies a *new* test file stops the phase on a missing file.

**Reason declined.** The flagged text is upstream `main`'s bundled prompt, byte-identical to `main` (`git diff main -- packages/foreman_server/priv/defaults/workflows/prompts/fix.md` is empty): the defect is pre-existing upstream, not introduced by this run's work. Changing bundled prompt semantics is outside this run's task (PR title/body generation), and the prompt is installed into every operator's `~/.foreman/workflows` by `foreman init --force`, so the correction belongs in its own upstream change rather than in this branch. It stays visible to the operator as an unresolved major finding.

## 5. Verification

| Command | Result |
| --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test TEST_DB_POOL_SIZE=5 MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/'` | exit 0 — `Result: 1564 passed` (before the fix: 1561/1564, the 3 failures being the stale bundled `fix.yaml` and its stale test expectations) |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted test/foreman_server/workflow/bundled_workflow_models_test.exs test/foreman_server/workflow/catalog_test.exs test/foreman_server/workflow/full_workflow_lifecycle_test.exs test/foreman_server/workflow/interpreter_test.exs'` | exit 0 |
| `foreman init --force` | exit 0 — `{"status":"installed", ...}` |
| `diff -rq ~/.foreman/workflows packages/foreman_server/priv/defaults/workflows` | exit 0 — no drift between installed and bundled copies |
| `git diff main -- packages/foreman_server/priv/defaults/workflows/` | empty — bundled workflow matches upstream `main` |

Documentation gate — greps over `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`: `enseble` → 0 hits; `merge-pr` → 0 hits; `ensemble:` → 0 hits; `fix.yaml` / `repo-rules-review` / `coderabbit-review` / `pr-review` → 0 hits; `fix-plan` → 0 hits in those four files (only inside `packages/`). The two restored model pins are documented in `docs/user-guide.md` §7.3, matching the allowed-pin list in `packages/foreman_server/test/foreman_server/workflow/bundled_workflow_models_test.exs`. `CLAUDE.md`, `README.md` and `docs/cli-reference.md` needed no edit: this phase changed no CLI verb, route, MCP tool, config key or env var.

All fixes are left uncommitted for Foreman to commit. No PR was opened or merged (operator-only merge gate).

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 35, "description": "The bundled fix workflow ran the non-existent command \"/enseble:merge-pr --foreman\", a typo of the ensemble namespace, in a phase that also dropped the plan and review phases; restored main's prompt-driven fix workflow with its plan, fix, coderabbit-review and repo-rules-review phases.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/prompts/fix.md", "line": 22, "description": "The bundled fix prompt tells the agent to run the plan's failing check before the new regression test exists; declined as pre-existing upstream main content and outside this run's task scope.", "disposition": "declined", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The phase's only code change restores upstream main's prompt-driven bundled fix workflow (plus its two prompts, the matching test expectations and the user-guide paragraph documenting the two model pins), so the branch no longer diverges from main on bundled workflow content and the repository's own workflow suite passes 1564/1564. The residual risk is that one major CodeRabbit finding on upstream's bundled fix.md prompt was declined as pre-existing and remains unresolved, and the run's actual PR title/body task was never implemented because phase 1 blocked on a missing PLAN.md."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
