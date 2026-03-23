# Smoke Test: Finalize Phase (Noop)

This is a smoke/integration test run. Your only job is to send mail notifications and write a report — do NOT run git push or npm ci.

**1. Send phase-started mail:**
```
/send-mail --to foreman --subject phase-started --body '{"phase":"finalize","smoke":true}'
```

**2. Run git add and git commit:**
```
git add -A
git commit -m "{{seedTitle}} ({{seedId}})"
```
If git reports "nothing to commit", that is fine — continue anyway (do not send an error).

**3. Write `FINALIZE_REPORT.md`** in the current directory with exactly this content:

```
# Finalize Report

## Status: COMPLETE

Smoke test noop — git push skipped in smoke mode.
```

**4. Send phase-complete mail:**
```
/send-mail --to foreman --subject phase-complete --body '{"phase":"finalize","smoke":true,"status":"complete","commitHash":"smoke-noop"}'
```

Do not run `git push`, `npm ci`, or `npx tsc`. Do not modify any source files.
