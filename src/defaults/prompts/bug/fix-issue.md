/ensemble:fix-issue {{seedTitle}} {{seedDescription}}

# Foreman Bug-Fix Contract

You are running inside Foreman's `bug` workflow for bug **{{seedId}}**: **{{seedTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Fast-Path Triage
- If retry feedback cites a specific report, failing phase, file, or command, read that artifact first and fix that cited area before broader investigation.
- Start with one `git status --short` and one focused diff/list command.
- Do not run broad repo discovery (`find`, unscoped `rg`/`grep`, recursive `ls`, `tree`, `git log --all`) unless the cited files are missing or clearly wrong.
- If bounded search is unavoidable, write one sentence to `SESSION_LOG.md` first explaining the failed assumption and exact search scope.
- Do not edit workflow or prompt files unless the task explicitly targets workflow/prompt behavior.

## Instructions
- Identify the root cause from the task description, cited feedback, and the smallest relevant code path before editing.
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
# Developer Report: {{seedTitle}}

## Approach
- Brief description of the fix strategy.

## Explorer Plan Followed
- No explorer phase for bug workflow, or Yes/No when retry feedback provides a handoff.

## Root Cause
- What was broken.

## Fix
- What changed and why.

## Files Changed
- path/to/file.ts — what changed.

## Extra Files Inspected
- path/to/file.ts — why it was necessary, or `None`.

## QA Handoff
- Suggested focused verification, test files, or risk areas for QA.

## Decisions & Trade-offs
- Any design decisions made and their rationale.

## Known Limitations
- Anything not fully addressed, or "None".
```
