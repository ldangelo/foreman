---
name: jj
description: "Jujutsu (jj) — Git-compatible distributed VCS with undo and better branching. Use when: (1) managing code changes and commits, (2) creating or switching worktrees/branches (bookmarks), (3) rebasing or reorganizing commits, (4) reviewing git history, (5) any jj command appears in prompts, (6) user mentions jujutsu, bookmarks, or worktrees. Make sure to use this skill whenever the user mentions version control, branches, commits, git operations, or working with code changes — even if they don't explicitly say 'jj'."
---

# jj — Jujutsu Version Control

`jj` is a Git-compatible, Git-backed distributed VCS with first-class undo, better branching (bookmarks), and intelligent commit stacking. It stores history in the `.jj/` directory and can work with existing Git repos.

## When to Use

- Managing commits and changes (create, modify, split, squash)
- Working with branches (called "bookmarks" in jj)
- Rebasing and reorganizing commit history
- Reviewing repository state and history
- Creating worktrees for parallel development
- Any Git-like operation where jj's undo capability is valuable

## Key Differences from Git

| Git Concept | jj Equivalent | Notes |
|------------|--------------|-------|
| Branch | Bookmark | `jj bookmark` |
| `git commit` | `jj describe -m` + `jj new` | Or just `jj commit -m` |
| `git branch -d` | `jj bookmark delete` | Deletions sync to remote on push |
| Worktree | Workspace | `jj workspace` |
| Stash | Commits are undoable | No stash needed |

## Quick Reference

| Command | Purpose |
|---------|---------|
| `jj status` | Show working copy state |
| `jj log` | Show commit history |
| `jj new` | Create new commit |
| `jj commit` | Describe and commit (shorthand) |
| `jj bookmark` | Manage bookmarks (branches) |
| `jj rebase` | Move commits |
| `jj squash` | Combine commits |
| `jj split` | Split commits |
| `jj git push` | Push to remote |

## Essential Commands

### Repository State

```bash
# Show working copy state
jj status
jj st

# Show commit history
jj log
jj log -n 10                    # Last 10 commits
jj log --reversed               # Oldest first
jj log -G                       # Flat list (no graph)

# Show specific revision
jj show @
jj show main

# File diff
jj diff -r @-                  # Show working copy changes
jj diff -r main                # Diff from main
jj diff --summary              # Files changed only
```

### Creating and Editing Commits

```bash
# Create new empty commit (advances @)
jj new
jj new main                    # Create from main

# Describe current commit and create new one (shorthand)
jj commit -m "Add feature X"
jj ci -m "Fix bug Y"

# Edit commit description
jj describe -m "New description"
jj desc -m "Updated description"

# Show what changed in working copy
jj diff
```

### Bookmarks (Branches)

```bash
# List bookmarks
jj bookmark list
jj b list

# Create/update bookmark
jj bookmark set feature-x
jj b s my-feature

# Create bookmark at specific commit
jj bookmark set feature-x -r @-

# Rename bookmark
jj bookmark rename old-name new-name
jj b r old-name new-name

# Delete bookmark (syncs deletion to remote on push)
jj bookmark delete feature-x
jj b d feature-x

# Move bookmark to different commit
jj bookmark move feature-x -r main

# Track remote bookmark
jj bookmark track origin/main
jj b t origin/main
```

### Navigating History

```bash
# Move working copy to different commit
jj edit main
jj edit feature-x

# Go to parent commit
jj prev

# Go to child commit
jj next

# Abandon current change (like "undo" in other VCSs)
jj abandon

# Undo last operation (full undo of any command)
jj undo

# Redo undone operation
jj redo
```

### Rewriting History

```bash
# Rebase commits
jj rebase -s @ -o main                    # Move @ and children onto main
jj rebase -b feature-x -o main            # Rebase entire branch
jj rebase -r abc123 -o main               # Rebase single commit

# Insert commit after another
jj rebase -s mycommit -A main             # Insert after main

# Insert commit before another
jj rebase -s mycommit -B main            # Insert before main

# Squash commits (combine into parent)
jj squash                                  # Squash @ into parent
jj squash -r feature-x                    # Squash commit into parent

# Move changes from one commit to another
jj squash --from mycommit --into main

# Split commit (interactive)
jj split

# Split non-interactively
jj split file1 file2                     # Files go in first commit

# Duplicate commit
jj duplicate mycommit
```

### Absorb Changes

```bash
# Automatically move changes to appropriate commits
jj absorb
jj absorb --from @                        # Absorb from working copy
jj absorb file1 file2                     # Only specific files

# Absorb into specific destination
jj absorb -t main
```

### Git Interop

```bash
# Clone Git repo (creates jj repo backed by Git)
jj git clone https://github.com/user/repo

# Initialize jj repo in Git repo
jj git init

# Export jj changes to Git
jj git export

# Import Git changes into jj
jj git import

# Push to remote
jj git push
jj git push --branch feature-x
jj git push --all

# Fetch from remote
jj git fetch

# Remote management
jj git remote add origin https://github.com/user/repo
jj git remote list
```

### Workspaces (Like Git Worktrees)

```bash
# List workspaces
jj workspace list

# Add new workspace
jj workspace add ../workspace-name
jj workspace add ../backend -r main

# Update stale workspace
jj workspace update-stale

# Rename workspace
jj workspace rename new-name

# Forget workspace
jj workspace forget workspace-name
```

### Advanced History

```bash
# Show how a commit evolved
jj evolog mycommit

# Parallelize revisions (make siblings)
jj parallelize mycommit

# Resolve conflicts with external tool
jj resolve

# Restore files from another commit
jj restore -r main -- file.txt

# Revert a commit
jj revert mycommit
```

## Common Workflows

### Feature Development

```bash
# 1. Start from main
jj edit main

# 2. Create your feature commit
jj new
# ... make changes ...
jj describe -m "Implement feature X"

# 3. Add more commits to stack
# ... more changes ...
jj describe -m "Add tests for feature X"

# 4. Review the stack
jj log

# 5. Push when done
jj git push --branch my-feature
```

### Rebase onto Updated Main

```bash
# 1. Fetch latest
jj git fetch

# 2. Rebase your branch
jj rebase -b @ -o origin/main

# 3. Verify
jj log
```

### Fix Bug in Middle of Stack

```bash
# 1. Edit the commit with the bug
jj edit mycommit
# ... fix the bug ...
jj describe -m "Fix bug in feature"

# 2. Absorb changes to appropriate commits
jj absorb

# Or squash manually:
jj squash -r mycommit
```

### Undo Operations

```bash
# Undo the last operation (any command!)
jj undo

# Redo if needed
jj redo

# View operation history
jj op log
jj op log -n 20

# Go back to specific operation
jj --at-op abc123 status
```

## Revision (Revset) Syntax

```bash
# Common revisions
@                # Working copy
@ - 1            # Parent of working copy
@ - 2            # Grandparent
main              # Bookmark named main
origin/main       # Remote bookmark
-:               # Root commit
@+               # Working copy parent

# Revsets
:@               # All commits up to working copy
main..@           # Commits on current branch
::main            # Ancestors of main

# By description
jj log -r 'description(grep: fix)'
jj log -r 'file(path_pattern: src/**/*.ts)'
```

## Template Formatting

```bash
# Custom log format
jj log -T 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"'

# Show just the graph
jj log -T 'graph + " " ++ description.first_line()'

# Verbose format
jj log -T 'commit_id.short() ++ " " ++ author.username() ++ " " ++ timestamp.format("%Y-%m-%d") ++ "\n  " ++ description'
```

## Global Options

```bash
-R, --repository <path>      # Operate on specific repo
--ignore-working-copy        # Don't update working copy
--ignore-immutable           # Allow rewriting immutable commits
--at-operation <id>          # View at specific operation
--debug                     # Debug output
--color <when>             # When to colorize (auto, always, never)
--quiet                     # Suppress non-primary output
--no-pager                  # Disable pager
```

## Tips

- **`@` always points to working copy** — safe to reference
- **Commits are immutable by default** — use `jj rebase` or `jj undo` to modify
- **Descriptions can be changed** — no need for perfect commit messages upfront
- **Pushing syncs deletions** — `jj bookmark delete` marks deletion for sync
- **Workspaces > worktrees** — jj's workspace support is more flexible than Git worktrees
- **Full undo** — `jj undo` can undo ANY operation, not just commits
