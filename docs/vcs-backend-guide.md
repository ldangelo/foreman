# VCS Backend Guide

> **Reference for TRD-2026-004 — VCS Backend Abstraction Layer**
>
> Phase G completion documentation.

---

## Overview

Foreman supports multiple VCS backends through a unified `VcsBackend` interface. All orchestration code (Dispatcher, Refinery, Finalize agent) is decoupled from the concrete VCS tool — the backend is selected at startup from configuration or auto-detected from the repository contents.

**Supported backends:**

| Backend | Name | Repository type |
|---------|------|----------------|
| `GitBackend` | `git` | Standard git repositories |
| `JujutsuBackend` | `jujutsu` | Colocated Jujutsu+Git repositories (`.jj/` + `.git/`) |

---

## Quick Start

### Automatic detection (recommended)

Set `vcs.backend: auto` in `.foreman/config.yaml` (or omit — this is the default):

```yaml
# .foreman/config.yaml
vcs:
  backend: auto
```

Auto-detection checks for the presence of `.jj/` in the project root:
- `.jj/` exists → `JujutsuBackend`
- `.jj/` absent → `GitBackend`

### Explicit git

```yaml
# .foreman/config.yaml
vcs:
  backend: git
```

### Explicit jujutsu

```yaml
# .foreman/config.yaml
vcs:
  backend: jujutsu
  jujutsu:
    minVersion: "0.16.0"  # optional minimum version check
```

---

## VcsBackend Interface

All 26 methods are `async`, returning Promises. Error messages follow the pattern:
`"<backend> <command> failed: <stderr>"`
(e.g. `"git rev-parse failed: fatal: not a git repository"`)

### Repository Introspection

| Method | Description |
|--------|-------------|
| `getRepoRoot(path)` | Find the root of the VCS repository containing `path` |
| `getMainRepoRoot(path)` | Find the main repo root (traverses worktrees to common-dir) |
| `detectDefaultBranch(repoPath)` | Detect the default/trunk branch (main, master, dev…) |
| `getCurrentBranch(repoPath)` | Get the currently checked-out branch or bookmark name |

### Branch / Bookmark Operations

| Method | Description |
|--------|-------------|
| `checkoutBranch(repoPath, branchName)` | Checkout a branch or bookmark |
| `branchExists(repoPath, branchName)` | Returns true if the branch/bookmark exists locally |
| `branchExistsOnRemote(repoPath, branchName)` | Returns true if the branch/bookmark exists on origin |
| `deleteBranch(repoPath, branchName, options?)` | Delete a local branch/bookmark |

### Workspace / Worktree Operations

| Method | Description |
|--------|-------------|
| `createWorkspace(repoPath, seedId, baseBranch?)` | Create a new workspace for a seed |
| `removeWorkspace(repoPath, workspacePath)` | Remove a workspace and clean up metadata |
| `listWorkspaces(repoPath)` | List all workspaces for the repository |

**Workspace convention:**
- Location: `<repoPath>/.foreman-worktrees/<seedId>/`
- Branch name: `foreman/<seedId>` (both backends)

### Staging and Commit Operations

| Method | Description |
|--------|-------------|
| `stageAll(workspacePath)` | Stage all changes (no-op for jj — auto-staged) |
| `commit(workspacePath, message)` | Commit staged changes |
| `push(workspacePath, branchName, options?)` | Push to remote origin |
| `pull(workspacePath, branchName)` | Pull/fast-forward from remote |

### Rebase and Merge Operations

| Method | Description |
|--------|-------------|
| `rebase(workspacePath, onto)` | Rebase the workspace onto a target branch |
| `abortRebase(workspacePath)` | Abort an in-progress rebase |
| `merge(repoPath, sourceBranch, targetBranch?)` | Merge a source branch into a target branch |

### Diff, Status and Conflict Detection

| Method | Description |
|--------|-------------|
| `getHeadId(workspacePath)` | Get the current HEAD commit hash or jj change ID |
| `fetch(repoPath)` | Fetch updates from the remote |
| `diff(repoPath, from, to)` | Get a unified diff between two refs |
| `getModifiedFiles(workspacePath)` | List modified files (staged or unstaged) |
| `getConflictingFiles(workspacePath)` | List files with merge/rebase conflicts |
| `status(workspacePath)` | Get working tree status (porcelain format) |
| `cleanWorkingTree(workspacePath)` | Discard unstaged changes and untracked files |

### Finalize Support

| Method | Description |
|--------|-------------|
| `getFinalizeCommands(vars)` | Returns pre-computed backend-specific finalize commands |

---

## GitBackend

**Location:** `src/lib/vcs/git-backend.ts`

The `GitBackend` wraps standard `git` CLI commands. It uses `execFile` (no shell interpolation) with a 10 MB buffer.

### Key behaviors

- **createWorkspace**: Creates a git worktree at `.foreman-worktrees/<seedId>/` with a new branch `foreman/<seedId>`. If the worktree already exists, it rebases onto the base branch.
- **merge**: Uses `git merge --no-ff`. Stashes unstaged changes before merge if present.
- **push**: Calls `git push -u origin <branchName>`. Use `PushOptions.force` for force-push.
- **stageAll**: Calls `git add -A`.
- **commit**: Calls `git commit -m <message>`.

### Finalize commands (Git)

```
stageCommand:         "git add -A"
commitCommand:        "git commit -m '<title> (<seedId>)'"
pushCommand:          "git push -u origin foreman/<seedId>"
rebaseCommand:        "git fetch origin && git rebase origin/<baseBranch>"
branchVerifyCommand:  "git ls-remote --heads origin foreman/<seedId>"
cleanCommand:         "git worktree remove <worktreePath> --force"
```

---

## JujutsuBackend

**Location:** `src/lib/vcs/jujutsu-backend.ts`

The `JujutsuBackend` wraps `jj` CLI commands and supports **colocated** Jujutsu+Git repositories only (both `.jj/` and `.git/` must be present).

### Colocated repo requirement

Foreman requires colocated repos because:
- GitHub Actions, `gh` CLI, and other git tooling continue to work.
- `git push` and `git fetch` work alongside `jj` operations.
- Branches (jj "bookmarks") are visible to git consumers.

Initialize with:
```bash
jj git init --colocate
```

### Key behaviors

- **createWorkspace**: Creates a jj workspace with `jj workspace add`. The parent directory `.foreman-worktrees/` is created automatically. A bookmark `foreman/<seedId>` is created pointing to the new workspace's working copy.
- **stageAll**: No-op — jj auto-stages all changes.
- **commit**: Calls `jj describe -m <message>` followed by `jj new` (to advance the working copy).
- **merge**: Uses `jj new <base> <source> --message 'Merge...'`.
- **push**: Calls `jj git push --bookmark foreman/<seedId>`. Uses `--allow-new` for first push.
- **getCurrentBranch**: Returns the current workspace's bookmark via `jj log`.

### Finalize commands (Jujutsu)

```
stageCommand:         ""  (no-op — auto-staged)
commitCommand:        "jj describe -m '<title> (<seedId>)' && jj new"
pushCommand:          "jj git push --bookmark foreman/<seedId>"
rebaseCommand:        "jj git fetch && jj rebase -d <baseBranch>"
branchVerifyCommand:  "jj bookmark list foreman/<seedId>"
cleanCommand:         "jj workspace forget foreman-<seedId>"
```

### Revset syntax

In jj revset notation, workspace working copies are referenced as `<workspacename>@`:
- `default@` — main workspace
- `foreman-bd-abc@` — workspace named `foreman-bd-abc`

This is different from earlier jj versions. The JujutsuBackend uses the correct syntax.

---

## VcsBackendFactory

**Location:** `src/lib/vcs/index.ts`

### Async creation (preferred)

```typescript
import { VcsBackendFactory } from './src/lib/vcs/index.js';

const backend = await VcsBackendFactory.create({ backend: 'auto' }, projectPath);
// or
const backend = await VcsBackendFactory.create({ backend: 'git' }, projectPath);
const backend = await VcsBackendFactory.create({ backend: 'jujutsu' }, projectPath);
```

### From environment variable

Agent workers reconstruct the backend from `FOREMAN_VCS_BACKEND`:

```typescript
const backend = await VcsBackendFactory.fromEnv(projectPath, process.env.FOREMAN_VCS_BACKEND);
```

### Auto-detection logic

```typescript
VcsBackendFactory.resolveBackend({ backend: 'auto' }, projectPath)
// → 'jujutsu' if .jj/ exists at projectPath
// → 'git' otherwise
```

---

## Conflict Resolution and VCS Backend

The `ConflictResolver` is backend-aware. When using `JujutsuBackend`, call `setVcsBackend('jujutsu')` to enable jj-specific behavior:

```typescript
const resolver = new ConflictResolver(projectPath, config);
resolver.setVcsBackend('jujutsu');
```

### Conflict marker formats

**Git-style (always detected):**
```
<<<<<<< HEAD
const b = 'main';
=======
const b = 'feature';
>>>>>>> feature/branch
```

**Jujutsu diff-style:**
```
<<<<<<< Conflict 1 of 1
%%%%%%% Changes from base to side #1
-const b = 'original';
+const b = 'side1';
+++++++ Contents of side #2
const b = 'side2';
>>>>>>>
```

Both formats are detected by `ConflictResolver.hasConflictMarkers()` and `MergeValidator.conflictMarkerCheck()`. The AI prompt in Tier 3 resolution describes the active format when `jujutsu` backend is set.

---

## Doctor Checks

Run `foreman doctor` to validate your VCS configuration:

```
foreman doctor
```

### Jujutsu-specific checks

| Check | Pass | Warn | Fail | Skip |
|-------|------|------|------|------|
| `jj binary` | jj found in PATH | jj missing + backend=auto | jj missing + backend=jujutsu | backend=git |
| `jj colocated repo` | .jj + .git + .jj/repo/store/git present | .jj/repo/store/git missing | .jj present but .git missing | .jj not found |
| `jj version` | version ≥ minVersion | version unparseable | version < minVersion | jj not installed |

To run jj validation programmatically:

```typescript
const doctor = new Doctor(store, projectPath);

const binaryResult = await doctor.checkJjBinary('auto');   // pass/warn/skip
const colocResult = await doctor.checkJjColocatedRepo();    // pass/warn/fail/skip
const versionResult = await doctor.checkJjVersion('0.16.0'); // pass/warn/fail/skip
```

---

## Setup Cache

The dependency cache (`setupCache` in workflow YAML) is **VCS-backend-agnostic**:

```yaml
# workflow.yaml
setupCache:
  key: package.json
  path: node_modules
```

How it works:
1. First workspace: hash `package.json` → compute cache key → run setup steps → move `node_modules/` to `.foreman/setup-cache/<hash>/node_modules/` → symlink back.
2. Subsequent workspaces with same `package.json`: cache hit → symlink directly. Setup steps are skipped.

Since jj workspaces use identical directory structure to git worktrees, the cache mechanism is transparent across backends.

---

## Static Analysis Gate

CI enforces that no new code calls `git` or `jj` CLI directly outside the designated backend files. The `src/lib/vcs/__tests__/static-analysis.test.ts` test will fail if a new file violates the encapsulation boundary.

**Allowed direct CLI callers:**

| File | Reason |
|------|--------|
| `src/lib/vcs/git-backend.ts` | Primary git backend |
| `src/lib/vcs/jujutsu-backend.ts` | Primary jj backend (also calls git for colocated ops) |
| `src/lib/git.ts` | Backward-compat shim (pending full migration) |
| `src/orchestrator/conflict-resolver.ts` | Legacy (pre-migration) |
| `src/orchestrator/refinery.ts` | Legacy (pre-migration) |
| `src/orchestrator/doctor.ts` | Git version/config checks |
| `src/orchestrator/agent-worker-finalize.ts` | Legacy finalize path |
| `src/orchestrator/agent-worker.ts` | Legacy diff detection |
| `src/orchestrator/merge-queue.ts` | Legacy branch verification |
| `src/orchestrator/sentinel.ts` | Legacy health checks |

---

## Implementing a Custom Backend

To add a new VCS backend (e.g. `mercurial`), implement the `VcsBackend` interface:

```typescript
// src/lib/vcs/mercurial-backend.ts
import type { VcsBackend } from './interface.js';

export class MercurialBackend implements VcsBackend {
  readonly name = 'mercurial' as const;

  constructor(readonly projectPath: string) {}

  async getRepoRoot(path: string): Promise<string> {
    // ... hg root
  }

  // ... implement all 26 interface methods
}
```

Then register in `VcsBackendFactory.create()` in `src/lib/vcs/index.ts`.

The `VcsConfig` type (`src/lib/vcs/types.ts`) would need a new `backend` option.

---

## Configuration Reference

### VcsConfig (from `src/lib/vcs/types.ts`)

```typescript
interface VcsConfig {
  backend: 'git' | 'jujutsu' | 'auto';
  git?: {
    useTown?: boolean;  // Use git-town for branch management. Default: true
  };
  jujutsu?: {
    minVersion?: string;  // e.g. "0.16.0" — validated by foreman doctor
  };
}
```

### Workflow-level VCS config (`.foreman/config.yaml`)

```yaml
vcs:
  backend: auto          # or: git | jujutsu

  # Git-specific options
  git:
    useTown: true        # use git-town for branch syncing

  # Jujutsu-specific options
  jujutsu:
    minVersion: "0.16.0"  # minimum jj version required
```

### Workflow YAML phase-level override

Individual phases can specify a model override but not a VCS override — the backend is project-wide:

```yaml
# .foreman/workflows/default.yaml
phases:
  - name: developer
    models:
      default: sonnet
      P0: opus
    # VCS backend is inherited from project config
```

---

## Performance Characteristics

Based on TRD-029 benchmarks (macOS, M-series, git 2.39+):

| Operation | Baseline (direct CLI) | VcsBackend overhead |
|-----------|----------------------|---------------------|
| `getRepoRoot` | ~15ms | < 5ms |
| `getCurrentBranch` | ~15ms | < 5ms |
| `getHeadId` | ~15ms | < 5ms |
| `status` | ~15ms | < 5ms |
| `getFinalizeCommands` | N/A (sync) | < 0.1ms per call |

The overhead comes from the TypeScript wrapper layer (Promise creation, argument validation), not from additional I/O.

---

## Migration from git.ts

If you have code that imports from `src/lib/git.ts`, consider migrating to the VCS abstraction:

```typescript
// Before (git.ts shim — still works):
import { getRepoRoot, getCurrentBranch } from '../lib/git.js';
const root = await getRepoRoot(path);

// After (VcsBackend — backend-agnostic):
import { VcsBackendFactory } from '../lib/vcs/index.js';
const backend = await VcsBackendFactory.create({ backend: 'auto' }, projectPath);
const root = await backend.getRepoRoot(path);
```

The `git.ts` shim remains for backward compatibility. New code should use `VcsBackend` directly.
