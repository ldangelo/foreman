# PRD-2026-004: VCS Backend Abstraction -- Git and Jujutsu Support

**Document ID:** PRD-2026-004
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-26
**Author:** Product Management
**Stakeholders:** Engineering (Foreman maintainers), Foreman operators, Teams using Jujutsu, DevOps
**Requirements:** 22 (REQ-001 through REQ-022)

---

## Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-26 | Product Management | Initial draft covering VcsBackend interface, Git backend, Jujutsu backend, auto-detection, configuration, prompt awareness, refinery abstraction, and workspace isolation. 22 requirements, 66 acceptance criteria. |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals and Non-Goals](#3-goals-and-non-goals)
4. [User Personas](#4-user-personas)
5. [Current State Analysis](#5-current-state-analysis)
6. [Solution Overview](#6-solution-overview)
7. [Functional Requirements -- Part 1: VcsBackend Interface and Plugin Architecture](#7-functional-requirements----part-1-vcsbackend-interface-and-plugin-architecture)
8. [Functional Requirements -- Part 2: Git Backend Implementation](#8-functional-requirements----part-2-git-backend-implementation)
9. [Functional Requirements -- Part 3: Jujutsu Backend Implementation](#9-functional-requirements----part-3-jujutsu-backend-implementation)
10. [Functional Requirements -- Part 4: Configuration and Detection](#10-functional-requirements----part-4-configuration-and-detection)
11. [Functional Requirements -- Part 5: Pipeline Integration](#11-functional-requirements----part-5-pipeline-integration)
12. [Non-Functional Requirements](#12-non-functional-requirements)
13. [Implementation Strategy](#13-implementation-strategy)
14. [Risks and Mitigations](#14-risks-and-mitigations)
15. [Acceptance Criteria Summary](#15-acceptance-criteria-summary)
16. [Success Metrics](#16-success-metrics)
17. [Release Plan](#17-release-plan)
18. [Open Questions](#18-open-questions)

---

## 1. Executive Summary

Foreman is tightly coupled to Git for all version control operations: worktree creation, branching, committing, pushing, rebasing, merging, and conflict resolution. Every layer of the system -- from `src/lib/git.ts` through `src/orchestrator/refinery.ts` to the finalize phase prompts -- directly invokes `git` CLI commands. This makes it impossible to use Foreman with repositories managed by Jujutsu (`jj`), a modern VCS gaining adoption for its ergonomic branching model, first-class conflict handling, and operation log.

This PRD introduces a **VcsBackend plugin architecture** that abstracts all VCS operations behind a common interface. Two backend implementations are provided: **GitBackend** (wrapping the existing git/git-town logic) and **JujutsuBackend** (wrapping `jj` CLI commands). The backend is selectable via configuration (`git`, `jujutsu`, or `auto`), where `auto` detects the presence of a `.jj` directory to choose the appropriate backend. All existing Foreman functionality -- dispatcher, agent pipeline, refinery, finalize, merge queue -- operates through the abstraction without backend-specific conditionals scattered throughout the codebase.

---

## 2. Problem Statement

### 2.1 Hard-Coded Git Dependency

Every VCS operation in Foreman directly calls `git` via `execFileAsync("git", ...)` or `execFileSync("git", ...)`. There are at least **four distinct locations** where git commands are issued:

1. **`src/lib/git.ts`** -- 15+ exported functions (`createWorktree`, `removeWorktree`, `listWorktrees`, `mergeWorktree`, `getCurrentBranch`, `deleteBranch`, `detectDefaultBranch`, etc.)
2. **`src/orchestrator/refinery.ts`** -- merge, rebase, conflict detection, stacked branch management, PR creation via `gh`
3. **`src/orchestrator/agent-worker-finalize.ts`** -- `git add`, `git commit`, `git push`, `git rebase`, `git pull --rebase`, branch verification
4. **`src/defaults/prompts/default/finalize.md`** and **`src/defaults/prompts/smoke/finalize.md`** -- agent-executed git commands embedded in markdown prompts
5. **`src/orchestrator/conflict-resolver.ts`** -- git-specific conflict resolution via rebase/merge

A team using Jujutsu cannot use Foreman at all today, even though Jujutsu can operate on git-backed repositories. The semantic differences between `git` branching and `jj` bookmarks/changes, between `git worktree` and `jj workspace`, and between `git rebase` and `jj rebase` mean a simple alias layer is insufficient.

### 2.2 Jujutsu Adoption Trend

Jujutsu (`jj`) is gaining traction in engineering teams for several reasons relevant to Foreman's use case:
- **First-class conflict handling**: Conflicts are recorded in the commit graph rather than blocking operations, reducing the need for complex resolution cascades like Foreman's tiered conflict resolver.
- **Anonymous branches (changes)**: Every working-copy modification is automatically a change; no explicit `git checkout -b` required.
- **Operation log**: Every repository mutation is logged and reversible, providing better recovery from agent mistakes.
- **Workspace support**: `jj workspace add` provides isolated working copies analogous to `git worktree add`, but with jj's conflict-aware semantics.

### 2.3 Prompt Coupling

The finalize prompts (`finalize.md`) contain literal `git` commands that agents execute. These prompts cannot be made backend-agnostic without either templating the VCS commands or providing entirely separate prompt variants per backend.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **Introduce a `VcsBackend` interface** that abstracts all VCS operations Foreman performs, enabling backend-agnostic orchestration.
2. **Implement a `GitBackend`** that wraps the existing `src/lib/git.ts` and refinery logic, preserving all current behavior including git-town integration.
3. **Implement a `JujutsuBackend`** that maps Foreman's VCS operations to `jj` CLI equivalents (`jj workspace add`, `jj bookmark`, `jj new`, `jj describe`, `jj git push`, etc.).
4. **Auto-detect the VCS backend** when configured as `auto` by checking for a `.jj` directory in the project root.
5. **Make finalize prompts backend-aware** so agents receive the correct VCS commands for the active backend.
6. **Route all refinery operations** (merge, rebase, conflict resolution, PR creation) through the VcsBackend abstraction.
7. **Ensure workspace isolation** works correctly with both git worktrees and jj workspaces.

### 3.2 Non-Goals

1. **Supporting other VCS systems** (Mercurial, Fossil, Pijul) -- the interface should be extensible, but only Git and Jujutsu backends are in scope.
2. **Native jj repositories** (non-git-backed) -- initial Jujutsu support targets `jj` operating on a git-backed repo (the most common configuration). Pure jj-native repos are deferred.
3. **Automatic migration** from git to jj or vice versa -- Foreman does not convert repositories.
4. **Modifying jj's colocated mode behavior** -- Foreman uses jj as-is; it does not manage jj's internal git interop.
5. **Rewriting the conflict-resolver AI tiers** -- the tiered AI conflict resolution in `conflict-resolver.ts` will be adapted to work through the backend interface but not redesigned.

---

## 4. User Personas

### 4.1 Git Power User (Current)

**Name:** Dana, Senior Engineer
**Context:** Uses Foreman daily on a large git-town-managed monorepo. Relies on git worktrees for parallel agent execution. Expects zero regression in git-based workflows.
**Needs:** Existing behavior preserved exactly. No new configuration required for git-only projects.

### 4.2 Jujutsu Adopter

**Name:** Kai, Tech Lead
**Context:** Team migrated to jj (colocated on git) six months ago. Uses `jj workspace` for parallel development. Wants to adopt Foreman for AI-assisted task execution but cannot because Foreman only speaks git.
**Needs:** Foreman dispatches agents into jj workspaces. Agent commits use `jj describe`/`jj new`. Merging uses `jj` semantics. No manual git commands required.

### 4.3 Multi-VCS Team Lead

**Name:** Alex, Engineering Manager
**Context:** Manages multiple repositories -- some pure git, some migrating to jj. Wants a single Foreman installation that works across all repos without per-repo configuration.
**Needs:** `auto` detection mode so Foreman picks the right backend per project without manual config.

### 4.4 Foreman Plugin Developer

**Name:** Morgan, Platform Engineer
**Context:** Maintains custom Foreman extensions. Wants to understand the VcsBackend interface to potentially contribute a third-party backend or extend existing ones.
**Needs:** Clean, well-documented interface. Clear separation between interface and implementation.

---

## 5. Current State Analysis

### 5.1 VCS Operations Inventory

The following table catalogs every VCS operation Foreman performs today, the source location, and the jj equivalent:

| Operation | Git Command(s) | Source File(s) | jj Equivalent |
|-----------|----------------|----------------|---------------|
| Get repo root | `git rev-parse --show-toplevel` | `git.ts` | `jj root` |
| Get main repo root | `git rev-parse --git-common-dir` | `git.ts` | `jj root` (workspaces share root) |
| Detect default branch | `git config get git-town.main-branch`, `git symbolic-ref`, branch existence checks | `git.ts` | `jj config get revset-aliases.'trunk()'` or convention |
| Get current branch | `git rev-parse --abbrev-ref HEAD` | `git.ts` | `jj log -r @ --no-graph -T 'bookmarks'` |
| Checkout branch | `git checkout <branch>` | `git.ts` | `jj edit <change-id>` |
| Create worktree | `git worktree add -b <branch> <path> <base>` | `git.ts` | `jj workspace add <path>` |
| Remove worktree | `git worktree remove --force`, `git worktree prune` | `git.ts` | `jj workspace forget <name>` |
| List worktrees | `git worktree list --porcelain` | `git.ts` | `jj workspace list` |
| Rebase onto base | `git rebase <base>` | `git.ts`, `refinery.ts` | `jj rebase -r @ -d <base>` |
| Stage all files | `git add -A` | `agent-worker-finalize.ts`, prompts | Not needed (jj auto-tracks) |
| Commit | `git commit -m <msg>` | `agent-worker-finalize.ts`, prompts | `jj describe -m <msg>` + `jj new` |
| Push to remote | `git push -u origin <branch>` | `agent-worker-finalize.ts`, prompts | `jj git push --bookmark <bookmark>` |
| Merge branch | `git merge <branch> --no-ff` | `git.ts` | `jj new <target> <source>` (merge commit) |
| Abort rebase | `git rebase --abort` | `git.ts`, `refinery.ts`, `agent-worker-finalize.ts` | `jj op undo` |
| Detect conflicts | `git diff --name-only --diff-filter=U` | `git.ts` | `jj resolve --list` |
| Delete branch | `git branch -d/-D <branch>` | `git.ts` | `jj bookmark delete <bookmark>` |
| Branch exists | `git show-ref --verify` | `git.ts` | `jj bookmark list --name <bookmark>` |
| Remote branch exists | `git rev-parse origin/<branch>` | `git.ts` | `jj git fetch` + bookmark check |
| Stash changes | `git stash push/pop` | `git.ts` | Not needed (jj always has working copy as a change) |
| Diff for conflict markers | `git diff <target>..<branch>` | `refinery.ts` | `jj diff --from <target> --to <source>` |
| Force push | `git push -u -f origin <branch>` | `refinery.ts` | `jj git push --bookmark <b> --allow-new` |
| Pull with rebase | `git pull --rebase origin <branch>` | `agent-worker-finalize.ts` | `jj git fetch` + `jj rebase -d <remote>` |
| Clean working tree | `git checkout -- .`, `git clean -fd` | `git.ts` | `jj restore` |
| Create PR | `gh pr create` | `refinery.ts` | `gh pr create` (same -- operates on git remote) |

### 5.2 Architecture Coupling Points

1. **`src/lib/git.ts`** -- 644 lines, 15+ exported functions. All direct `execFileAsync("git", ...)` calls.
2. **`src/orchestrator/refinery.ts`** -- `Refinery` class has its own `git()` helper and calls git directly for merge, rebase, conflict scanning, PR creation.
3. **`src/orchestrator/agent-worker-finalize.ts`** -- `finalize()` function uses `execFileSync("git", ...)` for add, commit, push, rebase, branch verification.
4. **`src/orchestrator/conflict-resolver.ts`** -- Git-specific conflict resolution (rebase --continue, merge markers).
5. **Finalize prompts** -- Markdown files containing literal `git add`, `git commit`, `git push`, `git rebase` commands that agents execute.
6. **`src/orchestrator/templates.ts`** -- `workerAgentMd()` generates TASK.md; currently VCS-unaware.

---

## 6. Solution Overview

### 6.1 Architecture

```
                          VcsBackend (interface)
                         /                      \
                GitBackend                  JujutsuBackend
              (src/lib/vcs/git.ts)       (src/lib/vcs/jujutsu.ts)
                  |                            |
            git CLI + git-town              jj CLI
```

```
  Configuration (.foreman/config.yaml or workflow YAML)
       |
       v
  VcsBackendFactory.create(config, projectPath)
       |
       +---> 'git'      -> new GitBackend(projectPath)
       +---> 'jujutsu'  -> new JujutsuBackend(projectPath)
       +---> 'auto'     -> detect .jj dir -> GitBackend or JujutsuBackend
```

### 6.2 Module Structure

```
src/lib/vcs/
  index.ts              -- VcsBackend interface + VcsBackendFactory
  types.ts              -- Shared types (Worktree, MergeResult, etc.)
  git-backend.ts        -- GitBackend class (refactored from git.ts)
  jujutsu-backend.ts    -- JujutsuBackend class
  __tests__/
    git-backend.test.ts
    jujutsu-backend.test.ts
    factory.test.ts
```

### 6.3 Integration Points

1. **Dispatcher** (`src/orchestrator/dispatcher.ts`) -- receives `VcsBackend` instance, passes to agent workers.
2. **Agent Worker** -- uses `VcsBackend` for worktree creation/teardown.
3. **Finalize** (`agent-worker-finalize.ts`) -- uses `VcsBackend` for commit/push/rebase. OR: finalize prompts are templated with backend-specific commands.
4. **Refinery** (`refinery.ts`) -- uses `VcsBackend` for merge, rebase, conflict detection, branch cleanup.
5. **Workflow Loader** -- reads `vcs` config from workflow YAML; passes to factory.
6. **Prompts** -- finalize prompt templates include `{{vcsCommitCommand}}`, `{{vcsPushCommand}}`, etc., or separate prompt variants per backend.

---

## 7. Functional Requirements -- Part 1: VcsBackend Interface and Plugin Architecture

### REQ-001: VcsBackend Interface Definition

**Priority:** P0 (critical)
**Type:** Architecture

The system shall define a `VcsBackend` TypeScript interface in `src/lib/vcs/index.ts` that abstracts all VCS operations Foreman performs. The interface shall be the sole contract between Foreman's orchestration layer and the underlying version control system.

**Interface surface (minimum):**

```typescript
interface VcsBackend {
  readonly name: 'git' | 'jujutsu';

  // Repository introspection
  getRepoRoot(path: string): Promise<string>;
  getMainRepoRoot(path: string): Promise<string>;
  detectDefaultBranch(repoPath: string): Promise<string>;
  getCurrentBranch(repoPath: string): Promise<string>;

  // Branch / bookmark operations
  checkoutBranch(repoPath: string, branchName: string): Promise<void>;
  branchExists(repoPath: string, branchName: string): Promise<boolean>;
  branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean>;
  deleteBranch(repoPath: string, branchName: string, opts?: DeleteBranchOptions): Promise<DeleteBranchResult>;

  // Workspace isolation
  createWorkspace(repoPath: string, seedId: string, baseBranch?: string, setupSteps?: WorkflowSetupStep[], setupCache?: WorkflowSetupCache): Promise<WorkspaceResult>;
  removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;
  listWorkspaces(repoPath: string): Promise<Workspace[]>;

  // Commit operations
  stageAll(workspacePath: string): Promise<void>;
  commit(workspacePath: string, message: string): Promise<string>; // returns commit/change ID
  getHeadId(workspacePath: string): Promise<string>;

  // Sync operations
  push(workspacePath: string, branchName: string, opts?: PushOptions): Promise<void>;
  pull(workspacePath: string, branchName: string): Promise<void>;
  fetch(workspacePath: string): Promise<void>;
  rebase(workspacePath: string, onto: string): Promise<RebaseResult>;
  abortRebase(workspacePath: string): Promise<void>;

  // Merge operations
  merge(repoPath: string, branchName: string, targetBranch?: string): Promise<MergeResult>;

  // Diff and conflict detection
  getConflictingFiles(workspacePath: string): Promise<string[]>;
  diff(repoPath: string, from: string, to: string): Promise<string>;
  getModifiedFiles(workspacePath: string, base: string): Promise<string[]>;

  // Working tree state
  cleanWorkingTree(workspacePath: string): Promise<void>;
  status(workspacePath: string): Promise<string>;

  // Finalize helpers
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
```

**Acceptance Criteria:**

- **AC-001-1:** Given the `VcsBackend` interface is defined, when a TypeScript module imports it, then it compiles without errors and all methods have explicit return types.
- **AC-001-2:** Given a class implements `VcsBackend`, when any interface method is missing, then the TypeScript compiler emits an error.
- **AC-001-3:** Given the interface, when a new VCS backend is needed, then a developer can implement the interface without modifying any existing Foreman orchestration code.

### REQ-002: VcsBackendFactory

**Priority:** P0 (critical)
**Type:** Architecture

The system shall provide a `VcsBackendFactory` with a static `create()` method that instantiates the appropriate backend based on configuration.

```typescript
class VcsBackendFactory {
  static create(config: VcsConfig, projectPath: string): VcsBackend;
}

interface VcsConfig {
  backend: 'git' | 'jujutsu' | 'auto';
}
```

**Acceptance Criteria:**

- **AC-002-1:** Given `config.backend` is `'git'`, when `VcsBackendFactory.create()` is called, then a `GitBackend` instance is returned.
- **AC-002-2:** Given `config.backend` is `'jujutsu'`, when `VcsBackendFactory.create()` is called, then a `JujutsuBackend` instance is returned.
- **AC-002-3:** Given `config.backend` is `'auto'` and a `.jj` directory exists at `projectPath/.jj`, when `VcsBackendFactory.create()` is called, then a `JujutsuBackend` instance is returned.
- **AC-002-4:** Given `config.backend` is `'auto'` and no `.jj` directory exists at `projectPath`, when `VcsBackendFactory.create()` is called, then a `GitBackend` instance is returned.
- **AC-002-5:** Given `config.backend` is an unrecognized value, when `VcsBackendFactory.create()` is called, then a descriptive error is thrown listing valid options.

### REQ-003: Shared VCS Types

**Priority:** P1 (high)
**Type:** Architecture

The system shall define shared types in `src/lib/vcs/types.ts` used by both backends and all consumers. These types replace the existing types in `src/lib/git.ts`.

Required types: `Workspace` (replaces `Worktree`), `WorkspaceResult`, `MergeResult`, `DeleteBranchResult`, `RebaseResult`, `PushOptions`, `DeleteBranchOptions`, `FinalizeTemplateVars`, `FinalizeCommands`.

**Acceptance Criteria:**

- **AC-003-1:** Given the shared types are defined, when `GitBackend` and `JujutsuBackend` both use them, then both compile without type errors.
- **AC-003-2:** Given existing code imports `Worktree` from `git.ts`, when it is migrated to import `Workspace` from `vcs/types.ts`, then all existing test assertions continue to pass with the renamed type.
- **AC-003-3:** Given `FinalizeCommands` is defined, when it contains `stageCommand`, `commitCommand`, `pushCommand`, `rebaseCommand`, `branchVerifyCommand`, and `cleanCommand` fields, then finalize prompts can be rendered backend-agnostically.

---

## 8. Functional Requirements -- Part 2: Git Backend Implementation

### REQ-004: GitBackend Class

**Priority:** P0 (critical)
**Type:** Implementation

The system shall implement a `GitBackend` class in `src/lib/vcs/git-backend.ts` that implements the `VcsBackend` interface. This class shall encapsulate all logic currently in `src/lib/git.ts`, including git-town integration for default branch detection.

**Acceptance Criteria:**

- **AC-004-1:** Given a git repository, when `GitBackend.createWorkspace()` is called with a seedId, then a git worktree is created at `<repoPath>/.foreman-worktrees/<seedId>` on branch `foreman/<seedId>`, matching current `createWorktree()` behavior exactly.
- **AC-004-2:** Given an existing worktree from a failed run, when `GitBackend.createWorkspace()` is called for the same seedId, then the worktree is reused and rebased onto the base branch, matching current retry behavior.
- **AC-004-3:** Given a git repository with git-town configured, when `GitBackend.detectDefaultBranch()` is called, then the `git-town.main-branch` config value is returned (matching current priority order).
- **AC-004-4:** Given a git worktree, when `GitBackend.commit()` is called, then `git add -A` and `git commit -m <message>` are executed and the short commit hash is returned.
- **AC-004-5:** Given a branch with diverged history, when `GitBackend.push()` is called and receives a non-fast-forward rejection, then the push fails with a typed error that callers can inspect (no automatic rebase -- that is the caller's responsibility).

### REQ-005: GitBackend Merge Operations

**Priority:** P0 (critical)
**Type:** Implementation

The `GitBackend.merge()` method shall reproduce the exact behavior of the current `mergeWorktree()` function in `src/lib/git.ts`: stash local changes, checkout target branch, run `git merge --no-ff`, detect conflicts, restore stash.

**Acceptance Criteria:**

- **AC-005-1:** Given a clean merge, when `GitBackend.merge()` is called, then `MergeResult.success` is `true` and no conflicts are reported.
- **AC-005-2:** Given a conflicting merge, when `GitBackend.merge()` is called, then `MergeResult.success` is `false` and `MergeResult.conflicts` contains the list of conflicting file paths.
- **AC-005-3:** Given dirty working tree state before merge, when `GitBackend.merge()` is called, then changes are stashed before checkout and restored after merge completion (success or failure).

### REQ-006: GitBackend Finalize Commands

**Priority:** P1 (high)
**Type:** Implementation

`GitBackend.getFinalizeCommands()` shall return the exact git commands currently embedded in the finalize prompts, parameterized by template variables.

**Acceptance Criteria:**

- **AC-006-1:** Given finalize template vars with `seedId`, `seedTitle`, `baseBranch`, when `GitBackend.getFinalizeCommands()` is called, then the returned `stageCommand` is `git add -A`.
- **AC-006-2:** Given the same vars, when `getFinalizeCommands()` is called, then `commitCommand` is `git commit -m "<seedTitle> (<seedId>)"`.
- **AC-006-3:** Given the same vars, then `pushCommand` is `git push -u origin foreman/<seedId>`.
- **AC-006-4:** Given the same vars, then `rebaseCommand` is `git fetch origin && git rebase origin/<baseBranch>`.

### REQ-007: GitBackend Backward Compatibility

**Priority:** P0 (critical)
**Type:** Constraint

The `GitBackend` shall produce identical behavior to the current `src/lib/git.ts` functions for every operation. Existing tests shall pass without modification (beyond import path changes).

**Acceptance Criteria:**

- **AC-007-1:** Given the existing `src/lib/git.ts` test suite, when tests are updated to use `GitBackend` instead of direct function imports, then all tests pass with zero behavioral changes.
- **AC-007-2:** Given a full pipeline run with `GitBackend`, when compared to a run with the current direct git calls, then the same git commands are executed in the same order.
- **AC-007-3:** Given the `git.ts` module, when the migration is complete, then `git.ts` re-exports from `GitBackend` for backward compatibility (deprecation shim) until all consumers are migrated.

---

## 9. Functional Requirements -- Part 3: Jujutsu Backend Implementation

### REQ-008: JujutsuBackend Class

**Priority:** P1 (high)
**Type:** Implementation

The system shall implement a `JujutsuBackend` class in `src/lib/vcs/jujutsu-backend.ts` that implements the `VcsBackend` interface using `jj` CLI commands. The backend targets jj operating in **colocated mode** (git-backed repository with `.jj` directory).

**Acceptance Criteria:**

- **AC-008-1:** Given a jj-managed repository, when `JujutsuBackend.getRepoRoot()` is called, then `jj root` is executed and the repository root path is returned.
- **AC-008-2:** Given a jj repository, when `JujutsuBackend.getCurrentBranch()` is called, then the bookmark(s) pointing to the current working-copy change are returned. If no bookmark exists, a synthetic identifier based on the change ID is returned.
- **AC-008-3:** Given `jj` is not installed or not in PATH, when any `JujutsuBackend` method is called, then a clear error is thrown: `"jj (Jujutsu) CLI not found. Install from https://github.com/jj-vcs/jj"`.

### REQ-009: Jujutsu Workspace Management

**Priority:** P1 (high)
**Type:** Implementation

`JujutsuBackend.createWorkspace()` shall create isolated workspaces using `jj workspace add`. Each workspace gets a bookmark named `foreman/<seedId>` for push/PR operations.

**Acceptance Criteria:**

- **AC-009-1:** Given a jj repository, when `JujutsuBackend.createWorkspace()` is called with seedId `bd-abc1`, then `jj workspace add <path> --name foreman-bd-abc1` is executed, creating a workspace at `<repoPath>/.foreman-worktrees/bd-abc1`.
- **AC-009-2:** Given the workspace is created, when the workspace is initialized, then a bookmark `foreman/bd-abc1` is created pointing to the new workspace's working-copy change via `jj bookmark create foreman/bd-abc1 -r @`.
- **AC-009-3:** Given an existing workspace from a failed run, when `createWorkspace()` is called for the same seedId, then the existing workspace is reused: `jj workspace update-stale` is run if needed, and the working copy is rebased onto the base branch.
- **AC-009-4:** Given a workspace, when `JujutsuBackend.removeWorkspace()` is called, then `jj workspace forget <name>` is executed and the workspace directory is removed.
- **AC-009-5:** Given a jj repository, when `JujutsuBackend.listWorkspaces()` is called, then `jj workspace list` is parsed and returned as `Workspace[]` objects.

### REQ-010: Jujutsu Commit Operations

**Priority:** P1 (high)
**Type:** Implementation

Jujutsu does not require explicit staging (`git add`). The `JujutsuBackend` shall handle commit operations using jj's change-based model.

**Acceptance Criteria:**

- **AC-010-1:** Given a jj workspace with modified files, when `JujutsuBackend.stageAll()` is called, then the method is a no-op (jj auto-tracks all files in the working copy) but does not throw.
- **AC-010-2:** Given a jj workspace, when `JujutsuBackend.commit()` is called with a message, then `jj describe -m <message>` is run to set the change description, followed by `jj new` to create a new empty change on top (so subsequent work starts fresh). The change ID of the described change is returned.
- **AC-010-3:** Given a jj workspace with no modifications, when `JujutsuBackend.commit()` is called, then `jj describe -m <message>` is run on the current (empty) change. The behavior mirrors git's "nothing to commit" -- the caller determines whether this is an error.

### REQ-011: Jujutsu Sync Operations

**Priority:** P1 (high)
**Type:** Implementation

Push, pull, fetch, and rebase operations shall use jj's git interop commands.

**Acceptance Criteria:**

- **AC-011-1:** Given a jj workspace with a bookmark `foreman/bd-abc1`, when `JujutsuBackend.push()` is called, then `jj git push --bookmark foreman/bd-abc1` is executed.
- **AC-011-2:** Given a push that fails because the bookmark is new, when `push()` is called with `opts.allowNew: true`, then `--allow-new` flag is added to the push command.
- **AC-011-3:** Given a jj workspace, when `JujutsuBackend.fetch()` is called, then `jj git fetch` is executed.
- **AC-011-4:** Given a jj workspace, when `JujutsuBackend.rebase()` is called with `onto`, then `jj rebase -d <onto>` is executed. If the rebase produces conflicts, `RebaseResult.hasConflicts` is `true` and the conflicting files are listed.
- **AC-011-5:** Given a failed rebase, when `JujutsuBackend.abortRebase()` is called, then `jj op undo` is executed to reverse the last operation.

### REQ-012: Jujutsu Merge Operations

**Priority:** P1 (high)
**Type:** Implementation

Merging in jj creates a merge commit with multiple parents using `jj new`.

**Acceptance Criteria:**

- **AC-012-1:** Given a jj repository, when `JujutsuBackend.merge()` is called with `branchName` and `targetBranch`, then `jj new <targetBranch> <branchName> -m "Merge <branchName>"` is executed to create a merge change.
- **AC-012-2:** Given a merge that produces conflicts, when `merge()` returns, then `MergeResult.success` is `false` and `MergeResult.conflicts` lists the conflicting files (from `jj resolve --list`).
- **AC-012-3:** Given a clean merge, when `merge()` returns, then `MergeResult.success` is `true`.

### REQ-013: Jujutsu Finalize Commands

**Priority:** P1 (high)
**Type:** Implementation

`JujutsuBackend.getFinalizeCommands()` shall return jj-specific commands for use in finalize prompts.

**Acceptance Criteria:**

- **AC-013-1:** Given finalize template vars, when `JujutsuBackend.getFinalizeCommands()` is called, then `stageCommand` is empty string (jj auto-stages).
- **AC-013-2:** Given the same vars, then `commitCommand` is `jj describe -m "<seedTitle> (<seedId>)" && jj new`.
- **AC-013-3:** Given the same vars, then `pushCommand` is `jj git push --bookmark foreman/<seedId> --allow-new`.
- **AC-013-4:** Given the same vars, then `rebaseCommand` is `jj git fetch && jj rebase -d <baseBranch>@origin`.
- **AC-013-5:** Given the same vars, then `branchVerifyCommand` is `jj bookmark list --name foreman/<seedId>` (verification that the bookmark exists).

---

## 10. Functional Requirements -- Part 4: Configuration and Detection

### REQ-014: Workflow YAML Configuration

**Priority:** P1 (high)
**Type:** Configuration

The workflow YAML files shall support a top-level `vcs` key to specify the backend.

```yaml
name: default
vcs: auto  # 'git' | 'jujutsu' | 'auto' (default: 'auto')
setup:
  ...
phases:
  ...
```

**Acceptance Criteria:**

- **AC-014-1:** Given a workflow YAML with `vcs: jujutsu`, when the workflow is loaded, then the pipeline uses `JujutsuBackend`.
- **AC-014-2:** Given a workflow YAML with no `vcs` key, when the workflow is loaded, then the default `auto` detection is used.
- **AC-014-3:** Given a workflow YAML with `vcs: git`, when the workflow is loaded on a jj-managed repository, then `GitBackend` is used (explicit config overrides detection).

### REQ-015: Project-Level Configuration

**Priority:** P2 (medium)
**Type:** Configuration

The `.foreman/config.yaml` file (if it exists) shall support a `vcs` key that serves as the project-wide default. Workflow-level `vcs` overrides project-level `vcs`.

```yaml
# .foreman/config.yaml
vcs: jujutsu
```

**Acceptance Criteria:**

- **AC-015-1:** Given `.foreman/config.yaml` contains `vcs: jujutsu` and the workflow YAML has no `vcs` key, when the pipeline starts, then `JujutsuBackend` is used.
- **AC-015-2:** Given `.foreman/config.yaml` contains `vcs: jujutsu` and the workflow YAML has `vcs: git`, when the pipeline starts, then `GitBackend` is used (workflow overrides project).
- **AC-015-3:** Given no `.foreman/config.yaml` and no workflow `vcs` key, when the pipeline starts, then `auto` detection is used.

### REQ-016: Auto-Detection Logic

**Priority:** P0 (critical)
**Type:** Implementation

When the VCS backend is `auto`, the system shall detect the appropriate backend by checking for a `.jj` directory in the project root.

**Acceptance Criteria:**

- **AC-016-1:** Given a project directory containing `.jj/`, when auto-detection runs, then `JujutsuBackend` is selected.
- **AC-016-2:** Given a project directory containing `.git/` but no `.jj/`, when auto-detection runs, then `GitBackend` is selected.
- **AC-016-3:** Given a project directory containing both `.jj/` and `.git/` (colocated jj), when auto-detection runs, then `JujutsuBackend` is selected (`.jj` takes precedence).
- **AC-016-4:** Given a project directory containing neither `.jj/` nor `.git/`, when auto-detection runs, then an error is thrown: `"No VCS detected in <path>. Expected .git/ or .jj/ directory."`.

---

## 11. Functional Requirements -- Part 5: Pipeline Integration

### REQ-017: Finalize Prompt Backend Awareness

**Priority:** P0 (critical)
**Type:** Integration

The finalize phase prompts shall be rendered with backend-specific VCS commands. The system shall support this via template variables populated from `VcsBackend.getFinalizeCommands()`.

**Acceptance Criteria:**

- **AC-017-1:** Given a pipeline using `GitBackend`, when the finalize prompt is rendered, then all VCS commands in the prompt are git commands (matching current behavior exactly).
- **AC-017-2:** Given a pipeline using `JujutsuBackend`, when the finalize prompt is rendered, then all VCS commands in the prompt are jj commands.
- **AC-017-3:** Given the finalize prompt template, when it contains `{{vcsStageCommand}}`, `{{vcsCommitCommand}}`, `{{vcsPushCommand}}`, `{{vcsRebaseCommand}}`, `{{vcsBranchVerifyCommand}}`, then these are replaced with backend-specific commands.
- **AC-017-4:** Given the current default finalize prompt, when migrated to use template variables, then the rendered output for `GitBackend` is character-identical to the current prompt.

### REQ-018: Refinery VCS Abstraction

**Priority:** P0 (critical)
**Type:** Integration

The `Refinery` class shall accept a `VcsBackend` instance and route all VCS operations through it instead of calling git directly.

**Acceptance Criteria:**

- **AC-018-1:** Given the `Refinery` constructor, when it receives a `VcsBackend` instance, then no direct `execFileAsync("git", ...)` calls exist in `refinery.ts`.
- **AC-018-2:** Given a merge operation via refinery, when `VcsBackend.merge()` returns a conflict, then the existing conflict resolution cascade (report file auto-resolve, tiered AI resolution, PR fallback) operates correctly.
- **AC-018-3:** Given the refinery performs stacked branch rebasing, when `rebaseStackedBranches()` runs, then it uses `VcsBackend.rebase()` and `VcsBackend.branchExists()` instead of direct git calls.

### REQ-019: Agent Worker Finalize Abstraction

**Priority:** P0 (critical)
**Type:** Integration

The `finalize()` function in `agent-worker-finalize.ts` shall accept a `VcsBackend` instance and use it for all VCS operations (commit, push, branch verification, rebase recovery).

**Acceptance Criteria:**

- **AC-019-1:** Given `finalize()` receives a `VcsBackend`, when it performs commit operations, then `VcsBackend.stageAll()` and `VcsBackend.commit()` are called instead of `execFileSync("git", ["add", "-A"])` and `execFileSync("git", ["commit", ...])`.
- **AC-019-2:** Given `finalize()` receives a `VcsBackend`, when push fails with non-fast-forward, then recovery uses `VcsBackend.pull()` and `VcsBackend.push()` instead of `execFileSync("git", ["pull", "--rebase", ...])`.
- **AC-019-3:** Given the finalize function, when migrated to use VcsBackend, then no direct `execFileSync("git", ...)` calls remain in the function body.

### REQ-020: Dispatcher VCS Backend Propagation

**Priority:** P1 (high)
**Type:** Integration

The dispatcher shall create the `VcsBackend` instance once at startup and propagate it to all pipeline components: agent workers, refinery, and merge queue.

**Acceptance Criteria:**

- **AC-020-1:** Given the dispatcher starts, when it reads the workflow config, then a single `VcsBackend` instance is created via `VcsBackendFactory.create()`.
- **AC-020-2:** Given the VcsBackend is created, when agent workers are spawned, then the backend `name` is passed as an environment variable (`FOREMAN_VCS_BACKEND`) so the worker process can reconstruct the correct backend.
- **AC-020-3:** Given a worker process starts, when it reads `FOREMAN_VCS_BACKEND`, then it creates the matching `VcsBackend` instance without re-running auto-detection (deterministic).

### REQ-021: Conflict Resolver Backend Awareness

**Priority:** P1 (high)
**Type:** Integration

The `ConflictResolver` class shall operate through the `VcsBackend` interface for rebase continuation, abort, and conflict file detection.

**Acceptance Criteria:**

- **AC-021-1:** Given a merge conflict during refinery, when `ConflictResolver.autoResolveRebaseConflicts()` runs, then it uses `VcsBackend.getConflictingFiles()` instead of parsing `git diff --name-only --diff-filter=U` directly.
- **AC-021-2:** Given a rebase abort is needed, when `autoResolveRebaseConflicts()` decides to abort, then it calls `VcsBackend.abortRebase()`.
- **AC-021-3:** Given jj's first-class conflict handling, when `JujutsuBackend` is active, then the conflict resolver recognizes that jj records conflicts in-tree (no rebase --continue loop needed) and adapts its strategy accordingly.

---

## 12. Non-Functional Requirements

### REQ-022: Performance and Reliability

**Priority:** P1 (high)
**Type:** Non-Functional

The VCS abstraction layer shall not introduce measurable latency or reliability regression.

**Acceptance Criteria:**

- **AC-022-1:** Given a pipeline run with `GitBackend`, when compared to the current direct-git implementation, then end-to-end pipeline time does not increase by more than 1%.
- **AC-022-2:** Given either backend, when a VCS CLI command fails, then the error message includes: the backend name, the command that failed, the exit code, and stderr output (matching current git error reporting quality).
- **AC-022-3:** Given the `JujutsuBackend`, when `jj` commands are invoked, then the same `maxBuffer` (10 MB) and timeout conventions used for git commands are applied.
- **AC-022-4:** Given a jj workspace, when workspace creation includes setup steps (npm install, etc.), then the same setup-cache mechanism works identically to git worktrees.

---

## 13. Implementation Strategy

### 13.1 Phased Delivery

| Phase | Scope | Duration | Dependencies |
|-------|-------|----------|-------------|
| Phase A | Define `VcsBackend` interface, shared types, `VcsBackendFactory`. Stub both backends. | 2 days | None |
| Phase B | Implement `GitBackend` by extracting logic from `git.ts`. All existing tests pass. `git.ts` becomes a thin re-export shim. | 3 days | Phase A |
| Phase C | Migrate `refinery.ts`, `agent-worker-finalize.ts`, `conflict-resolver.ts` to accept `VcsBackend`. Remove all direct git calls from orchestration layer. | 3 days | Phase B |
| Phase D | Implement `JujutsuBackend` with unit tests using `jj` CLI. | 3 days | Phase A |
| Phase E | Add configuration support (workflow YAML `vcs` key, `.foreman/config.yaml` `vcs` key, auto-detection). | 1 day | Phase A |
| Phase F | Finalize prompt templating -- add VCS command template variables, render backend-specific prompts. | 2 days | Phase C, Phase D |
| Phase G | Integration testing -- full pipeline run with both backends. | 2 days | All above |

**Total estimated effort:** 16 days (can parallelize Phase D with Phases B+C)

### 13.2 Migration Strategy for `git.ts`

1. Create `src/lib/vcs/git-backend.ts` implementing `VcsBackend`.
2. Move function bodies from `git.ts` into `GitBackend` methods.
3. Update `git.ts` exports to delegate to a singleton `GitBackend` instance (backward compatibility shim).
4. Migrate consumers one-by-one to accept `VcsBackend` instead of importing from `git.ts` directly.
5. Once all consumers are migrated, deprecate the `git.ts` shim exports.

### 13.3 Testing Strategy

- **Unit tests:** Each backend tested in isolation using real CLI calls against temporary repositories.
- **Integration tests:** Full pipeline run with `GitBackend` must produce identical results to current behavior.
- **JJ integration tests:** Require `jj` installed in CI. Skip gracefully if `jj` not available (`describe.skipIf`).
- **Factory tests:** Verify auto-detection logic with mocked filesystem (`.jj` presence/absence).
- **Prompt rendering tests:** Verify finalize prompt output for each backend matches expected commands.

---

## 14. Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Jujutsu CLI output format changes between versions | Backend breaks on jj upgrade | Medium | Pin minimum jj version. Parse output defensively. Add `foreman doctor` check for jj version. |
| git.ts refactoring introduces subtle behavior changes | Pipeline failures on existing git projects | High | Comprehensive test coverage before refactoring. Run full pipeline comparison test. |
| jj workspace semantics differ from git worktree in unexpected ways | Agent isolation breaks | Medium | Spike on jj workspace behavior before implementation. Document differences. |
| Colocated jj mode has git interop edge cases | Push/PR creation fails | Medium | Test colocated mode explicitly. `gh pr create` operates on git remote regardless of jj. |
| Performance overhead from abstraction layer | Slower pipeline execution | Low | The abstraction is a thin function call wrapper; VCS CLI invocations dominate latency. |
| Conflict resolution differences between git and jj | Refinery AI resolution fails for jj | Medium | jj records conflicts in commits (no blocking). Adapt conflict resolver to skip rebase-continue loop for jj. |

---

## 15. Acceptance Criteria Summary

| REQ ID | Requirement | AC Count | Priority |
|--------|-------------|----------|----------|
| REQ-001 | VcsBackend Interface Definition | 3 | P0 |
| REQ-002 | VcsBackendFactory | 5 | P0 |
| REQ-003 | Shared VCS Types | 3 | P1 |
| REQ-004 | GitBackend Class | 5 | P0 |
| REQ-005 | GitBackend Merge Operations | 3 | P0 |
| REQ-006 | GitBackend Finalize Commands | 4 | P1 |
| REQ-007 | GitBackend Backward Compatibility | 3 | P0 |
| REQ-008 | JujutsuBackend Class | 3 | P1 |
| REQ-009 | Jujutsu Workspace Management | 5 | P1 |
| REQ-010 | Jujutsu Commit Operations | 3 | P1 |
| REQ-011 | Jujutsu Sync Operations | 5 | P1 |
| REQ-012 | Jujutsu Merge Operations | 3 | P1 |
| REQ-013 | Jujutsu Finalize Commands | 5 | P1 |
| REQ-014 | Workflow YAML Configuration | 3 | P1 |
| REQ-015 | Project-Level Configuration | 3 | P2 |
| REQ-016 | Auto-Detection Logic | 4 | P0 |
| REQ-017 | Finalize Prompt Backend Awareness | 4 | P0 |
| REQ-018 | Refinery VCS Abstraction | 3 | P0 |
| REQ-019 | Agent Worker Finalize Abstraction | 3 | P0 |
| REQ-020 | Dispatcher VCS Backend Propagation | 3 | P1 |
| REQ-021 | Conflict Resolver Backend Awareness | 3 | P1 |
| REQ-022 | Performance and Reliability | 4 | P1 |
| **Total** | **22 requirements** | **78 ACs** | |

---

## 16. Success Metrics

| Metric | Target | Measurement Method |
|--------|--------|--------------------|
| Git backend parity | 100% existing tests pass | CI test suite |
| Jujutsu pipeline completion rate | >= 90% on colocated jj repos | End-to-end test runs |
| Zero git regression | 0 new failures in git-only projects | Production monitoring, existing CI |
| Abstraction adoption | 0 direct `execFileAsync("git", ...)` calls outside `git-backend.ts` | Static analysis / grep |
| Auto-detection accuracy | 100% correct backend selection | Unit tests for factory |
| Configuration override works | Explicit config always wins over auto-detect | Integration tests |

---

## 17. Release Plan

| Release | Contents | Gate Criteria |
|---------|----------|---------------|
| v0.1-alpha | VcsBackend interface + GitBackend + migration shim. All existing tests pass. No user-facing changes. | All unit tests green. Full pipeline smoke test on git repo. |
| v0.2-alpha | Refinery + finalize + conflict-resolver migrated to VcsBackend. `git.ts` shim deprecated. | All integration tests green. No direct git calls outside `git-backend.ts`. |
| v0.3-alpha | JujutsuBackend implementation + configuration + auto-detection. | jj unit tests pass. Auto-detection tests pass. |
| v0.4-beta | Finalize prompt templating. Full pipeline with jj backend. | End-to-end pipeline run on a colocated jj repo succeeds. |
| v1.0 | Production release. `foreman doctor` checks jj version. Documentation. | All success metrics met. Manual testing on 3+ real repositories. |

---

## 18. Open Questions

| ID | Question | Status | Resolution |
|----|----------|--------|------------|
| OQ-1 | Should `foreman doctor` validate jj version and colocated mode? | Open | Likely yes -- add a `jj version` check and `.jj/repo/store/git` existence check. |
| OQ-2 | How should jj's first-class conflict handling interact with the tiered conflict resolver? jj allows conflicts to be committed, unlike git. | Open | Options: (A) Skip tier 3/4 AI resolution for jj and rely on jj's conflict markers, (B) Adapt AI resolver to work on jj conflict syntax. |
| OQ-3 | Should the `foreman merge` command use `jj` directly or go through `jj git push` + `gh pr merge`? | Open | For colocated repos, the PR-based flow (`gh pr create/merge`) works identically since the git remote is shared. Direct jj merge is an optimization. |
| OQ-4 | Should agent prompts (not just finalize) be aware of the VCS backend? Explorer and developer prompts may reference git concepts (branches, commits). | Open | Likely low priority -- agents interact with files, not VCS. Only finalize and reviewer prompts contain VCS commands. |
| OQ-5 | Does jj workspace support the setup-cache symlink optimization used for git worktrees? | Open | Needs investigation. jj workspaces share the store but have independent working copies; symlink caching of `node_modules` should work identically. |
| OQ-6 | Should we support pure jj-native repos (non-git-backed) in a future version? | Open | Deferred to post-v1.0. Requires solving remote push (no git remote) and PR creation (no GitHub integration without git). |
