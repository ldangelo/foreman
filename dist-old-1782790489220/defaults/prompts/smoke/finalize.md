# Smoke Test: Finalize Phase (Noop)

This is a smoke/integration test run. Your only job is to commit files and write a report — do NOT run git push or npm ci.

**0. Verify working directory:**
Run `pwd` and confirm you are in `{{worktreePath}}`. If not, run `cd {{worktreePath}}` first.

**1. Run stage and commit (skip stage command if empty — some backends auto-stage):**
```
{{vcsStageCommand}}
{{vcsRestoreTrackedStateCommand}}
{{vcsCommitCommand}}
```
If git reports "nothing to commit", that is fine — continue anyway (do not send an error).

**2. Write `FINALIZE_VALIDATION.md`** in the current directory with exactly this content:

```
# Finalize Validation

## Test Validation
- Status: PASS
- Output: Smoke test noop — git push skipped in smoke mode.

## Failure Scope
- UNKNOWN

## Verdict: PASS
```

**3. If you encounter an error**, use the `send_mail` tool to report it:
- to: `foreman`
- subject: `agent-error`
- body: `{"phase":"finalize","error":"<description>"}`

Do not run `git push`, `npm ci`, or `npx tsc`. Do not modify any source files.
