# Developer Report: Agent observability: dashboard command with live TUI

## Approach

This iteration addressed four code-review issues in the existing `dashboard` command implementation — two warnings (bugs), one note (missing test coverage), and one note (confusing comment). No new features were added; all changes are correctness/quality fixes.

## Files Changed

- **src/cli/commands/dashboard.ts**
  - **Bug fix (WARNING):** `pollDashboard` previously used `store.getProjectByPath(resolve("."))` when a `projectId` was given, then filtered by `.id === projectId`. This silently returned an empty dashboard for any cross-directory invocation. Fixed by replacing with `store.getProject(projectId)` (which looks up directly by ID) and filtering out `null`.
  - **Bug fix (WARNING):** In `--no-watch` (single-shot) mode, `store.close()` was only called in the happy path. If `pollDashboard()` or `renderDashboard()` threw, the SQLite handle/WAL lock was leaked. Wrapped the snapshot block in `try/finally` to guarantee `store.close()`.
  - **Cleanup:** Removed the now-unused `import { resolve } from "node:path"` that was only needed for the buggy `getProjectByPath` call.
  - **Comment (NOTE):** Added an explanatory comment on the `store.close()` call inside the watch-mode `finally` block, clarifying that `onSigint` calls `process.exit(0)` before the `finally` can run in the normal SIGINT path, so this is belt-and-suspenders for future exit paths.

- **src/cli/__tests__/dashboard.test.ts**
  - Added `getProject` mock method to `makeMockStore` (built from the `projects` array keyed by ID), enabling proper testing of the fixed code path.
  - Added test **"filters to the specified projectId using store.getProject"** — verifies that when `projectId` is passed, only the matching project is returned, `store.getProject` is called with the correct ID, and `store.listProjects` is not called.
  - Added test **"returns empty projects array when projectId does not exist"** — verifies that a non-existent `projectId` returns an empty projects array gracefully.

## Tests Added/Modified

- **src/cli/__tests__/dashboard.test.ts** — 32 tests total (2 new, 1 mock updated). All pass.

## Decisions & Trade-offs

- Used `[store.getProject(projectId)].filter(...)` rather than an `if/else` block to stay consistent with the original one-liner style.
- The `try/finally` in single-shot mode is idiomatic and avoids any need to duplicate the `store.close()` call in an error branch.

## Known Limitations

- None. All four review findings have been addressed.
