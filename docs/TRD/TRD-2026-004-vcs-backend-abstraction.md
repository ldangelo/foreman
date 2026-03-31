# TRD-2026-004: VCS Backend Abstraction -- Git and Jujutsu Support

**Document ID:** TRD-2026-004
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-27
**PRD Reference:** PRD-2026-004 v1.1
**Author:** Tech Lead (AI-assisted)

---

## Version History

| Version | Date       | Author    | Changes       |
|---------|------------|-----------|---------------|
| 1.0     | 2026-03-27 | Tech Lead | Initial draft: 38 implementation tasks + 38 paired test tasks (76 total). 5 sprints across 5 release phases. Full AC traceability for 23 PRD requirements / 81 acceptance criteria. |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture](#2-system-architecture)
3. [Data Architecture](#3-data-architecture)
4. [Master Task List](#4-master-task-list)
5. [Sprint Planning](#5-sprint-planning)
6. [Quality Requirements](#6-quality-requirements)
7. [Acceptance Criteria Traceability](#7-acceptance-criteria-traceability)
8. [Technical Decisions](#8-technical-decisions)

---

## 1. Executive Summary

This TRD translates PRD-2026-004 into an implementable plan for abstracting Foreman's VCS operations behind a plugin interface, enabling both Git and Jujutsu backends. The migration spans 5 phases over 16 working days, producing 38 implementation tasks and 38 paired verification tasks (76 total).

**Key architectural changes:**
- New `VcsBackend` TypeScript interface in `src/lib/vcs/index.ts` abstracting all 25+ VCS operations
- `GitBackend` class encapsulating all logic currently in `src/lib/git.ts` (644 lines, 15+ functions)
- `JujutsuBackend` class mapping Foreman operations to `jj` CLI commands in colocated mode
- `VcsBackendFactory` with `auto` detection via `.jj` directory presence
- Finalize/reviewer prompt templating with `{{vcsStageCommand}}`, `{{vcsCommitCommand}}`, etc.
- Refinery, conflict-resolver, and agent-worker-finalize migrated to accept `VcsBackend` injection
- Backward-compatible `git.ts` shim re-exporting from `GitBackend` during migration

**Current architecture touchpoints (from codebase analysis):**

| Component | File | Lines | Impact |
|-----------|------|-------|--------|
| Git operations library | `src/lib/git.ts` | 644 | Extract all functions into `GitBackend` class methods |
| Refinery merge/rebase | `src/orchestrator/refinery.ts` | ~580 | Replace private `git()` helper with `VcsBackend` injection |
| Finalize phase | `src/orchestrator/agent-worker-finalize.ts` | 355 | Replace `execFileSync("git", ...)` with `VcsBackend` calls |
| Conflict resolver | `src/orchestrator/conflict-resolver.ts` | ~500 | Replace private `git()`/`gitTry()` with `VcsBackend` injection |
| Finalize prompt (default) | `src/defaults/prompts/default/finalize.md` | 183 | Template VCS commands via `{{vcs*}}` variables |
| Finalize prompt (smoke) | `src/defaults/prompts/smoke/finalize.md` | ~100 | Same templating as default |
| Workflow loader | `src/lib/workflow-loader.ts` | 585 | Add `vcs` key parsing to `WorkflowConfig` |
| Dispatcher | `src/orchestrator/dispatcher.ts` | ~830 | Create `VcsBackend` at startup, propagate to workers |
| Templates | `src/orchestrator/templates.ts` | ~200 | Pass VCS backend name for TASK.md context |

---

## 2. System Architecture

### 2.1 Component Diagram

```
Foreman CLI (commander)
  |
  |-- Dispatcher
  |     |
  |     |-- VcsBackendFactory.create(config, projectPath)
  |     |     |
  |     |     +-- config.backend === 'git'     -> new GitBackend(projectPath)
  |     |     +-- config.backend === 'jujutsu'  -> new JujutsuBackend(projectPath)
  |     |     +-- config.backend === 'auto'     -> detect .jj -> Git or Jujutsu
  |     |
  |     |-- Agent Workers (spawned processes)
  |     |     |-- env: FOREMAN_VCS_BACKEND = 'git' | 'jujutsu'
  |     |     |-- Finalize phase uses VcsBackend for commit/push/rebase
  |     |     |-- Finalize prompt rendered with backend-specific commands
  |     |
  |     |-- Refinery (merge queue processor)
  |           |-- VcsBackend.merge() for branch merging
  |           |-- VcsBackend.rebase() for stacked branch management
  |           |-- ConflictResolver receives VcsBackend for conflict detection
  |
  |-- foreman doctor
        |-- Validates jj binary + version when backend=jujutsu
        |-- Validates colocated mode (.jj/repo/store/git)
```

### 2.2 VcsBackend Interface Class Diagram

```
<<interface>>
VcsBackend
  +name: 'git' | 'jujutsu'
  +getRepoRoot(path): Promise<string>
  +getMainRepoRoot(path): Promise<string>
  +detectDefaultBranch(repoPath): Promise<string>
  +getCurrentBranch(repoPath): Promise<string>
  +checkoutBranch(repoPath, branchName): Promise<void>
  +branchExists(repoPath, branchName): Promise<boolean>
  +branchExistsOnRemote(repoPath, branchName): Promise<boolean>
  +deleteBranch(repoPath, branchName, opts?): Promise<DeleteBranchResult>
  +createWorkspace(repoPath, seedId, baseBranch?, setupSteps?, setupCache?): Promise<WorkspaceResult>
  +removeWorkspace(repoPath, workspacePath): Promise<void>
  +listWorkspaces(repoPath): Promise<Workspace[]>
  +stageAll(workspacePath): Promise<void>
  +commit(workspacePath, message): Promise<string>
  +getHeadId(workspacePath): Promise<string>
  +push(workspacePath, branchName, opts?): Promise<void>
  +pull(workspacePath, branchName): Promise<void>
  +fetch(workspacePath): Promise<void>
  +rebase(workspacePath, onto): Promise<RebaseResult>
  +abortRebase(workspacePath): Promise<void>
  +merge(repoPath, branchName, targetBranch?): Promise<MergeResult>
  +getConflictingFiles(workspacePath): Promise<string[]>
  +diff(repoPath, from, to): Promise<string>
  +getModifiedFiles(workspacePath, base): Promise<string[]>
  +cleanWorkingTree(workspacePath): Promise<void>
  +status(workspacePath): Promise<string>
  +getFinalizeCommands(vars): FinalizeCommands
        |
        +----------------------------+
        |                            |
   GitBackend                  JujutsuBackend
   (git-backend.ts)           (jujutsu-backend.ts)
   - projectPath: string       - projectPath: string
   - git(args, cwd)            - jj(args, cwd)
   - Wraps existing git.ts     - Wraps jj CLI
   - git-town integration      - Colocated mode (git-backed)
   - git worktree add/remove   - jj workspace add/forget
   - git add -A / commit       - jj describe / jj new
   - git push -u origin        - jj git push --bookmark
   - git merge --no-ff         - jj new <target> <source>
   - git rebase                - jj rebase -d
   - git rebase --abort        - jj op undo
```

### 2.3 Module Structure

```
src/lib/vcs/
  index.ts              -- VcsBackend interface, VcsBackendFactory, re-exports
  types.ts              -- Workspace, WorkspaceResult, MergeResult, RebaseResult,
                           DeleteBranchResult, DeleteBranchOptions, PushOptions,
                           FinalizeTemplateVars, FinalizeCommands
  git-backend.ts        -- GitBackend implements VcsBackend
  jujutsu-backend.ts    -- JujutsuBackend implements VcsBackend
  __tests__/
    git-backend.test.ts
    jujutsu-backend.test.ts
    factory.test.ts
    types.test.ts

src/lib/git.ts          -- Deprecation shim: re-exports from GitBackend (backward compat)
```

### 2.4 Integration Flow: Dispatcher to VcsBackend

```
1. Dispatcher.start()
   |-- loadWorkflowConfig(name, projectRoot)  // reads vcs key
   |-- loadProjectConfig(projectRoot)          // reads .foreman/config.yaml vcs
   |-- resolveVcsConfig(workflow, projectConfig)
   |     |-- workflow.vcs ?? projectConfig.vcs ?? 'auto'
   |-- VcsBackendFactory.create({ backend: resolved }, projectPath)
   |     |-- returns VcsBackend instance
   |
2. Dispatcher.spawnWorkerProcess(seed)
   |-- env.FOREMAN_VCS_BACKEND = vcsBackend.name  // 'git' or 'jujutsu'
   |-- vcsBackend.createWorkspace(repoPath, seedId, baseBranch, setupSteps, setupCache)
   |     |-- returns { workspacePath, branchName }
   |
3. Agent Worker (child process)
   |-- reads FOREMAN_VCS_BACKEND env
   |-- VcsBackendFactory.create({ backend: env.FOREMAN_VCS_BACKEND }, projectPath)
   |-- Renders finalize prompt with vcsBackend.getFinalizeCommands(vars)
   |-- finalize(config, logFile, vcsBackend)
   |     |-- vcsBackend.stageAll()
   |     |-- vcsBackend.commit()
   |     |-- vcsBackend.push()
   |
4. Refinery.processQueue()
   |-- new Refinery(store, seeds, projectPath, vcsBackend)
   |-- vcsBackend.merge(repoPath, branchName, targetBranch)
   |-- On conflict: ConflictResolver(projectPath, config, vcsBackend)
   |     |-- vcsBackend.getConflictingFiles()
   |     |-- vcsBackend.abortRebase()
```

### 2.5 Configuration Resolution Order

```
Priority (highest to lowest):
  1. Workflow YAML vcs key     (.foreman/workflows/default.yaml -> vcs: git)
  2. Project config vcs key    (.foreman/config.yaml -> vcs.backend: jujutsu)
  3. Auto-detection            (.jj exists -> jujutsu; else -> git)

Note: Explicit config always overrides auto-detection.
      Workflow-level overrides project-level.
```

### 2.6 Finalize Prompt Templating

```
Current (hardcoded git):
  "git add -A"
  "git commit -m '{{seedTitle}} ({{seedId}})'"
  "git push -u origin foreman/{{seedId}}"

After (backend-agnostic):
  "{{vcsStageCommand}}"          -> GitBackend: "git add -A"
                                  -> JujutsuBackend: "" (no-op)
  "{{vcsCommitCommand}}"         -> GitBackend: "git commit -m '...'"
                                  -> JujutsuBackend: "jj describe -m '...' && jj new"
  "{{vcsPushCommand}}"           -> GitBackend: "git push -u origin foreman/..."
                                  -> JujutsuBackend: "jj git push --bookmark foreman/... --allow-new"
  "{{vcsRebaseCommand}}"         -> GitBackend: "git fetch origin && git rebase origin/..."
                                  -> JujutsuBackend: "jj git fetch && jj rebase -d ...@origin"
  "{{vcsBranchVerifyCommand}}"   -> GitBackend: "git rev-parse --abbrev-ref HEAD"
                                  -> JujutsuBackend: "jj bookmark list --name foreman/..."
  "{{vcsCleanCommand}}"          -> GitBackend: "git checkout -- . && git clean -fd"
                                  -> JujutsuBackend: "jj restore"
```

---

## 3. Data Architecture

### 3.1 Shared Types (`src/lib/vcs/types.ts`)

```typescript
/** Replaces Worktree from git.ts. Backend-agnostic workspace representation. */
export interface Workspace {
  path: string;
  branch: string;      // git branch name or jj bookmark name
  head: string;        // git commit hash or jj change ID
  bare: boolean;       // always false for jj workspaces
}

/** Result of createWorkspace(). */
export interface WorkspaceResult {
  workspacePath: string;
  branchName: string;   // 'foreman/<seedId>' for both backends
}

/** Result of a merge operation. */
export interface MergeResult {
  success: boolean;
  conflicts?: string[];
}

/** Result of a rebase operation. */
export interface RebaseResult {
  success: boolean;
  hasConflicts: boolean;
  conflictingFiles?: string[];
}

/** Options for delete branch/bookmark. */
export interface DeleteBranchOptions {
  force?: boolean;
  targetBranch?: string;
}

/** Result of delete branch/bookmark. */
export interface DeleteBranchResult {
  deleted: boolean;
  wasFullyMerged: boolean;
}

/** Options for push. */
export interface PushOptions {
  force?: boolean;
  allowNew?: boolean;   // jj-specific: --allow-new flag
}

/** Template variables for finalize command generation. */
export interface FinalizeTemplateVars {
  seedId: string;
  seedTitle: string;
  baseBranch: string;
  worktreePath: string;
}

/** Backend-specific finalize commands for prompt rendering. */
export interface FinalizeCommands {
  stageCommand: string;
  commitCommand: string;
  pushCommand: string;
  rebaseCommand: string;
  branchVerifyCommand: string;
  cleanCommand: string;
}

/** VCS configuration from YAML. */
export interface VcsConfig {
  backend: 'git' | 'jujutsu' | 'auto';
  git?: {
    useTown?: boolean;
  };
  jujutsu?: {
    minVersion?: string;
  };
}
```

### 3.2 WorkflowConfig Extension

The existing `WorkflowConfig` in `src/lib/workflow-loader.ts` gains a `vcs` field:

```typescript
export interface WorkflowConfig {
  name: string;
  vcs?: 'git' | 'jujutsu' | 'auto';  // NEW
  setup?: WorkflowSetupStep[];
  setupCache?: WorkflowSetupCache;
  phases: WorkflowPhaseConfig[];
}
```

### 3.3 Project Config Schema (`.foreman/config.yaml`)

```yaml
# .foreman/config.yaml
vcs:
  backend: auto          # 'git' | 'jujutsu' | 'auto'
  git:
    useTown: true        # use git-town for branch management (default: true)
  jujutsu:
    minVersion: "0.25.0" # minimum jj version to validate in doctor
```

---

## 4. Master Task List

### Legend

- `[satisfies REQ-NNN]` -- links to PRD requirement
- `Validates PRD ACs: AC-NNN-M` -- specific acceptance criteria covered
- `[verifies TRD-NNN]` -- test task verifying an implementation task
- `[depends: TRD-NNN]` -- task dependency
- Checkbox: ( ) not started, (>) in progress, (x) completed

### Phase A: Interface and Types (v0.1-alpha)

---

#### TRD-001: Define VcsBackend Interface
`[satisfies REQ-001]`
**File:** `src/lib/vcs/index.ts`
**Estimate:** 3h
**Depends:** None

Define the `VcsBackend` TypeScript interface with all 25+ methods covering repository introspection, branch/bookmark operations, workspace isolation, commit operations, sync operations, merge operations, diff/conflict detection, working tree state, and finalize command generation.

**Validates PRD ACs:** AC-001-1, AC-001-2, AC-001-3

**Implementation ACs:**
- ( ) AC-I-001-1: Given the VcsBackend interface is defined in `src/lib/vcs/index.ts`, when a TypeScript module imports it, then `npx tsc --noEmit` compiles without errors and all methods have explicit return types.
- ( ) AC-I-001-2: Given a class implements `VcsBackend`, when any interface method is missing, then `npx tsc --noEmit` emits an error.
- ( ) AC-I-001-3: Given the interface, when a new VCS backend is needed, then a developer can implement the interface without modifying any existing Foreman orchestration code (no imports from `git.ts` required).

---

#### TRD-001-TEST: Verify VcsBackend Interface Compilation
`[verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]`
**File:** `src/lib/vcs/__tests__/interface.test.ts`
**Estimate:** 1h

- ( ) AC-T-001-1: Given a mock class implementing `VcsBackend`, when compiled, then TypeScript accepts it with zero errors.
- ( ) AC-T-001-2: Given a mock class missing one method, when compiled, then TypeScript emits an error naming the missing method.
- ( ) AC-T-001-3: Given the interface is exported, when imported from `src/lib/vcs/index.ts`, then the import resolves correctly.

---

#### TRD-002: Define Shared VCS Types
`[satisfies REQ-003]`
**File:** `src/lib/vcs/types.ts`
**Estimate:** 2h
**Depends:** None

Define all shared types: `Workspace`, `WorkspaceResult`, `MergeResult`, `RebaseResult`, `DeleteBranchResult`, `DeleteBranchOptions`, `PushOptions`, `FinalizeTemplateVars`, `FinalizeCommands`, `VcsConfig`.

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-003-3

**Implementation ACs:**
- ( ) AC-I-002-1: Given `Workspace` type is defined, when it replaces `Worktree` from `git.ts`, then existing consumer code compiles with only import path changes.
- ( ) AC-I-002-2: Given `FinalizeCommands` type is defined, when it contains `stageCommand`, `commitCommand`, `pushCommand`, `rebaseCommand`, `branchVerifyCommand`, `cleanCommand` fields, then finalize prompts can be rendered backend-agnostically.
- ( ) AC-I-002-3: Given both `GitBackend` and `JujutsuBackend` use the shared types, when compiled together, then no type errors occur.

---

#### TRD-002-TEST: Verify Shared Types
`[verifies TRD-002] [satisfies REQ-003] [depends: TRD-002]`
**File:** `src/lib/vcs/__tests__/types.test.ts`
**Estimate:** 1h

- ( ) AC-T-002-1: Given `Workspace` type, when constructing a valid object, then TypeScript accepts it.
- ( ) AC-T-002-2: Given `FinalizeCommands` type, when all 6 command fields are present, then TypeScript accepts it.
- ( ) AC-T-002-3: Given `MergeResult` type, when `success: false` and `conflicts` array is set, then TypeScript accepts it.

---

#### TRD-003: Implement VcsBackendFactory
`[satisfies REQ-002, REQ-016]`
**File:** `src/lib/vcs/index.ts`
**Estimate:** 3h
**Depends:** TRD-001, TRD-002

Implement `VcsBackendFactory.create()` with support for `'git'`, `'jujutsu'`, and `'auto'` modes. Auto-detection checks for `.jj` directory existence.

**Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3, AC-002-4, AC-002-5, AC-016-1, AC-016-2, AC-016-3, AC-016-4

**Implementation ACs:**
- ( ) AC-I-003-1: Given `config.backend` is `'git'`, when `VcsBackendFactory.create()` is called, then a `GitBackend` instance is returned with `name === 'git'`.
- ( ) AC-I-003-2: Given `config.backend` is `'jujutsu'`, when `VcsBackendFactory.create()` is called, then a `JujutsuBackend` instance is returned with `name === 'jujutsu'`.
- ( ) AC-I-003-3: Given `config.backend` is `'auto'` and `.jj/` exists at `projectPath`, when `create()` is called, then `JujutsuBackend` is returned.
- ( ) AC-I-003-4: Given `config.backend` is `'auto'` and no `.jj/` exists but `.git/` exists, when `create()` is called, then `GitBackend` is returned.
- ( ) AC-I-003-5: Given `config.backend` is `'auto'` and neither `.jj/` nor `.git/` exists, when `create()` is called, then an error is thrown: `"No VCS detected in <path>. Expected .git/ or .jj/ directory."`.
- ( ) AC-I-003-6: Given `config.backend` is `'unknown'`, when `create()` is called, then a descriptive error is thrown listing valid options.

---

#### TRD-003-TEST: Verify VcsBackendFactory
`[verifies TRD-003] [satisfies REQ-002, REQ-016] [depends: TRD-003]`
**File:** `src/lib/vcs/__tests__/factory.test.ts`
**Estimate:** 2h

- ( ) AC-T-003-1: Given a temp directory with `.git/`, when `create({backend:'auto'}, dir)`, then result `name === 'git'`.
- ( ) AC-T-003-2: Given a temp directory with `.jj/` and `.git/`, when `create({backend:'auto'}, dir)`, then result `name === 'jujutsu'` (`.jj` takes precedence).
- ( ) AC-T-003-3: Given a temp directory with neither, when `create({backend:'auto'}, dir)`, then an error is thrown.
- ( ) AC-T-003-4: Given `create({backend:'git'}, dir)`, then `GitBackend` is returned regardless of directory contents.
- ( ) AC-T-003-5: Given `create({backend:'invalid' as any}, dir)`, then descriptive error is thrown.

---

### Phase B: GitBackend Implementation (v0.1-alpha)

---

#### TRD-004: Implement GitBackend -- Repository Introspection
`[satisfies REQ-004, REQ-007]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 3h
**Depends:** TRD-001, TRD-002

Implement `getRepoRoot()`, `getMainRepoRoot()`, `detectDefaultBranch()`, `getCurrentBranch()` by moving logic from `src/lib/git.ts`. Preserve git-town integration in `detectDefaultBranch()`.

**Validates PRD ACs:** AC-004-3, AC-007-1, AC-007-2

**Implementation ACs:**
- ( ) AC-I-004-1: Given a git repository, when `GitBackend.getRepoRoot()` is called, then it returns the same value as the current `getRepoRoot()` in `git.ts`.
- ( ) AC-I-004-2: Given a git-town-configured repository, when `GitBackend.detectDefaultBranch()` is called, then the `git-town.main-branch` config value is returned first (matching current priority order: git-town > origin/HEAD > main > master > current branch).
- ( ) AC-I-004-3: Given a git worktree, when `GitBackend.getMainRepoRoot()` is called, then it resolves through `--git-common-dir` to the main project root.

---

#### TRD-004-TEST: Verify GitBackend Repository Introspection
`[verifies TRD-004] [satisfies REQ-004, REQ-007] [depends: TRD-004]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 2h

- ( ) AC-T-004-1: Given a temp git repo, when `getRepoRoot()` is called, then the repo root path is returned.
- ( ) AC-T-004-2: Given a temp git repo with a `main` branch, when `detectDefaultBranch()` is called, then `'main'` is returned.
- ( ) AC-T-004-3: Given a temp git repo, when `getCurrentBranch()` is called, then the current branch name is returned.

---

#### TRD-005: Implement GitBackend -- Branch Operations
`[satisfies REQ-004, REQ-007]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 3h
**Depends:** TRD-004

Implement `checkoutBranch()`, `branchExists()`, `branchExistsOnRemote()`, `deleteBranch()` by extracting from `git.ts`.

**Validates PRD ACs:** AC-004-5, AC-007-1

**Implementation ACs:**
- ( ) AC-I-005-1: Given a git repository, when `GitBackend.checkoutBranch()` is called with a valid branch, then `git checkout <branch>` is executed.
- ( ) AC-I-005-2: Given `GitBackend.deleteBranch()`, when the branch is fully merged, then `git branch -D` is used (matching current behavior).
- ( ) AC-I-005-3: Given `GitBackend.branchExists()`, when the branch exists, then `true` is returned using `git show-ref --verify`.

---

#### TRD-005-TEST: Verify GitBackend Branch Operations
`[verifies TRD-005] [satisfies REQ-004, REQ-007] [depends: TRD-005]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 2h

- ( ) AC-T-005-1: Given a temp git repo with branch `feature`, when `branchExists(repo, 'feature')`, then `true` is returned.
- ( ) AC-T-005-2: Given a temp git repo, when `branchExists(repo, 'nonexistent')`, then `false` is returned.
- ( ) AC-T-005-3: Given a merged branch, when `deleteBranch()` is called without `force`, then the branch is deleted and `wasFullyMerged` is `true`.

---

#### TRD-006: Implement GitBackend -- Workspace Management
`[satisfies REQ-004, REQ-007]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 4h
**Depends:** TRD-004, TRD-005

Implement `createWorkspace()`, `removeWorkspace()`, `listWorkspaces()` by extracting from `git.ts`'s `createWorktree()`, `removeWorktree()`, `listWorktrees()`. Preserve all retry/reuse semantics for existing worktrees (rebase on reuse, clean unstaged changes, setup step caching).

**Validates PRD ACs:** AC-004-1, AC-004-2, AC-007-1, AC-007-2

**Implementation ACs:**
- ( ) AC-I-006-1: Given a git repository, when `GitBackend.createWorkspace('bd-abc1')` is called, then a git worktree is created in Foreman's workspace root (default: `<repoParent>/.foreman-worktrees/<repoName>/bd-abc1`) on branch `foreman/bd-abc1`.
- ( ) AC-I-006-2: Given an existing worktree from a failed run, when `createWorkspace()` is called for the same seedId, then the worktree is reused and rebased onto the base branch (matching current retry behavior).
- ( ) AC-I-006-3: Given a worktree with untracked files, when `removeWorkspace()` is called, then the worktree is removed (falling back to `fs.rm` if `git worktree remove --force` fails) and `git worktree prune` is run.
- ( ) AC-I-006-4: Given multiple worktrees, when `listWorkspaces()` is called, then all worktrees are returned as `Workspace[]` objects with `path`, `branch`, `head`, `bare` fields.

---

#### TRD-006-TEST: Verify GitBackend Workspace Management
`[verifies TRD-006] [satisfies REQ-004, REQ-007] [depends: TRD-006]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 3h

- ( ) AC-T-006-1: Given a temp git repo, when `createWorkspace(repo, 'test-seed')`, then a worktree exists in Foreman's workspace root for that repo on branch `foreman/test-seed`.
- ( ) AC-T-006-2: Given a worktree already exists, when `createWorkspace()` is called again, then no error is thrown and the workspace is reused.
- ( ) AC-T-006-3: Given a created worktree, when `removeWorkspace()` is called, then the directory no longer exists and `listWorkspaces()` does not include it.

---

#### TRD-007: Implement GitBackend -- Commit and Sync Operations
`[satisfies REQ-004, REQ-005, REQ-007]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 4h
**Depends:** TRD-004

Implement `stageAll()`, `commit()`, `getHeadId()`, `push()`, `pull()`, `fetch()`, `rebase()`, `abortRebase()`.

**Validates PRD ACs:** AC-004-4, AC-004-5, AC-007-1

**Implementation ACs:**
- ( ) AC-I-007-1: Given a git worktree with changes, when `stageAll()` then `commit('msg')` is called, then `git add -A` and `git commit -m 'msg'` are executed and the short commit hash is returned.
- ( ) AC-I-007-2: Given a push with non-fast-forward rejection, when `push()` is called, then the error is propagated with stderr (no automatic rebase in `push()` -- that is caller's responsibility).
- ( ) AC-I-007-3: Given a rebase that fails with conflicts, when `rebase()` returns, then `RebaseResult.hasConflicts` is `true` and `conflictingFiles` lists the affected paths.
- ( ) AC-I-007-4: Given a failed rebase, when `abortRebase()` is called, then `git rebase --abort` is executed.

---

#### TRD-007-TEST: Verify GitBackend Commit and Sync Operations
`[verifies TRD-007] [satisfies REQ-004, REQ-005, REQ-007] [depends: TRD-007]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 3h

- ( ) AC-T-007-1: Given a temp git repo with a modified file, when `stageAll()` + `commit('test')`, then `getHeadId()` returns a valid short hash.
- ( ) AC-T-007-2: Given a rebase onto a branch with no conflicts, when `rebase()` is called, then `success` is `true` and `hasConflicts` is `false`.
- ( ) AC-T-007-3: Given a workspace with nothing to commit, when `commit()` is called, then a "nothing to commit" error is thrown or indicated.

---

#### TRD-008: Implement GitBackend -- Merge Operations
`[satisfies REQ-005, REQ-007]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 3h
**Depends:** TRD-007

Implement `merge()` reproducing the exact behavior of `mergeWorktree()` from `git.ts`: stash local changes, checkout target, `git merge --no-ff`, detect conflicts, restore stash.

**Validates PRD ACs:** AC-005-1, AC-005-2, AC-005-3, AC-007-1

**Implementation ACs:**
- ( ) AC-I-008-1: Given a clean merge, when `GitBackend.merge()` is called, then `MergeResult.success` is `true`.
- ( ) AC-I-008-2: Given a conflicting merge, when `merge()` is called, then `MergeResult.success` is `false` and `conflicts` lists the conflicting file paths.
- ( ) AC-I-008-3: Given a dirty working tree, when `merge()` is called, then changes are stashed before checkout and restored after.

---

#### TRD-008-TEST: Verify GitBackend Merge Operations
`[verifies TRD-008] [satisfies REQ-005, REQ-007] [depends: TRD-008]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 2h

- ( ) AC-T-008-1: Given two branches with no conflicts, when `merge()` is called, then `success === true`.
- ( ) AC-T-008-2: Given two branches with conflicting changes to the same file, when `merge()` is called, then `success === false` and `conflicts` is non-empty.

---

#### TRD-009: Implement GitBackend -- Diff, Conflict, and Status
`[satisfies REQ-004, REQ-007]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 2h
**Depends:** TRD-004

Implement `getConflictingFiles()`, `diff()`, `getModifiedFiles()`, `cleanWorkingTree()`, `status()`.

**Validates PRD ACs:** AC-007-1

**Implementation ACs:**
- ( ) AC-I-009-1: Given a workspace with unresolved merge conflicts, when `getConflictingFiles()` is called, then it returns the list of conflicting files (using `git diff --name-only --diff-filter=U`).
- ( ) AC-I-009-2: Given a workspace with modified files, when `cleanWorkingTree()` is called, then `git checkout -- .` and `git clean -fd` are executed.

---

#### TRD-009-TEST: Verify GitBackend Diff, Conflict, and Status
`[verifies TRD-009] [satisfies REQ-004, REQ-007] [depends: TRD-009]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 1h

- ( ) AC-T-009-1: Given a workspace with a modified file, when `status()` is called, then the output includes the modified filename.
- ( ) AC-T-009-2: Given a workspace with modified files, when `cleanWorkingTree()` then `status()`, then the output indicates a clean working tree.

---

#### TRD-010: Implement GitBackend -- Finalize Commands
`[satisfies REQ-006]`
**File:** `src/lib/vcs/git-backend.ts`
**Estimate:** 2h
**Depends:** TRD-002

Implement `getFinalizeCommands()` returning git-specific commands parameterized by `FinalizeTemplateVars`.

**Validates PRD ACs:** AC-006-1, AC-006-2, AC-006-3, AC-006-4

**Implementation ACs:**
- ( ) AC-I-010-1: Given vars `{seedId:'bd-abc1', seedTitle:'Add login', baseBranch:'main'}`, when `getFinalizeCommands()` is called, then `stageCommand === 'git add -A'`.
- ( ) AC-I-010-2: Given the same vars, then `commitCommand === 'git commit -m "Add login (bd-abc1)"'`.
- ( ) AC-I-010-3: Given the same vars, then `pushCommand === 'git push -u origin foreman/bd-abc1'`.
- ( ) AC-I-010-4: Given the same vars, then `rebaseCommand === 'git fetch origin && git rebase origin/main'`.

---

#### TRD-010-TEST: Verify GitBackend Finalize Commands
`[verifies TRD-010] [satisfies REQ-006] [depends: TRD-010]`
**File:** `src/lib/vcs/__tests__/git-backend.test.ts`
**Estimate:** 1h

- ( ) AC-T-010-1: Given finalize vars, when `getFinalizeCommands()` returns, then all 6 command fields are non-null strings.
- ( ) AC-T-010-2: Given finalize vars with `seedId='test-123'`, then `pushCommand` contains `'foreman/test-123'`.
- ( ) AC-T-010-3: Given finalize vars with `baseBranch='dev'`, then `rebaseCommand` contains `'origin/dev'`.

---

#### TRD-011: Create git.ts Backward Compatibility Shim
`[satisfies REQ-007]`
**File:** `src/lib/git.ts`
**Estimate:** 2h
**Depends:** TRD-004, TRD-005, TRD-006, TRD-007, TRD-008, TRD-009

Refactor `src/lib/git.ts` to become a thin re-export shim that delegates to a singleton `GitBackend` instance. All existing public API signatures preserved. Deprecation warnings on direct imports.

**Validates PRD ACs:** AC-007-1, AC-007-2, AC-007-3

**Implementation ACs:**
- ( ) AC-I-011-1: Given existing code imports `createWorktree` from `../lib/git.js`, when compiled, then it resolves to `GitBackend.createWorkspace()` via the shim.
- ( ) AC-I-011-2: Given the shim is in place, when the existing test suite for `git.ts` runs, then all tests pass with zero behavioral changes.
- ( ) AC-I-011-3: Given the shim exports, when `@deprecated` JSDoc tags are added, then IDEs show deprecation warnings for direct `git.ts` imports.

---

#### TRD-011-TEST: Verify git.ts Backward Compatibility
`[verifies TRD-011] [satisfies REQ-007] [depends: TRD-011]`
**File:** `src/lib/__tests__/git-shim.test.ts`
**Estimate:** 2h

- ( ) AC-T-011-1: Given existing git.ts tests, when run against the shim, then all pass unchanged.
- ( ) AC-T-011-2: Given `import { createWorktree } from '../lib/git.js'`, when called, then it delegates to `GitBackend.createWorkspace()`.
- ( ) AC-T-011-3: Given `import { Worktree } from '../lib/git.js'`, when used as a type, then TypeScript compiles (type alias to `Workspace`).

---

### Phase C: Orchestration Layer Migration (v0.2-alpha)

---

#### TRD-012: Migrate Refinery to VcsBackend
`[satisfies REQ-018]`
**File:** `src/orchestrator/refinery.ts`
**Estimate:** 5h
**Depends:** TRD-008, TRD-009

Refactor `Refinery` to accept a `VcsBackend` instance in its constructor. Replace the private `git()` helper and all direct `execFileAsync("git", ...)` calls with `VcsBackend` method calls. Remove imports from `../lib/git.js` except for backward-compat types.

**Validates PRD ACs:** AC-018-1, AC-018-2, AC-018-3

**Implementation ACs:**
- ( ) AC-I-012-1: Given the `Refinery` constructor, when it receives a `VcsBackend` instance, then no direct `execFileAsync("git", ...)` calls exist in `refinery.ts`.
- ( ) AC-I-012-2: Given a merge operation via refinery, when `VcsBackend.merge()` returns a conflict, then the existing conflict resolution cascade (report file auto-resolve, tiered AI resolution, PR fallback) operates correctly.
- ( ) AC-I-012-3: Given the refinery performs stacked branch rebasing, when `rebaseStackedBranches()` runs, then it uses `VcsBackend.rebase()` and `VcsBackend.branchExists()`.

---

#### TRD-012-TEST: Verify Refinery VcsBackend Migration
`[verifies TRD-012] [satisfies REQ-018] [depends: TRD-012]`
**File:** `src/orchestrator/__tests__/refinery-vcs.test.ts`
**Estimate:** 4h

- ( ) AC-T-012-1: Given a mock `VcsBackend`, when `Refinery.processQueue()` runs a clean merge, then `VcsBackend.merge()` is called and the seed is closed.
- ( ) AC-T-012-2: Given a mock `VcsBackend.merge()` returning conflicts, when refinery processes, then the conflict resolution cascade is triggered.
- ( ) AC-T-012-3: Grep `refinery.ts` for `execFileAsync("git"` -- zero matches.

---

#### TRD-013: Migrate Conflict Resolver to VcsBackend
`[satisfies REQ-021]`
**File:** `src/orchestrator/conflict-resolver.ts`
**Estimate:** 4h
**Depends:** TRD-009, TRD-012

Refactor `ConflictResolver` to accept a `VcsBackend` instance. Replace the private `git()`/`gitTry()` helpers with `VcsBackend` method calls. For `JujutsuBackend`, adapt the conflict detection strategy: jj records conflicts in-tree (no `git rebase --continue` loop needed).

**Validates PRD ACs:** AC-021-1, AC-021-2, AC-021-3

**Implementation ACs:**
- ( ) AC-I-013-1: Given a merge conflict during refinery, when `autoResolveRebaseConflicts()` runs, then it uses `VcsBackend.getConflictingFiles()` instead of parsing `git diff --name-only --diff-filter=U` directly.
- ( ) AC-I-013-2: Given a rebase abort is needed, then `VcsBackend.abortRebase()` is called (maps to `git rebase --abort` for git, `jj op undo` for jj).
- ( ) AC-I-013-3: Given `JujutsuBackend` is active, when the conflict resolver encounters jj's in-tree conflict markers, then it recognizes the format and adapts resolution strategy (no rebase-continue loop; use `jj resolve` integration).

---

#### TRD-013-TEST: Verify Conflict Resolver VcsBackend Migration
`[verifies TRD-013] [satisfies REQ-021] [depends: TRD-013]`
**File:** `src/orchestrator/__tests__/conflict-resolver-vcs.test.ts`
**Estimate:** 3h

- ( ) AC-T-013-1: Given a mock `VcsBackend` with conflicts, when `autoResolveRebaseConflicts()` runs, then `VcsBackend.getConflictingFiles()` is called.
- ( ) AC-T-013-2: Given a mock `VcsBackend`, when abort is triggered, then `VcsBackend.abortRebase()` is called.
- ( ) AC-T-013-3: Grep `conflict-resolver.ts` for `execFileAsync("git"` -- zero matches.

---

#### TRD-014: Migrate Agent Worker Finalize to VcsBackend
`[satisfies REQ-019]`
**File:** `src/orchestrator/agent-worker-finalize.ts`
**Estimate:** 4h
**Depends:** TRD-007, TRD-008

Refactor `finalize()` to accept a `VcsBackend` parameter. Replace all `execFileSync("git", ...)` calls with `VcsBackend` method calls. The function signature becomes `finalize(config: FinalizeConfig, logFile: string, vcs: VcsBackend)`.

**Validates PRD ACs:** AC-019-1, AC-019-2, AC-019-3

**Implementation ACs:**
- ( ) AC-I-014-1: Given `finalize()` receives a `VcsBackend`, when it performs commit, then `VcsBackend.stageAll()` and `VcsBackend.commit()` are called instead of `execFileSync("git", ["add", "-A"])`.
- ( ) AC-I-014-2: Given push fails with non-fast-forward, when recovery runs, then `VcsBackend.pull()` and `VcsBackend.push()` are used instead of `execFileSync("git", ["pull", "--rebase", ...])`.
- ( ) AC-I-014-3: Given the finalize function, when migrated, then no direct `execFileSync("git", ...)` calls remain in the function body.

---

#### TRD-014-TEST: Verify Agent Worker Finalize Migration
`[verifies TRD-014] [satisfies REQ-019] [depends: TRD-014]`
**File:** `src/orchestrator/__tests__/agent-worker-finalize-vcs.test.ts`
**Estimate:** 3h

- ( ) AC-T-014-1: Given a mock `VcsBackend`, when `finalize()` is called, then `VcsBackend.stageAll()` and `VcsBackend.commit()` are called.
- ( ) AC-T-014-2: Given a mock `VcsBackend.push()` that throws non-fast-forward, when finalize recovers, then `VcsBackend.pull()` is called.
- ( ) AC-T-014-3: Grep `agent-worker-finalize.ts` for `execFileSync("git"` -- zero matches.

---

#### TRD-015: Migrate Dispatcher to Create and Propagate VcsBackend
`[satisfies REQ-020]`
**File:** `src/orchestrator/dispatcher.ts`
**Estimate:** 3h
**Depends:** TRD-003, TRD-012, TRD-014

Refactor the dispatcher to create a `VcsBackend` instance at startup using `VcsBackendFactory.create()`. Pass the backend to agent workers via `FOREMAN_VCS_BACKEND` environment variable. Pass the instance to `Refinery` and `finalize()`.

**Validates PRD ACs:** AC-020-1, AC-020-2, AC-020-3

**Implementation ACs:**
- ( ) AC-I-015-1: Given the dispatcher starts, when it reads the workflow config, then a single `VcsBackend` instance is created via `VcsBackendFactory.create()`.
- ( ) AC-I-015-2: Given the VcsBackend is created, when agent workers are spawned, then `FOREMAN_VCS_BACKEND` is set in the child process environment.
- ( ) AC-I-015-3: Given a worker process starts, when it reads `FOREMAN_VCS_BACKEND`, then it creates the matching `VcsBackend` instance without re-running auto-detection.

---

#### TRD-015-TEST: Verify Dispatcher VcsBackend Propagation
`[verifies TRD-015] [satisfies REQ-020] [depends: TRD-015]`
**File:** `src/orchestrator/__tests__/dispatcher-vcs.test.ts`
**Estimate:** 2h

- ( ) AC-T-015-1: Given a mock workflow config with `vcs: 'git'`, when the dispatcher creates a VcsBackend, then the result has `name === 'git'`.
- ( ) AC-T-015-2: Given the dispatcher spawns a worker, when the child env is inspected, then `FOREMAN_VCS_BACKEND` is set.

---

#### TRD-016: Deprecate Direct git Imports Across Codebase
`[satisfies REQ-007, REQ-018]`
**Files:** Multiple consumer files
**Estimate:** 3h
**Depends:** TRD-011, TRD-012, TRD-013, TRD-014, TRD-015

Audit all files importing from `../lib/git.js`. Migrate imports to use either the `VcsBackend` interface or the `git.ts` shim. Verify zero direct `execFileAsync("git", ...)` calls exist outside `git-backend.ts`.

**Validates PRD ACs:** AC-007-3, AC-018-1

**Implementation ACs:**
- ( ) AC-I-016-1: Given a `grep -r 'execFileAsync("git"' src/` scan, when run after migration, then zero matches exist outside `src/lib/vcs/git-backend.ts`.
- ( ) AC-I-016-2: Given a `grep -r 'execFileSync("git"' src/` scan, when run after migration, then zero matches exist outside `src/lib/vcs/git-backend.ts`.
- ( ) AC-I-016-3: Given all consumer migrations are complete, when `npx tsc --noEmit` runs, then zero type errors.

---

#### TRD-016-TEST: Verify No Direct Git Calls Outside Backend
`[verifies TRD-016] [satisfies REQ-007, REQ-018] [depends: TRD-016]`
**File:** `src/lib/vcs/__tests__/no-direct-git.test.ts`
**Estimate:** 1h

- ( ) AC-T-016-1: Given the codebase, when scanning `src/` for `execFileAsync("git"` excluding `git-backend.ts`, then zero matches.
- ( ) AC-T-016-2: Given the codebase, when scanning `src/` for `execFileSync("git"` excluding `git-backend.ts`, then zero matches.

---

### Phase D: JujutsuBackend Implementation (v0.3-alpha)

---

#### TRD-017: Implement JujutsuBackend -- Repository Introspection
`[satisfies REQ-008]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 3h
**Depends:** TRD-001, TRD-002

Implement `getRepoRoot()` (`jj root`), `getMainRepoRoot()` (`jj root` -- workspaces share root), `detectDefaultBranch()` (trunk revset alias or convention), `getCurrentBranch()` (bookmarks on `@`).

**Validates PRD ACs:** AC-008-1, AC-008-2, AC-008-3

**Implementation ACs:**
- ( ) AC-I-017-1: Given a jj-managed repo, when `getRepoRoot()` is called, then `jj root` is executed and the path is returned.
- ( ) AC-I-017-2: Given a jj repo, when `getCurrentBranch()` is called, then the bookmark(s) on `@` are returned. If no bookmark, a synthetic `change-<id>` identifier is returned.
- ( ) AC-I-017-3: Given `jj` is not installed, when any method is called, then the error message is: `"jj (Jujutsu) CLI not found. Install from https://github.com/jj-vcs/jj"`.

---

#### TRD-017-TEST: Verify JujutsuBackend Repository Introspection
`[verifies TRD-017] [satisfies REQ-008] [depends: TRD-017]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 2h

Tests use `describe.skipIf(!jjAvailable)` to skip when jj is not installed.

- ( ) AC-T-017-1: Given a temp jj repo, when `getRepoRoot()` is called, then the repo root path is returned.
- ( ) AC-T-017-2: Given a temp jj repo, when `getCurrentBranch()` is called with no bookmark, then a synthetic change ID identifier is returned.
- ( ) AC-T-017-3: Given jj is not in PATH (mocked), when any method is called, then the correct error message is thrown.

---

#### TRD-018: Implement JujutsuBackend -- Workspace Management
`[satisfies REQ-009]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 5h
**Depends:** TRD-017

Implement `createWorkspace()` (`jj workspace add <path> --name foreman-<seedId>` + `jj bookmark create foreman/<seedId> -r @`), `removeWorkspace()` (`jj workspace forget`), `listWorkspaces()` (`jj workspace list`).

**Validates PRD ACs:** AC-009-1, AC-009-2, AC-009-3, AC-009-4, AC-009-5

**Implementation ACs:**
- ( ) AC-I-018-1: Given a jj repo, when `createWorkspace('bd-abc1')` is called, then `jj workspace add <path> --name foreman-bd-abc1` is executed, placing the workspace in Foreman's workspace root (default: `<repoParent>/.foreman-worktrees/<repoName>/bd-abc1`).
- ( ) AC-I-018-2: Given the workspace is created, then a bookmark `foreman/bd-abc1` is created via `jj bookmark create foreman/bd-abc1 -r @`.
- ( ) AC-I-018-3: Given an existing workspace, when `createWorkspace()` is called again, then `jj workspace update-stale` runs and the working copy is rebased onto base.
- ( ) AC-I-018-4: Given a workspace, when `removeWorkspace()` is called, then `jj workspace forget <name>` is executed and the directory is removed.
- ( ) AC-I-018-5: Given workspaces exist, when `listWorkspaces()` is called, then `jj workspace list` output is parsed into `Workspace[]`.

---

#### TRD-018-TEST: Verify JujutsuBackend Workspace Management
`[verifies TRD-018] [satisfies REQ-009] [depends: TRD-018]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 3h

- ( ) AC-T-018-1: Given a temp jj repo, when `createWorkspace(repo, 'test-seed')`, then a workspace directory exists and a bookmark `foreman/test-seed` is created.
- ( ) AC-T-018-2: Given a workspace, when `removeWorkspace()` is called, then the directory is removed and `listWorkspaces()` no longer includes it.
- ( ) AC-T-018-3: Given a workspace already exists, when `createWorkspace()` is called again, then no error is thrown.

---

#### TRD-019: Implement JujutsuBackend -- Commit Operations
`[satisfies REQ-010]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 3h
**Depends:** TRD-017

Implement `stageAll()` (no-op for jj), `commit()` (`jj describe -m <msg>` + `jj new`), `getHeadId()` (change ID of `@-`).

**Validates PRD ACs:** AC-010-1, AC-010-2, AC-010-3

**Implementation ACs:**
- ( ) AC-I-019-1: Given a jj workspace, when `stageAll()` is called, then it is a no-op that returns without error (jj auto-tracks).
- ( ) AC-I-019-2: Given a jj workspace with modifications, when `commit('msg')` is called, then `jj describe -m 'msg'` sets the description and `jj new` starts a fresh change. The change ID of the described change is returned.
- ( ) AC-I-019-3: Given a jj workspace with no modifications, when `commit('msg')` is called, then `jj describe -m 'msg'` runs on the empty change without error.

---

#### TRD-019-TEST: Verify JujutsuBackend Commit Operations
`[verifies TRD-019] [satisfies REQ-010] [depends: TRD-019]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 2h

- ( ) AC-T-019-1: Given a temp jj workspace with a file change, when `stageAll()` then `commit('test')`, then a change ID is returned.
- ( ) AC-T-019-2: Given `stageAll()` is called, then it does not throw.
- ( ) AC-T-019-3: Given `getHeadId()` is called after `commit()`, then a valid change ID string is returned.

---

#### TRD-020: Implement JujutsuBackend -- Sync Operations
`[satisfies REQ-011]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 4h
**Depends:** TRD-017, TRD-018

Implement `push()` (`jj git push --bookmark <name>`), `pull()` (`jj git fetch` + rebase), `fetch()` (`jj git fetch`), `rebase()` (`jj rebase -d <onto>`), `abortRebase()` (`jj op undo`).

**Validates PRD ACs:** AC-011-1, AC-011-2, AC-011-3, AC-011-4, AC-011-5

**Implementation ACs:**
- ( ) AC-I-020-1: Given a bookmark `foreman/bd-abc1`, when `push(workspace, 'foreman/bd-abc1')` is called, then `jj git push --bookmark foreman/bd-abc1` is executed.
- ( ) AC-I-020-2: Given `push()` is called with `opts.allowNew: true`, then `--allow-new` flag is appended.
- ( ) AC-I-020-3: Given `fetch()` is called, then `jj git fetch` is executed.
- ( ) AC-I-020-4: Given `rebase(workspace, 'main@origin')` is called, then `jj rebase -d main@origin` is executed. If conflicts arise, `RebaseResult.hasConflicts` is `true`.
- ( ) AC-I-020-5: Given a failed operation, when `abortRebase()` is called, then `jj op undo` reverses the last operation.

---

#### TRD-020-TEST: Verify JujutsuBackend Sync Operations
`[verifies TRD-020] [satisfies REQ-011] [depends: TRD-020]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 3h

- ( ) AC-T-020-1: Given a temp jj repo with a remote, when `fetch()` is called, then no error is thrown.
- ( ) AC-T-020-2: Given a workspace, when `rebase()` onto a non-conflicting target, then `success === true`.
- ( ) AC-T-020-3: Given `abortRebase()` is called after a rebase, then `jj op undo` is invoked (verify via jj op log).

---

#### TRD-021: Implement JujutsuBackend -- Merge Operations
`[satisfies REQ-012]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 3h
**Depends:** TRD-017

Implement `merge()` using `jj new <target> <source> -m "Merge <branchName>"`.

**Validates PRD ACs:** AC-012-1, AC-012-2, AC-012-3

**Implementation ACs:**
- ( ) AC-I-021-1: Given a jj repo, when `merge(repoPath, 'foreman/bd-abc1', 'main')` is called, then `jj new main foreman/bd-abc1 -m "Merge foreman/bd-abc1"` creates a merge change.
- ( ) AC-I-021-2: Given a merge with conflicts, then `MergeResult.success === false` and `conflicts` lists affected files (from `jj resolve --list`).
- ( ) AC-I-021-3: Given a clean merge, then `MergeResult.success === true`.

---

#### TRD-021-TEST: Verify JujutsuBackend Merge Operations
`[verifies TRD-021] [satisfies REQ-012] [depends: TRD-021]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 2h

- ( ) AC-T-021-1: Given two non-conflicting bookmarks in a jj repo, when `merge()` is called, then `success === true`.
- ( ) AC-T-021-2: Given two conflicting changes, when `merge()` is called, then `success === false` and `conflicts` is non-empty.

---

#### TRD-022: Implement JujutsuBackend -- Diff, Conflict, and Status
`[satisfies REQ-008]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 2h
**Depends:** TRD-017

Implement `getConflictingFiles()` (`jj resolve --list`), `diff()` (`jj diff --from <from> --to <to>`), `getModifiedFiles()`, `cleanWorkingTree()` (`jj restore`), `status()` (`jj status`).

**Validates PRD ACs:** AC-008-1

**Implementation ACs:**
- ( ) AC-I-022-1: Given a jj workspace with conflicts, when `getConflictingFiles()` is called, then `jj resolve --list` output is parsed.
- ( ) AC-I-022-2: Given a jj workspace, when `cleanWorkingTree()` is called, then `jj restore` resets the working copy.

---

#### TRD-022-TEST: Verify JujutsuBackend Diff, Conflict, and Status
`[verifies TRD-022] [satisfies REQ-008] [depends: TRD-022]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 1h

- ( ) AC-T-022-1: Given a jj workspace with a modified file, when `status()` is called, then the output includes the filename.
- ( ) AC-T-022-2: Given a jj workspace, when `cleanWorkingTree()` then `status()`, then working copy is clean.

---

#### TRD-023: Implement JujutsuBackend -- Finalize Commands
`[satisfies REQ-013]`
**File:** `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 2h
**Depends:** TRD-002

Implement `getFinalizeCommands()` returning jj-specific commands.

**Validates PRD ACs:** AC-013-1, AC-013-2, AC-013-3, AC-013-4, AC-013-5

**Implementation ACs:**
- ( ) AC-I-023-1: Given finalize vars, when `getFinalizeCommands()` is called, then `stageCommand === ''` (jj auto-stages).
- ( ) AC-I-023-2: Given vars `{seedId:'bd-abc1', seedTitle:'Add login'}`, then `commitCommand === 'jj describe -m "Add login (bd-abc1)" && jj new'`.
- ( ) AC-I-023-3: Given the same vars, then `pushCommand === 'jj git push --bookmark foreman/bd-abc1 --allow-new'`.
- ( ) AC-I-023-4: Given `baseBranch:'main'`, then `rebaseCommand === 'jj git fetch && jj rebase -d main@origin'`.
- ( ) AC-I-023-5: Given vars, then `branchVerifyCommand === 'jj bookmark list --name foreman/bd-abc1'`.

---

#### TRD-023-TEST: Verify JujutsuBackend Finalize Commands
`[verifies TRD-023] [satisfies REQ-013] [depends: TRD-023]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend.test.ts`
**Estimate:** 1h

- ( ) AC-T-023-1: Given finalize vars, when `getFinalizeCommands()` returns, then `stageCommand` is empty string.
- ( ) AC-T-023-2: Given vars with `seedId='test-123'`, then `pushCommand` contains `'foreman/test-123'`.
- ( ) AC-T-023-3: Given vars, then `commitCommand` contains `'jj describe'` and `'jj new'`.

---

### Phase E: Configuration and Detection (v0.3-alpha)

---

#### TRD-024: Add VCS Key to Workflow YAML
`[satisfies REQ-014]`
**File:** `src/lib/workflow-loader.ts`
**Estimate:** 2h
**Depends:** TRD-003

Extend `validateWorkflowConfig()` to parse the optional `vcs` key. Add `vcs` field to `WorkflowConfig` interface. Valid values: `'git'`, `'jujutsu'`, `'auto'`. Default: `'auto'`.

**Validates PRD ACs:** AC-014-1, AC-014-2, AC-014-3

**Implementation ACs:**
- ( ) AC-I-024-1: Given a workflow YAML with `vcs: jujutsu`, when loaded, then `WorkflowConfig.vcs === 'jujutsu'`.
- ( ) AC-I-024-2: Given a workflow YAML with no `vcs` key, when loaded, then `WorkflowConfig.vcs` is `undefined` (caller applies default `'auto'`).
- ( ) AC-I-024-3: Given a workflow YAML with `vcs: invalid`, when loaded, then `WorkflowConfigError` is thrown with a descriptive message.

---

#### TRD-024-TEST: Verify Workflow YAML VCS Key
`[verifies TRD-024] [satisfies REQ-014] [depends: TRD-024]`
**File:** `src/lib/__tests__/workflow-loader-vcs.test.ts`
**Estimate:** 1h

- ( ) AC-T-024-1: Given YAML with `vcs: git`, when validated, then `config.vcs === 'git'`.
- ( ) AC-T-024-2: Given YAML without `vcs`, when validated, then `config.vcs` is undefined.
- ( ) AC-T-024-3: Given YAML with `vcs: bad`, when validated, then WorkflowConfigError is thrown.

---

#### TRD-025: Implement Project-Level Config (`.foreman/config.yaml`)
`[satisfies REQ-015]`
**File:** `src/lib/project-config.ts` (new)
**Estimate:** 3h
**Depends:** TRD-003

Create a `loadProjectConfig()` function that reads `.foreman/config.yaml` and returns a typed `ProjectConfig` with `vcs` settings. Implement config resolution: workflow vcs > project vcs > auto.

**Validates PRD ACs:** AC-015-1, AC-015-2, AC-015-3

**Implementation ACs:**
- ( ) AC-I-025-1: Given `.foreman/config.yaml` contains `vcs: {backend: jujutsu}` and workflow YAML has no `vcs`, then `resolveVcsConfig()` returns `'jujutsu'`.
- ( ) AC-I-025-2: Given `.foreman/config.yaml` contains `vcs: {backend: jujutsu}` and workflow YAML has `vcs: git`, then `resolveVcsConfig()` returns `'git'` (workflow overrides project).
- ( ) AC-I-025-3: Given no `.foreman/config.yaml` and no workflow `vcs` key, then `resolveVcsConfig()` returns `'auto'`.

---

#### TRD-025-TEST: Verify Project-Level Config
`[verifies TRD-025] [satisfies REQ-015] [depends: TRD-025]`
**File:** `src/lib/__tests__/project-config.test.ts`
**Estimate:** 2h

- ( ) AC-T-025-1: Given a temp project with `.foreman/config.yaml` containing `vcs: {backend: jujutsu}`, when `loadProjectConfig()`, then `config.vcs.backend === 'jujutsu'`.
- ( ) AC-T-025-2: Given workflow vcs is `'git'` and project vcs is `'jujutsu'`, when `resolveVcsConfig()`, then result is `'git'`.
- ( ) AC-T-025-3: Given no config files, when `resolveVcsConfig()`, then result is `'auto'`.

---

### Phase F: Prompt Templating (v0.4-beta)

---

#### TRD-026: Template Finalize Prompts with VCS Commands
`[satisfies REQ-017]`
**Files:** `src/defaults/prompts/default/finalize.md`, `src/defaults/prompts/smoke/finalize.md`, `src/orchestrator/templates.ts`
**Estimate:** 4h
**Depends:** TRD-010, TRD-023

Replace hardcoded git commands in finalize prompts with template variables: `{{vcsStageCommand}}`, `{{vcsCommitCommand}}`, `{{vcsPushCommand}}`, `{{vcsRebaseCommand}}`, `{{vcsBranchVerifyCommand}}`, `{{vcsCleanCommand}}`. Update prompt rendering in `templates.ts` / `agent-worker.ts` to populate these variables from `VcsBackend.getFinalizeCommands()`.

**Validates PRD ACs:** AC-017-1, AC-017-2, AC-017-3, AC-017-4

**Implementation ACs:**
- ( ) AC-I-026-1: Given a pipeline using `GitBackend`, when the finalize prompt is rendered, then all VCS commands are git commands matching current behavior exactly.
- ( ) AC-I-026-2: Given a pipeline using `JujutsuBackend`, when the finalize prompt is rendered, then all VCS commands are jj commands.
- ( ) AC-I-026-3: Given the finalize prompt template contains `{{vcsStageCommand}}` et al., then the rendering replaces each with the backend-specific command.
- ( ) AC-I-026-4: Given the current default finalize prompt, when rendered with `GitBackend`, then the output is character-identical to the current prompt (no regression).

---

#### TRD-026-TEST: Verify Finalize Prompt Rendering
`[verifies TRD-026] [satisfies REQ-017] [depends: TRD-026]`
**File:** `src/orchestrator/__tests__/finalize-prompt-vcs.test.ts`
**Estimate:** 3h

- ( ) AC-T-026-1: Given git finalize commands, when prompt is rendered, then it contains `git add -A` and `git push -u origin`.
- ( ) AC-T-026-2: Given jj finalize commands, when prompt is rendered, then it contains `jj describe` and `jj git push --bookmark`.
- ( ) AC-T-026-3: Given `GitBackend` finalize rendering, when compared to a snapshot of the current finalize.md output, then they are character-identical.

---

#### TRD-027: Template Reviewer Prompt with VCS Context
`[satisfies REQ-017]`
**Files:** `src/defaults/prompts/default/reviewer.md`, `src/defaults/prompts/smoke/reviewer.md`
**Estimate:** 2h
**Depends:** TRD-026

Per OQ-4 resolution: reviewer prompts also need VCS awareness (they may reference branch/commit concepts). Add minimal VCS context template variables: `{{vcsBackendName}}`, `{{vcsBranchPrefix}}`.

**Validates PRD ACs:** AC-017-2 (reviewer prompts)

**Implementation ACs:**
- ( ) AC-I-027-1: Given `GitBackend`, when reviewer prompt is rendered, then `{{vcsBackendName}}` is `'git'` and `{{vcsBranchPrefix}}` is `'foreman/'`.
- ( ) AC-I-027-2: Given `JujutsuBackend`, when reviewer prompt is rendered, then `{{vcsBackendName}}` is `'jujutsu'` and `{{vcsBranchPrefix}}` is `'foreman/'`.

---

#### TRD-027-TEST: Verify Reviewer Prompt Rendering
`[verifies TRD-027] [satisfies REQ-017] [depends: TRD-027]`
**File:** `src/orchestrator/__tests__/reviewer-prompt-vcs.test.ts`
**Estimate:** 1h

- ( ) AC-T-027-1: Given git backend, when reviewer prompt is rendered, then it contains `'git'` as the VCS name.
- ( ) AC-T-027-2: Given jj backend, when reviewer prompt is rendered, then it contains `'jujutsu'` as the VCS name.

---

### Phase G: Integration, Doctor, and Polish (v0.4-beta, v1.0)

---

#### TRD-028: Implement foreman doctor Jujutsu Validation
`[satisfies REQ-023]`
**File:** `src/cli/commands/doctor.ts`
**Estimate:** 3h
**Depends:** TRD-003, TRD-025

Add doctor checks: (1) validate `jj` binary is in PATH when backend=jujutsu, (2) validate colocated mode (`.jj/repo/store/git` exists), (3) validate minimum jj version if configured. Report as ERROR for explicit jujutsu, WARNING for auto.

**Validates PRD ACs:** AC-023-1, AC-023-2, AC-023-3

**Implementation ACs:**
- ( ) AC-I-028-1: Given `backend=jujutsu`, when `jj` binary is not found, then doctor reports ERROR with installation URL.
- ( ) AC-I-028-2: Given `backend=auto`, when `jj` binary is not found, then doctor reports WARNING (can fall back to git).
- ( ) AC-I-028-3: Given `backend=jujutsu`, when `.jj/repo/store/git` is missing (non-colocated), then doctor reports ERROR indicating colocated mode is required.

---

#### TRD-028-TEST: Verify foreman doctor Jujutsu Validation
`[verifies TRD-028] [satisfies REQ-023] [depends: TRD-028]`
**File:** `src/cli/__tests__/doctor-vcs.test.ts`
**Estimate:** 2h

- ( ) AC-T-028-1: Given jj not in PATH and backend=jujutsu, when doctor runs, then output contains "ERROR" and "https://github.com/jj-vcs/jj".
- ( ) AC-T-028-2: Given jj not in PATH and backend=auto, when doctor runs, then output contains "WARNING" (not ERROR).
- ( ) AC-T-028-3: Given a non-colocated jj repo and backend=jujutsu, when doctor runs, then output contains "colocated".

---

#### TRD-029: Performance Validation -- VcsBackend Overhead
`[satisfies REQ-022]`
**File:** `src/lib/vcs/__tests__/performance.test.ts`
**Estimate:** 2h
**Depends:** TRD-004, TRD-011

Validate that the VcsBackend abstraction layer does not introduce measurable latency. Compare GitBackend operations to direct git.ts calls.

**Validates PRD ACs:** AC-022-1, AC-022-2, AC-022-3, AC-022-4

**Implementation ACs:**
- ( ) AC-I-029-1: Given a pipeline run with `GitBackend`, when timed, then end-to-end pipeline time does not increase by more than 1% vs direct git calls.
- ( ) AC-I-029-2: Given either backend, when a VCS CLI command fails, then the error includes: backend name, command, exit code, stderr.
- ( ) AC-I-029-3: Given `JujutsuBackend`, when `jj` commands are invoked, then the same 10 MB `maxBuffer` and timeout conventions are applied.

---

#### TRD-029-TEST: Verify Performance Targets
`[verifies TRD-029] [satisfies REQ-022] [depends: TRD-029]`
**File:** `src/lib/vcs/__tests__/performance.test.ts`
**Estimate:** 2h

- ( ) AC-T-029-1: Given 100 `getRepoRoot()` calls via GitBackend, when timed, then average overhead per call is < 5ms beyond direct git execution.
- ( ) AC-T-029-2: Given a failing VCS command, when the error is caught, then it contains the backend name.

---

#### TRD-030: GitBackend Integration Test -- Full Pipeline
`[satisfies REQ-007, REQ-022]`
**File:** `src/lib/vcs/__tests__/git-backend-integration.test.ts`
**Estimate:** 4h
**Depends:** TRD-011, TRD-012, TRD-014

End-to-end integration test running a full pipeline cycle (create workspace, commit, push, merge) using `GitBackend` against a real git repository. Validates identical behavior to current implementation.

**Validates PRD ACs:** AC-007-2, AC-022-1

**Implementation ACs:**
- ( ) AC-I-030-1: Given a real git repository, when a full create-commit-push-merge cycle runs through `GitBackend`, then the same git commands are executed in the same order as the current implementation.
- ( ) AC-I-030-2: Given the integration test passes, when compared to a current-implementation run, then all outcomes are identical.

---

#### TRD-030-TEST: Verify GitBackend Full Pipeline Integration
`[verifies TRD-030] [satisfies REQ-007, REQ-022] [depends: TRD-030]`
**File:** `src/lib/vcs/__tests__/git-backend-integration.test.ts` (same file, assertions section)
**Estimate:** 2h

- ( ) AC-T-030-1: Given the full pipeline test, when workspace is created, then `listWorkspaces()` includes it.
- ( ) AC-T-030-2: Given a commit and push, when merge is called, then `MergeResult.success === true`.

---

#### TRD-031: JujutsuBackend Integration Test -- Full Pipeline
`[satisfies REQ-008, REQ-009, REQ-010, REQ-011, REQ-012]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend-integration.test.ts`
**Estimate:** 5h
**Depends:** TRD-018, TRD-019, TRD-020, TRD-021

End-to-end integration test running a full pipeline cycle using `JujutsuBackend` against a real colocated jj repository. Validates workspace creation, bookmark management, commit, push, merge.

**Validates PRD ACs:** AC-009-1 through AC-012-3

**Implementation ACs:**
- ( ) AC-I-031-1: Given a real colocated jj repo, when `createWorkspace('test-seed')` runs, then a workspace directory exists and `foreman/test-seed` bookmark is created.
- ( ) AC-I-031-2: Given a commit via `describe` + `new`, when pushed via `jj git push --bookmark`, then the bookmark exists on the remote.
- ( ) AC-I-031-3: Given a merge via `jj new <target> <source>`, when no conflicts exist, then `MergeResult.success === true`.

---

#### TRD-031-TEST: Verify JujutsuBackend Full Pipeline Integration
`[verifies TRD-031] [satisfies REQ-008, REQ-009, REQ-010, REQ-011, REQ-012] [depends: TRD-031]`
**File:** `src/lib/vcs/__tests__/jujutsu-backend-integration.test.ts` (assertions section)
**Estimate:** 2h

- ( ) AC-T-031-1: Given the jj pipeline test with `describe.skipIf(!jjAvailable)`, when jj is installed, then all assertions pass.
- ( ) AC-T-031-2: Given the jj pipeline test, when jj is not installed, then tests are gracefully skipped.

---

#### TRD-032: AI Conflict Resolver -- Jujutsu Conflict Syntax Adaptation
`[satisfies REQ-021]`
**File:** `src/orchestrator/conflict-resolver.ts`
**Estimate:** 4h
**Depends:** TRD-013

Adapt the tiered AI conflict resolution cascade to understand jj's conflict syntax (which differs from git's `<<<<<<<`/`=======`/`>>>>>>>` markers). Jj uses `<<<<<<<` with `%%%%%%%` (diff-style) or `+++++++`/`-------` markers. The AI resolver prompt must include backend-aware conflict format descriptions.

**Validates PRD ACs:** AC-021-3

**Implementation ACs:**
- ( ) AC-I-032-1: Given a jj conflict file, when the AI resolver processes it, then the prompt describes jj's conflict marker format.
- ( ) AC-I-032-2: Given a git conflict file, when the AI resolver processes it, then the prompt describes standard git markers (no regression).
- ( ) AC-I-032-3: Given 3+ jj conflict scenarios (simple text, code, config files), when AI resolution runs, then at least 2 resolve successfully.

---

#### TRD-032-TEST: Verify AI Conflict Resolver Jujutsu Adaptation
`[verifies TRD-032] [satisfies REQ-021] [depends: TRD-032]`
**File:** `src/orchestrator/__tests__/conflict-resolver-jj.test.ts`
**Estimate:** 3h

- ( ) AC-T-032-1: Given a jj-format conflict marker in a file, when the resolver parses it, then it correctly identifies the conflict regions.
- ( ) AC-T-032-2: Given a git-format conflict marker, when the resolver parses it, then it still works (backward compat).
- ( ) AC-T-032-3: Given the resolver with `JujutsuBackend`, when processing a conflict, then the AI prompt includes jj-specific instructions.

---

#### TRD-033: Setup-Cache Compatibility for jj Workspaces
`[satisfies REQ-022]`
**File:** `src/lib/git.ts` (setup cache functions), `src/lib/vcs/jujutsu-backend.ts`
**Estimate:** 2h
**Depends:** TRD-018

Verify and adapt the setup-cache symlink mechanism (`runSetupWithCache`) to work correctly with jj workspaces. Jj workspaces share the store but have independent working copies, so `node_modules` symlink caching should work identically.

**Validates PRD ACs:** AC-022-4

**Implementation ACs:**
- ( ) AC-I-033-1: Given a jj workspace, when `createWorkspace()` runs with `setupSteps` and `setupCache`, then the cache mechanism correctly symlinks `node_modules` on cache hit.
- ( ) AC-I-033-2: Given a jj workspace cache miss, when setup steps run and complete, then the cache is populated for next workspace creation.

---

#### TRD-033-TEST: Verify Setup-Cache for jj Workspaces
`[verifies TRD-033] [satisfies REQ-022] [depends: TRD-033]`
**File:** `src/lib/vcs/__tests__/jujutsu-setup-cache.test.ts`
**Estimate:** 1h

- ( ) AC-T-033-1: Given a jj workspace with setup-cache config, when `createWorkspace()` runs twice, then the second run is a cache hit (symlink exists).

---

#### TRD-034: Static Analysis Gate -- No Direct VCS Calls
`[satisfies REQ-007, REQ-018, REQ-019]`
**File:** CI config / test suite
**Estimate:** 1h
**Depends:** TRD-016

Add a CI step or test that greps the codebase for direct `execFileAsync("git"` and `execFileSync("git"` calls outside of `src/lib/vcs/git-backend.ts`, and for direct `execFileAsync("jj"` calls outside `src/lib/vcs/jujutsu-backend.ts`. Fail if any matches found.

**Implementation ACs:**
- ( ) AC-I-034-1: Given the CI pipeline, when the static analysis step runs, then it reports zero violations.

---

#### TRD-034-TEST: Verify Static Analysis Gate
`[verifies TRD-034] [satisfies REQ-007, REQ-018, REQ-019] [depends: TRD-034]`
**File:** `src/lib/vcs/__tests__/static-analysis.test.ts`
**Estimate:** 1h

- ( ) AC-T-034-1: Given the codebase after full migration, when the static analysis test runs, then it passes with zero violations.

---

#### TRD-035: Documentation -- VcsBackend Interface and Configuration
`[satisfies REQ-001, REQ-014, REQ-015]`
**Files:** `docs/`, `CLAUDE.md`
**Estimate:** 3h
**Depends:** TRD-026, TRD-025

Document the VcsBackend interface for plugin developers, configuration options (workflow YAML `vcs` key, project-level `.foreman/config.yaml`), auto-detection behavior, and jj-specific considerations.

**Implementation ACs:**
- ( ) AC-I-035-1: Given the documentation, when a developer reads it, then they can implement a custom VcsBackend without reading source code.
- ( ) AC-I-035-2: Given the configuration docs, when a user reads them, then they can configure jj backend via workflow YAML or project config.

---

#### TRD-035-TEST: Verify Documentation Completeness
`[verifies TRD-035] [depends: TRD-035]`
**Estimate:** 1h

- ( ) AC-T-035-1: Given the docs, when checked for all 25+ VcsBackend methods, then each has a description and example.
- ( ) AC-T-035-2: Given the config docs, when reviewed, then both workflow-level and project-level config are documented.

---

#### TRD-036: Manual Validation on Real Repositories
`[satisfies REQ-022]`
**Estimate:** 4h
**Depends:** All above

Manual testing on 3+ real repositories: (1) existing git-only project, (2) colocated jj project, (3) project with `.foreman/config.yaml` overrides. Validates all success metrics from PRD section 16.

**Implementation ACs:**
- ( ) AC-I-036-1: Given an existing git project, when running `foreman run` with no config changes, then behavior is identical to pre-migration.
- ( ) AC-I-036-2: Given a colocated jj project with `vcs: auto`, when running `foreman run`, then jj backend is auto-detected and pipeline completes.
- ( ) AC-I-036-3: Given a project with `vcs: git` override on a jj repo, when running `foreman run`, then git backend is used regardless.

---

#### TRD-036-TEST: Verify Manual Validation Checklist
`[verifies TRD-036] [depends: TRD-036]`
**Estimate:** 1h

- ( ) AC-T-036-1: Git-only repository pipeline passes end-to-end.
- ( ) AC-T-036-2: Colocated jj repository pipeline passes end-to-end.
- ( ) AC-T-036-3: Config override scenario works correctly.

---

## 5. Sprint Planning

### Sprint 1: Foundation (v0.1-alpha) -- 5 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-001: VcsBackend Interface | 3h | -- | ( ) |
| TRD-001-TEST | 1h | TRD-001 | ( ) |
| TRD-002: Shared Types | 2h | -- | ( ) |
| TRD-002-TEST | 1h | TRD-002 | ( ) |
| TRD-003: VcsBackendFactory | 3h | TRD-001, TRD-002 | ( ) |
| TRD-003-TEST | 2h | TRD-003 | ( ) |
| TRD-004: GitBackend Repo Introspection | 3h | TRD-001, TRD-002 | ( ) |
| TRD-004-TEST | 2h | TRD-004 | ( ) |
| TRD-005: GitBackend Branch Ops | 3h | TRD-004 | ( ) |
| TRD-005-TEST | 2h | TRD-005 | ( ) |
| TRD-006: GitBackend Workspace Mgmt | 4h | TRD-004, TRD-005 | ( ) |
| TRD-006-TEST | 3h | TRD-006 | ( ) |
| TRD-007: GitBackend Commit/Sync | 4h | TRD-004 | ( ) |
| TRD-007-TEST | 3h | TRD-007 | ( ) |
| TRD-008: GitBackend Merge | 3h | TRD-007 | ( ) |
| TRD-008-TEST | 2h | TRD-008 | ( ) |
| TRD-009: GitBackend Diff/Conflict/Status | 2h | TRD-004 | ( ) |
| TRD-009-TEST | 1h | TRD-009 | ( ) |
| TRD-010: GitBackend Finalize Commands | 2h | TRD-002 | ( ) |
| TRD-010-TEST | 1h | TRD-010 | ( ) |
| TRD-011: git.ts Backward Compat Shim | 2h | TRD-004..TRD-009 | ( ) |
| TRD-011-TEST | 2h | TRD-011 | ( ) |

**Sprint 1 Total:** 51h (~6.4 days at 8h/day)
**Gate:** All existing tests pass. `npx tsc --noEmit` clean. `GitBackend` feature-complete.

---

### Sprint 2: Orchestration Migration (v0.2-alpha) -- 3 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-012: Migrate Refinery | 5h | TRD-008, TRD-009 | ( ) |
| TRD-012-TEST | 4h | TRD-012 | ( ) |
| TRD-013: Migrate Conflict Resolver | 4h | TRD-009, TRD-012 | ( ) |
| TRD-013-TEST | 3h | TRD-013 | ( ) |
| TRD-014: Migrate Finalize | 4h | TRD-007, TRD-008 | ( ) |
| TRD-014-TEST | 3h | TRD-014 | ( ) |
| TRD-015: Migrate Dispatcher | 3h | TRD-003, TRD-012, TRD-014 | ( ) |
| TRD-015-TEST | 2h | TRD-015 | ( ) |
| TRD-016: Deprecate Direct git Imports | 3h | TRD-011..TRD-015 | ( ) |
| TRD-016-TEST | 1h | TRD-016 | ( ) |

**Sprint 2 Total:** 32h (~4 days at 8h/day)
**Gate:** Zero direct git calls outside `git-backend.ts`. All integration tests green.

---

### Sprint 3: Jujutsu Backend + Config (v0.3-alpha) -- 3 days

Parallelizable with Sprint 2 (TRD-017 through TRD-023 depend only on Phase A).

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-017: JujutsuBackend Repo Introspection | 3h | TRD-001, TRD-002 | ( ) |
| TRD-017-TEST | 2h | TRD-017 | ( ) |
| TRD-018: JujutsuBackend Workspace Mgmt | 5h | TRD-017 | ( ) |
| TRD-018-TEST | 3h | TRD-018 | ( ) |
| TRD-019: JujutsuBackend Commit Ops | 3h | TRD-017 | ( ) |
| TRD-019-TEST | 2h | TRD-019 | ( ) |
| TRD-020: JujutsuBackend Sync Ops | 4h | TRD-017, TRD-018 | ( ) |
| TRD-020-TEST | 3h | TRD-020 | ( ) |
| TRD-021: JujutsuBackend Merge Ops | 3h | TRD-017 | ( ) |
| TRD-021-TEST | 2h | TRD-021 | ( ) |
| TRD-022: JujutsuBackend Diff/Conflict/Status | 2h | TRD-017 | ( ) |
| TRD-022-TEST | 1h | TRD-022 | ( ) |
| TRD-023: JujutsuBackend Finalize Commands | 2h | TRD-002 | ( ) |
| TRD-023-TEST | 1h | TRD-023 | ( ) |
| TRD-024: Workflow YAML VCS Key | 2h | TRD-003 | ( ) |
| TRD-024-TEST | 1h | TRD-024 | ( ) |
| TRD-025: Project-Level Config | 3h | TRD-003 | ( ) |
| TRD-025-TEST | 2h | TRD-025 | ( ) |

**Sprint 3 Total:** 44h (~5.5 days at 8h/day)
**Gate:** jj unit tests pass (with `skipIf` for CI without jj). Auto-detection tests pass.

---

### Sprint 4: Prompt Templating + Conflict Adaptation (v0.4-beta) -- 3 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-026: Template Finalize Prompts | 4h | TRD-010, TRD-023 | ( ) |
| TRD-026-TEST | 3h | TRD-026 | ( ) |
| TRD-027: Template Reviewer Prompt | 2h | TRD-026 | ( ) |
| TRD-027-TEST | 1h | TRD-027 | ( ) |
| TRD-032: AI Conflict Resolver jj Adaptation | 4h | TRD-013 | ( ) |
| TRD-032-TEST | 3h | TRD-032 | ( ) |
| TRD-033: Setup-Cache jj Compat | 2h | TRD-018 | ( ) |
| TRD-033-TEST | 1h | TRD-033 | ( ) |

**Sprint 4 Total:** 20h (~2.5 days at 8h/day)
**Gate:** E2E pipeline on colocated jj repo succeeds. AI conflict resolver tested on 3+ jj scenarios.

---

### Sprint 5: Integration, Doctor, Polish (v1.0) -- 2 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-028: foreman doctor jj Validation | 3h | TRD-003, TRD-025 | ( ) |
| TRD-028-TEST | 2h | TRD-028 | ( ) |
| TRD-029: Performance Validation | 2h | TRD-004, TRD-011 | ( ) |
| TRD-029-TEST | 2h | TRD-029 | ( ) |
| TRD-030: GitBackend Integration Test | 4h | TRD-011, TRD-012 | ( ) |
| TRD-030-TEST | 2h | TRD-030 | ( ) |
| TRD-031: JujutsuBackend Integration Test | 5h | TRD-018..TRD-021 | ( ) |
| TRD-031-TEST | 2h | TRD-031 | ( ) |
| TRD-034: Static Analysis Gate | 1h | TRD-016 | ( ) |
| TRD-034-TEST | 1h | TRD-034 | ( ) |
| TRD-035: Documentation | 3h | TRD-026, TRD-025 | ( ) |
| TRD-035-TEST | 1h | TRD-035 | ( ) |
| TRD-036: Manual Validation | 4h | All | ( ) |
| TRD-036-TEST | 1h | TRD-036 | ( ) |

**Sprint 5 Total:** 33h (~4.1 days at 8h/day)
**Gate:** All success metrics met. Manual testing on 3+ repositories. Production-ready.

---

### Summary

| Sprint | Release | Tasks (impl + test) | Estimated Hours | Calendar Days |
|--------|---------|---------------------|-----------------|---------------|
| 1 | v0.1-alpha | 22 (11 + 11) | 51h | 5 |
| 2 | v0.2-alpha | 10 (5 + 5) | 32h | 3 |
| 3 | v0.3-alpha | 18 (9 + 9) | 44h | 3* |
| 4 | v0.4-beta | 8 (4 + 4) | 20h | 3 |
| 5 | v1.0 | 14 (7 + 7) | 33h | 2 |
| **Total** | | **72 (36 + 36)** | **180h** | **16 days** |

*Sprint 3 is parallelizable with Sprint 2 (different developers/agents can work on jj backend while orchestration migration proceeds).

---

## 6. Quality Requirements

### 6.1 Testing Strategy

| Level | Coverage Target | Tools | Scope |
|-------|----------------|-------|-------|
| Unit | >= 80% | Vitest | Each backend method in isolation against temp repos |
| Integration | >= 70% | Vitest | Full pipeline cycle through VcsBackend (both backends) |
| E2E | >= 50% | Vitest + real CLI | `foreman run` with both backends on real repositories |
| Static Analysis | 100% | grep-based test | Zero direct VCS CLI calls outside backend files |
| Snapshot | Per prompt | Vitest | Finalize prompt rendering matches expected output |

### 6.2 Testing Conventions

- **GitBackend tests:** Use real git repositories in temp directories (`mkdtemp`). No mocks for git CLI.
- **JujutsuBackend tests:** Use `describe.skipIf(!jjAvailable)` to skip when jj is not installed. CI must have jj installed in at least one matrix entry.
- **Factory tests:** Use mocked filesystem (`.jj`/`.git` directory presence) for auto-detection logic.
- **Integration tests:** Use real repositories with commits, branches, and merges.
- **TDD cycle:** RED (write failing test) -> GREEN (minimal implementation) -> REFACTOR.

### 6.3 Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| VcsBackend method overhead | < 5ms per call beyond CLI execution time | Benchmark test (TRD-029) |
| GitBackend pipeline parity | < 1% slowdown vs direct git calls | E2E timing comparison |
| JujutsuBackend pipeline completion | >= 90% success rate on colocated repos | Integration test pass rate |
| Error message quality | Backend name + command + exit code + stderr in all errors | Unit test assertions |

### 6.4 Backward Compatibility Gates

| Gate | Validation | Blocks |
|------|------------|--------|
| All existing git.ts tests pass through shim | CI green | Sprint 1 completion |
| Zero direct git calls outside git-backend.ts | Static analysis test | Sprint 2 completion |
| Finalize prompt rendering identical for git | Snapshot test | Sprint 4 completion |
| Full pipeline smoke test on existing git repo | Manual + CI | v1.0 release |

### 6.5 Security Considerations

- No new secrets or credentials introduced.
- `jj` CLI invoked with same security constraints as `git` (no shell interpolation; `execFileAsync` with argument arrays).
- `FOREMAN_VCS_BACKEND` env var is non-sensitive (contains only `'git'` or `'jujutsu'`).
- Setup-cache symlinks validated for path traversal (existing `computeCacheHash` logic).

---

## 7. Acceptance Criteria Traceability

### 7.1 Traceability Matrix: PRD Requirements to TRD Tasks

| REQ ID | Requirement | Priority | Implementation Tasks | Test Tasks |
|--------|-------------|----------|---------------------|------------|
| REQ-001 | VcsBackend Interface Definition | P0 | TRD-001 | TRD-001-TEST |
| REQ-002 | VcsBackendFactory | P0 | TRD-003 | TRD-003-TEST |
| REQ-003 | Shared VCS Types | P1 | TRD-002 | TRD-002-TEST |
| REQ-004 | GitBackend Class | P0 | TRD-004, TRD-005, TRD-006, TRD-007, TRD-009 | TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST, TRD-009-TEST |
| REQ-005 | GitBackend Merge Operations | P0 | TRD-007, TRD-008 | TRD-007-TEST, TRD-008-TEST |
| REQ-006 | GitBackend Finalize Commands | P1 | TRD-010 | TRD-010-TEST |
| REQ-007 | GitBackend Backward Compatibility | P0 | TRD-011, TRD-016, TRD-034 | TRD-011-TEST, TRD-016-TEST, TRD-034-TEST |
| REQ-008 | JujutsuBackend Class | P1 | TRD-017, TRD-022 | TRD-017-TEST, TRD-022-TEST |
| REQ-009 | Jujutsu Workspace Management | P1 | TRD-018 | TRD-018-TEST |
| REQ-010 | Jujutsu Commit Operations | P1 | TRD-019 | TRD-019-TEST |
| REQ-011 | Jujutsu Sync Operations | P1 | TRD-020 | TRD-020-TEST |
| REQ-012 | Jujutsu Merge Operations | P1 | TRD-021 | TRD-021-TEST |
| REQ-013 | Jujutsu Finalize Commands | P1 | TRD-023 | TRD-023-TEST |
| REQ-014 | Workflow YAML Configuration | P1 | TRD-024 | TRD-024-TEST |
| REQ-015 | Project-Level Configuration | P2 | TRD-025 | TRD-025-TEST |
| REQ-016 | Auto-Detection Logic | P0 | TRD-003 | TRD-003-TEST |
| REQ-017 | Finalize Prompt Backend Awareness | P0 | TRD-026, TRD-027 | TRD-026-TEST, TRD-027-TEST |
| REQ-018 | Refinery VCS Abstraction | P0 | TRD-012, TRD-016 | TRD-012-TEST, TRD-016-TEST |
| REQ-019 | Agent Worker Finalize Abstraction | P0 | TRD-014 | TRD-014-TEST |
| REQ-020 | Dispatcher VCS Backend Propagation | P1 | TRD-015 | TRD-015-TEST |
| REQ-021 | Conflict Resolver Backend Awareness | P1 | TRD-013, TRD-032 | TRD-013-TEST, TRD-032-TEST |
| REQ-022 | Performance and Reliability | P1 | TRD-029, TRD-033 | TRD-029-TEST, TRD-033-TEST |
| REQ-023 | Foreman Doctor jj Validation | P1 | TRD-028 | TRD-028-TEST |

### 7.2 PRD Acceptance Criteria Coverage

| AC ID | PRD AC Description | TRD Task | Test Task |
|-------|-------------------|----------|-----------|
| AC-001-1 | Interface compiles, explicit return types | TRD-001 | TRD-001-TEST |
| AC-001-2 | Missing method causes compile error | TRD-001 | TRD-001-TEST |
| AC-001-3 | New backend without modifying orchestration | TRD-001 | TRD-001-TEST |
| AC-002-1 | Factory returns GitBackend for 'git' | TRD-003 | TRD-003-TEST |
| AC-002-2 | Factory returns JujutsuBackend for 'jujutsu' | TRD-003 | TRD-003-TEST |
| AC-002-3 | Auto-detect .jj -> JujutsuBackend | TRD-003 | TRD-003-TEST |
| AC-002-4 | Auto-detect no .jj -> GitBackend | TRD-003 | TRD-003-TEST |
| AC-002-5 | Unknown backend -> descriptive error | TRD-003 | TRD-003-TEST |
| AC-003-1 | Both backends use shared types | TRD-002 | TRD-002-TEST |
| AC-003-2 | Worktree->Workspace migration compiles | TRD-002 | TRD-002-TEST |
| AC-003-3 | FinalizeCommands has all 6 fields | TRD-002 | TRD-002-TEST |
| AC-004-1 | createWorkspace creates worktree at correct path | TRD-006 | TRD-006-TEST |
| AC-004-2 | Existing worktree reused and rebased | TRD-006 | TRD-006-TEST |
| AC-004-3 | detectDefaultBranch respects git-town | TRD-004 | TRD-004-TEST |
| AC-004-4 | commit returns short hash | TRD-007 | TRD-007-TEST |
| AC-004-5 | push non-fast-forward typed error | TRD-007 | TRD-007-TEST |
| AC-005-1 | Clean merge success | TRD-008 | TRD-008-TEST |
| AC-005-2 | Conflicting merge returns conflicts | TRD-008 | TRD-008-TEST |
| AC-005-3 | Dirty tree stashed/restored | TRD-008 | TRD-008-TEST |
| AC-006-1 | stageCommand = git add -A | TRD-010 | TRD-010-TEST |
| AC-006-2 | commitCommand = git commit -m | TRD-010 | TRD-010-TEST |
| AC-006-3 | pushCommand = git push -u origin | TRD-010 | TRD-010-TEST |
| AC-006-4 | rebaseCommand = git fetch && git rebase | TRD-010 | TRD-010-TEST |
| AC-007-1 | Existing test suite passes through shim | TRD-011 | TRD-011-TEST |
| AC-007-2 | Same git commands in same order | TRD-011, TRD-030 | TRD-011-TEST, TRD-030-TEST |
| AC-007-3 | git.ts re-exports with deprecation | TRD-011 | TRD-011-TEST |
| AC-008-1 | getRepoRoot uses jj root | TRD-017 | TRD-017-TEST |
| AC-008-2 | getCurrentBranch returns bookmarks or synthetic ID | TRD-017 | TRD-017-TEST |
| AC-008-3 | jj not installed -> clear error | TRD-017 | TRD-017-TEST |
| AC-009-1 | jj workspace add with correct name | TRD-018 | TRD-018-TEST |
| AC-009-2 | Bookmark created on workspace | TRD-018 | TRD-018-TEST |
| AC-009-3 | Existing workspace reused | TRD-018 | TRD-018-TEST |
| AC-009-4 | jj workspace forget on remove | TRD-018 | TRD-018-TEST |
| AC-009-5 | jj workspace list parsed | TRD-018 | TRD-018-TEST |
| AC-010-1 | stageAll no-op for jj | TRD-019 | TRD-019-TEST |
| AC-010-2 | commit = jj describe + jj new | TRD-019 | TRD-019-TEST |
| AC-010-3 | commit on empty change | TRD-019 | TRD-019-TEST |
| AC-011-1 | push = jj git push --bookmark | TRD-020 | TRD-020-TEST |
| AC-011-2 | push with --allow-new | TRD-020 | TRD-020-TEST |
| AC-011-3 | fetch = jj git fetch | TRD-020 | TRD-020-TEST |
| AC-011-4 | rebase = jj rebase -d | TRD-020 | TRD-020-TEST |
| AC-011-5 | abortRebase = jj op undo | TRD-020 | TRD-020-TEST |
| AC-012-1 | merge = jj new <target> <source> | TRD-021 | TRD-021-TEST |
| AC-012-2 | merge conflict detected via jj resolve --list | TRD-021 | TRD-021-TEST |
| AC-012-3 | clean merge success | TRD-021 | TRD-021-TEST |
| AC-013-1 | stageCommand = '' (empty) | TRD-023 | TRD-023-TEST |
| AC-013-2 | commitCommand = jj describe + jj new | TRD-023 | TRD-023-TEST |
| AC-013-3 | pushCommand = jj git push --bookmark --allow-new | TRD-023 | TRD-023-TEST |
| AC-013-4 | rebaseCommand = jj git fetch + jj rebase | TRD-023 | TRD-023-TEST |
| AC-013-5 | branchVerifyCommand = jj bookmark list | TRD-023 | TRD-023-TEST |
| AC-014-1 | Workflow YAML vcs: jujutsu -> JujutsuBackend | TRD-024 | TRD-024-TEST |
| AC-014-2 | No vcs key -> auto default | TRD-024 | TRD-024-TEST |
| AC-014-3 | vcs: git on jj repo -> GitBackend | TRD-024 | TRD-024-TEST |
| AC-015-1 | Project config jujutsu + no workflow -> jujutsu | TRD-025 | TRD-025-TEST |
| AC-015-2 | Project jujutsu + workflow git -> git | TRD-025 | TRD-025-TEST |
| AC-015-3 | No config -> auto | TRD-025 | TRD-025-TEST |
| AC-016-1 | .jj/ present -> JujutsuBackend | TRD-003 | TRD-003-TEST |
| AC-016-2 | .git/ only -> GitBackend | TRD-003 | TRD-003-TEST |
| AC-016-3 | Both .jj/ and .git/ -> JujutsuBackend | TRD-003 | TRD-003-TEST |
| AC-016-4 | Neither -> error | TRD-003 | TRD-003-TEST |
| AC-017-1 | GitBackend finalize prompt = git commands | TRD-026 | TRD-026-TEST |
| AC-017-2 | JujutsuBackend finalize prompt = jj commands | TRD-026, TRD-027 | TRD-026-TEST, TRD-027-TEST |
| AC-017-3 | Template variables replaced | TRD-026 | TRD-026-TEST |
| AC-017-4 | Git rendering character-identical to current | TRD-026 | TRD-026-TEST |
| AC-018-1 | No execFileAsync("git") in refinery.ts | TRD-012 | TRD-012-TEST |
| AC-018-2 | Conflict cascade works through VcsBackend | TRD-012 | TRD-012-TEST |
| AC-018-3 | Stacked branch rebase uses VcsBackend | TRD-012 | TRD-012-TEST |
| AC-019-1 | Finalize uses VcsBackend.stageAll/commit | TRD-014 | TRD-014-TEST |
| AC-019-2 | Non-fast-forward recovery uses VcsBackend | TRD-014 | TRD-014-TEST |
| AC-019-3 | No execFileSync("git") in finalize | TRD-014 | TRD-014-TEST |
| AC-020-1 | Dispatcher creates VcsBackend at startup | TRD-015 | TRD-015-TEST |
| AC-020-2 | FOREMAN_VCS_BACKEND env propagated | TRD-015 | TRD-015-TEST |
| AC-020-3 | Worker reconstructs backend from env | TRD-015 | TRD-015-TEST |
| AC-021-1 | Conflict resolver uses VcsBackend.getConflictingFiles | TRD-013 | TRD-013-TEST |
| AC-021-2 | Abort uses VcsBackend.abortRebase | TRD-013 | TRD-013-TEST |
| AC-021-3 | jj conflict syntax adapted | TRD-032 | TRD-032-TEST |
| AC-022-1 | < 1% pipeline overhead | TRD-029, TRD-030 | TRD-029-TEST, TRD-030-TEST |
| AC-022-2 | Error messages include backend+command+exit+stderr | TRD-029 | TRD-029-TEST |
| AC-022-3 | jj uses same maxBuffer/timeout | TRD-029 | TRD-029-TEST |
| AC-022-4 | Setup-cache works for jj workspaces | TRD-033 | TRD-033-TEST |
| AC-023-1 | Doctor ERROR when jj missing + backend=jujutsu | TRD-028 | TRD-028-TEST |
| AC-023-2 | Doctor WARNING when jj missing + backend=auto | TRD-028 | TRD-028-TEST |
| AC-023-3 | Doctor ERROR for non-colocated jj repo | TRD-028 | TRD-028-TEST |

**Coverage: 81/81 PRD acceptance criteria mapped (100%).**

---

## 8. Technical Decisions

### TD-001: Interface vs Abstract Class

**Decision:** Use a TypeScript `interface` (not abstract class) for `VcsBackend`.

**Rationale:** Interfaces provide structural typing, allow multiple implementations without inheritance constraints, and work cleanly with dependency injection. Abstract classes would force a single inheritance chain and are heavier than needed for a simple method contract.

### TD-002: Singleton GitBackend for Backward Compat Shim

**Decision:** The `git.ts` shim creates a lazy singleton `GitBackend` instance for re-exports.

**Rationale:** Existing consumers import standalone functions from `git.ts`. The shim creates a `GitBackend` instance on first use and delegates. This avoids changing all consumer call sites immediately while ensuring behavioral identity.

### TD-003: FOREMAN_VCS_BACKEND Environment Variable

**Decision:** Pass the resolved backend name (`'git'` or `'jujutsu'`) to worker processes via environment variable, not auto-detection.

**Rationale:** Auto-detection in the worker would race with the dispatcher's detection and could produce different results if filesystem state changes. Explicit propagation is deterministic.

### TD-004: FinalizeCommands as Strings, Not Structured Commands

**Decision:** `getFinalizeCommands()` returns shell command strings, not structured `{binary, args}` objects.

**Rationale:** The finalize prompts are rendered as markdown text that agents execute. Agents need human-readable shell commands, not structured data. The commands are rendered into prompt templates as-is.

### TD-005: jj Workspace Path Convention

**Decision:** jj workspaces use the same Foreman-managed workspace root as git worktrees, defaulting to an external location (`<repoParent>/.foreman-worktrees/<repoName>/<seedId>`) so parent-repo state writes do not dirty active workspaces.

**Rationale:** Consistency across backends. The dispatcher, agent-worker, and status commands all reference this path. Using a different convention for jj would require conditional logic throughout the codebase.

### TD-006: PR-Based Merge Flow for Jujutsu

**Decision:** Jujutsu uses `jj git push` + `gh pr create` for merging, same as git backend.

**Rationale:** Per OQ-3 resolution in the PRD. Colocated jj repos share the git remote, so `gh pr create` works identically. This keeps GitHub as the review/merge gateway for both backends.

### TD-007: Conflict Resolver Adaptation Strategy for jj

**Decision:** Adapt the existing tiered AI resolver to understand jj's conflict syntax rather than skipping AI resolution for jj.

**Rationale:** Per OQ-2 resolution in the PRD. Provides the same AI-assisted resolution experience. jj's conflict markers (`%%%%%%%` diff-style and `+++++++`/`-------`) differ from git's but can be parsed by the same AI with backend-aware prompting.

### TD-008: Reviewer + Finalize Prompts Only (Not All Prompts)

**Decision:** Only finalize and reviewer prompts receive VCS-aware templating. Explorer, developer, and QA prompts are unchanged.

**Rationale:** Per OQ-4 resolution. Explorer/developer/QA agents work with files and code, not VCS commands. Only finalize (commit/push) and reviewer (branch/merge context) need backend awareness.
