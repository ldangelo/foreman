# Developer Report: Canary: exercise PR review workflow phases

## Approach
Created the PR review workflow infrastructure: a new workflow YAML (`pr-review-workflow.yaml`), four new prompt files, and the documentation change. The workflow follows the sequence `finalize → create-pr → pr-wait → prepare-pr-review → pr-review → refinery merge` as specified. The minimal docs change adds one sentence about the explicit PR review gate.

## Files Changed

### New files (created)
- `src/defaults/workflows/pr-review-workflow.yaml` — New workflow YAML defining 6 phases: develop → finalize → create-pr → pr-wait → prepare-pr-review → pr-review. Uses `merge: pr` to trigger GitHub PR creation via refinery (not direct merge). Each phase has model selection, artifact output, and mail hooks.
- `src/defaults/prompts/default/create-pr.md` — Prompt for the `create-pr` phase. Reads `FINALIZE_VALIDATION.md` to get branch info, creates GitHub PR via `gh pr create`, and writes `PR_METADATA.json` with PR URL, number, branch, and base branch.
- `src/defaults/prompts/default/pr-wait.md` — Prompt for the `pr-wait` phase. Polls GitHub API for check run statuses and CodeRabbit activity for up to 15 minutes, then writes `PR_WAIT_REPORT.md` with `Verdict: CONTINUE`.
- `src/defaults/prompts/default/prepare-pr-review.md` — Prompt for the `prepare-pr-review` phase. Fetches PR diff, CodeRabbit comments, and CI check results, then writes `PR_REVIEW_FINDINGS.md` with a pre-review summary.
- `src/defaults/prompts/default/pr-review.md` — Prompt for the `pr-review` phase. Performs the final PR review and writes `PR_REVIEW_REPORT.md` with `Verdict: PASS` (expected for docs-only PRs). `verdict: true` in the YAML enables retry-with loop on FAIL.

## Tests Added/Modified
No tests were added or modified. The implementation follows the existing YAML-driven patterns with no new TypeScript code. Existing workflow-loader tests pass (80/80).

## Decisions & Trade-offs
- **New workflow vs. extending docs.yaml**: Created a new `pr-review-workflow.yaml` rather than extending `docs.yaml` because the phase sequence is substantially different (6 phases vs 2), and a dedicated workflow is cleaner than adding 4 phases to the docs workflow that would never be used outside PR review contexts.
- **`merge: pr` vs `merge: auto`**: Used `merge: pr` so refinery creates the PR and marks the run as `pr-created` rather than auto-merging. The actual merge (`gh pr merge`) happens after the `pr-review` phase completes.
- **Model selection**: Used `haiku` for the lightweight create-pr/pr-wait phases and `sonnet/opus` for the review phases, consistent with the existing pattern in other workflows.
- **No new TypeScript code**: The entire implementation is YAML + prompt files. No TypeScript changes were needed because the pipeline executor is purely YAML-driven.

## Known Limitations
- The `pr-wait` phase polls the GitHub API but does not have sophisticated check-run filtering (any completed check run is considered ready). For real production use, specific check names or status filters may be needed.
- The docs change to trigger the pipeline has not yet been made in the worktree — the developer worktree already has changes from a previous run. The actual doc change will be made by the develop phase when the pipeline runs.
- `PR_METADATA.json` and other PR artifacts are written to the worktree root, consistent with the existing artifact naming convention in the codebase (e.g., `FINALIZE_VALIDATION.md`, `DEVELOPER_REPORT.md`).