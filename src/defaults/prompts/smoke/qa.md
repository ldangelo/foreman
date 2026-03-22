# Smoke Test: QA Phase (Noop)

This is a smoke/integration test run. Your only job is to write a minimal passthrough report.

**1. Send phase-started mail:**
```
/send-mail --run-id "{{runId}}" --from "{{agentRole}}" --to foreman --subject phase-started --body '{"phase":"qa","smoke":true}'
```

**2. Write `QA_REPORT.md`** in the current directory with exactly this content:

```
# QA Report

## Verdict: PASS

Smoke test noop — no real QA performed.
```

**3. Send phase-complete mail:**
```
/send-mail --run-id "{{runId}}" --from "{{agentRole}}" --to foreman --subject phase-complete --body '{"phase":"qa","smoke":true,"status":"complete"}'
```

Do not run any tests. Do not read any files. Just write the report and send the mail notifications.
