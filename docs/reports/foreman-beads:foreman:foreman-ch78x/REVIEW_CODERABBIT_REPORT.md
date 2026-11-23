# CodeRabbit Review — task `beads:foreman:foreman-ch78x`

Run: `run-8dec153539dbd49ac86c0a25c6bbc698` · phase 2 (`coderabbit-review`) · base branch: `main`
Worktree: `/Users/ldangelo/.foreman/worktrees/foreman/foreman-ch78x/run-8dec153539dbd49ac86c0a25c6bbc698/workspace`
Branch HEAD at review time: `9095fb24` · merge base with `main`: `4099cce4`

## Review engine

Command run from the worktree root:

```
FOREMAN_BASE_BRANCH=main coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

`$FOREMAN_BASE_BRANCH` was set (`main`), `coderabbit` was on `PATH`
(`/Users/ldangelo/.local/bin/coderabbit`) and `coderabbit auth status` reported an
authenticated GitHub account, so the engine ran for real against the diff
`main...HEAD` in this worktree.

Six invocations were made. Three aborted inside the engine **before producing any
finding** (engine-side failures, not review results):

| Attempt | Output | Result |
| --- | --- | --- |
| 1 | `/tmp/cr-ch78x-r1.out` | exit non-zero — `{"type":"error","errorType":"connection","message":"Connection failed: WebSocket closed", ... "cause":{"name":"TRPCWebSocketClosedError"}}` then `Error: An unexpected error occurred.` |
| 2 | `/tmp/cr-ch78x-r2.out` | identical WebSocket-closed connection error |
| 3 | `/tmp/cr-ch78x-r3.out` | `{"type":"error","errorType":"interrupted","message":"The review was stopped by SIGTERM after 23s, before it finished, and its results were discarded...","retryable":true,"elapsedSeconds":23}` — the background process died with the shell call |
| 4 | `/tmp/cr-ch78x-r4.out` | **completed** — `{"type":"complete","status":"review_completed","findings":1,"reviewedFiles":["docs/reports/foreman-beads:foreman:foreman-ch78x/FIX_REPORT.md","packages/foreman_server/priv/defaults/workflows/fix.yaml"],"outcome":"completed"}` |
| 5 | `/tmp/cr-ch78x-r5.out` | **completed** — same single finding (same file, same line) |
| 6 | `/tmp/cr-ch78x-r6.out` | **completed** (post-fix) — `{"type":"complete","status":"review_completed","findings":0,"reviewedFiles":["docs/reports/foreman-beads:foreman:foreman-ch78x/FIX_REPORT.md"],"outcome":"completed"}` |

No findings were inferred from attempts 1–3: they yielded engine errors, not review
results. Three completed rounds (attempts 4, 5, 6) were used, which is the round budget.

## Rounds

- **Round 1** (attempt 4) — findings received: 1 (`major`, `fix.yaml:35`). Fixed: 1.
  Declined: 0.
- **Round 2** (attempt 5) — findings received: 1 (`major`, same file and line, same
  issue restated as "Correct the `pr-review` command namespace to `ensemble`.").
  Duplicate of round 1: no new action taken, no additional fix applied.
- **Round 3** (attempt 6, run after the fix) — findings received: 0. The bogus command
  reference is gone and the engine reported a clean review of the remaining diff
  (`REVIEW_CODERABBIT_REPORT.md`'s sibling `FIX_REPORT.md` only).

## Fixed

1. **`packages/foreman_server/priv/defaults/workflows/fix.yaml`** — finding anchored at
   line 35: *"Correct the `merge-pr` command namespace in the `pr-review` phase."*
   - **What was wrong.** The branch's copy of the bundled `fix` workflow was the WIP
     command-based manifest that came in with commit `dd0c239b` ("[pi] Work in progress",
     merged into the branch by `6905638c`, and *not* an ancestor of `main`). Its
     `pr-review` phase ran `command: "/enseble:merge-pr --foreman"`: `enseble` is not a
     registered command namespace, and the ensemble plugin ships no `merge-pr` command at
     all (`packages/development/commands/` contains `fix-issue.yaml`; the skill behind the
     merge gate is `/ensemble:pr-merge`). The sibling `fix` phase was command-based too
     (`/ensemble:fix-issue --foreman {{input.prompt}}`), so the whole manifest bypassed
     Foreman's bundled prompts.
   - **Why the suggested replacement was not applied.** CodeRabbit proposed the
     `ensemble` namespace (`/ensemble:merge-pr`). That namespace exists, but the command
     name does not: the ensemble plugin registers `pr-merge`, not `merge-pr`. On top of
     that, this branch's own workflow tests forbid *any* `command:`-driven phase
     (`test/foreman_server/workflow/catalog_test.exs:142-170` asserts
     `fix_phase.action == :prompt` and `fix_phase.command in [nil, ""]`;
     `prompt_inbox_progress_test.exs:25-40` and
     `full_workflow_lifecycle_test.exs:510-524` assert the phases carry no `command`
     key). A one-line typo edit would have left a red suite behind and still pointed at
     an unregistered command.
   - **What changed.** The file was restored to the prompt-driven manifest that upstream
     ships, taken verbatim from this branch's own merge base:
     `git show 4099cce4:packages/foreman_server/priv/defaults/workflows/fix.yaml`
     (upstream made the same restoration in `51311def`, "fix(workflows): restore
     prompt-driven fix.yaml"). The result is the 3-phase manifest
     `fix` → `coderabbit-review` → `repo-rules-review`, each phase running a bundled
     Foreman prompt (`fix.md`, `review-coderabbit.md`, `review-repo-rules.md`) and writing
     `FIX_REPORT.md` / `REVIEW_CODERABBIT_REPORT.md` / `REVIEW_REPORT.md`; the
     workflow-level `worktree:` block is unchanged. Both `command:` phases and the bogus
     `/enseble:merge-pr` reference are gone.
   - **Diff.** One file, 13 insertions / 5 deletions. Left uncommitted, as this phase
     requires (Foreman commits it).
   - **Merge safety.** The restored file is byte-identical to the merge-base version
     (`git diff 4099cce4 -- packages/foreman_server/priv/defaults/workflows/fix.yaml` is
     empty), so once committed the branch carries no change to that file relative to the
     merge base and cannot revert `main`'s newer manifest.

## Declined

None. The one finding received was real and was fixed.

## Verification

All commands run from the run's worktree; the Elixir ones through
`devbox run -- bash -c '...'` with an absolute `cd`.

| # | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `MIX_ENV=test mix deps.get` (worktree had no `deps/`) | 0 | deps fetched |
| 2 | `MIX_ENV=test mix compile` | 0 | compiled, no warnings |
| 3 | `MIX_ENV=test DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_ch78x TEST_DB_POOL_SIZE=5 mix test test/foreman_server/workflow/catalog_test.exs test/foreman_server/workflow/prompt_inbox_progress_test.exs` | 0 | `Result: 36 passed` |
| 4 | same env, `mix test test/foreman_server/workflow/full_workflow_lifecycle_test.exs` | 0 | `Result: 6 passed` |
| 5 | same env, `mix test test/foreman_server/workflow/bundled_workflow_models_test.exs test/foreman_server/workflow/interpreter_test.exs` | 0 | `Result: 78 passed` |
| 6 | same env, `mix test test/foreman_server/workflow` (whole directory) | 0 | `Finished in 363.4 seconds`, `Result: 1564 passed` |
| 7 | final post-fix re-run of the three files that pin the `fix` manifest (catalog + prompt inbox + full lifecycle) | 0 | `Result: 42 passed`, `ProjectionLeakGuard: judged 1 of 2 modules, no run left behind` |
| 8 | `mix format --check-formatted priv/defaults/workflows/fix.yaml` | 0 | no output (the repo formats Elixir only; there is no YAML linter in CI) |
| 9 | `grep -rn "enseble" .` | 0 | only one hit, a historical note in `docs/reports/trd-2026-b9e27ab5-per-project-dispatch-queues-completion-2026-11-20.md:83`; no live code or config reference remains |

Test-environment notes (not part of the change): the suite takes a session advisory lock
on the `foreman_test` database, so this run used a dedicated database
`foreman_test_ch78x` (`mix event_store.init` first); the ambient `DATABASE_URL` on port
55434 fails password auth.

## Residual issues for the operator (not CodeRabbit findings)

- **The task itself is still unimplemented.** Phase 1 wrote `Blocked: no plan found` into
  `FIX_REPORT.md`; nothing on this branch implements the requested base-ref refresh
  (`git fetch origin <base_branch>` before worktree creation, a `base_ref_policy`
  project setting, the base commit SHA in `RunBaseBranchRecorded`, and a "base is N
  commits behind origin/<base>" surface on the run and in `foreman project recommend`).
  A review phase cannot implement a feature that has no plan and no code.
- **The branch base is stale.** `main` has since replaced the 3-phase `fix` manifest with
  a 4-phase one that adds a `plan` phase writing `PLAN.md` (`e89fa4da`, PR #920). The
  manifest restored here matches this branch's merge base, so the branch still lacks that
  plan phase. The operator-level remedy is to rebase the branch onto `main` — which is
  exactly the defect task `foreman-ch78x` describes. Note also that `.beads/issues.jsonl`
  changed on both sides of the merge base, so merging this branch as-is may conflict
  there; a rebase avoids it.
- **Documentation gate.** The change removes two operator-visible command strings from the
  bundled `fix` workflow (`/ensemble:fix-issue --foreman {{input.prompt}}` and
  `/enseble:merge-pr --foreman`) and drops the `pr-review` phase in favour of the
  `coderabbit-review` / `repo-rules-review` phases. No new identifier is introduced: the
  restored manifest is exactly what this branch's merge base already shipped, and `main`
  carries the same prompt-driven phases. Grepping `CLAUDE.md`, `README.md`,
  `docs/user-guide.md` and `docs/cli-reference.md` for `enseble` / `merge-pr` finds
  nothing, so none of those four files needed an edit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 35, "description": "The pr-review phase invoked the non-existent command /enseble:merge-pr, so that phase could never resolve a command.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The only code change restores the bundled fix workflow manifest to the prompt-driven version this branch's merge base already shipped, removing a command that exists in no command registry; the workflow test directory is green (1564 passed) and the restored file is identical to the merge base, so the branch cannot revert main's newer manifest. Risk stays MEDIUM because the run delivered no implementation of the requested base-ref refresh (phase 1 wrote 'Blocked: no plan found') and the branch is behind main, so it must be rebased rather than merged as-is."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
