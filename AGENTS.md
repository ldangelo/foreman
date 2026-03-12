# Agent Instructions

This project uses **sd** (seeds) for issue tracking. Seeds uses git-tracked JSONL files — no server required.

## Quick Reference

```bash
sd ready              # Find available work
sd show <id>          # View issue details
sd update <id> --claim  # Claim work atomically
sd close <id>         # Complete work
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Issue Tracking with sd (seeds)

**IMPORTANT**: This project uses **sd (seeds)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why seeds?

- Dependency-aware: Track blockers and relationships between issues
- Git-native: JSONL files committed to git, no server required
- Agent-optimized: JSON output, ready work detection
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
sd ready --json
```

**Create new issues:**

```bash
sd create --title "Issue title" --description "Detailed context" --type bug|feature|task --priority P1 --json
```

**Claim and update:**

```bash
sd update <id> --claim --json
sd update <id> --status in_progress --json
```

**Complete work:**

```bash
sd close <id> --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `P0` - Critical (security, data loss, broken builds)
- `P1` - High (major features, important bugs)
- `P2` - Medium (default, nice-to-have)
- `P3` - Low (polish, optimization)
- `P4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `sd ready` shows unblocked issues
2. **Claim your task atomically**: `sd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create a linked issue
5. **Complete**: `sd close <id> --reason "Done"`

### Important Rules

- Use sd for ALL task tracking
- Always use `--json` flag for programmatic use
- Check `sd ready` before asking "what should I work on?"
- Do NOT create markdown TODO lists
- Do NOT use external issue trackers
- Do NOT duplicate tracking systems

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
