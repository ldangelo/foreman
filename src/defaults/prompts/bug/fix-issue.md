/ensemble:fix-issue {{seedTitle}} {{seedDescription}}

# Foreman Bug-Fix Contract

You are running inside Foreman's `bug` workflow for bug **{{seedId}}**: **{{seedTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Fast-Path Triage
- If retry feedback cites a specific report, failing phase, file, or command, read that artifact first and fix that cited area before broader investigation.
- Start with one `git status --short` and one focused diff/list command; avoid repeated broad `ls`, `git log --all`, or directory walks unless they answer a specific question.
- Do not edit workflow or prompt files unless the task explicitly targets workflow/prompt behavior.

## Instructions
- Identify the root cause before editing.
- Make the smallest correct fix; do not mask symptoms or add unrelated cleanup.
- Add or update a focused regression test when practical.
- Run targeted verification for the bug path. The workflow QA phase runs the broader unit suite later.
- Do **not** commit, push, create PRs, or close the task. The pipeline handles that.
- If blocked, write `BLOCKED.md` explaining the blocker and still write `DEVELOPER_REPORT.md` with what you tried.

## Validation Ledger
After running targeted verification (e.g., `npm test -- path/to/bug.test.ts`), write an entry to the validation ledger so downstream phases can skip redundant re-validation:

```bash
mkdir -p "{{reportDir}}"
if [ -f "{{reportDir}}/VALIDATION_LEDGER.md" ]; then
  # Append row to existing ledger
  printf '\n| fix | %s | targeted | <bug test paths> | <PASS|FAIL> | <notes or empty> |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "{{reportDir}}/VALIDATION_LEDGER.md"
else
  # Create new ledger with header
  cat > "{{reportDir}}/VALIDATION_LEDGER.md" << 'LEDGER'
# Validation Ledger

This ledger tracks test validation runs across pipeline phases to prevent redundant test execution.

| Phase | Timestamp | Scope | Files/Modules | Result | Notes |
|-------|-----------|-------|---------------|--------|-------|
| fix | TIMESTAMP | targeted | PATHS | RESULT | NOTES |
LEDGER
  sed "s/TIMESTAMP/$(date -u +%Y-%m-%dT%H:%M:%SZ)/; s|PATHS|<bug test paths>|; s|RESULT|<PASS|FAIL>|; s|NOTES|<notes or empty>|" "{{reportDir}}/VALIDATION_LEDGER.md" > "{{reportDir}}/VALIDATION_LEDGER.md.tmp" && mv "{{reportDir}}/VALIDATION_LEDGER.md.tmp" "{{reportDir}}/VALIDATION_LEDGER.md"
fi
```

**Schema columns:**
- **Phase**: Always `fix` for this phase
- **Timestamp**: ISO 8601 format
- **Scope**: Always `targeted` for fix verification
- **Files/Modules**: Comma-separated list of files/modules tested
- **Result**: `PASS` or `FAIL`
- **Notes**: Any observations or empty

## Required Artifact
Before finishing, write `{{reportDir}}/DEVELOPER_REPORT.md`. Create the directory first:
```bash
mkdir -p "{{reportDir}}"
```

Use this structure:

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
