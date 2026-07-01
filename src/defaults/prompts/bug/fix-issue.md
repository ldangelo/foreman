/ensemble:fix-issue {{taskTitle}} {{taskDescription}}

# Foreman Bug-Fix Contract

You are running inside Foreman's `bug` workflow for bug **{{taskId}}**: **{{taskTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Fast-Path Triage
- If retry feedback cites a specific report, failing phase, file, or command, read that artifact first and fix that cited area before broader investigation.
- Start with one `git status --short` and one focused diff/list command; avoid repeated broad `ls`, `git log --all`, or directory walks unless they answer a specific question.
- Do not edit workflow or prompt files unless the task explicitly targets workflow/prompt behavior.

## Instructions
- Identify the root cause before editing.
- Make the smallest correct fix; do not mask symptoms or add unrelated cleanup.
- Do not add, update, or run tests; QA/finalize own verification. Note suggested bug-path verification for QA.
- Do **not** commit, push, create PRs, or close the task. The pipeline handles that.
- If blocked, write `BLOCKED.md` explaining the blocker and still write `DEVELOPER_REPORT.md` with what you tried.

## Required Artifact
Before finishing, write `{{reportDir}}/DEVELOPER_REPORT.md`. Create the directory first:
```bash
mkdir -p "{{reportDir}}"
```

Use this structure:

```markdown
# Developer Report: {{taskTitle}}

## Root Cause
- What was broken.

## Fix
- What changed and why.

## Files Changed
- path/to/file.ts — what changed.

## QA Handoff
- Suggested focused verification, test files, or risk areas for QA.

## Known Limitations
- Anything not fully addressed, or "None".
```
