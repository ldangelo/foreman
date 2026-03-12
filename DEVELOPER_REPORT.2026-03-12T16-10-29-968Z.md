# Developer Report: Add pre-commit bug scanning to finalize phase

## Approach

Inserted a `npx tsc --noEmit` type-check step into the `finalize()` function in `agent-worker.ts`, running **before** `git add -A` / `git commit`. The check is non-blocking (follows the existing pattern for push and seed-close: log, record in report, continue). Results are written to a new `## Build / Type Check` section in `FINALIZE_REPORT.md`.

Updated the lead-prompt finalize documentation to list the new step, and updated the two prompt-content tests to assert `tsc --noEmit` appears in finalize instructions.

## Files Changed

- **src/orchestrator/agent-worker.ts** — Added a pre-commit bug-scan block (lines ~441–458). Uses `execFileSync("npx", ["tsc", "--noEmit"], buildOpts)` with a 60-second timeout (doubled from the default 30s to accommodate TypeScript compilation). Errors are captured from `err.stderr` (the buffer `execFileSync` attaches when `stdio:"pipe"`) and truncated to 500 chars for the report / 200 chars for the log. Non-fatal: type-check failure never prevents the commit step.

- **src/orchestrator/lead-prompt.ts** — Updated the `## Finalize` section to list `npx tsc --noEmit` as step 1 (preceding the git operations), renumbering subsequent steps.

## Tests Added/Modified

- **src/orchestrator/__tests__/lead-prompt.test.ts** — Updated test name and added `expect(prompt).toContain("tsc --noEmit")` assertion.

- **src/orchestrator/__tests__/agent-worker-team.test.ts** — Updated test name and added `expect(prompt).toContain("tsc --noEmit")` assertion.

Both test files: 13 tests each, all passing (26 total).

## Decisions & Trade-offs

- **`npx tsc --noEmit` vs `npm run build`**: Chose `tsc --noEmit` because it is non-destructive (no dist/ output), faster, and confirmed working in the worktree environment by a prior QA run. `npm run build` would write artifacts to disk unnecessarily.

- **Non-blocking on failure**: Consistent with the existing finalize pattern (push and sd-close failures are also non-blocking). Type errors are surfaced in `FINALIZE_REPORT.md` for the developer/reviewer to address in the next iteration, rather than silently preventing the commit.

- **60-second timeout**: TypeScript compilation can take longer than 30s on a cold start; doubling the timeout reduces false-negative timeouts without material cost.

- **`err.stderr` extraction**: `execFileSync` with `stdio:"pipe"` attaches a `stderr` Buffer to the thrown error. Extracting it directly gives clean compiler output rather than the noisy Node.js error message wrapper.

## Known Limitations

- If `npx` or `tsc` is not available in the worktree PATH, the step fails and is logged as `Status: FAILED` (gracefully handled). A future improvement could fall back to a full-path resolution similar to how `sd` is located.
- The bug scan runs even when there are no code changes (e.g., "nothing to commit" scenarios). This is a minor inefficiency; skipping the scan when `git diff --name-only --cached` is empty could be added later.
