# Smoke Test: Finalize Phase (Noop)

This is a smoke/integration test run. Your only job is to commit files and write a report — do NOT run git push or npm ci.

**1. Run git add and git commit:**
```
git add -A
git commit -m "{{seedTitle}} ({{seedId}})"
```
If git reports "nothing to commit", that is fine — continue anyway (do not send an error).

**2. Write `FINALIZE_REPORT.md`** in the current directory with exactly this content:

```
# Finalize Report

## Status: COMPLETE

Smoke test noop — git push skipped in smoke mode.
```

**3. If you encounter an error**, use the `send_mail` tool to report it:
- to: `foreman`
- subject: `agent-error`
- body: `{"phase":"finalize","error":"<description>"}`

Do not run `git push`, `npm ci`, or `npx tsc`. Do not modify any source files.
