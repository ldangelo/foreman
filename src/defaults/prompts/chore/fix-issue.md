/ensemble:fix-issue {{seedTitle}} {{seedDescription}}

# Foreman Chore-Fix Contract

You are running inside Foreman's `chore` workflow for chore **{{seedId}}**: **{{seedTitle}}**.

{{commentsSection}}
{{feedbackSection}}

## Fast-Path Triage
- If retry feedback cites a specific report, failing phase, file, or command, read that artifact first and fix that cited area before broader investigation.
- Start with one `git status --short` and one focused diff/list command; avoid repeated broad `ls`, `git log --all`, or directory walks unless they answer a specific question.
- Do not edit workflow or prompt files unless the task explicitly targets workflow/prompt behavior.

## Instructions
- Keep the change mechanical and scoped to the chore.
- Preserve existing behavior unless the task explicitly asks to change it.
- Update directly affected tests when behavior or public interfaces change.
- Run targeted verification for the touched area. The workflow test phase (`npm run test:unit`) runs the broader unit suite later.
- Do **not** commit, push, create PRs, or close the task. The pipeline handles that.
- If blocked, write `BLOCKED.md` explaining the blocker and still write `DEVELOPER_REPORT.md` with what you tried.

## Validation Ledger
After running targeted verification (e.g., `npm test -- path/to/changed.test.ts`), write an entry to the validation ledger so the downstream test phase can skip redundant re-validation:

```bash
mkdir -p "{{reportDir}}"
if [ -f "{{reportDir}}/VALIDATION_LEDGER.md" ]; then
  # Append row to existing ledger
  printf '\n| fix | %s | targeted | <changed file paths> | <PASS|FAIL> | <notes or empty> |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "{{reportDir}}/VALIDATION_LEDGER.md"
else
  # Create new ledger with header
  cat > "{{reportDir}}/VALIDATION_LEDGER.md" << 'LEDGER'
# Validation Ledger

This ledger tracks test validation runs across pipeline phases to prevent redundant test execution.

| Phase | Timestamp | Scope | Files/Modules | Result | Notes |
|-------|-----------|-------|---------------|--------|-------|
| fix | TIMESTAMP | targeted | PATHS | RESULT | NOTES |
LEDGER
  sed "s/TIMESTAMP/$(date -u +%Y-%m-%dT%H:%M:%SZ)/; s|PATHS|<changed file paths>|; s|RESULT|<PASS|FAIL>|; s|NOTES|<notes or empty>|" "{{reportDir}}/VALIDATION_LEDGER.md" > "{{reportDir}}/VALIDATION_LEDGER.md.tmp" && mv "{{reportDir}}/VALIDATION_LEDGER.md.tmp" "{{reportDir}}/VALIDATION_LEDGER.md"
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
