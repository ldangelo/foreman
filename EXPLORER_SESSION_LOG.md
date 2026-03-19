# Session Log: Explorer Phase

**Date:** 2026-03-19
**Task ID:** bd-vrst
**Phase:** Explorer
**Agent:** Claude (Explorer)
**Status:** ✅ Complete

## Objective
Understand and document the codebase to enable implementation of a fix for the `checkOrphanedWorktrees()` function that incorrectly flags SDK-based agent runs as zombies.

## Key Finding
The `checkOrphanedWorktrees()` function at lines 234-251 in `src/orchestrator/doctor.ts` contains a zombie detection check that:
1. Calls `extractPid(activeRun.session_key)` to get a process ID
2. Uses `isProcessAlive(pid)` to check if the process is alive
3. **Problem:** For SDK-based runs, `session_key` format is `foreman:sdk:<model>:<uuid>`, which has no PID
4. **Result:** `extractPid()` returns null, `isProcessAlive(null)` returns false, run is incorrectly marked as zombie

Meanwhile, the separate `checkZombieRuns()` function (lines 384-396) correctly handles this case using an `isSDKBasedRun()` guard that was already implemented in the codebase.

## Work Completed

### 1. Codebase Analysis
- ✅ Located primary file: `src/orchestrator/doctor.ts` (1161 lines)
- ✅ Identified problematic code: lines 234-251 in `checkOrphanedWorktrees()`
- ✅ Found existing correct pattern: lines 384-396 in `checkZombieRuns()`
- ✅ Located utility functions: `isSDKBasedRun()` (lines 41-43), `extractPid()` (lines 28-32), `isProcessAlive()` (lines 19-26)

### 2. Dependencies Mapped
- ✅ Store interface: `src/lib/store.ts` (Run type, lines 18-31)
- ✅ Types: `src/orchestrator/types.ts` (CheckResult, CheckStatus, DoctorReport)
- ✅ Git operations: `src/orchestrator/lib/git.js` (listWorktrees, removeWorktree, branchExistsOnOrigin)
- ✅ Archive: `src/orchestrator/lib/archive-reports.js`

### 3. Test Coverage Analysis
**doctor-worktrees.test.ts:** 13 comprehensive tests, but missing SDK-based run scenarios
- ✅ Tests for active running runs with valid PID (line 87)
- ✅ Tests for active pending runs (line 104)
- ✅ Tests for various run states (completed, merged, failed, stuck, conflict, test-failed)
- ❌ **Missing:** Tests for SDK-based running runs with `foreman:sdk:*` session keys

**doctor.test.ts:** 11 comprehensive tests, WITH SDK-based run scenarios (lines 179-245)
- ✅ Test SDK run without tmux_session (line 179)
- ✅ Test SDK run with session suffix (line 196)
- ✅ Test SDK run with tmux_session (line 213)
- ✅ Test SDK run with fix=true (verifies NOT fixed) (line 232)
- ✅ Test mixed SDK and traditional zombie runs (line 247)

### 4. Patterns Identified
- **Session Key Formats:** Traditional `pid-<number>` vs. SDK `foreman:sdk:<model>:<uuid>[:<suffix>]`
- **Doctor Check Pattern:** Analyze → Report with CheckResult → Optional fix/dryRun
- **Liveness Strategy:** PID-based for traditional runs, tmux/timeout for SDK runs
- **Related Checks:** checkGhostRuns(), checkZombieRuns(), checkStalePendingRuns() work together

### 5. Documentation Created
- ✅ EXPLORER_REPORT.md (detailed technical report for Developer phase)
- ✅ EXPLORER_SESSION_LOG.md (this file)

## Technical Details Discovered

### Session Key Formats
```
Traditional: "pid-12345"
SDK:         "foreman:sdk:claude-sonnet-4-6:run-uuid"
SDK+suffix:  "foreman:sdk:claude-sonnet-4-6:run-uuid:session-abc123"
```

### Key Functions
**extractPid()** (lines 28-32):
```typescript
function extractPid(sessionKey: string | null): number | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/pid-(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}
// Returns null for SDK sessions (no "pid-" pattern found)
```

**isSDKBasedRun()** (lines 41-43) — Already exists, just needs to be used in checkOrphanedWorktrees:
```typescript
function isSDKBasedRun(sessionKey: string | null): boolean {
  return sessionKey?.startsWith("foreman:sdk:") ?? false;
}
```

## Files Examined
1. `TASK.md` — Task description and requirements
2. `src/orchestrator/doctor.ts` — Main doctor class with all check methods
3. `src/lib/store.ts` — Run interface definition
4. `src/orchestrator/types.ts` — CheckResult, DoctorReport types
5. `src/orchestrator/__tests__/doctor-worktrees.test.ts` — Tests for checkOrphanedWorktrees
6. `src/orchestrator/__tests__/doctor.test.ts` — Tests for checkZombieRuns (includes SDK patterns)

## Implementation Path for Developer

The fix is a straightforward code change:
1. Add `if (isSDKBasedRun(activeRun.session_key))` guard at line 235
2. Return "pass" status for SDK runs (no PID check needed)
3. Keep existing PID-based logic in else branch
4. Add test cases to verify SDK runs are handled correctly

**Estimated effort:** Low — single guard clause, pattern already exists in checkZombieRuns

## Artifacts Created
- ✅ EXPLORER_REPORT.md — 400+ line technical report with code snippets, test analysis, architecture patterns, and validation checklist
- ✅ EXPLORER_SESSION_LOG.md — This file, documenting the exploration process

## Status
**✅ Phase Complete**
All exploration objectives met. The codebase is well-understood, and a clear, actionable implementation path has been documented in EXPLORER_REPORT.md for the Developer phase.
