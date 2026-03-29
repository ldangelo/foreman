# VcsBackend Interface Reference

> **Audience:** Platform engineers and contributors implementing a custom VCS backend for Foreman.

Foreman abstracts all version-control operations behind the `VcsBackend` interface so that the orchestration layer (Dispatcher, Refinery, Finalize, ConflictResolver) works with any compatible VCS. Two built-in implementations ship with Foreman: `GitBackend` and `JujutsuBackend`.

This guide covers:
- Why the interface exists
- Full method reference with parameters, return types, and behavior notes
- How to implement a custom backend
- Error handling conventions
- Testing patterns

---

## Why Abstract VCS?

Without abstraction, orchestration code contains branching logic like:

```ts
if (isJujutsu) {
  await execFile('jj', ['workspace', 'add', ...]);
} else {
  await execFile('git', ['worktree', 'add', ...]);
}
```

This scatters VCS knowledge throughout the codebase. `VcsBackend` collects all such decisions in one place:

```ts
// Dispatcher (VCS-agnostic)
const workspace = await vcs.createWorkspace(projectPath, seedId, baseBranch);
```

---

## Interface Location

```
src/lib/vcs/interface.ts   — VcsBackend interface definition
src/lib/vcs/types.ts       — All shared types (Workspace, MergeResult, etc.)
src/lib/vcs/index.ts       — Re-exports + VcsBackendFactory
src/lib/vcs/git-backend.ts — GitBackend implementation
src/lib/vcs/jujutsu-backend.ts — JujutsuBackend implementation
```

---

## Method Reference

All methods are `async` and return `Promise<T>`. Implementations **must not** swallow errors — throw with a descriptive message so callers can log and propagate.

### Identity

#### `name: 'git' | 'jujutsu'`

A readonly string identifying the backend. Used by the Dispatcher to set `FOREMAN_VCS_BACKEND` in worker environments.

```ts
console.log(vcs.name); // 'git' or 'jujutsu'
```

---

### Repository Introspection

#### `getRepoRoot(path: string): Promise<string>`

Returns the root directory of the VCS repository containing `path`.

| Backend | Equivalent |
|---------|-----------|
| Git | `git rev-parse --show-toplevel` |
| Jujutsu | `git rev-parse --show-toplevel` (colocated mode) |

For linked git worktrees, this returns the **worktree** root (not the main project root). Use `getMainRepoRoot()` to always get the primary project directory.

**Throws** if `path` is not inside a VCS repository.

---

#### `getMainRepoRoot(path: string): Promise<string>`

Returns the primary (main) repository root, traversing up from any worktree or workspace.

| Backend | Equivalent |
|---------|-----------|
| Git | Resolves `--git-common-dir`, strips trailing `/.git` |
| Jujutsu | Same git fallback in colocated mode |

Use this when you need the project root regardless of which worktree `path` lives in.

---

#### `detectDefaultBranch(repoPath: string): Promise<string>`

Detects the default trunk branch name (e.g. `main`, `master`, `dev`).

| Backend | Resolution order |
|---------|----------------|
| Git | git-town config → `origin/HEAD` symbolic ref → `main` → `master` |
| Jujutsu | `jj config get --repo trunk` → same git fallbacks |

**Returns** branch name as a string.

---

#### `getCurrentBranch(repoPath: string): Promise<string>`

Returns the name of the currently checked-out branch or bookmark.

| Backend | Equivalent |
|---------|-----------|
| Git | `git rev-parse --abbrev-ref HEAD` |
| Jujutsu | `jj bookmark list --revisions @` (current workspace bookmark) |

---

### Branch / Bookmark Operations

Jujutsu uses "bookmarks" internally, but the `VcsBackend` interface uses the term `branchName` uniformly for cross-backend consistency.

#### `checkoutBranch(repoPath: string, branchName: string): Promise<void>`

Switches the repository to the named branch or bookmark.

| Backend | Equivalent |
|---------|-----------|
| Git | `git checkout <branchName>` |
| Jujutsu | `jj bookmark set <branchName> -r @` + `jj new <branchName>` |

---

#### `branchExists(repoPath: string, branchName: string): Promise<boolean>`

Returns `true` if the branch/bookmark exists **locally**.

---

#### `branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean>`

Returns `true` if the branch/bookmark exists on the `origin` remote.

| Backend | Equivalent |
|---------|-----------|
| Git | `git ls-remote --heads origin <branchName>` |
| Jujutsu | `jj bookmark list --all` filtered for remote tracking refs |

---

#### `deleteBranch(repoPath, branchName, options?): Promise<DeleteBranchResult>`

Deletes a local branch or bookmark.

**Options (`DeleteBranchOptions`):**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `force` | boolean | `false` | Force-delete even if unmerged (`git branch -D` equivalent) |
| `targetBranch` | string | default branch | Branch to check merge status against |

**Returns (`DeleteBranchResult`):**

| Field | Description |
|-------|-------------|
| `deleted` | `true` if deletion succeeded |
| `wasFullyMerged` | `true` if branch was fully merged into `targetBranch` before deletion |

---

### Workspace / Worktree Operations

"Workspaces" map to git worktrees on git backends and `jj workspace` on Jujutsu.

#### `createWorkspace(repoPath, seedId, baseBranch?): Promise<WorkspaceResult>`

Creates an isolated workspace for a seed.

- **Branch name:** `foreman/<seedId>` (both backends)
- **Location:** `<repoPath>/.foreman-worktrees/<seedId>`

| Backend | Equivalent |
|---------|-----------|
| Git | `git worktree add -b foreman/<seedId> <path> <baseBranch>` |
| Jujutsu | `jj workspace add <path>` + `jj bookmark create foreman/<seedId>` |

**Returns (`WorkspaceResult`):**

```ts
interface WorkspaceResult {
  workspacePath: string;  // Absolute path to the created workspace
  branchName: string;     // 'foreman/<seedId>'
}
```

**Throws** if workspace creation fails (e.g. branch already exists and is in use).

---

#### `removeWorkspace(repoPath: string, workspacePath: string): Promise<void>`

Removes the workspace directory and cleans up associated VCS metadata.

| Backend | Equivalent |
|---------|-----------|
| Git | `git worktree remove --force <workspacePath>` |
| Jujutsu | `jj workspace forget <name>` + directory removal |

---

#### `listWorkspaces(repoPath: string): Promise<Workspace[]>`

Returns all workspaces for the repository.

**Returns (`Workspace[]`):**

```ts
interface Workspace {
  path: string;    // Absolute filesystem path
  branch: string;  // Branch/bookmark name
  head: string;    // Commit hash (git) or change ID (jj)
  bare: boolean;   // Always false for jj; may be true for git bare worktrees
}
```

---

### Staging and Commit Operations

#### `stageAll(workspacePath: string): Promise<void>`

Stages all changes in the workspace.

| Backend | Behavior |
|---------|---------|
| Git | `git add -A` |
| Jujutsu | No-op (jj auto-stages all changes) |

> **Note:** Even for jj, `getFinalizeCommands()` returns an empty string for `stageCommand` so the finalize prompt handles it gracefully without needing an `if` branch.

---

#### `commit(workspacePath: string, message: string): Promise<void>`

Commits staged changes with the given message.

| Backend | Equivalent |
|---------|-----------|
| Git | `git commit -m "<message>"` |
| Jujutsu | `jj describe -m "<message>"` + `jj new` |

---

#### `push(workspacePath, branchName, options?): Promise<void>`

Pushes the branch/bookmark to the `origin` remote.

**Options (`PushOptions`):**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `force` | boolean | `false` | Force-push (overwrite remote history) |
| `allowNew` | boolean | `false` | jj-specific: `--allow-new` for first push of new bookmarks |

| Backend | Equivalent |
|---------|-----------|
| Git | `git push -u origin <branchName>` |
| Jujutsu | `jj git push --bookmark <branchName> --allow-new` |

---

#### `pull(workspacePath: string, branchName: string): Promise<void>`

Fetches and fast-forwards the current branch from `origin`.

| Backend | Equivalent |
|---------|-----------|
| Git | `git pull origin <branchName> --ff-only` |
| Jujutsu | `jj git fetch` + `jj rebase -d origin/<branchName>` |

---

### Rebase and Merge Operations

#### `rebase(workspacePath: string, onto: string): Promise<RebaseResult>`

Rebases the workspace branch onto `onto`.

**Returns (`RebaseResult`):**

```ts
interface RebaseResult {
  success: boolean;
  hasConflicts: boolean;
  conflictingFiles?: string[];  // Present only when hasConflicts is true
}
```

| Backend | Equivalent |
|---------|-----------|
| Git | `git rebase origin/<onto>` |
| Jujutsu | `jj rebase -d origin/<onto>` |

> **Important:** Unlike git, jj records conflicts in-tree rather than halting with a merge block. `hasConflicts` will be true if any conflict markers exist in the working tree after the rebase.

---

#### `abortRebase(workspacePath: string): Promise<void>`

Aborts an in-progress rebase, returning the workspace to pre-rebase state.

| Backend | Equivalent |
|---------|-----------|
| Git | `git rebase --abort` |
| Jujutsu | `jj abandon` on the conflict commit |

---

#### `merge(repoPath, sourceBranch, targetBranch?): Promise<MergeResult>`

Merges `sourceBranch` into `targetBranch` (defaults to current branch).

**Returns (`MergeResult`):**

```ts
interface MergeResult {
  success: boolean;
  conflicts?: string[];  // Omitted when merge succeeds cleanly
}
```

---

### Diff, Status, and Conflict Detection

#### `getHeadId(workspacePath: string): Promise<string>`

Returns the current HEAD commit hash (git) or change ID (jj).

| Backend | Equivalent |
|---------|-----------|
| Git | `git rev-parse HEAD` |
| Jujutsu | `jj log -r @ --no-graph --template change_id` |

---

#### `resolveRef(repoPath: string, ref: string): Promise<string>`

Resolves an arbitrary ref to its commit hash.

| Backend | Equivalent |
|---------|-----------|
| Git | `git rev-parse <ref>` |
| Jujutsu | `jj log -r <ref> --no-graph --template commit_id` |

**Throws** if the ref does not exist.

---

#### `fetch(repoPath: string): Promise<void>`

Fetches from the remote without merging.

| Backend | Equivalent |
|---------|-----------|
| Git | `git fetch origin` |
| Jujutsu | `jj git fetch` |

---

#### `diff(repoPath, from, to): Promise<string>`

Returns a unified diff between two refs.

| Backend | Equivalent |
|---------|-----------|
| Git | `git diff <from>..<to>` |
| Jujutsu | `jj diff --revision <from>..<to>` |

---

#### `getChangedFiles(repoPath, from, to): Promise<string[]>`

Returns file paths changed between two refs (three-dot semantics).

| Backend | Equivalent |
|---------|-----------|
| Git | `git diff --name-only <from>...<to>` |
| Jujutsu | `jj diff --revision <from>..<to> --summary` |

Returns an empty array if no files changed or refs do not exist.

---

#### `getRefCommitTimestamp(repoPath, ref): Promise<number | null>`

Returns the Unix timestamp (seconds) of the most recent commit on `ref`.

| Backend | Equivalent |
|---------|-----------|
| Git | `git log -1 --format=%ct <ref>` |
| Jujutsu | `jj log -r <ref> --template committer.timestamp().utc().format('%s')` |

Returns `null` if the ref does not exist.

---

#### `getModifiedFiles(workspacePath: string): Promise<string[]>`

Lists files modified (staged or unstaged) in the workspace.

| Backend | Equivalent |
|---------|-----------|
| Git | `git status --porcelain` filtered for modified/staged |
| Jujutsu | `jj status` parsed for modified files |

---

#### `getConflictingFiles(workspacePath: string): Promise<string[]>`

Lists files with unresolved merge/rebase conflicts.

| Backend | Equivalent |
|---------|-----------|
| Git | `git diff --name-only --diff-filter=U` |
| Jujutsu | `jj resolve --list` (files with conflict markers) |

---

#### `status(workspacePath: string): Promise<string>`

Returns working tree status as a porcelain string (equivalent to `git status --porcelain`).

---

#### `cleanWorkingTree(workspacePath: string): Promise<void>`

Discards all unstaged changes and removes untracked files.

| Backend | Equivalent |
|---------|-----------|
| Git | `git clean -fd && git checkout -- .` |
| Jujutsu | `jj restore` + `jj abandon` of untracked changes |

---

### Finalize Support

#### `getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands`

Returns pre-computed shell commands for the Finalize agent prompt. This is the **only synchronous method** — it computes strings from the template vars without making any system calls.

**Input (`FinalizeTemplateVars`):**

```ts
interface FinalizeTemplateVars {
  seedId: string;       // e.g. 'bd-deoi'
  seedTitle: string;    // Human-readable title
  baseBranch: string;   // e.g. 'dev' or 'main'
  worktreePath: string; // Absolute path to the worktree
}
```

**Returns (`FinalizeCommands`):**

```ts
interface FinalizeCommands {
  stageCommand: string;         // e.g. 'git add -A'  (empty for jj)
  commitCommand: string;        // e.g. 'git commit -m "..."'
  pushCommand: string;          // e.g. 'git push -u origin foreman/bd-deoi'
  rebaseCommand: string;        // e.g. 'git rebase origin/dev'
  branchVerifyCommand: string;  // e.g. 'git branch -r | grep foreman/bd-deoi'
  cleanCommand: string;         // e.g. 'git clean -fd'
}
```

The Finalize prompt embeds these verbatim as `{{vcsStageCommand}}`, `{{vcsCommitCommand}}`, etc. so the agent never needs to know which backend is active.

---

## Implementing a Custom Backend

A custom backend must implement all methods of `VcsBackend`. The easiest way to start is to copy `git-backend.ts` and adapt individual methods.

### Minimal TypeScript Example

```ts
import type { VcsBackend } from './src/lib/vcs/interface.js';
import type {
  Workspace, WorkspaceResult, MergeResult, RebaseResult,
  DeleteBranchOptions, DeleteBranchResult, PushOptions,
  FinalizeTemplateVars, FinalizeCommands,
} from './src/lib/vcs/types.js';

export class MercurialBackend implements VcsBackend {
  readonly name = 'git' as const; // Use 'git' or 'jujutsu' — no custom names yet

  constructor(private readonly projectPath: string) {}

  async getRepoRoot(path: string): Promise<string> {
    // return root from `hg root`
    throw new Error('Not implemented');
  }

  async getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands {
    return {
      stageCommand: 'hg add',
      commitCommand: `hg commit -m "${vars.seedTitle}"`,
      pushCommand: 'hg push',
      rebaseCommand: `hg rebase -d ${vars.baseBranch}`,
      branchVerifyCommand: `hg branches | grep foreman/${vars.seedId}`,
      cleanCommand: 'hg revert --all && hg purge',
    };
  }

  // ... implement all other methods
}
```

> **Note:** The `name` field is currently typed as `'git' | 'jujutsu'`. To add a third backend name, update the type in `interface.ts` and the `VcsBackendFactory`.

---

## Error Handling Conventions

All VcsBackend implementations follow these conventions:

1. **Always throw, never return null** for methods that return a required value. Let callers handle errors.
2. **Error messages include the failed command:** `git rebase failed: CONFLICT (content): Merge conflict in src/foo.ts`
3. **Methods returning `false` or empty arrays** indicate absence/emptiness without throwing: `branchExists()` returns `false` for non-existent branches.
4. **Transient vs permanent errors:** The orchestrator treats all VcsBackend errors as potentially transient and will retry the pipeline phase on rate-limit failures.

---

## Testing Patterns

### Unit Tests with Mocks

```ts
import type { VcsBackend } from '../src/lib/vcs/interface.js';

const mockVcs: VcsBackend = {
  name: 'git',
  getRepoRoot: vi.fn().mockResolvedValue('/tmp/repo'),
  getMainRepoRoot: vi.fn().mockResolvedValue('/tmp/repo'),
  detectDefaultBranch: vi.fn().mockResolvedValue('main'),
  getCurrentBranch: vi.fn().mockResolvedValue('foreman/bd-abc1'),
  checkoutBranch: vi.fn().mockResolvedValue(undefined),
  branchExists: vi.fn().mockResolvedValue(true),
  branchExistsOnRemote: vi.fn().mockResolvedValue(false),
  deleteBranch: vi.fn().mockResolvedValue({ deleted: true, wasFullyMerged: true }),
  createWorkspace: vi.fn().mockResolvedValue({
    workspacePath: '/tmp/repo/.foreman-worktrees/bd-abc1',
    branchName: 'foreman/bd-abc1',
  }),
  removeWorkspace: vi.fn().mockResolvedValue(undefined),
  listWorkspaces: vi.fn().mockResolvedValue([]),
  stageAll: vi.fn().mockResolvedValue(undefined),
  commit: vi.fn().mockResolvedValue(undefined),
  push: vi.fn().mockResolvedValue(undefined),
  pull: vi.fn().mockResolvedValue(undefined),
  rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
  abortRebase: vi.fn().mockResolvedValue(undefined),
  merge: vi.fn().mockResolvedValue({ success: true }),
  getHeadId: vi.fn().mockResolvedValue('abc1234'),
  resolveRef: vi.fn().mockResolvedValue('abc1234'),
  fetch: vi.fn().mockResolvedValue(undefined),
  diff: vi.fn().mockResolvedValue(''),
  getChangedFiles: vi.fn().mockResolvedValue([]),
  getRefCommitTimestamp: vi.fn().mockResolvedValue(1700000000),
  getModifiedFiles: vi.fn().mockResolvedValue([]),
  getConflictingFiles: vi.fn().mockResolvedValue([]),
  status: vi.fn().mockResolvedValue(''),
  cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
  getFinalizeCommands: vi.fn().mockReturnValue({
    stageCommand: 'git add -A',
    commitCommand: 'git commit -m "test"',
    pushCommand: 'git push -u origin foreman/bd-abc1',
    rebaseCommand: 'git rebase origin/main',
    branchVerifyCommand: 'git branch -r | grep foreman/bd-abc1',
    cleanCommand: 'git clean -fd',
  }),
};
```

### Integration Tests

Integration tests for custom backends should:

1. Create a temp directory and initialize the VCS (`git init` / `jj git init --colocate`).
2. Run the VcsBackend method under test.
3. Verify the result by inspecting the VCS state directly (e.g. `git log --oneline`).
4. Clean up the temp directory in `afterEach`.

See `src/lib/vcs/__tests__/git-backend-integration.test.ts` for a complete example.

---

## Known Limitations

The `VcsBackend` interface deliberately omits some advanced git operations that are used only in the `Refinery` via a `gitSpecial()` helper:

| Operation | Reason not in interface |
|-----------|------------------------|
| `git stash push/pop` | No cross-backend stash concept |
| `git reset --hard` | Semantics differ significantly in jj |
| `git merge --abort` | No `abortMerge()` method yet |
| `git merge -X theirs` | VcsBackend.merge() has no strategy parameter |
| `git apply --index` | Patch application not yet abstracted |
| `git checkout --theirs <file>` | Per-file conflict resolution not yet abstracted |
| `git log --oneline` | No log iterator in VcsBackend |
| `git rebase --onto <from> <onto>` | Only simple rebase-onto supported |

If your backend requires these operations, add a `gitSpecial()`-equivalent helper in the backend class and leave a comment explaining why it bypasses the interface.

---

## Related Documentation

- [VCS Configuration Guide](./vcs-configuration.md) — How to configure git vs jujutsu
- [Jujutsu Considerations](./jujutsu-considerations.md) — Jujutsu-specific integration guide
- [Workflow YAML Reference](../workflow-yaml-reference.md) — `vcs:` block in workflow config
