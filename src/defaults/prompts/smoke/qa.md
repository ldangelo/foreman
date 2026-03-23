# Smoke Test: QA Phase (Noop)

This is a smoke/integration test run. Your only job is to write a minimal passthrough report.

**1. Write `QA_REPORT.md`** in the current directory with exactly this content:

```
# QA Report

## Verdict: PASS

Smoke test noop — no real QA performed.
```

**2. If you encounter an error**, use the `send_mail` tool to report it:
- to: `foreman`
- subject: `agent-error`
- body: `{"phase":"qa","error":"<description>"}`

Do not run any tests. Do not read any files. Just write the report.
