# Smoke Test: Explorer Phase (Noop)

This is a smoke/integration test run. Your only job is to write a minimal passthrough report.

**1. Send phase-started mail:**
```
/send-mail --to foreman --subject phase-started --body '{"phase":"explorer","smoke":true}'
```

**2. Write `EXPLORER_REPORT.md`** in the current directory with exactly this content:

```
# Explorer Report

## Verdict: PASS

Smoke test noop — no real exploration performed.
```

**3. Send phase-complete mail:**
```
/send-mail --to foreman --subject phase-complete --body '{"phase":"explorer","smoke":true,"status":"complete"}'
```

Do not read any files. Do not explore the codebase. Just write the report and send the mail notifications.
