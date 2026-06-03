# Developer Report: Canary: exercise PR review workflow phases

## Approach
The PR review workflow infrastructure (YAML + prompts) was already created in `~/.foreman/`. I made two targeted fixes:
1. Fixed the template variable syntax bug in `pr-review.md` (legacy `{var}` → `{{var}}`)
2. Added a one-sentence docs note to README.md about the explicit PR review workflow option

## Files Changed

### `~/.foreman/prompts/default/pr-review.md`
- Fixed template variable syntax from `{var}` to `{{var}}` style (6 replacements: `{seedTitle}`, `{seedId}`, `{runId}`, `{worktreePath}`)
- This was a CRITICAL bug: the pipeline executor interpolates `{{var}}` placeholders; `{var}` would be emitted literally, breaking agent instructions

### `README.md` (line 17)
- Added sentence describing the optional explicit PR review gate: "with optional explicit PR review gate: finalize → create-pr → pr-wait → prepare-pr-review → pr-review → refinery merge"
- Minimal, docs-only change safe to merge

## Tests Added/Modified
- None required — this is a workflow infrastructure task, not a code change task
- The PR review phases are exercised by the pipeline itself, not unit tested

## Decisions & Trade-offs
- The explorer plan mentioned creating prompt files, but all 4 prompt files (`create-pr.md`, `pr-wait.md`, `prepare-pr-review.md`, `pr-review.md`) and the workflow YAML (`pr-review.yaml`) already existed from previous work
- Only the template syntax fix was needed in `pr-review.md` — the other 3 prompts were already correct
- The docs change is the smallest viable diff to satisfy the task requirement of "a minimal docs-only change"

## Known Limitations
- The pipeline dispatcher must select `pr-review` workflow (via `workflow:pr-review` label on bead) for the phases to execute — this is a configuration/dispatch concern outside the implementation scope
- Cannot verify end-to-end workflow execution in this session; relies on pipeline re-run with correct workflow label