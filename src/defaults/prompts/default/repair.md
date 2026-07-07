/ensemble:repair {{taskTitle}} {{taskDescription}}

# Foreman Focused Repair Contract

You are running a retry-only repair phase for task **{{taskId}}**: **{{taskTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Mission
Patch only the reported failure from the prior QA/review/finalize/PR report. Do not broaden scope.

## Required Triage
1. Read the Focused Repair Feedback above first.
2. Read the referenced report/artifact when named (for example `QA_REPORT.md`, `CR_CLI_REPORT.md`, `FINALIZE_VALIDATION.md`, `PR_WAIT_REPORT.md`, or `MERGE_REPORT.md`).
3. Inspect only the files and diff needed to confirm the failing assertion.
4. Write a short checklist of exact failing assertions before editing.

## Edit Rules
- Patch only the reported failure.
- Do not re-implement the original task.
- Do not refactor, rename, reformat, or clean unrelated code/docs.
- Do not create temporary debug files.
- Do not commit, push, create PRs, merge, or close the task.
- If the feedback is ambiguous, make the smallest safe fix and document the ambiguity.

## Verification
- Run the narrow command(s) or grep checks that directly prove the reported failure is fixed.
- If a command is unsafe or unavailable, explain why and provide the exact check QA should run.

## Required Artifact
Before finishing, write `{{reportDir}}/FIX_REPORT.md`. Create the directory first:
```bash
mkdir -p "{{reportDir}}"
```

Use this structure:

```markdown
# Fix Report: {{taskTitle}}

## Failed Assertions
- Exact QA/review/finalize failure(s) addressed.

## Changes Made
- path/to/file — minimal change made.

## Verification
- Command/check run and result.

## Scope Guard
- Confirmation that no unrelated task scope was expanded.

## Known Limitations
- Anything not fully addressed, or "None".
```
