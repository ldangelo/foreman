/ensemble:fix-issue {{seedTitle}} {{seedDescription}}

# Foreman Bug-Fix Contract

You are running inside Foreman's `bug` workflow for bug **{{seedId}}**: **{{seedTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Instructions
- Identify the root cause before editing.
- Make the smallest correct fix; do not mask symptoms or add unrelated cleanup.
- Add or update a focused regression test when practical.
- Run targeted verification for the bug path. The workflow test phase runs the broader unit suite later.
- Do **not** commit, push, create PRs, or close the task. The pipeline handles that.
- If blocked, write `BLOCKED.md` explaining the blocker and still write `DEVELOPER_REPORT.md` with what you tried.

## Required Artifact
Before finishing, write `DEVELOPER_REPORT.md` in the worktree root with this structure:

```markdown
# Developer Report: {{seedTitle}}

## Root Cause
- What was broken.

## Fix
- What changed and why.

## Files Changed
- path/to/file.ts — what changed.

## Tests Added/Modified
- path/to/test.ts — what is covered.

## Verification
- Command or check run, with observed result.

## Known Limitations
- Anything not fully addressed, or "None".
```
