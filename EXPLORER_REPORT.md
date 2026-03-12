# Explorer Report: Task groups for batch coordination

## Task Summary

Implement task groups (batch coordination primitives) that auto-close when all member tasks complete. This enables workflows like: decompose creates an epic with 10 tasks → a task group tracks the batch → epic auto-closes when all children finish.

**Key distinction**: Task groups are coordination primitives, NOT dependency constraints. They differ from parent-child deps which are organizational only.

**Required commands**:
- `foreman group create <name>` — create a new task group
- `foreman group status [group-id]` — show group status and member tasks
- `foreman group add <group-id> <seed-id>` — add task(s) to a group

## Relevant Files

### Core CLI & Command Structure
- **src/cli/index.ts** — CLI entry point, command registration. Currently has 11 commands (init, plan, decompose, run, status, merge, pr, monitor, reset, attach, doctor). Need to add `groupCommand`.
- **src/cli/commands/run.ts** (lines 1-162) — Shows dispatch loop and batch iteration pattern. Demonstrates watching runs and handling completion. Key pattern: dispatcher.dispatch() returns DispatchResult with dispatched/skipped/resumed tasks.
- **src/cli/commands/status.ts** (lines 1-185) — Shows how to query seeds status via `sd list`, `sd ready`, `sd blocked` commands. Demonstrates fetching data from both Seeds CLI and SQLite store.
- **src/cli/commands/decompose.ts** (lines 1-88) — Shows epic creation pattern where a parent epic is created, then sprints/stories/tasks are created with parent relationships.

### Storage & Data Models
- **src/lib/store.ts** (lines 1-300+) — SQLite store for foreman runtime state. Currently has tables for:
  - `projects` — registered projects
  - `runs` — agent execution records (seed_id, status, session_key, worktree_path, etc.)
  - `costs` — token usage tracking
  - `events` — audit log of dispatch/complete/fail/stuck events

  **Key patterns**:
  - Uses better-sqlite3 with migrations array (line 133-136)
  - Methods: createRun(), updateRun(), getRun(), getActiveRuns(), getRunsByStatus()
  - Status values: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created"
  - Each run has project_id, seed_id, agent_type, session_key, worktree_path, timestamps (created_at, started_at, completed_at)
  - Events logged for dispatch, complete, fail, stuck, restart, recover, etc.

- **src/lib/seeds.ts** (lines 1-256) — Wrapper around the `sd` (seeds) CLI. Key methods:
  - `create(title, opts)` — creates a new seed with type, priority, parent, description, labels
  - `close(id, reason)` — closes a seed
  - `list()`, `ready()`, `show()`, `update()` — query/modify seeds
  - `addDependency(childId, parentId)` — declare task dependency
  - `getGraph(epicId)` — fetch seed hierarchy graph
  - Does NOT store data locally; all state in Seeds database

### Orchestration & Monitoring
- **src/orchestrator/monitor.ts** (lines 1-100+) — Monitors active runs and updates store status. Key behaviors:
  - `checkAll()` — iterates active runs, checks if seed is "closed" or "completed" (line 39-40)
  - When seed is closed, sets run status to "completed" and logs "complete" event
  - Detects stuck agents after timeout (default 15 minutes)
  - Pattern: seeds.show(run.seed_id) → check status → update store accordingly

- **src/orchestrator/dispatcher.ts** (lines 1-692) — Dispatches ready seeds to agents. Key patterns:
  - `dispatch()` — queries ready seeds, creates worktrees, writes TASK.md, records runs, spawns agents
  - Returns DispatchResult with dispatched/skipped/resumed tasks
  - Seeds marked "in_progress" before agent spawns (line 146)
  - Runs created in store (line 129) with status "pending", then transitioned to "running" after agent spawn (line 165)

- **src/orchestrator/planner.ts** (lines 1-100+) — Executes decomposition plans. Creates hierarchy:
  - Epic seed (line 62-66)
  - Sprints with parent=epicSeed.id (line 77-83)
  - Stories with parent=sprintSeed.id (line 87-93)
  - Tasks with parent=storySeed.id and labels for semantic type preservation (line 96-100)
  - Uses `toSeedsType()` to map internal types to valid sd types:
    - sprint → "feature" + label "kind:sprint"
    - story → "feature" + label "kind:story"
    - spike → "chore" + label "kind:spike"
    - test → "task" + label "kind:test"

### Type Definitions
- **src/orchestrator/types.ts** — Defines:
  - `DispatchedTask`, `SkippedTask`, `ResumedTask` (lines 56-86)
  - `Run` interface (from store) with status enum
  - No existing task group types

## Architecture & Patterns

### 1. CLI Command Pattern
All commands use Commander.js with `.action()` handler. Pattern:
```typescript
export const groupCommand = new Command("group")
  .description("Manage task groups for batch coordination")
  .addCommand(groupCreateCommand)
  .addCommand(groupStatusCommand)
  .addCommand(groupAddCommand);
```

Each subcommand (create, status, add) is a separate Command with `.action()`.

### 2. Seeds Integration Pattern
Direct CLI wrapping via execSd():
- All seed queries/mutations go through SeedsClient methods
- Seeds client methods call execSd() which spawns `sd` binary with `--json` flag
- Results unwrapped via unwrapSdResponse() helper (lines 55-69)

**Task groups cannot store data in Seeds** — they're foreman-specific concepts. Must use SQLite store instead.

### 3. Store Pattern
SQLite-based single instance:
```typescript
const store = new ForemanStore();
// Uses ~/.foreman/foreman.db by default
// SCHEMA defines tables + MIGRATIONS for schema changes
// Methods: createRun(), updateRun(), getActiveRuns(), logEvent(), etc.
```

### 4. Dispatching & Monitoring Loop
From run.ts (lines 92-153):
```typescript
while (true) {
  const result = await dispatcher.dispatch({ maxAgents, ... });
  if (result.dispatched.length === 0) break;  // done
  if (watch) {
    await watchRunsInk(store, runIds);  // block until batch completes
    continue;  // loop to next batch
  }
}
```

Pattern: dispatch batch → watch until done → check for more work

### 5. Auto-Close Pattern
From monitor.ts (lines 39-52): Detects seed completion by polling Seeds status:
```typescript
const seedDetail = await this.seeds.show(run.seed_id);
if (seedDetail.status === "closed" || seedDetail.status === "completed") {
  this.store.updateRun(run.id, {
    status: "completed",
    completed_at: new Date().toISOString(),
  });
  this.store.logEvent(..., "complete", ...);
}
```

**Auto-close pattern needed for task groups**:
- Check if all group members are closed/completed
- If yes, close the parent seed and log completion

## Dependencies & Relationships

### Task Group Dependencies (New)
```
task_groups table:
  - id (UUID)
  - project_id (FK → projects.id)
  - name (string) — user-friendly name
  - parent_seed_id (string) — the epic/container to auto-close
  - status ("active" | "completed" | "failed")
  - created_at, updated_at, completed_at (timestamps)

task_group_members table:
  - id (UUID)
  - group_id (FK → task_groups.id)
  - seed_id (string) — member task
  - created_at
```

### What depends on task groups
- **Decompose command** — after creating epic+tasks, could optionally create a group
- **Monitor command** — needs to check group status and trigger auto-close
- **Status command** — should show group status alongside seed status

### What task groups depends on
- **Store** — SQLite for persistence
- **Seeds** — for parent seed close/update
- **Monitor** — to detect when members are done and trigger auto-close

## Existing Tests

Found test files across the codebase:
- **src/orchestrator/__tests__/dispatcher.test.ts** — Tests Dispatcher.selectModel() for model selection
- **src/orchestrator/__tests__/monitor.test.ts** — Tests Monitor.checkAll() logic (likely)
- **src/lib/__tests__/store.test.ts** — Tests ForemanStore methods
- **src/lib/__tests__/seeds.test.ts** — Tests SeedsClient (mocking sd CLI)
- **src/cli/__tests__/commands.test.ts** — Tests CLI commands

No existing group tests — will need to create new test file.

## Recommended Approach

### Phase 1: Data Model (Store)
1. Add `task_groups` and `task_group_members` tables to schema (src/lib/store.ts SCHEMA)
2. Create migration for schema addition (MIGRATIONS array)
3. Implement ForemanStore methods:
   - `createGroup(projectId, name, parentSeedId)` → Group
   - `updateGroup(id, updates)` → void
   - `getGroup(id)` → Group | null
   - `getGroupMembers(groupId)` → GroupMember[]
   - `addGroupMember(groupId, seedId)` → void
   - `listGroupsByProject(projectId)` → Group[]

### Phase 2: Core Group Logic
4. Create src/orchestrator/group-manager.ts with GroupManager class:
   - `createGroup(seeds, store, projectId, name, parentSeedId)` → Group
   - `addMembers(groupId, seedIds)` → void
   - `checkAndAutoClose(group)` → Promise<boolean> — returns true if group auto-closed
     - Query all members' status from seeds
     - If all closed, close parent seed and update group status to "completed"
     - Log event to store
   - `getGroupStatus(groupId)` → object with name, parent, members, status, progress

### Phase 3: CLI Commands (src/cli/commands/group.ts)
5. Create group command with three subcommands:
   - `foreman group create <name> [--parent <seed-id>]`
     - Creates group, optionally links to parent seed (epic)
     - Returns group-id for shell scripting
   - `foreman group status <group-id>`
     - Shows group members, their statuses, progress
     - Shows if auto-close is pending
   - `foreman group add <group-id> <seed-id>...`
     - Adds one or more seeds to group
     - Can be called multiple times or with multiple args

### Phase 4: Integration
6. Register group command in src/cli/index.ts (add after status command, before merge)
7. Integrate with monitor.ts:
   - In Monitor.checkAll(), after checking individual runs, also check all active groups
   - Call groupManager.checkAndAutoClose() for each group
   - Log auto-close event to store

### Phase 5: Tests
8. Create src/cli/__tests__/group.test.ts:
   - Test group create/add/status commands
   - Test auto-close detection logic
   - Mock SeedsClient and ForemanStore

## Potential Pitfalls & Edge Cases

1. **Race Conditions**: If multiple agents finish simultaneously, could double-trigger auto-close. Solution: Use atomic update with status check.

2. **Parent Seed Not Found**: Group references parent_seed_id but parent might not exist. Handle gracefully in status/auto-close.

3. **Group Without Parent**: Can create groups without a parent seed (for pure coordination). Auto-close just marks group completed, doesn't close anything in Seeds.

4. **Nested Groups**: Current design doesn't support groups of groups. Keep flat for v1.

5. **Circular Dependencies**: Could theoretically create a group whose members include the parent seed. Detect and prevent in addGroupMember().

6. **Stale Group Closure**: If a member seed is manually re-opened after group closes, group stays closed. This is acceptable — groups are point-in-time snapshots.

7. **Concurrent Monitor Checks**: Monitor runs periodically and could check same group twice in parallel. Use database transactions/locking to prevent double auto-close.

## Key Implementation Notes

- **No Breaking Changes**: Task groups are purely additive; existing decompose/run/merge flows work unchanged.
- **Idempotent Adds**: Adding same seed to group twice should be safe (upsert pattern).
- **Seed Integration**: Unlike parent-child deps which Seeds understands, groups are foreman-only. Cannot use Seeds parent field — must track in store.
- **Monitoring**: Hook into existing Monitor.checkAll() loop (called from run/monitor commands) for auto-close detection.
- **Labels Preservation**: Groups can use seed labels for metadata (e.g., `group:batch-123`) if needed for cross-referencing.
