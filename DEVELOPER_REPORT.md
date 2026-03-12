# Developer Report: Task groups for batch coordination

## Approach

This iteration addressed four issues flagged in the previous review, all of which
were `[NOTE]`-level items. The core data model, GroupManager, CLI commands, and
store methods were already implemented in a prior pass. The focus here was:

1. **Wire `checkGroups()` into the monitor and run commands** — the most impactful
   fix, ensuring auto-close of task groups fires during normal `foreman run` and
   `foreman monitor` usage.
2. **Fix duplicate group ID in `group create` output** — minor UX fix.
3. **Document the silent-failure behavior** in `group-manager.ts` for seed fetch
   errors (deleted seeds will never auto-close their group).

## Files Changed

- **src/cli/commands/monitor.ts** — Added `await monitor.checkGroups()` call
  immediately after `checkAll()`. Auto-closed groups are displayed in their own
  "Auto-closed groups" section with group name, ID, and parent seed ID (if any).
  The "No active runs found" message now also requires no closed groups, so it
  doesn't appear when only groups were processed.

- **src/cli/commands/run.ts** — Imported `Monitor` and created an instance
  alongside the `Dispatcher`. In the watch loop, after `watchRunsInk` returns
  (i.e. a batch completes), `monitor.checkGroups()` is called to trigger any
  pending group auto-close. A brief summary line is printed if any groups closed.

- **src/cli/commands/group.ts** — Fixed the `group create` success line to print
  the group **name** (not ID) inline: `✓ Created group <name>`. The machine-
  readable `Group ID: <id>` line at the end is preserved for shell scripting.

- **src/orchestrator/group-manager.ts** — Added an explanatory comment in the
  `checkAndAutoClose` catch block documenting the safety-default behavior and its
  implication: groups with deleted member seeds will never auto-close in v1.

## Tests Added/Modified

- **src/orchestrator/__tests__/monitor.test.ts** — Extended the mock `store`
  object with `listActiveGroups`, `getGroupMembers`, and `updateGroup` (needed by
  `GroupManager` used inside `Monitor.checkGroups`). Also extended `seeds` mock
  with `close`. Added a `describe("checkGroups")` block with two tests:
  - Returns an empty array when no active groups exist.
  - Delegates to `GroupManager.checkAllGroups` and returns the list of groups
    that were auto-closed when all members are done.

## Decisions & Trade-offs

- **`checkGroups()` call placement in `monitor.ts`**: Called after `checkAll` but
  before printing, so the output is grouped — runs first, then groups. This keeps
  the display coherent.

- **`checkGroups()` call placement in `run.ts`**: Called after `watchRunsInk`
  (inside the watch loop only). In `--no-watch` mode there is nothing to trigger
  on, which is correct — groups only auto-close when tasks are observed to finish.

- **No project-scoping in `run.ts` `checkGroups()` call**: The call uses no
  `projectId` argument, which means it checks all active groups across all
  projects. This matches the existing `monitor.checkAll()` behaviour (which also
  checks all projects by default). Both can be scoped per-project via the optional
  `projectId` parameter if needed in future.

## Known Limitations

- **Groups with deleted member seeds never auto-close** (documented in
  `group-manager.ts`). This is the safe default for v1; a future enhancement could
  add a `foreman group remove <group-id> <seed-id>` command to manually remove
  stale members.
- **`name` and `parent_seed_id` are immutable after creation** (`updateGroup` only
  permits `status` and `completed_at`). Acceptable for v1.
- **No event logging for group auto-close** in the store's `events` table. The
  group status update itself is the record of truth. Adding `logEvent` calls could
  improve audit trails in a future iteration.
