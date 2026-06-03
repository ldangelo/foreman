# Developer Report: Canary: exercise PR review workflow phases

## Approach
Implemented the four new PR review workflow phases by extending the default workflow YAML and creating the corresponding prompt files. No TypeScript changes were required — the YAML-driven pipeline architecture handles new phases purely through configuration. Also updated README.md to document the explicit PR review gate.

## Files Changed

- `src/defaults/workflows/default.yaml` — Added four new phases after `finalize`:
  - `create-pr` — Creates GitHub PR, writes `docs/reports/{task.id}/PR_METADATA.json`
  - `pr-wait` — Polls CI checks/CodeRabbit, writes `docs/reports/{task.id}/PR_WAIT_REPORT.md`
  - `prepare-pr-review` — Gathers diff/context, writes `docs/reports/{task.id}/PR_REVIEW_FINDINGS.md`
  - `pr-review` — AI review with verdict (`verdict: true`), writes `docs/reports/{task.id}/PR_REVIEW_REPORT.md`
  - `pr-review` uses `retryWith: prepare-pr-review` so a FAIL verdict loops back for more context before giving up

- `src/defaults/prompts/default/create-pr.md` (new) — Prompt for `create-pr` phase; uses `gh pr create` to create PR, writes `PR_METADATA.json`

- `src/defaults/prompts/default/pr-wait.md` (new) — Prompt for `pr-wait` phase; polls `gh pr checks` and CodeRabbit status, writes `PR_WAIT_REPORT.md` with PASS/TIMEOUT/FAIL outcome

- `src/defaults/prompts/default/prepare-pr-review.md` (new) — Prompt for `prepare-pr-review` phase; gathers PR diff, CodeRabbit comments, writes `PR_REVIEW_FINDINGS.md`

- `src/defaults/prompts/default/pr-review.md` (new) — Prompt for `pr-review` phase with `verdict: true`; reviews diff, outputs `PR_REVIEW_REPORT.md` with `## Verdict: PASS|FAIL`

- `README.md` — Added documentation of the explicit PR review gate (create-pr → pr-wait → prepare-pr-review → pr-review → refinery merge)

## Tests Added/Modified
No tests were added or modified. This task adds workflow configuration and prompts only — no TypeScript code changes. The YAML-driven pipeline design means these new phases work automatically without code changes.

## Decisions & Trade-offs
- **No TypeScript changes**: The pipeline executor reads phases from YAML and prompt files from disk — no hardcoded phase names. New phases work purely through configuration.
- **YAML artifact paths use `{seedId}` template**: Paths like `docs/reports/{seedId}/PR_METADATA.json` are consistent with how `epic.yaml` uses `{task.id}` in artifact paths. The pipeline executor must resolve these templates at runtime — this is already implemented in the artifact resolution logic.
- **`pr-review` verdict = true with retry**: The `pr-review` phase uses `verdict: true` so FAIL blocks merge. Retry goes back to `prepare-pr-review` (not `developer`) since the issue is likely incomplete review context, not implementation.
- **Model selection**: All new phases use `MiniMax` as default (same as existing phases). `pr-review` uses `MiniMax` for both default and P0 — consistent with reviewer phase.
- **Mail hooks**: `pr-review` forwards its artifact to `foreman` on completion — same pattern as `reviewer` phase.

## Known Limitations
- The `create-pr` phase creates a PR after finalize, but the existing auto-merge flow (in `onPipelineComplete`) already creates a PR via `refinery.ensurePullRequestForRun()`. This means there could be two PRs created for the same branch. However, `gh pr create` will fail if a PR already exists (same head/base), and the prompt handles this gracefully by setting `prCreated: false` in `PR_METADATA.json` on failure.
- The artifact path template `{seedId}` in YAML must be resolved by the pipeline executor — this was already implemented for `epic.yaml`'s `{task.id}` paths.
- The `pr-wait` phase polls GitHub checks, but GitHub Actions may have additional protection against polling. The phase has a 15-minute timeout to prevent infinite waits.