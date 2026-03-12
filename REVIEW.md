# Code Review: Health monitoring: doctor command with auto-fix

## Verdict: PASS

## Summary
The implementation cleanly refactors the monolithic `doctor.ts` CLI command into a proper `Doctor` class following the existing `Monitor` class pattern. The separation of concerns is well-executed: the CLI command is now a thin wrapper (~100 lines) delegating all logic to `src/orchestrator/doctor.ts`. New features include a `--dry-run` flag, a `run state consistency` check, and typed `DoctorReport`/`CheckResult` types promoted into `orchestrator/types.ts`. The 18 unit tests are well-structured and cover the main behaviors including fix, dry-run, and no-project edge cases. TypeScript compiles cleanly. No security vulnerabilities or logic bugs were found.

## Issues

- **[NOTE]** `src/orchestrator/doctor.ts:461` — `checkBlockedSeeds` uses the synchronous `execFileSync` instead of the `execFileAsync` already imported for other checks in the same file. This blocks the Node.js event loop while `sd blocked --json` runs. Since `checkDataIntegrity` calls `checkBlockedSeeds` inside a `Promise.all`, this runs concurrently with the other async checks but still blocks the thread until it completes. Low impact in practice, but inconsistent with the rest of the file.

- **[NOTE]** `src/orchestrator/doctor.ts:144,264,322,415` — When both `--fix` and `--dry-run` are passed simultaneously (a user error), `dryRun` silently wins because each check tests `if (dryRun) ... else if (fix)`. This is the right behavior, but there is no warning to the user that `--fix` is being ignored. The CLI entry point at `src/cli/commands/doctor.ts:73` passes both flags through without validation.

- **[NOTE]** `src/orchestrator/__tests__/doctor.test.ts:37-43` — The `checkGitBinary` test asserts `expect(["pass", "fail"]).toContain(result.status)`, which always passes regardless of the actual behavior. A more useful assertion would pin to `"pass"` on a dev/CI machine where git is guaranteed to exist, or the test could inject a mock `execFileAsync`. As written, the test does not actually verify anything.

- **[NOTE]** `src/orchestrator/doctor.ts:173-174` — The seed ID is extracted using `wt.branch.replace("foreman/", "")` (replaces only the first occurrence), which is correct for the `foreman/<seedId>` branch naming scheme. However, if a branch were named `foreman/foreman/xyz` (e.g., a nested worktree accident), the result would be `foreman/xyz` rather than `xyz`. This is an unlikely edge case but worth being aware of; using `wt.branch.slice("foreman/".length)` would be more defensive.

## Positive Notes
- Clean extraction into a `Doctor` class with injectable `store` dependency mirrors the existing `Monitor` class perfectly, making the code easy to test and extend.
- The `--dry-run` flag is a well-designed addition that was not in the original task description but adds real value.
- Error handling is thorough: each auto-fix operation in `checkOrphanedWorktrees` is individually try-caught so one failure cannot block others.
- `DoctorReport` and `CheckResult` types are cleanly placed in `orchestrator/types.ts` alongside the other report types, keeping the type system cohesive.
- The `runAll` method uses `Promise.all` across all three check categories (system, repository, data integrity), improving perceived performance for users.
- The `skip` status was added to both the type and the CLI renderer, giving future checks a clean way to indicate intentionally skipped items.
- The CLI now emits well-formed JSON on the early-exit "not a git repo" path, which is good for scripting consumers.
