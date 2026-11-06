# Assessment: post-merge-smoke-1557

Phase: `assess` / `impact-analysis` (phase 1 of 1)
Run: `run-8af842f0c20de26bb95b0af3e798b6a5` · Task: `post-merge-smoke-1557`

## What this phase found

**There is nothing to assess.** The change this phase is supposed to analyze does not exist in the
workspace it was launched in, and no discovery report was supplied.

- `git merge-base --is-ancestor origin/main HEAD` → **YES**: HEAD (`a6e4b5a4`) *is* `origin/main`. There
  is no post-merge delta — the branch contains nothing that main does not already have.
- Diff against `main`: **0 files, 0 insertions, 0 deletions** (`git diff --stat main...HEAD`).
- Diff against `origin/main`: same, 0 files.
- Working tree: clean.
- `docs/reports/` contains **no** discovery report (the `assess` phase lists one as an input; none was
  produced, so this run skipped or did not include a `discover` phase).

Two plausible readings, both outside this phase's authority to resolve:

1. **It is a smoke test of the `assess` workflow itself** — the task title says "post-merge smoke". Then
   the correct behavior is to report an empty impact analysis truthfully rather than manufacture one,
   which is what this document does.
2. **The run was cut against the wrong ref.** Orchestrator evidence points here: the `project_overview`
   context still describes an open task *"Automatically remove merged branches and worktrees"* with
   commits `7a802d32`, `0e14b6d0`, `6d9f3a28`, and a PR
   `https://github.com/rx10146/foreman/pull/7` "base: `main`", yet **none of those SHAs exist** in this
   workspace (`git cat-file -t` fails on all three) and that PR number does not resolve in the `foreman`
   repo on this machine. The branch this run sits on is the `ask-bridge` PRD/TRD pipeline
   (`feature/foreman-oq6oab`), whose last commit is a merged PR #840.

I did not try to make the assessment meaningful by analyzing the merged PRD/TRD commits on this branch.
That history is already merged, is not a post-merge delta, and inventing a scope for it would produce a
confident-looking report with no basis. Fields below are `Unknown` where the data genuinely is absent.

## 1. Scope

`Unknown` — no files or modules change. Diff vs `main` and `origin/main` is empty, and the working tree
is clean. If the intended subject is the automatic cleanup of merged branches/worktrees, that work is
not present in this workspace.

## 2. Impact

`Unknown` for the same reason: with no changed files there are no call sites to trace.

For orientation only (not a finding about this run): cleanup-shaped code that such a feature would
plausibly touch lives in `lib/foreman_server/workflow.ex` (`build_worktree_cleanup_plan/4`),
`lib/foreman_server/workflow/jobsite_plan.ex:106`, and
`lib/foreman_server/services/worktree_retention.ex`. Naming them here is a guess about intent, not an
assessment of a diff, and must not be used to scope implementation.

## 3. Risks

Ranked. Only risks that hold regardless of the intended delta are listed.

| # | Severity | Risk | Evidence / mitigation |
|---|---|---|---|
| R1 | **High** | Phase reports are written into the repo (`docs/reports/…`), so a phase run in a workspace whose branch isn't the intended one produces an artifact that looks authoritative for the wrong change. | This report is the mitigation: it states emptiness rather than guessing. Verify the branch/SHA before consuming any `post-merge-smoke-*` artifact. |
| R2 | Medium | Stale `project_overview` / task context fed into phases (PR #7, SHAs `7a802d32`/`0e14b6d0`/`6d9f3a28` don't exist here). Phases that trust it will edit the wrong files. | Regenerate or expire that task's context, or check whether the context projection is decoupled from the run's workspace. |
| R3 | Medium | Any change that deletes worktrees/branches is irreversible for unpushed work. | Applies only if R2's intended feature is real. Guardrails that must exist: clean-tree check, refuse when `git branch --contains` fails (already in `workflow.ex:2090` for PR-based retain decisions), and don't delete the current workspace. |
| R4 | Low | Toolchain drift: `mix.lock` differs from `origin/main`, but `mix deps.get` + `mix compile --warnings-as-errors` are clean at `a6e4b5a4`, and CI (lint + test) passes on that commit. | Already validated before this merge; no action. |

## 4. Test plan

`Unknown` — no code change means no tests can be named as "must pass for this change".

Standing gate for whatever this task eventually changes (per `AGENTS.md`), applicable to any repo where
tests can actually run:

- `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`, or
  the narrowest affected files.
- **Caveat found in this workspace:** `devbox.json` here has **no `services` block** (no
  postgres/redis/langfuse), so `mix test` cannot boot — `mix.exs:203` `claim_database!/2` fails with
  `FATAL 28P01 password authentication failed for user "postgres"` against
  `postgres://postgres:postgres@localhost:55432/foreman_test`. Same limitation was hit in
  `run-c5530c37` phases 6–7. `mix compile --warnings-as-errors` **does** work (706 files, exit 0).
  Note this as a fact about the workspace, not a code defect; it is unverified whether the deletion is
  intentional or a local override.

## 5. Rollback

Nothing to revert: the workspace is at `origin/main` with a clean tree, so rollback is a no-op
(`git checkout a6e4b5a4` already is the current state; no new commits, no files written except this
untracked report under `docs/reports/`, which Foreman's own worktree-cleanup rules keep as a phase
artifact).

If the intended subject is merged-branch/worktree auto-cleanup, rollback for that feature would be
config-only rather than a code revert: retain-all (`worktree:` `retain: "all"` / `after_merge: "retain"`
/ `after_open: "retain"`) to disable the behavior without touching code — the retention knobs are
already in place and tested (`test/foreman_server/worktree_retention_test.exs`).

## Recommended next step

Resolve the branch/context mismatch (R1/R2) before any implementation phase runs against this task:
confirm which branch and which change `post-merge-smoke-1557` is meant to assess. Nothing in this
phase can be built on.
