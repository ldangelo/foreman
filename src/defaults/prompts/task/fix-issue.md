/ensemble:fix-issue {{seedTitle}} {{seedDescription}}

# Foreman Fix-Issue Contract

You are running inside Foreman's `task` workflow for task **{{seedId}}**: **{{seedTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Instructions
- Make the smallest correct change that satisfies the task.
- Reuse existing project patterns; do not introduce abstractions for one-off code.
- Update directly affected tests when behavior changes.
- Run targeted verification for the files or behavior you changed. The workflow test phase runs the broader unit suite later.
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
