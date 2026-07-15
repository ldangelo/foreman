/ensemble:fix-issue {{taskTitle}} {{taskDescription}}

# Foreman Bug-Fix Contract

You are running inside Foreman's `bug` workflow for bug **{{taskId}}**: **{{taskTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Fast-Path Triage
- Read `{{reportDir}}/EXPLORER_REPORT.md` first when present; use it as the primary handoff before doing any extra discovery.
- If retry feedback cites a specific report, failing phase, file, or command, read that artifact first and fix that cited area before broader investigation.
- Start with one `git status --short` and one focused diff/list command; avoid repeated broad `ls`, `git log --all`, or directory walks unless they answer a specific question.
- Do not edit workflow or prompt files unless the task explicitly targets workflow/prompt behavior.
- Stay on the active task branch/worktree. Do **not** create, check out, or switch to another branch; branch management, commits, pushes, PRs, and task closure are owned by the pipeline.
- If the target branch already contains the requested behavior or the recorded PR is already merged, do not create a compensating/no-op change. Document the evidence in `{{reportDir}}/DEVELOPER_REPORT.md` and leave the worktree clean so finalize can reconcile state.

## Instructions
- Identify the root cause before editing.
- Make the smallest correct fix; do not mask symptoms or add unrelated cleanup.
- Do not add, update, or run tests; QA/finalize own verification. Note suggested bug-path verification for QA.
- Do **not** commit, push, create PRs, or close the task. The pipeline handles that.
- Do not send `agent-error` for ordinary product findings such as missing behavior, failing tests, no-op diffs, or stale branch state; write the required report and hand off normally. Reserve `agent-error` for infrastructure failures that prevent producing the report.
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
