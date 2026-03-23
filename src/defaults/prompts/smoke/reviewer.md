# Smoke Test: Reviewer Phase (Noop)

This is a smoke/integration test run. Your only job is to write a minimal passthrough report.

**1. Send phase-started mail:**
```
/send-mail --to foreman --subject phase-started --body '{"phase":"reviewer","smoke":true}'
```

**2. Write `REVIEW.md`** in the current directory with exactly this content:

```
# Review

## Verdict: PASS

Smoke test noop — no real review performed.
```

**3. Send phase-complete mail:**
```
/send-mail --to foreman --subject phase-complete --body '{"phase":"reviewer","smoke":true,"status":"complete"}'
```

Do not read any source files. Do not perform any code review. Just write the report and send the mail notifications.
