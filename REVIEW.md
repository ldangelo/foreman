# Code Review: Multi-repo orchestration support

## Verdict: FAIL

## Summary

The implementation delivers a solid foundation for multi-repo orchestration: new `dispatchMultiRepo` / `mergeMultiRepo` methods on `Dispatcher` and `Refinery`, static `SeedsClient.readyAcrossRepos` / `listAcrossRepos` helpers, dependency-ordered merging via Kahn's algorithm, and CLI flags (`--projects`, `--project`, `--all-projects`, `--seed`, `--list`). The code is well-structured, backward-compatible, and TypeScript compiles cleanly. However, several issues warrant attention before shipping, including one that can cause silent data corruption on `--all-projects` status and one that makes the `--projects` multi-repo flag not useful in production.

## Issues

- **[CRITICAL]** `src/cli/commands/status.ts:33` — When `renderStatus()` is called from the `--all-projects` loop, any failure to read seeds for a project calls `process.exit(1)`, killing the whole process mid-loop and aborting all remaining project statuses. The `process.exit(1)` in the `catch` block was already present in single-repo mode (where it is appropriate) but becomes wrong when called iteratively across multiple projects. Each failed project should log an error and `continue` to the next project rather than terminating. A user with one misconfigured project would get no output for any subsequent projects.

- **[WARNING]** `src/cli/commands/run.ts:44-73` — The `--projects` flag creates its own dispatcher from the primary project's `seeds`/`store`/`projectPath` (resolved from `cwd`) but immediately delegates to `dispatchMultiRepo`, which internally creates fresh `SeedsClient` and `Dispatcher` instances per project. The outer dispatcher's `projectPath` is irrelevant and the `seeds` object is never used. More importantly, the `--seed` flag (single-seed filter) is silently ignored when `--projects` is used; using both flags together gives no warning and simply dispatches all ready seeds. This should either be documented or error out.

- **[WARNING]** `src/orchestrator/dispatcher.ts:447` — The `maxTotal` limit check (`if (totalDispatched >= maxTotal)`) fires only when entering a new project's loop iteration. If the first project dispatches exactly `maxTotal` tasks, the second project is still entered and `remaining = 0` is passed as `projectMaxAgents`, causing `dispatch()` to be called with `maxAgents: 0`. That path silently dispatches nothing (the `available = Math.max(0, 0 - activeRuns.length)` calculation keeps the cap at 0), so behavior is correct, but it is an unnecessary round-trip through the store and seeds query. The guard should use `>= maxTotal` consistently; given the current logic is technically safe the main concern is the extra store hit per over-limit project.

- **[WARNING]** `src/orchestrator/refinery.ts:460` — In `mergeMultiRepo`, the error-case `FailedRun` object is constructed with `runId: ""` and `seedId: ""`. This sentinel value will show up in any consumer iterating `report.testFailures` (e.g. the CLI printing `f.seedId` and `f.branchName` for test failures), producing a confusing empty-string output. A dedicated error-level field on `MultiRepoMergeReport` per project (e.g. `errors: Record<string, string>`) would be cleaner, or at minimum the fake `FailedRun` should carry a non-empty identifier such as the `projectPath`.

- **[WARNING]** `src/orchestrator/refinery.ts:119-121` — The fallback `sorted.includes(run)` check in `orderByDependencies` uses reference equality (`Array.prototype.includes` on objects) which is correct here since the same `Run` object instances from the input array are used throughout. However, this is fragile: if the calling code ever passes cloned run objects (e.g. after JSON round-trip), the guard will append all runs a second time. Prefer `sorted.some(r => r.id === run.id)` for robustness.

- **[WARNING]** `src/cli/commands/status.ts:168` — `const projectPath = opts.project ?? undefined;` is a no-op since `opts.project` is already `string | undefined`; `undefined ?? undefined` is `undefined`. This is harmless but suggests a misunderstanding; the line can simply be removed and `opts.project` used directly.

- **[NOTE]** `src/orchestrator/refinery.ts:468-471` — The `log()` function is defined as a module-level function after the class. This works due to function-declaration hoisting in JavaScript, but is unconventional (and `log` here is a named function expression, not a declaration — the hoisting relies on the fact that calls inside class methods only execute at runtime, not at parse time). Moving `log` before the class would be safer and more idiomatic.

- **[NOTE]** `src/cli/commands/run.ts:24` — The `--projects` help text says "Comma-separated list of project paths" but the paths must also be registered via `foreman init`; unregistered paths are silently skipped. Adding "(must be registered)" to the description would help discoverability.

- **[NOTE]** `src/orchestrator/refinery.ts:55` — `getCompletedRuns` is declared as `public` (no modifier = public) and returns the raw `import("../lib/store.js").Run[]` inline type. The inline `import(...)` type annotation style is used several times in this file; it would be cleaner to import `Run` at the top of the file alongside the other store imports.

- **[NOTE]** `src/cli/commands/status.ts:170-182` — `--all-projects` and `--watch` are mutually exclusive in a meaningful way (watch with all-projects would need to loop through projects on each tick), but combining them currently silently ignores `--watch` because `--all-projects` returns early before the watch block. This silent discard should be documented or produce a warning.

## Positive Notes

- The Kahn's algorithm implementation for dependency-ordered merging is correct and well-scoped — it only orders within the current run set and gracefully falls back on graph unavailability.
- All new CLI flags are fully backward compatible with the existing single-repo workflow.
- `dispatchMultiRepo` correctly passes an explicit `projectId` to the inner `dispatch()` call, preventing the inner dispatcher from looking up the wrong project via `resolveProjectId()` using its own (correct) `projectPath`.
- Silent-fail behavior in `readyAcrossRepos` / `listAcrossRepos` is appropriate for batch operations — one broken repo shouldn't abort the entire run.
- TypeScript types for multi-repo operations (`MultiRepoDispatchOpts`, `MultiRepoDispatchResult`, `MultiRepoMergeOpts`, `MultiRepoMergeReport`) are clean and well-documented with inline comments.
- Test coverage for the new paths is reasonable: all 12 new tests pass, covering empty-input, failure isolation, multi-project aggregation, and limit enforcement.
- The `--list` flag for `foreman merge` is a genuinely useful addition that exposes dependency ordering to users before they commit to a merge.
