/ensemble:fix-issue {{seedTitle}} {{seedDescription}}

# Foreman Chore-Fix Contract

You are running inside Foreman's `chore` workflow for chore **{{seedId}}**: **{{seedTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Instructions
- Keep the change mechanical and scoped to the chore.
- Preserve existing behavior unless the task explicitly asks to change it.
- Update directly affected tests when behavior or public interfaces change.
- Run targeted verification for the touched area. The workflow test phase runs the broader unit suite later.
- Do **not** commit, push, create PRs, or close the task. The pipeline handles that.
- If blocked, write `BLOCKED.md` explaining the blocker and still write `DEVELOPER_REPORT.md` with what you tried.

## Required Artifact
Before finishing, write `DEVELOPER_REPORT.md` in the worktree root with this structure:

```markdown
# Developer Report: {{seedTitle}}

## Approach
- What changed and why.

## Files Changed
- path/to/file.ts — what changed.

## Tests Added/Modified
- path/to/test.ts — what is covered.

## Verification
- Command or check run, with observed result.

## Decisions & Trade-offs
- Any relevant design decisions.

## Known Limitations
- Anything not fully addressed, or "None".
```
