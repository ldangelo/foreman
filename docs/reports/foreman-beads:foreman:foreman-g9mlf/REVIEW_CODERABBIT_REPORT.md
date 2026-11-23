# CodeRabbit review — `beads:foreman:foreman-g9mlf`

Phase 2 (`coderabbit-review`) of run `run-2f7c6aa64adb932cf7f37e0ac2de5ad8`. Diff base: `$FOREMAN_BASE_BRANCH` = `main` (merge-base `4099cce4`, branch HEAD `c77b40d2`).

Two files differ from `main`:
- `packages/foreman_server/priv/defaults/workflows/fix.yaml` — the branch's command-phase variant (`fix` → `/ensemble:fix-issue …`, `pr-review` → `/enseble:merge-pr …`), from commit `dd0c239b`.
- `docs/reports/foreman-beads:foreman:foreman-g9mlf/FIX_REPORT.md` — phase 1's committed `Blocked: no plan found` report.

**Bottom line: the branch is still 0 commits of implementation ahead of `main`** (see §6). The only code-shaped change on the branch is the one-line workflow correction made in this phase.

## 1. Review engine

`coderabbit` 0.9.6 at `/Users/ldangelo/.local/bin/coderabbit`, authenticated. Command run from the worktree root, backgrounded with a 600s budget:

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

A first foreground attempt at 600s timed out and was discarded. A first backgrounded attempt failed transiently with `{"type":"error","errorType":"connection","message":"WebSocket closed"}` (exit 1) and was retried, not counted as a round. Successful runs took 135–240s each.

## 2. Rounds

**Round 1** — `review_completed`, `findings: 1`, `reviewedFiles`: `FIX_REPORT.md`, `fix.yaml`. One `major` finding at `packages/foreman_server/priv/defaults/workflows/fix.yaml:35`: namespace `enseble` is inconsistent with the `ensemble` namespace used at line 29, and no command definition in the repository registers `/enseble:merge-pr`. Suggested replacing it with a registered `/ensemble:` name, or restoring the prompt-based review phases.

**Round 2** (post-fix, re-run over the working tree) — same `major` finding at `fix.yaml:35`, now citing the committed phase-1 report as evidence that the invocation does not exist. Its advice was narrowed to: "Update `pr-review` command in workflow to use command verified to be registered in the `/ensemble:` namespace; if no registered equivalent exists, restore prompt-based review phases rather invoking undefined command." The flagged line at round-2 time was the stale committed text — the fix was in the working tree, uncommitted, and CodeRabbit's comment is anchored to HEAD.

**Round 3** — not run. Rounds 1 and 2 independently reported the identical single finding and the same `reviewedFiles` set; round 3 would re-derive the same conclusion. The post-fix verification (below) is what actually settles it.

## 3. Fixed

**`packages/foreman_server/priv/defaults/workflows/fix.yaml:35`** — `command: "/enseble:merge-pr --foreman"` → `command: "/ensemble:pr-merge --foreman"`. Left uncommitted for Foreman's phase commit.

The finding is real on both counts:
- `enseble` is a typo of `ensemble`; the sibling `fix` phase at line 29 already uses `/ensemble:fix-issue --foreman {{input.prompt}}`.
- `merge-pr` does not exist. The ensemble repo's real command is `ensemble:pr-merge` (`/Users/ldangelo/Development/Sunstone/ensemble/packages/git/commands/pr-merge.yaml`, `metadata.name: ensemble:pr-merge`, whose `argument_hint` includes `--foreman`). No `merge-pr` or `enseble` token appears anywhere in the ensemble repo; the only occurrence in this repo was `fix.yaml:35`.

Why the colon form rather than a pi-native one: a workflow `command:` phase value is agent prompt text, not a shell command (`lib/foreman_server/workflow/phase_spec.ex` accepts `command:`, `lib/foreman_server/workflow/lowering.ex:190-200` requires it to be non-empty, `lib/foreman_server/workflow/interpreter.ex:777-797` requires exactly one of `prompt`/`command`/`bash` and that `command` start with `/`). pi 1.6.0 exposes prompt templates as `/ensemble-<cmd>` and skills as `/skill:<name>`, and `lib/foreman_server/workflow/validator.ex` validates only `/skill:`-prefixed commands against `@known_skills` — which lists `ensemble-fix-issue` but **not** `ensemble-pr-merge`. So `/skill:ensemble-pr-merge` would fail bundled-workflow validation and require a Validator change, which is beyond a review phase. `/ensemble:pr-merge` matches the file's existing convention and Foreman's own `ensemble:<cmd>` vocabulary (`lib/foreman_server/agents/jido_signal_topics.ex:49`), and bypasses that validator check exactly as the neighbouring `fix` phase already does.

## 4. Declined

- **Restoring the prompt-based review phases** (CodeRabbit's alternative). Reverting the branch's command-phase design is not a review-phase fix; it duplicates main's newer shape (`e89fa4da` moved the phases to prompts `fix-plan.md`/`fix.md`/`review-coderabbit.md`/`review-repo-rules.md`) and is a design decision for the operator, not this phase. The finding is resolved by the naming fix alone.
- **`/ensemble:fix-issue` at line 29.** Same non-pi-resolvable namespace concern applies, but CodeRabbit did not flag it, the token is spelled correctly, and it predates this run.

## 5. Verification

Narrowest affected tests (`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test … --warnings-as-errors'`), against EventStore on port 55432, database `foreman_test_g9mlf` created via `PGPASSWORD=postgres psql -h 127.0.0.1 -p 55432 -U postgres -c "CREATE DATABASE foreman_test_g9mlf;"` then `MIX_ENV=test mix event_store.init` (the worktree's exported `DATABASE_URL` on 55434 rejects its password; `mix ecto.create`/`ecto.migrate` are no-ops in this app):

- `test/foreman_server/workflow/bundled_workflow_skills_test.exs` + `bundled_workflow_models_test.exs` — **EXIT 0, 4 passed, 0 failures**, `--warnings-as-errors` clean. These load every bundled workflow YAML through `Interpreter.load!/1` and `Validator.validate/1`, so they cover the changed file.
- `test/foreman_server/workflow/` (whole directory, `--seed 0`) — **EXIT 2, 1561/1564 passed; 3 failures**, `ProjectionLeakGuard: judged 68 of 83 modules, no run left behind`. The three failures all assert that `fix.yaml` phases are *prompt*-driven:
  - `PromptInboxProgressTest` — "fix and review prompt phases are prompt-driven and keep inbox progress guidance" (`prompt_inbox_progress_test.exs:25` does `refute Map.has_key?(phase, "command")`).
  - `FullWorkflowLifecycleTest` — "AC 1: workflow manifest correctness via `Interpreter.load/1` fix.yaml runs the bundled `fix.md` prompt, not an external skill" (`assert fix_phase["prompt"] == "fix.md"` → `left: nil`, `right: "fix.md"`).
  - `CatalogTest` — "fix workflow (WFD-T006 / TRD-069) loading fix.yaml yields the fix phase followed by the two review phases" (`assert length(wf.phases) == 3` → `left: 2`, `right: 3`).

  These are **pre-existing on this branch, not caused by this fix**: `git stash push -- packages/foreman_server/priv/defaults/workflows/fix.yaml` and re-running those three files reproduces the identical 3 failures (EXIT 2, 39/42 passed) with the file untouched; `git stash pop` restored the fix. Cause is the branch's own command-phase revert `dd0c239b`, which main's newer `e89fa4da` supersedes — this branch predates main's prompt-based `fix` workflow, so main's tests and this branch's `fix.yaml` disagree. Reconciling them is a rebase/re-authoring decision for the operator, out of a review phase's scope.
- **Formatter:** repo has no YAML linter (no yamllint, pre-commit hook, or `.editorconfig`; `.github/workflows` has no yamllint/actionlint step) and `mix format` does not touch `priv/`. `MIX_ENV=test mix format --check-formatted` → exit 0 (no Elixir file changed). YAML validity of the edited file is proven by the passing `Interpreter.load!/1` load in the tests above.
- **Documentation gate.** Identifiers touched: the workflow command string `/enseble:merge-pr` (removed) and `/ensemble:pr-merge` (added). `grep -rn -i "enseble|merge-pr|pr-merge"` over `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` → **no hits in any of the four**, so none needed edits: no route, config key, env var, CLI verb, or MCP tool was added, removed, or renamed — the change is inside one workflow YAML's phase list. The one historical mention, `docs/reports/trd-2026-b9e27ab5-per-project-dispatch-queues-completion-2026-11-20.md:83` (describes the old `/enseble:merge-pr` and the commit that restored `fix.yaml`), is a point-in-time completion report and is left as written.

## 6. Unresolved, for the operator

The task's 5-point objective (launch pi workers under `PI_SUBAGENT_CHILD=1`, assert the effective model equals the resolved model, surface the effective model on run/thread views, a failing-first fake-extension test, and treat a `stopReason: length` turn with no tool call as a failed worker turn) is **entirely unimplemented**. Branch diff vs `main` contains no `lib/` or `test/` change; phase 1 correctly stopped because no `PLAN.md` producer exists in the dispatched `fix` workflow. This review found only the workflow-naming defect, so the underlying `ensemble-pdf-f2`-class failure (a user-level pi extension silently rewriting the worker's model, plus 8192-token reasoning caps ending sessions) is still live on `main`.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema":"foreman.review_findings/1","reviewed":true,"findings":[{"severity":"major","path":"packages/foreman_server/priv/defaults/workflows/fix.yaml","line":35,"description":"The pr-review phase invokes /enseble:merge-pr --foreman, a misspelled namespace for a command that does not exist; the correct registered command is /ensemble:pr-merge.","disposition":"fixed","source":"coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema":"foreman.risk_judgement/1","level":"LOW","rationale":"Only one line of executable config changed: a misspelled, non-existent command name corrected to the registered ensemble:pr-merge, matching the sibling fix phase's existing namespace convention. No Elixir, no schema, no route, no CLI or MCP surface touched; bundled-workflow load and validation tests pass with --warnings-as-errors. The change cannot make the pr-review phase worse than invoking a command that never existed. Caveats a reviewer should see: the 3 failing tests in the workflow directory (catalog, prompt_inbox_progress, full_workflow_lifecycle) are pre-existing on this branch, reproduced identically with the file stashed, because the branch predates main's prompt-based fix workflow; the run's real 5-point objective remains unimplemented; and pi expands only /skill: names, prompt templates and extension commands, so this colon-namespaced string reaches the model as prompt text exactly as the neighbouring fix phase's /ensemble:fix-issue already does."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
