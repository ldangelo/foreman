# Developer Report: Add pre-commit bug scanning to finalize phase

## Approach

Inserted a `npx tsc --noEmit` type-check step into the `finalize()` function in `agent-worker.ts`, running **before** `git add -A` / `git commit`. The check is non-blocking (follows the existing pattern for push and seed-close: log, record in report, continue). Results are written to a new `## Build / Type Check` section in `FINALIZE_REPORT.md`.

Updated the lead-prompt finalize documentation to list the new step, and updated the two prompt-content tests to assert `tsc --noEmit` appears in finalize instructions.

## Files Changed

- **src/orchestrator/agent-worker.ts** — Added a pre-commit bug-scan block before the commit step. Uses `execFileSync("npx", ["tsc", "--noEmit"], { ...opts, timeout: 60_000 })` with a 60-second timeout (doubled from the default 30s to accommodate TypeScript compilation). Errors are captured from `err.stderr` (the buffer `execFileSync` attaches when `stdio:"pipe"`) and truncated to 500 chars for the report / 200 chars for the log. Non-fatal: type-check failure never prevents the commit step.
  - `buildOpts` now uses `{ ...opts, timeout: 60_000 }` spread to make the relationship with the base `opts` object explicit (addressed review note).

- **src/orchestrator/lead-prompt.ts** — Updated the `## Finalize` section to list `npx tsc --noEmit` as step 1 (preceding the git operations), renumbering subsequent steps.

## Tests Added/Modified

- **src/orchestrator/__tests__/lead-prompt.test.ts** — Updated test name and added `expect(prompt).toContain("tsc --noEmit")` assertion.

- **src/orchestrator/__tests__/agent-worker-team.test.ts** — Updated test name and added `expect(prompt).toContain("tsc --noEmit")` assertion.

All tests pass (26 total across both files).

## Decisions & Trade-offs

- **`npx tsc --noEmit` vs `npm run build`**: Chose `tsc --noEmit` because it is non-destructive (no dist/ output), faster, and confirmed working in the worktree environment. `npm run build` would write artifacts to disk unnecessarily.

- **Non-blocking on failure**: Consistent with the existing finalize pattern (push and sd-close failures are also non-blocking). Type errors are surfaced in `FINALIZE_REPORT.md` for the developer/reviewer to address in the next iteration, rather than silently preventing the commit.

- **60-second timeout**: TypeScript compilation can take longer than 30s on a cold start; doubling the timeout reduces false-negative timeouts without material cost. The `buildOpts` uses `{ ...opts, timeout: 60_000 }` spread to make it clear it inherits all other options from `opts`.

- **`err.stderr` extraction**: `execFileSync` with `stdio:"pipe"` attaches a `stderr` Buffer to the thrown error. Extracting it directly gives clean compiler output rather than the noisy Node.js error message wrapper.

## Known Limitations

- **`npx` PATH dependency**: `npx tsc` relies on `npx` being in the worker's PATH. All other finalize calls use fully-resolved binary paths (`git` via PATH, `sd` via `$HOME/.bun/bin/sd`). Low risk in practice since `npx` is nearly universally available, but a future improvement could resolve the tsc binary path explicitly (e.g., `join(worktreePath, "node_modules", ".bin", "tsc")`) for strict consistency.
- **Non-blocking failure**: A failed type check still allows the commit to proceed. Callers may later want a mode where a type-check failure aborts the commit — tracked as a future enhancement.
- **Scans even when nothing to commit**: The bug scan runs even when there are no code changes. Skipping the scan when `git diff --name-only` is empty could be added later as an optimization.
