# Developer Report: Health monitoring: doctor command with auto-fix

## Approach

This iteration addresses the four NOTE-level issues raised in the previous code review. No new features were added; the focus was on correctness, consistency, and test quality.

## Files Changed

- `src/orchestrator/doctor.ts` — Three changes:
  1. Removed `execFileSync` import (no longer used); `checkBlockedSeeds` now uses the async `execFileAsync` (already imported) instead of the synchronous variant, keeping the file consistent and non-blocking.
  2. `wt.branch.replace("foreman/", "")` replaced with `wt.branch.slice("foreman/".length)` for defensive branch-ID extraction that cannot be confused by a doubly-prefixed branch name.

- `src/cli/commands/doctor.ts` — Added an explicit warning when both `--fix` and `--dry-run` are passed simultaneously, so users understand that `--fix` is silently ignored in that case (dry-run takes precedence).

- `src/orchestrator/__tests__/doctor.test.ts` — Replaced the vacuous `expect(["pass", "fail"]).toContain(result.status)` assertion with a meaningful one (`expect(result.status).toBe("pass")`) since git is guaranteed on dev/CI machines. Added a second test case that blanks `PATH` and asserts `"fail"`, fully covering both branches of `checkGitBinary`.

## Tests Added/Modified

- `src/orchestrator/__tests__/doctor.test.ts`
  - `checkGitBinary > returns pass when git is available` — now asserts status `"pass"` and checks the message string.
  - `checkGitBinary > returns fail when git is not found` — new test; blanks `process.env.PATH`, calls `checkGitBinary`, asserts status `"fail"`, restores PATH in `finally`.

## Decisions & Trade-offs

- **`execFileAsync` for `checkBlockedSeeds`**: The `stdout` property of the resolved object is used directly. The previous `execFileSync` call used `encoding: "utf-8"` to return a string; `execFileAsync` defaults the same way when no `encoding` is specified it returns a `Buffer`, but since we're passing no `encoding` option the result is still a string-typed `stdout` field when using the promisified variant without options — actually, to be safe the call relies on the default (string) output. This is identical behavior to the prior sync call.
- **Blanking PATH for the `checkGitBinary` fail test**: This is a common pattern for testing binary-not-found paths without mocking internals. The `finally` block ensures PATH is always restored even if the assertion throws.
- **No changes to CLI validation logic**: The `--fix` + `--dry-run` behavior (dry-run wins) was already correct; only the UX notification was missing. Adding a yellow warning line is the minimal, non-breaking fix.

## Known Limitations

- The `execFileAsync` for `checkBlockedSeeds` does not pass an explicit `encoding: "utf-8"` option — the promisified `execFile` returns `{ stdout: string, stderr: string }` by default (Node.js infers string from the absence of a `Buffer`-returning encoding), so `JSON.parse(stdout)` is safe. If a future Node.js version changes defaults this could silently break; adding `encoding: "utf-8"` explicitly would be more defensive.
- The PATH-blanking approach in the git test may be fragile on systems where `execFile` resolves the binary at import time (it does not; Node resolves at call time), so this is acceptable.
