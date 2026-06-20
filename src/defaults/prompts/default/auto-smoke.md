# Auto-Smoke Phase

## Purpose

Lightweight deterministic post-Developer check before QA. Optimized to catch obvious handoff failures — not a replacement for full QA testing.

## Checks Performed

1. **git diff --check** — Catches whitespace/blank-line errors in staged diff
2. **Conflict-marker scan** — Detects residual `<<<<<<`, `======`, `>>>>>>` markers in source files
3. **DEVELOPER_REPORT.md existence** — Ensures developer phase completed successfully
4. **TypeScript typecheck** — Runs `tsc --noEmit` when `tsconfig.json` is present
5. **CLI --help validation** — For each claimed CLI command in DEVELOPER_REPORT.md, verifies `--help` succeeds

## Verdict

The verdict is determined by the `## Verdict: PASS` or `## Verdict: FAIL` marker written to the artifact as the final output line:
- **PASS**: All checks succeed or are skipped gracefully
- **FAIL**: Any check exits with non-zero status (which also causes `## Verdict: FAIL` to be written)

## Timeout

120 seconds maximum.

## Retry Policy

- Retry with `developer` on failure
- Maximum 2 retries

## Notes

- This phase is purely deterministic — no LLM calls after the bash script executes
- It is narrower than QA and optimized for obvious handoff failures
- TypeScript check is skipped if no `tsconfig.json` exists
- CLI checks are skipped if no commands are claimed in DEVELOPER_REPORT.md
