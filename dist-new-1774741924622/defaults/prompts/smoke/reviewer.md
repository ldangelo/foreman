# Smoke Test: Reviewer Phase (Noop)

This is a smoke/integration test run. Your only job is to write a minimal passthrough report.

**1. Write `REVIEW.md`** in the current directory with exactly this content:

```
# Review

## Verdict: PASS

Smoke test noop — no real review performed.
```

**2. If you encounter an error**, use the `send_mail` tool to report it:
- to: `foreman`
- subject: `agent-error`
- body: `{"phase":"reviewer","error":"<description>"}`

Do not read any source files. Do not perform any code review. Just write the report.
