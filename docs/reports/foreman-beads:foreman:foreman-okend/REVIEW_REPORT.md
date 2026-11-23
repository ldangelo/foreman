# Repo-rules review — `beads:foreman:foreman-okend`

## Review engine

Reviewer: the `repo-rules` review phase agent of Foreman's `fix` workflow (phase 4 of 4), applying this repository's own contributor guidance — `AGENTS.md` at the repository root — together with the conventions of the files this run touches. No external review CLI was used; the pass was a direct read of the diff against those rules.

Diff range reviewed: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with `$FOREMAN_BASE_BRANCH=main` (set — the run was cut from `main`; merge base `f0f3b083`, HEAD `8b84206d`).

`git diff main...HEAD --name-status` — three added files, no modified file, nothing under `packages/`:

| File | Status |
| --- | --- |
| `docs/reports/foreman-beads:foreman:foreman-okend/PLAN.md` | added |
| `docs/reports/foreman-beads:foreman:foreman-okend/FIX_REPORT.md` | added |
| `docs/reports/foreman-beads:foreman:foreman-okend/REVIEW_CODERABBIT_REPORT.md` | added |

The committed diff therefore contains **no product code and no user-facing documentation**. The only reviewable surface is this run's own report artifacts, so `AGENTS.md`'s rules were applied to the claims those artifacts make (accuracy of evidence, no declaration without an implementation behind it, documentation reconciled with what the code actually does).

Carry-forward from the previous phase: `docs/reports/foreman-beads:foreman:foreman-okend/REVIEW_CODERABBIT_REPORT.md` exists but is **2 bytes** (`0a0a`) — it has **no readable findings block**, so **no findings were carried forward** from it. Its emptiness is reported as a declined finding below (D2) rather than treated as evidence, and no finding was invented on its behalf.

Uncommitted changes produced by this phase (left uncommitted for Foreman to commit): edits to `PLAN.md` and `FIX_REPORT.md` only.

## Findings

Received:

| # | Finding | Source | Outcome |
| --- | --- | --- | --- |
| F1 | Task prompt: "Update `docs/user-guide.md` — document the new `base_ref_policy` setting, the fetch-before-run behaviour, the base SHA surfaced on `RunBaseBranchRecorded`, and the 'behind origin' recommendation from `foreman project recommend`." | task prompt | **Declined** (D1) |
| F2 | Previous phase's `REVIEW_CODERABBIT_REPORT.md` findings block | coderabbit | **Absent** — the file is 2 bytes with no findings block, so there was nothing to carry forward (reported as D2) |

Raised by this phase against `AGENTS.md`:

| # | Finding | File | Outcome |
| --- | --- | --- | --- |
| F3 | The run's own plan claims `branch.behind_origin` has "no PR open" and is the only work "at risk of being lost"; PR #946 is open on that exact branch | `PLAN.md:16`, `PLAN.md:103` | **Fixed** (X1) |
| F4 | The run's own fix report repeats the false "zero open PR / at real risk of loss" operator action, cites the unresolvable commit `b7b7b974`, points at the non-existent path `packages/foreman_server/lib/foreman_server/aggregates/settings.ex:31`, and states that no escalation tools exist | `FIX_REPORT.md:10`, `FIX_REPORT.md:12-14`, `FIX_REPORT.md:18` | **Fixed** (X2) |

## Fixed

X1 — `docs/reports/foreman-beads:foreman:foreman-okend/PLAN.md`

- **What was wrong:** §1's table row claimed commit `295155d0` has "**no PR open**", and §4 told the operator that this work "exists solely as a local branch, so it is the only one at risk of being lost". `gh pr view 946` reports **OPEN** on branch `foreman/foreman-qdt14/run-0c30344c74abc80ba7c2b40090d98819`, so the plan named an operator action for work that is already tracked and pushed.
- **What changed:** the §1 table row now reads `commit 295155d0 (PR #946, open)`; §4's lead-in names PR #946 instead of "local branch"; §4's operator paragraph now records that **no** operator action remains, because all three subjects are carried by open PRs #943, #945 and #946.

X2 — `docs/reports/foreman-beads:foreman:foreman-okend/FIX_REPORT.md`

- **What was wrong:** (a) "**no PR**" for qdt14 and "**qdt14 has zero open PR** … that work is at real risk of loss. Open a PR for …" — false, PR #946 is open; (b) the cherry-pick instruction cited commit `b7b7b974`, which resolves to no object in any ref (`git rev-parse --verify b7b7b974` → exit 128); (c) the settings whitelist was cited at `packages/foreman_server/lib/foreman_server/aggregates/settings.ex:31`, a path that does not exist — the real file is `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex`, whose `@keys` sit at lines 47-51; (d) "all escalation tools remain unavailable … `foreman_inbox_send` / `foreman_task_add_comment` are not exposed here" — false, both work in this run through the codemode MCP namespace.
- **What changed:** all four claims corrected in place — PR #946 named as open; the operator-action header now reads "three items, none urgent" and its bullet says "`branch.behind_origin` is already carried by open PR #946 … no PR needs opening"; the cherry-pick bullet replaced by "closed once PR #943, PR #945 and PR #946 merge the three subjects into `main`. No cherry-pick is needed"; the settings path corrected to `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:47-51`; the escalation sentence now states that `foreman_inbox_send` and `foreman_task_add_comment` **are** available in this run through the codemode MCP namespace.

## Declined

D1 — `docs/user-guide.md`

- **The finding:** the task prompt asks this run to document the `base_ref_policy` setting, the fetch-before-run behaviour, the `base_sha` surfaced on `RunBaseBranchRecorded`, and the `branch.behind_origin` recommendation in `docs/user-guide.md`.
- **The reason:** all four subjects are absent from this branch, so documenting them here would describe behaviour the server does not have — `base_ref_policy` is not in `Aggregates.Project.Settings.@keys` (`packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:47-51`), so `project update --base-ref-policy` is rejected with `{:unknown_setting, :base_ref_policy}`; `RunBaseBranchRecorded` has no `base_sha` field (`packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex:23`); `packages/foreman_server/lib/foreman_server/projects/recommendations.ex` has no `branch.behind_origin` recommendation (its 19 `rec(` ids are unchanged from this branch); and no fetch-before-run exists (`git log --all -S"Git.fetch" -- packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` is empty; the only `Git.fetch_branch/4` caller is `Exec.Worktree.sync_branch/3`, the PR-head attach path). Writing the prose anyway is the "plausible-looking success" `AGENTS.md` §5.2 forbids. Each subject is already implemented and documented on its owning branch — PR #943 (`base_ref_policy`), PR #945 (`base_sha`), PR #946 (`branch.behind_origin`), all open, none merged into `HEAD` or `origin/dev` — so a copy here would also collide with those PRs in the same `docs/user-guide.md` lines. `docs/user-guide.md` is therefore left byte-identical to the base.

D2 — `docs/reports/foreman-beads:foreman:foreman-okend/REVIEW_CODERABBIT_REPORT.md`

- **The finding:** the previous phase's review artifact is empty (2 bytes, `0a0a`), so it carries no findings for this phase to forward.
- **The reason:** writing content into it would mean authoring a review this phase did not run. The emptiness is recorded here instead, and no finding was invented on its behalf.

## Verification

| Command | Exit | Result |
| --- | --- | --- |
| `git diff "$FOREMAN_BASE_BRANCH"...HEAD` (`$FOREMAN_BASE_BRANCH=main`) | 0 | 3 added files, no modified file, nothing under `packages/` |
| `git diff --quiet f0f3b083 HEAD -- docs/user-guide.md` | 0 | `docs/user-guide.md` byte-identical to the base |
| `git status --short` | 0 | only `PLAN.md`, `FIX_REPORT.md` modified plus this untracked report — all changes left uncommitted |
| `grep -rn "base_ref_policy\|base_sha\|behind_origin" CLAUDE.md README.md docs/user-guide.md docs/cli-reference.md` | 1 | no hits — this diff adds, removes or renames no identifier, so the documentation gate has nothing to reconcile |
| `grep -n "no PR open\|zero open PR\|b7b7b974\|aggregates/settings.ex\|not exposed here" PLAN.md FIX_REPORT.md` | 1 | no residual false claims after the fixes |
| `git rev-parse --verify b7b7b974` | 128 | commit does not exist in any ref — the dangling reference was removed |
| `git merge-base --is-ancestor <c489c0f3\|295155d0\|887b82a7> HEAD` and `… origin/dev` | 1 (×6) | none of the three owning commits is merged |
| `gh pr view 943`, `gh pr view 945`, `gh pr view 946` | 0 (×3) | all three PRs OPEN |
| `git log --all -S"base_ref_policy" -- …/aggregates/project/settings.ex`; `-S"base_sha" -- …/events/run_base_branch_recorded.ex`; `-S"branch.behind_origin" -- …/projects/recommendations.ex` | 0 | the three subjects exist only on their owning branches (`c489c0f3`, `887b82a7`/`edee4fb0`/`9978bdbe`, `295155d0`) |
| `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/observability/docs_test.exs --warnings-as-errors'` | **1** | **The test did not execute:** Mix cannot compile in this worktree — every dependency reports `the dependency is not available, run "mix deps.get"`, then `** (Mix) Can't continue due to errors on dependencies`. This is an environment defect (unfetched Hex deps), not a test failure; re-run the same command after `mix deps.get` in `packages/foreman_server`. |

No other test or formatter was run: this phase changed markdown report artifacts only (no source, no config, no user-facing doc); the repository ships no markdown linter or formatter for `docs/`, and `mix format` does not apply to markdown. The full suite was not run.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-okend/PLAN.md", "line": 16, "description": "PLAN.md asserted that qdt14's commit 295155d0 had no open PR and was the only work at risk of loss, but PR #946 is open on that branch; corrected in place.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-okend/FIX_REPORT.md", "line": 10, "description": "FIX_REPORT.md repeated the false \"zero open PR / at real risk of loss\" operator action, cited the unresolvable commit b7b7b974 and the non-existent path aggregates/settings.ex:31, and wrongly said no escalation tools exist; all corrected in place.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-okend/REVIEW_CODERABBIT_REPORT.md", "line": null, "description": "The previous phase's review report is empty (2 bytes), so it carries no findings and nothing could be carried forward.", "disposition": "declined", "source": "repo-rules"}, {"severity": "major", "path": "docs/user-guide.md", "line": null, "description": "The task prompt asked to document base_ref_policy, fetch-before-run, the base SHA and branch.behind_origin in docs/user-guide.md, but all four are absent from this branch and already documented by open PRs #943, #945 and #946.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The diff adds three report markdown documents only: no source, config, route, CLI verb, event type or user-facing documentation changed, and docs/user-guide.md is byte-identical to the base. The only corrections this phase made are to the run's own artifacts, replacing a false \"no PR open\" operator action with the verified PR #946, removing a dangling commit reference and a non-existent file path."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
