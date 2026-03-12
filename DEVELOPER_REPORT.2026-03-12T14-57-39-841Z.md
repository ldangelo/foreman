# Developer Report: Task groups for batch coordination

## Approach

Implemented task groups as a foreman-native coordination primitive stored in SQLite (not in Seeds). Groups track a set of seed IDs and optionally reference a parent seed to auto-close when all members complete. The implementation follows the five-phase plan from EXPLORER_REPORT.md:

1. **Data model** — two new SQLite tables with idempotent migrations
2. **GroupManager** — core logic for auto-close detection and status reporting
3. **CLI commands** — `group create`, `group add`, `group status`
4. **CLI registration** — plugged into the main `foreman` program
5. **Monitor integration** — `checkGroups()` method on Monitor delegates to GroupManager

## Files Changed

- **src/lib/store.ts** — Added `TaskGroup` and `TaskGroupMember` interfaces; added `task_groups` and `task_group_members` tables to both `SCHEMA` (for fresh installs) and `MIGRATIONS` array (for existing databases); added 7 new store methods: `createGroup`, `getGroup`, `updateGroup`, `listGroupsByProject`, `listActiveGroups`, `addGroupMember`, `getGroupMembers`.

- **src/orchestrator/group-manager.ts** *(new)* — `GroupManager` class with three public methods:
  - `checkAndAutoClose(group)` — polls all member seed statuses; if all done, marks group completed and optionally closes parent seed
  - `getGroupStatus(groupId)` — returns full status including per-member seed status and progress %
  - `checkAllGroups(projectId?)` — iterates active groups and auto-closes any that are done

- **src/cli/commands/group.ts** *(new)* — Three Commander.js subcommands:
  - `foreman group create <name> [--parent <seed-id>]` — creates group, prints group ID for scripting
  - `foreman group add <group-id> <seed-ids...>` — adds one or more seeds to a group (idempotent)
  - `foreman group status [group-id]` — shows detailed status for one group, or lists all groups for the project

- **src/cli/index.ts** — Added `groupCommand` import and registration after `statusCommand`.

- **src/orchestrator/monitor.ts** — Added `GroupManager` import and a new `checkGroups(projectId?)` method that callers (e.g., `run.ts`, `monitor.ts` command) can invoke alongside `checkAll()` to trigger auto-close detection.

## Tests Added/Modified

- **src/lib/__tests__/store.test.ts** — Added 6 new tests in a `"task groups"` describe block covering: create/retrieve, null for missing, idempotent member adds, project-filtered listing, active-only listing, and status update.

- **src/orchestrator/__tests__/group-manager.test.ts** *(new)* — 8 tests across three describe blocks:
  - `checkAndAutoClose`: empty group returns false; partial done returns false; all done auto-closes; parent seed is closed on completion; already-completed group is skipped
  - `getGroupStatus`: null for missing group; correct progress percentages
  - `checkAllGroups`: only fully-done groups are closed in a batch

All 244 pre-existing tests continue to pass. New tests: 14 (8 group-manager + 6 store).

## Decisions & Trade-offs

- **Groups are foreman-only** — They live purely in SQLite, not in Seeds. This avoids polluting the Seeds dependency graph with coordination metadata.
- **Idempotent member adds** — `addGroupMember` uses `INSERT OR IGNORE` so calling it twice for the same seed is safe (no error, no duplicate).
- **Monitor integration is opt-in** — Added `checkGroups()` as a separate method on Monitor rather than auto-calling it inside `checkAll()`. This lets callers decide when to run group checks and avoids surprises in existing flows. Callers that want automatic group closing should call both `checkAll()` and `checkGroups()`.
- **Graceful error handling in auto-close** — If a member seed cannot be fetched, it's treated as "not done" (safe default). If the parent seed close fails (already closed, not found), it's silently swallowed so the group still marks itself completed.
- **No breaking changes** — All existing commands, migrations, and interfaces are untouched.

## Known Limitations

- **Monitor not wired automatically** — `checkGroups()` is available on Monitor but is not called automatically from `run.ts` or the `monitor` command. A follow-up task should wire it into the dispatch loop.
- **No group-of-groups** — Flat structure only; nested groups are out of scope for v1.
- **Stale re-open** — If a member seed is manually re-opened after the group closes, the group stays closed (by design — point-in-time snapshot).
- **No CLI `group list`** — `foreman group status` (with no args) lists groups, but there's no dedicated `list` subcommand. Could be added later for alias ergonomics.
