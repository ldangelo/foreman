# Jujutsu (jj) Considerations

> **Audience:** Teams adopting Jujutsu as their VCS, or operators setting up a Foreman project on a jj repository.

[Jujutsu](https://martinvonz.github.io/jj/) is a next-generation VCS designed to be more ergonomic than git. Foreman supports jj via the `JujutsuBackend` and is actively migrating toward full **non-colocated jj** support. Colocated mode still works, but it is no longer the only intended deployment model.

This guide covers:
- Repository modes, setup, and migration status
- Workspace vs worktree semantics
- Bookmarks vs branches (terminology)
- Conflict handling differences
- How the Finalize phase changes
- Migration path from git
- Health checks with `foreman doctor`
- Known limitations

---

## Workspace Modes

Foreman can encounter jj repositories in either colocated or non-colocated mode:

```
project/
├── .jj/     ← Jujutsu metadata
├── .git/    ← Git metadata (still present)
└── src/
```

### Why Colocated Still Matters

- Git-based CI/CD tools (GitHub Actions, `gh` CLI, `git push`) continue to work unchanged.
- Foreman's refinery uses `git` commands for some operations that are not yet abstracted (stash, rebase-onto, merge strategies).
- Some older Foreman paths and external tooling still assume git interoperability.

### Initializing a Colocated Repo

```bash
# New project
mkdir myproject && cd myproject
jj git init --colocate

# Existing git project
cd myproject
jj git init --git-repo .    # Wraps the existing .git/ dir
```

### Verifying Workspace Mode

```bash
ls -la | grep -E "\.jj|\.git"
# Should show both .jj and .git

foreman doctor
# ✓ reports whether the repo is colocated or non-colocated
```

---

## Workspaces vs Worktrees

Foreman creates isolated environments for each task. In git these are **worktrees**; in jj they are **workspaces**. The `VcsBackend` interface unifies them as "workspaces".

| Concept | Git command | Jujutsu command |
|---------|------------|----------------|
| Create workspace | `git worktree add -b foreman/<id> <path> <base>` | `jj workspace add <path>` |
| Remove workspace | `git worktree remove --force <path>` | `jj workspace forget <name>` |
| List workspaces | `git worktree list` | `jj workspace list` |

**Location:** Both backends now place workspaces in Foreman's external workspace root by default (for example `../.foreman-worktrees/<repo-name>/<seedId>`), so parent-repo state writes do not dirty active workspaces.

**Branch naming:** The foreman branch/bookmark is always named `foreman/<seedId>` on both backends.

---

## Bookmarks vs Branches

Jujutsu uses the term **"bookmark"** for what git calls a **"branch"**. The `VcsBackend` interface uses `branchName` throughout for API consistency — the implementations translate to the appropriate jj bookmark commands internally.

| Operation | Git | Jujutsu |
|-----------|-----|--------|
| Create | `git checkout -b foreman/abc` | `jj bookmark create foreman/abc` |
| Switch | `git checkout foreman/abc` | `jj bookmark set foreman/abc -r @ && jj new foreman/abc` |
| Delete | `git branch -d foreman/abc` | `jj bookmark delete foreman/abc` |
| Push | `git push -u origin foreman/abc` | `jj git push --bookmark foreman/abc --allow-new` |
| List remote | `git branch -r` | `jj bookmark list --all` |

**Important:** `--allow-new` is required on the first push of a new jj bookmark. The `push()` method passes `options.allowNew: true` automatically when appropriate.

---

## Staging Differences

Git requires an explicit `git add -A` to stage changes before committing. Jujutsu tracks all changes automatically — there is no staging area.

| Operation | Git | Jujutsu |
|-----------|-----|--------|
| `stageAll()` | `git add -A` | No-op |
| `getFinalizeCommands().stageCommand` | `'git add -A'` | `''` (empty string) |

The Finalize agent's prompt includes `{{vcsStageCommand}}` which is either `git add -A` or an empty string. The prompt handles both cases without needing an `if` branch.

---

## Commit Differences

Jujutsu's commit model is different from git:

- In jj, you are **always working on a changeset** (the "working-copy commit").
- `jj describe -m "..."` sets the description (commit message) of the current changeset.
- `jj new` creates a new empty changeset, effectively "finalizing" the current one.
- There is no separate `git add` + `git commit` two-step.

| Operation | Git | Jujutsu |
|-----------|-----|--------|
| `commit(path, msg)` | `git commit -m "msg"` | `jj describe -m "msg" && jj new` |

---

## Push Differences

| Operation | Git | Jujutsu |
|-----------|-----|--------|
| First push | `git push -u origin foreman/abc` | `jj git push --bookmark foreman/abc --allow-new` |
| Subsequent push | `git push origin foreman/abc` | `jj git push --bookmark foreman/abc` |

The `PushOptions.allowNew` field controls the `--allow-new` flag. The JujutsuBackend passes this automatically for new bookmarks.

---

## Rebase Differences

Git's rebase is interactive and blocks on conflicts. Jujutsu's rebase is **non-blocking** — conflicts are recorded in-tree as conflict markers and the rebase completes immediately.

| Behavior | Git | Jujutsu |
|----------|-----|--------|
| Conflict handling | Blocks with `CONFLICT` message; requires `--continue` or `--abort` | Records conflicts in tree; operation completes |
| Detect conflicts | `git diff --name-only --diff-filter=U` | `jj resolve --list` |
| Continue rebase | `git rebase --continue` (after resolving) | Not needed — edit files, run `jj resolve --all` |
| Abort rebase | `git rebase --abort` | `jj abandon` on the conflict commit |

### Impact on Foreman Pipeline

The Finalize prompt includes `{{vcsRebaseCommand}}`:
- **Git:** `git rebase origin/dev` — may halt on conflicts requiring human intervention
- **Jujutsu:** `jj rebase -d origin/dev` — always completes; check `jj resolve --list` after

The `rebase()` method's `RebaseResult.hasConflicts` flag is set after the rebase completes (not before). The pipeline executor checks this and triggers conflict resolution if needed.

---

## Finalize Phase Command Differences

The `getFinalizeCommands()` method returns backend-specific commands that the Finalize agent uses verbatim. Here is a side-by-side comparison:

| Command | Git | Jujutsu |
|---------|-----|--------|
| `stageCommand` | `git add -A` | _(empty — auto-staged)_ |
| `commitCommand` | `git commit -m "feat: ..."` | `jj describe -m "feat: ..." && jj new` |
| `pushCommand` | `git push -u origin foreman/bd-abc1` | `jj git push --bookmark foreman/bd-abc1 --allow-new` |
| `rebaseCommand` | `git rebase origin/dev` | `jj rebase -d origin/dev` |
| `branchVerifyCommand` | `git branch -r \| grep foreman/bd-abc1` | `jj bookmark list --all \| grep foreman/bd-abc1` |
| `cleanCommand` | `git clean -fd` | `jj restore && jj abandon --ignore-immutable` |

---

## Reviewer Prompt Awareness

The Reviewer agent receives VCS context through prompt template variables:

| Variable | Git | Jujutsu |
|----------|-----|--------|
| `{{vcsBackendName}}` | `git` | `jujutsu` |
| `{{vcsBranchPrefix}}` | `foreman/` | `foreman/` |

Reviewers can use `{{vcsBackendName}}` to tailor feedback (e.g., noting that a diff uses jj-style change IDs rather than git SHA hashes).

---

## Migration: Enabling jj on an Existing Foreman Project

1. **Install jj** (>= 0.21.0 recommended):
   ```bash
   brew install jj      # macOS
   # or: https://martinvonz.github.io/jj/latest/install-and-setup
   ```

2. **Wrap existing git repo with jj**:
   ```bash
   cd /path/to/project
   jj git init --git-repo .
   ls -la   # should show both .jj and .git
   ```

3. **Update `.foreman/config.yaml`**:
   ```yaml
   vcs:
     backend: jujutsu
     jujutsu:
       minVersion: "0.21.0"
   ```

4. **Run doctor** to verify:
   ```bash
   foreman doctor
   # ✓ jj 0.24.0 >= 0.21.0 (required)
   # ✓ colocated repo detected (.jj/ + .git/ present)
   ```

5. **Clean up any existing worktrees** (they were created as git worktrees):
   ```bash
   foreman worktree clean
   ```

6. **Test with a smoke workflow**:
   ```bash
   br create --title "jj migration test" --type task --priority 3
   br update <id> --set-labels "workflow:smoke"
   foreman run
   ```

---

## `foreman doctor` Checks for Jujutsu

When a jujutsu backend is configured (or auto-detected), `foreman doctor` runs these additional checks:

| Check | Pass | Warn / Fail |
|-------|------|-------------|
| `jj` binary on PATH | ✓ jj 0.24.0 found | ✗ jj not found in PATH |
| Minimum version | ✓ 0.24.0 >= 0.21.0 | ⚠ 0.18.0 below minimum 0.21.0 |
| Repository mode | ✓ .jj/ and .git/ both present (colocated) | ⚠ Only .jj/ found (non-colocated; supported, but verify legacy flows) |
| Bookmark support | ✓ jj bookmark list OK | ✗ jj bookmark command failed |

To run only VCS checks:

```bash
foreman doctor --check vcs
```

---

## Known Limitations

| Limitation | Details | Workaround |
|-----------|---------|-----------|
| Legacy merge helpers still exist | A few advanced merge flows are still more git-oriented than the core jj-native path | Prefer jj-native finalize/merge flows and verify complex conflict scenarios |
| No stash support | `VcsBackend` has no stash/unstash | Git backends use `gitSpecial()`; jj backends should keep workspaces clean instead |
| Merge strategies | `VcsBackend.merge()` has no `-X theirs` equivalent | Prefer backend-native resolution; some complex merge strategies still use git-only helpers |
| Change ID vs commit hash | `getHeadId()` returns change ID, not commit hash | Use `resolveRef()` for commit hash if needed |
| Operation log | jj records an operation log; no API to query it | Access via `jj op log` manually |
| Non-linear history | jj supports more complex history shapes; Foreman assumes linear branches | Design beads to avoid complex merge topologies |

---

## Performance Notes

Jujutsu's workspace creation is slightly slower than `git worktree add` because `jj workspace add` initializes workspace-specific state. In practice this is not significant for Foreman's pipeline cadence (~5 seconds per workspace creation).

---

## Related Documentation

- [VCS Configuration Guide](./vcs-configuration.md) — How to configure the jj backend
- [VcsBackend Interface Reference](./vcs-backend-interface.md) — Full method reference
- [Workflow YAML Reference](../workflow-yaml-reference.md) — Workflow-level VCS config
- [Jujutsu Documentation](https://martinvonz.github.io/jj/latest/) — Official jj docs
