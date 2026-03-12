# Code Review: Add pre-commit bug scanning to finalize phase

## Verdict: PASS

## Summary
The implementation is clean, focused, and consistent with existing codebase patterns. A `npx tsc --noEmit` type-check step is correctly inserted into `finalize()` before the `git add -A` / `git commit` sequence, with non-blocking error handling that records failures to both the log file and the finalize report. The lead prompt is updated accordingly and both prompt-content tests are extended to assert the new step. No security, logic, or correctness issues found.

## Issues

- **[NOTE]** `src/orchestrator/agent-worker.ts:441–458` — The type-check failure is non-blocking: a failed scan still allows the commit to proceed. This is consistent with how every other finalize step (push, close) behaves, and QA confirmed it was intentional. However, callers may later want a mode where a type-check failure aborts the commit, since "pre-commit bug scanning" implies preventing bad code from landing. No action required now, but worth tracking.

- **[NOTE]** `src/orchestrator/agent-worker.ts:442` — `buildOpts` is a new object differing from `opts` only in its `timeout` (60 s vs 30 s). Minor: could simply have been `{ ...opts, timeout: 60_000 }` to make the relationship explicit, but the current form is not wrong.

- **[NOTE]** `src/orchestrator/agent-worker.ts:444` — `npx tsc` works correctly when TypeScript is a project devDependency (it is), but relies on `npx` being in the worker's PATH. All other finalize calls use fully-resolved binary paths (`git` via PATH, `sd` via `$HOME/.bun/bin/sd`). Low risk in practice, but worth noting for consistency.

- **[NOTE]** `QA_REPORT.md:53–61` — QA notes that the developer also landed bonus changes in `refinery.ts` and `merge.ts` (topological sort, `--seed`/`--list` flags) that are out of scope for this task. These commits are bundled into the same worktree. If this task's PR is shipped independently these extras will come along. Not a bug in the reviewed feature, but the Lead should be aware.

## Positive Notes
- Correct placement: bug scan executes strictly before `git add -A`, fulfilling the "pre-commit" requirement.
- Safe subprocess invocation: `execFileSync` with an args array — no shell interpolation risk.
- Excellent error extraction: separates `err.stderr` (Buffer) from the Node.js wrapper message, so the report shows clean TypeScript compiler output rather than noise.
- Appropriate 60-second timeout — TypeScript cold-start on a large project can exceed the default 30-second `opts` timeout.
- Truncation lengths (500 chars for report, 200 chars for log) match project conventions in surrounding code.
- Both affected tests updated with accurate assertions and descriptive names.
- TypeScript itself reports 0 errors (`tsc --noEmit` clean), confirming no type regressions.
