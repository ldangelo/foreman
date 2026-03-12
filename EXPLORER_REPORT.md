# Explorer Report: Health monitoring: doctor command with auto-fix

## Summary
The doctor command (`src/cli/commands/doctor.ts`) provides comprehensive health monitoring for the Foreman orchestrator with existing auto-fix capabilities via the `--fix` flag. The codebase has supporting infrastructure (Store, Monitor, git utilities) that can be leveraged for enhanced health checks and recovery.

## Relevant Files

### Core Implementation
- **src/cli/commands/doctor.ts** (609 lines)
  - Implements `doctorCommand` with health checks and auto-fix logic
  - Checks: SD binary, Git binary, Git repo, database file, project registration, seeds initialization, orphaned worktrees, zombie runs, stale pending runs, failed/stuck runs, blocked seeds
  - Auto-fixes (with `--fix` flag): orphaned/merged worktrees, zombie runs, stale pending runs
  - Outputs results in human-readable format or JSON (--json flag)
  - Status states: "pass", "warn", "fail", "fixed"

### Supporting Infrastructure
- **src/orchestrator/monitor.ts** (160 lines)
  - `Monitor` class: checks active runs, detects completion/stuck state
  - `recoverStuck()` method: recovers stuck runs with max retry limit (default 3)
  - Uses Store to update run status and log events
  - Already integrates with `monitor` command

- **src/lib/store.ts** (509 lines)
  - `ForemanStore` class: SQLite database for projects, runs, costs, events
  - Key methods: `getRunsByStatus()`, `updateRun()`, `logEvent()`, `getRunEvents()`
  - Tracks run status: pending, running, completed, failed, stuck, merged, conflict, test-failed, pr-created
  - Event types: dispatch, claim, complete, fail, merge, stuck, restart, recover, conflict, test-fail, pr-created

- **src/lib/git.ts** (150+ lines)
  - Worktree management: `createWorktree()`, `removeWorktree()`, `deleteBranch()`, `listWorktrees()`
  - Branch operations and git integration
  - Helper: `extractPid()` from session_key (format: `pid-<number>`)

- **src/cli/commands/monitor.ts** (107 lines)
  - CLI command wrapping the Monitor class
  - Options: `--recover` (auto-recover stuck agents), `--timeout` (stuck detection timeout)
  - Displays active/completed/stuck/failed runs

### CLI Integration
- **src/cli/index.ts** (36 lines)
  - Registers `doctorCommand` with the Commander.js program

### Testing
- **src/orchestrator/__tests__/monitor.test.ts** (134 lines)
  - Unit tests for Monitor class
  - Uses vitest with mocking of store/seeds dependencies
  - Tests: checkAll(), recoverStuck(), event logging
  - Pattern: create mock objects, inject into Monitor, verify behavior

- **src/cli/__tests__/commands.test.ts** (118 lines)
  - CLI smoke tests using tsx and execFile
  - Tests general commands (--help, --version, etc.)
  - Currently no doctor command tests

## Architecture & Patterns

### Health Check Pattern
Each check in doctor.ts follows this pattern:
```typescript
async function checkX(): Promise<CheckResult | CheckResult[]> {
  // Validation logic
  return {
    name: string,
    status: CheckStatus ("pass" | "warn" | "fail" | "fixed"),
    message: string,
    fixApplied?: string  // Only set when fix is applied
  };
}
```

### Auto-Fix Pattern
- Checks that can auto-fix accept a `fix: boolean` parameter
- When `fix` is true, immediately apply the fix and return status "fixed"
- When `fix` is false, return status "warn" with instruction message
- Example: `checkOrphanedWorktrees()` removes merged/orphaned worktrees

### Error Handling
- Try-catch blocks with graceful degradation
- Error messages extracted from exceptions
- Non-critical failures don't block other checks (e.g., git worktree prune)

### Logging & Events
- Monitor class logs all status transitions via `store.logEvent()`
- Event details include seedId, error messages, elapsed time, retry counts
- Events indexed by project_id and run_id

### Naming Conventions
- Command file: lowercase with hyphens (doctor.ts, monitor.ts)
- Type definitions: PascalCase with Result suffix (CheckResult, MonitorReport)
- Private functions: camelCase, start with check/is/extract prefixes
- Constants: SCREAMING_SNAKE_CASE (none currently in doctor.ts)

## Dependencies

### doctor.ts imports:
- Commander: CLI framework
- Chalk: colored terminal output
- Node.js builtins: fs, path, os, child_process, util
- Local: ForemanStore, git utilities (getRepoRoot, listWorktrees, removeWorktree)

### Monitor.ts dependencies:
- Store: database operations
- SeedsClient: seed/issue information
- Git utilities: worktree management

### Store.ts dependencies:
- better-sqlite3: database
- Node.js: fs, path, os, crypto

## Existing Tests

### Monitor Tests (monitor.test.ts)
- Tests checkAll() with various run states (completed, stuck, active, failed)
- Tests recoverStuck() with retry limits
- Tests event logging on status changes
- Mocking pattern: vitest.fn() for store/seeds methods

### CLI Tests (commands.test.ts)
- Smoke tests for --help, --version, other commands
- No doctor-specific tests currently
- Uses tsx to run CLI and captures stdout/stderr/exitCode

### Store Tests (store-metrics.test.ts)
- Database operations tests

## Recommended Approach

### Phase 1: Enhance doctor command with orchestrator integration
1. **Create Doctor class** (src/orchestrator/doctor.ts) similar to Monitor class
   - Move check logic into isolated, reusable methods
   - Each check returns CheckResult[] (supporting multiple results like worktrees)
   - Integrate with Store and SeedsClient for better data access
   - Public methods: `checkSystem()`, `checkRepository()`, `checkDataIntegrity()`
   - Public method: `fixAll()` to apply all available fixes

2. **Refactor doctor command** to use Doctor class
   - Simplified CLI implementation
   - Cleaner separation of concerns
   - Easier to test and extend

### Phase 2: Add new health checks
1. **Seed consistency checks**
   - Check for seeds with missing/invalid types
   - Verify seed hierarchy integrity (parent/child relationships)

2. **Database integrity checks**
   - Validate foreign key constraints
   - Check for orphaned records (runs without projects, events without runs)
   - Verify data completeness (all required fields populated)

3. **Worktree health checks**
   - Verify worktree branches match seed IDs
   - Check disk space for worktree directories
   - Validate worktree Git configuration

4. **Run state consistency**
   - Detect impossible state transitions
   - Check for runs with completed_at but status != completed
   - Verify progress field matches run status

### Phase 3: Enhance auto-fix capabilities
1. **Data repair fixes**
   - Auto-fix inconsistent run states
   - Repair orphaned database records (with confirmation)
   - Fix malformed seed IDs or properties

2. **Selective fixing**
   - Add `--fix-category` option to fix specific categories
   - Add `--dry-run` option (already common pattern in reset.ts)
   - Add confirmation prompts for destructive operations

### Phase 4: Testing
1. **Unit tests** (src/orchestrator/__tests__/doctor.test.ts)
   - Test each check method with mocked Store/SeedsClient
   - Test fix methods with transactional rollback
   - Test error handling and edge cases

2. **Integration tests** (src/cli/__tests__/doctor.test.ts)
   - Test `foreman doctor` command with temp repos
   - Test `--fix`, `--json` flags
   - Test exit codes (0 for pass/fixed, 1 for fail)

3. **Test utilities**
   - Helper to create mock projects/runs/seeds
   - Temporary database/git setup for integration tests
   - Pattern already used in commands.test.ts

## Key Files to Modify
1. Create: **src/orchestrator/doctor.ts** (new Doctor class, ~400 lines)
2. Modify: **src/cli/commands/doctor.ts** (refactor to use Doctor class, ~150 lines)
3. Create: **src/orchestrator/__tests__/doctor.test.ts** (unit tests, ~200 lines)
4. Modify: **src/cli/__tests__/commands.test.ts** (add doctor tests, +30 lines)
5. Modify: **src/cli/index.ts** (no changes needed)

## Potential Pitfalls & Edge Cases

1. **Transaction safety**: Auto-fixes modify database and filesystem — should be wrapped in transactions or have dry-run support
2. **Process kills**: `process.kill(pid, 0)` only works for processes the user owns — test with different user contexts
3. **Git operations**: Concurrent worktree operations can fail — add retry logic with exponential backoff
4. **Circular dependencies**: Orphaned worktree check iterates all worktrees — could be slow with many seeds
5. **Performance**: Doctor checks can take 30+ seconds with slow git/database — add progress reporting
6. **Stale data**: Monitor class queries seeds API synchronously — consider batching or caching
7. **Seed API failures**: Some checks depend on external `sd` CLI — need graceful fallback

## Design Decisions to Confirm
1. Should Doctor class be similar to Monitor (separate orchestrator concern) or integrated into doctor command?
2. Should fixes be transactional with rollback on error, or progressive with individual error handling?
3. Should there be a `--verbose` flag to show detailed check output?
4. Should failed checks exit with code 1, or only actual failures (not warnings)?
