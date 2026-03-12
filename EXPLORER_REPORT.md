# Explorer Report: Multi-repo orchestration support

## Executive Summary

Foreman currently operates under the assumption of **single-repository execution**. Each command resolves the project path from the current working directory via `getRepoRoot()`, and all orchestration (dispatch, merge, status) operates on that single project. Enabling multi-repo support requires:

1. **Store enhancements** — Track multiple projects and their relationships
2. **CLI modifications** — Accept explicit project selection (via flag/config/env)
3. **Dispatcher improvements** — Handle seeds from multiple repos in a single run
4. **Refinery extensions** — Merge work across multiple repositories
5. **Git management** — Support worktrees in separate repository roots
6. **Seeds coordination** — Execute seeds that reference multiple repos

---

## Relevant Files

### Store & Project Management
- **`src/lib/store.ts`** (lines 1-226)
  - `Project` interface with `id`, `name`, `path` (unique constraint), `status`, timestamps
  - `ForemanStore` class managing projects, runs, costs, events
  - Key methods: `registerProject()`, `getProjectByPath()`, `listProjects()`, `getActiveRuns(projectId?)`
  - **Current limitation**: `getProjectByPath()` assumes single lookup; no multi-project filtering
  - **Issue**: Runs are associated 1:1 with projects via `project_id`, but seeds live in `.seeds/` per repo

### CLI Commands
- **`src/cli/index.ts`** (line 1-36)
  - Main entry point with 11 commands, all invoked without project context

- **`src/cli/commands/init.ts`** (lines 1-67)
  - `foreman init --name` registers one project per directory
  - Uses `execFileSync()` to call `sd init` (Seeds CLI)
  - **Limitation**: Only works in current directory

- **`src/cli/commands/run.ts`** (lines 1-162)
  - Calls `getRepoRoot()` to resolve project path (line 38)
  - Creates `Dispatcher(seeds, store, projectPath)` (line 41)
  - **Limitation**: Single projectPath; no cross-repo dispatching

- **`src/cli/commands/merge.ts`** (lines 1-124)
  - Calls `getRepoRoot()` to resolve project (line 18)
  - Creates `Refinery(store, seeds, projectPath)` (line 21)
  - Looks up project with `getProjectByPath()` (line 23)
  - **Limitation**: Can only merge into single target branch in single repo

- **`src/cli/commands/status.ts`** (lines 1-185)
  - Fetches seeds with `sd list` from current directory (lines 19, 39, 53, 61)
  - Gets project with `getProjectByPath(resolve("."))` (line 78)
  - **Limitation**: Shows only current project status

- **Other commands**: `plan`, `decompose`, `monitor`, `attach`, `reset`, `pr`, `doctor` all follow same pattern of `getRepoRoot()` → single project lookup

### Orchestration Engine
- **`src/orchestrator/dispatcher.ts`** (lines 1-150+)
  - Constructor takes `projectPath: string` (single repo assumption)
  - `dispatch()` method queries seeds from single repo, creates worktrees in single repo
  - `createWorktree(repoPath, seedId)` writes to `.foreman-worktrees/<seedId>` within repo
  - **Critical limitation** (line 73): Worktree path assumes repo structure: `join(repoPath, ".foreman-worktrees", seedId)`

- **`src/orchestrator/refinery.ts`** (lines 1-250+)
  - Constructor takes `projectPath: string` (single repo)
  - `mergeCompleted()` merges branches into single target repo
  - Uses `mergeWorktree(projectPath, branchName, targetBranch)` which assumes single repo
  - **Limitation**: Cannot merge across repos

- **`src/orchestrator/types.ts`**
  - `DispatchedTask` includes `worktreePath` (assumes single repo)
  - No cross-repo references in types

### Git Management
- **`src/lib/git.ts`** (lines 1-150+)
  - `createWorktree(repoPath, seedId, baseBranch?)` — creates worktree in `.foreman-worktrees/`
  - `removeWorktree(repoPath, worktreePath)` — removes worktree
  - `listWorktrees(repoPath)` — lists worktrees in single repo
  - `mergeWorktree(repoPath, branchName, targetBranch)` — merges branch in single repo
  - All functions assume single repository root

### Seeds Client
- **`src/lib/seeds.ts`** (lines 1-100+)
  - `SeedsClient` constructor takes `projectPath: string`
  - All methods (ready, list, update, etc.) call `sd` CLI in project directory
  - No cross-repo seed querying

---

## Architecture & Patterns

### Current Single-Repo Architecture
```
┌─ Project Directory
│  ├─ .seeds/                    (Seeds workspace — all tasks)
│  ├─ .foreman-worktrees/        (Git worktrees per seed)
│  │  ├─ <seedId>/               (Branch: foreman/<seedId>)
│  │  └─ ...
│  └─ src/, tests/, etc.         (Actual code)
└─ SQLite Store (~/.foreman/foreman.db)
   ├─ projects table             (Project metadata)
   ├─ runs table                 (Run records per seed per project)
   └─ costs/events tables        (Metrics per run)
```

### Key Assumptions
1. **One project per CLI invocation** — `getRepoRoot()` determines context
2. **Seeds per repo** — `.seeds/` is repo-local; no cross-repo seed fetching
3. **Worktrees per repo** — `.foreman-worktrees/` lives in repo root
4. **Single merge target** — Refinery merges all branches into one repo/branch
5. **Project lookup by path** — Store treats path as unique identifier

### Naming Conventions
- Branches follow `foreman/<seedId>` pattern (repo-agnostic seed IDs)
- Seeds CLI is invoked via `sd` command (from `~/.bun/bin/sd`)
- Worktree removal uses `git worktree remove --force`

---

## Dependencies

### What Foreman depends on
- **Beads/Seeds CLI** (`sd` command) — Task definition & tracking
- **Git** — Worktree creation/management, merging
- **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`) — Agent spawning
- **Better SQLite3** — Local state store
- **Commander** — CLI parsing
- **Chalk** — Colored output

### What depends on Foreman's multi-repo capability
- **Dispatcher** — Needs to know which repo each seed belongs to
- **Refinery** — Needs to merge to different target repos
- **Status/Monitor** — Need to aggregate stats across multiple repos
- **Dashboard** — Should display multiple projects in parallel

### Current Pain Points
- Store has `project_id` FK on runs, but dispatcher doesn't propagate it explicitly
- SeedsClient has no way to query seeds from multiple repos
- Worktree paths are tightly coupled to single repo structure
- CLI assumes `cwd` determines project context

---

## Existing Tests

Tests exist for components that need to support multi-repo:
- **`src/lib/__tests__/store.test.ts`** — Project/run CRUD operations
- **`src/lib/__tests__/git.test.ts`** — Worktree creation/removal
- **`src/lib/__tests__/seeds.test.ts`** — Seeds CLI interactions
- **`src/orchestrator/__tests__/dispatcher.test.ts`** — Dispatch workflow
- **`src/cli/__tests__/commands.test.ts`** — CLI command execution
- **`src/orchestrator/__tests__/worker-spawn.test.ts`** — Agent spawning

**Test coverage**: Tests currently mock single-project scenarios; multi-repo tests will need to validate:
- Cross-repo seed queries
- Multi-repo merge ordering
- Worktree isolation across repos
- Cost aggregation across projects

---

## Recommended Approach

### Phase 1: CLI & Project Resolution (Priority: HIGH)
1. **Add `--project` flag** to all CLI commands (or env var `FOREMAN_PROJECT`)
   - `foreman run --project frontend --max-agents 3`
   - Fall back to `getRepoRoot()` if not specified (backward compatible)

2. **Extend `getRepoRoot()` behavior**
   - Allow explicit project path override
   - Validate project is registered in store

3. **Update command handlers** to accept optional `projectPath` parameter
   - `run.ts`, `merge.ts`, `status.ts`, `decompose.ts`, etc.

**Files to modify**: `src/cli/index.ts`, `src/cli/commands/*.ts`

### Phase 2: Multi-Repo Orchestration (Priority: HIGH)
1. **Enhance Dispatcher**
   - Add method `dispatchMultiRepo(projectIds: string[], opts)`
   - Gather seeds from all specified projects
   - Create worktrees in respective repos
   - **Constraint**: Different repos may have conflicting seed IDs → include repo prefix in run tracking

2. **Enhance Refinery**
   - Add method `mergeMultiRepo(projectMergeTargets: {[projectId]: branch})`
   - Iterate through projects, merge in dependency order
   - Handle cross-project dependencies in merge ordering

3. **Update Dispatcher.spawnAgent()** to pass project-specific context
   - Include `projectPath` in WorkerConfig
   - Agents need to know which repo their worktree belongs to

**Files to modify**: `src/orchestrator/dispatcher.ts`, `src/orchestrator/refinery.ts`, `src/orchestrator/agent-worker.ts`

### Phase 3: Seeds Multi-Repo Support (Priority: MEDIUM)
1. **Extend SeedsClient**
   - New method `readyAcrossRepos(projectPaths: string[])`
   - New method `getGraphAcrossRepos(projectPaths: string[])`
   - Combine results while handling duplicate seed IDs

2. **Worktree Path Encoding**
   - Include repo identifier in worktree path or metadata
   - Example: `.foreman-worktrees/<projectId>/<seedId>` OR store `(projectId, seedId)` tuple in runs table

**Files to modify**: `src/lib/seeds.ts`, `src/lib/store.ts` (add `project_seed_id` index)

### Phase 4: Git Management (Priority: MEDIUM)
1. **Enhance Git helpers**
   - `createWorktree()` already takes `repoPath` — no change needed
   - `mergeWorktree()` already takes `repoPath` — no change needed
   - **Actually**: Git layer is already repo-agnostic! Just need dispatcher/refinery to call with correct repo.

**Files to modify**: None (git.ts is already multi-repo compatible)

### Phase 5: Status & Observability (Priority: LOW)
1. **Extend status/monitor commands**
   - `foreman status --all-projects` to see all projects
   - `foreman status --projects frontend,backend` for subset
   - Dashboard should default to all projects

2. **Aggregate metrics across repos**
   - Refinery logs events per project — already supports filtering

**Files to modify**: `src/cli/commands/status.ts`, `src/cli/commands/monitor.ts`, `src/orchestrator/types.ts` (add MultiProject types)

---

## Potential Pitfalls & Edge Cases

### 1. Seed ID Collisions
- **Problem**: Two repos may have seeds with same ID (e.g., both have `db-01`)
- **Solution**: Store `(project_id, seed_id)` as composite key in runs; worktree path should encode both

### 2. Conflicting Dependencies Across Repos
- **Problem**: Repo A seed depends on Repo B seed; merge order matters
- **Solution**: Extend `orderByDependencies()` to handle cross-project deps via full seed graph

### 3. Worktree Cleanup on Merge Failure
- **Problem**: If multi-repo merge fails halfway, some worktrees cleaned up, others not
- **Solution**: Refinery should transaction-like behavior — track cleanup separately, defer until all merges attempted

### 4. Git Worktree Location
- **Problem**: `.foreman-worktrees/` lives in repo root; if coordinating from parent dir, unclear which repo owns worktree
- **Solution**: Worktree metadata in runs table (already includes `worktree_path`) should be absolute path; tests should validate

### 5. Seeds CLI Multi-Repo Querying
- **Problem**: `sd ready` only works in repo directory; no cross-repo querying
- **Solution**: Dispatcher must call `SeedsClient.ready()` separately for each project path, merge results

### 6. Test Suite Coverage
- **Problem**: Existing tests mock single-project workflows; new tests needed for multi-repo
- **Solution**: Create fixtures with 2+ test repos; test merge ordering, cleanup, cost aggregation

---

## Implementation Notes for Developer

### Type Safety
- Consider new types in `src/orchestrator/types.ts`:
  ```typescript
  export interface MultiRepoDispatchOpts {
    projectPaths: string[];  // or projectIds + store lookup
    maxAgentsPerProject?: number;
    maxAgentsTotal?: number;
  }

  export interface MultiRepoMergeOpts {
    targetBranches: Record<string, string>;  // projectId → branch
    runTests: boolean;
    testCommands: Record<string, string>;    // projectId → test command
  }
  ```

### Backward Compatibility
- All changes should be **backward compatible** — single-repo CLI commands must continue to work
- Flag defaults: `--project` unspecified = current working directory (existing behavior)

### Store Schema Changes (if needed)
- Consider adding migration to ensure `project_seed_id` uniqueness (if using composite key)
- Existing runs table already has `project_id` + `seed_id`; likely sufficient

### Testing Strategy
- **Unit tests**: Multi-project dispatcher, refinery, SeedsClient
- **Integration tests**: Two mock repos with dependent seeds; verify dispatch, merge order
- **E2E tests**: Real repos (or temp git repos); full pipeline with multi-project

---

## Summary for Developer

The foundation for multi-repo support is **already in place**:
- ✅ Store tracks multiple projects
- ✅ Runs associate with projects
- ✅ Git layer is repo-agnostic
- ✅ CLI has room for project selection flags

**Main work**:
1. Wire up project selection in CLI (Phase 1)
2. Enhance dispatcher/refinery for multi-repo orchestration (Phase 2)
3. Coordinate SeedsClient across multiple repos (Phase 3)
4. Update status/observability commands (Phase 5)

**Risk**: Seed ID collisions and cross-repo dependency ordering — require care in Phase 2-3.

**Estimated scope**: ~20-30 modified files, new multi-project types/methods, comprehensive test additions.
