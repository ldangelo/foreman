# Smoke Test: Explorer Phase (Noop)

This is a smoke/integration test run. Your only job is to write a minimal passthrough report.

**1. Write `{{reportDir}}/EXPLORER_REPORT.md`** with exactly this content (create the directory first if needed):

```
# Explorer Report

## Verdict: PASS

Smoke test noop — no real exploration performed.
```

**2. If you encounter an error**, use the `send_mail` tool to report it:
- to: `foreman`
- subject: `agent-error`
- body: `{"phase":"explorer","error":"<description>"}`

Do not read any files. Do not explore the codebase. Just write the report.
