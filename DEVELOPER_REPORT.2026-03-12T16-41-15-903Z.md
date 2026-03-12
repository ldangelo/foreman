# Developer Report: Multi-repo orchestration support

## Approach

Extended Foreman with multi-repo orchestration by layering new capabilities onto the existing single-repo architecture without breaking backward compatibility. The existing git layer was already repo-agnostic (all functions take `repoPath`), and the store already tracks multiple projects — so the main work was wiring up multi-project dispatch/merge logic and exposing it via CLI flags.

The implementation follows four layers:
1. **Types** — new `MultiRepo*` interfaces in `types.ts`
2. **Seeds layer** — static helpers on `SeedsClient` to aggregate across repos
3. **Orchestration layer** — `dispatchMultiRepo` on `Dispatcher`, `mergeMultiRepo` on `Refinery`
4. **CLI layer** — `--projects`/`--project`/`--all-projects` flags on existing commands

## Files Changed

- **`src/orchestrator/types.ts`** — Added `MultiRepoDispatchOpts`, `MultiRepoDispatchResult`, `MultiRepoMergeOpts`, `MultiRepoMergeReport` interfaces at the bottom of the file.

- **`src/lib/seeds.ts`** — Added two static methods to `SeedsClient`: `readyAcrossRepos(projectPaths)` and `listAcrossRepos(projectPaths, opts)`. Both iterate over project paths, silently swallow per-repo errors (returning empty arrays for failing repos), and return `{ projectPath, seeds }[]` tuples. Changed the import from type-only to value where needed.

- **`src/orchestrator/dispatcher.ts`** — Changed `SeedsClient` import from `import type` to value import (needed for `new SeedsClient(path)` inside `dispatchMultiRepo`). Added `MultiRepoDispatchOpts`/`MultiRepoDispatchResult` to the types import. Added `dispatchMultiRepo()` method: creates a per-project `Dispatcher` instance for each path, skips unregistered projects, respects `maxAgentsTotal` by stopping once the global limit is reached, and aggregates all results.

- **`src/orchestrator/refinery.ts`** — Changed `SeedsClient` import from `import type` to value import. Added `MultiRepoMergeOpts`/`MultiRepoMergeReport` to types import. Added `mergeMultiRepo()` method: creates a per-project `Refinery` instance for each entry in `targetBranches`, skips unregistered projects, and aggregates `MergeReport` results by project path. Added a `log()` helper (matching dispatcher's pattern).

- **`src/cli/commands/run.ts`** — Added `--projects <paths>` option (comma-separated absolute paths). When present, parses paths, calls `dispatcher.dispatchMultiRepo(...)`, prints per-project results, and returns early — leaving the existing single-repo path fully unchanged.

- **`src/cli/commands/merge.ts`** — Added `--project <path>` option that overrides `getRepoRoot(process.cwd())` for the project path. Backward compatible: if omitted, behavior is identical to before.

- **`src/cli/commands/status.ts`** — Added `--project <path>` and `--all-projects` options. Refactored `renderStatus()` to accept an optional `projectPath` parameter (defaults to `resolve(".")`), wired into all `execFileSync` calls and `store.getProjectByPath()`. `--all-projects` iterates over all registered projects and renders each.

## Tests Added/Modified

- **`src/orchestrator/__tests__/multi-repo.test.ts`** (new, 8 tests)
  - `Dispatcher.dispatchMultiRepo`: unregistered projects return empty results; registered projects aggregate results; `maxAgentsTotal` is respected
  - `Refinery.mergeMultiRepo`: unregistered projects return empty results; per-project target branches are used correctly
  - `SeedsClient.readyAcrossRepos` and `listAcrossRepos`: basic coverage via mocks

- **`src/lib/__tests__/seeds-multi-repo.test.ts`** (new, 4 tests)
  - `readyAcrossRepos`: aggregates seeds from multiple repos; isolates failures (one failing repo doesn't affect others); handles empty input
  - `listAcrossRepos`: verifies opts are passed through to each underlying `list()` call

## Decisions & Trade-offs

- **Per-project Dispatcher/Refinery instances**: `dispatchMultiRepo` and `mergeMultiRepo` create fresh instances per project path rather than sharing one. This is clean (each instance owns its `projectPath`/`seeds`) but does mean the outer `Dispatcher`'s `seeds` constructor arg is unused in multi-repo mode. This is acceptable since the primary `SeedsClient` is a placeholder when multi-repo is active.

- **Fail-open on unregistered projects**: Unregistered projects log a warning and return empty results rather than throwing. This lets multi-repo dispatch proceed across the registered subset without aborting the whole run.

- **Static helpers on `SeedsClient`**: Placing `readyAcrossRepos`/`listAcrossRepos` as static methods keeps the per-repo instance API clean and makes the helpers easy to discover and test without needing a store or dispatcher.

- **`--projects` vs `--project`**: `run` uses `--projects` (plural, comma-separated) for multi-repo, while `merge`/`status` use `--project` (singular path override). This distinction is deliberate: dispatch benefits from batching multiple repos in one call, while merge and status are typically one-project operations that just need a path override.

## Known Limitations

- **Seed ID collisions**: If two repos have seeds with the same ID (e.g., both have `feat-01`), the store's `(project_id, seed_id)` pairing handles them correctly at the data layer, but CLI output may be confusing since seed IDs are displayed without project context. A future improvement would prefix output with the project name/path.

- **Cross-repo dependency ordering in merge**: `mergeMultiRepo` merges each project independently and does not resolve cross-repo dependencies. Seeds in Repo A that depend on seeds in Repo B are not ordered globally — only within-repo ordering (via `orderByDependencies`) is applied.

- **`--all-projects` in status**: Lists all registered projects sequentially, running `sd` CLI commands in each project's directory. If a project directory no longer exists or `sd` is not initialized there, status will show an error for that project. Error handling could be improved.

- **Watch mode not wired for multi-repo run**: `foreman run --projects a,b --watch` exits after dispatch without entering watch mode. Watch mode for multi-repo would need a combined `runIds` list from all projects.
