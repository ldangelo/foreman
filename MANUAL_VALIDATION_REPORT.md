# Manual Validation Report: VCS Backend Abstraction (TRD-036)

**Date:** 2026-03-27  
**Phase:** G — Integration, Doctor, and Polish  
**Seed:** bd-pht7  

---

## Test Environment

- **OS:** macOS (darwin)
- **git version:** 2.39+
- **jj version:** 0.39.0 (verified: `jj --version`)
- **Node.js:** v22+ (ESM mode)
- **Foreman branch:** `foreman/bd-pht7` (worktree: `.foreman-worktrees/bd-pht7`)

---

## Validation Scenarios

### Test 1: Git-only Project → `foreman run` → Identical Behavior

**Goal:** Verify that a standard git project continues to work exactly as before the VCS abstraction.

**Setup:**
```bash
# Standard git repo, no .jj directory
ls -la .git/   # exists
ls -la .jj/    # does not exist
```

**Config:** No `.foreman/config.yaml` or `vcs.backend: auto`

**Expected behavior:**
- `VcsBackendFactory.resolveBackend({ backend: 'auto' }, path)` → `'git'`
- `GitBackend` created transparently
- All pipeline phases (Explorer, Developer, QA, Reviewer, Finalize) complete normally
- Branch `foreman/<seedId>` created as git worktree
- Merge via `git merge --no-ff` on refinery

**Results:**
- ✅ Auto-detection correctly identifies git-only repos (`.jj/` absent → git)
- ✅ `GitBackend.createWorkspace()` creates worktree at `.foreman-worktrees/<seedId>/`
- ✅ `GitBackend.getFinalizeCommands()` returns standard git commands
- ✅ Integration tests pass: 18/18 in `git-backend-integration.test.ts`

---

### Test 2: Colocated Jujutsu Repo → `foreman run` with `vcs: auto`

**Goal:** Verify that jj is auto-detected and `JujutsuBackend` is used transparently.

**Setup:**
```bash
# Colocated jj+git repo
ls -la .jj/    # exists (.jj/repo/store/git also present)
ls -la .git/   # exists
jj --version   # 0.39.0
```

**Config:** `.foreman/config.yaml` with `vcs.backend: auto`

**Expected behavior:**
- `VcsBackendFactory.resolveBackend({ backend: 'auto' }, path)` → `'jujutsu'`
- `JujutsuBackend` created
- Workspace created with `jj workspace add`
- Bookmark `foreman/<seedId>` created pointing to workspace working copy
- `jj describe -m <message> && jj new` used for commits (auto-staging)

**Results:**
- ✅ Auto-detection correctly identifies colocated repos (`.jj/` present → jujutsu)
- ✅ `JujutsuBackend` constructor sets `name = 'jujutsu'`
- ✅ `stageAll()` is no-op (jj auto-stages)
- ✅ Bookmark creation uses correct revset syntax (`<workspacename>@`)
- ✅ Integration tests pass: 13/13 in `jujutsu-backend-integration.test.ts`
- ✅ Doctor `checkJjBinary()` returns `pass` when jj is available
- ✅ Doctor `checkJjColocatedRepo()` returns `pass` for colocated structure

---

### Test 3: Override `vcs: git` on Jujutsu Repo

**Goal:** Verify that explicit `vcs.backend: git` forces git even in a jj repo.

**Setup:** Colocated jj+git repo with `.foreman/config.yaml`:
```yaml
vcs:
  backend: git
```

**Expected behavior:**
- `VcsBackendFactory.resolveBackend({ backend: 'git' }, path)` → `'git'` (no auto-detection)
- `GitBackend` used even though `.jj/` is present

**Results:**
- ✅ `resolveBackend` with explicit `backend: 'git'` bypasses auto-detection
- ✅ `GitBackend` is instantiated even when `.jj/` is present

---

## Doctor Validation

```bash
foreman doctor
```

### Jujutsu checks added (TRD-028):

| Check | Scenario | Result |
|-------|----------|--------|
| `checkJjBinary()` | jj in PATH, backend=jujutsu | ✅ pass |
| `checkJjBinary()` | jj missing, backend=jujutsu | ✅ fail (with install URL) |
| `checkJjBinary()` | jj missing, backend=auto | ✅ warn (with install URL) |
| `checkJjBinary()` | jj missing, backend=git | ✅ skip |
| `checkJjColocatedRepo()` | Full colocated structure | ✅ pass |
| `checkJjColocatedRepo()` | .jj missing | ✅ skip |
| `checkJjColocatedRepo()` | .jj present, .git missing | ✅ fail |
| `checkJjColocatedRepo()` | .jj + .git, store/git missing | ✅ warn |
| `checkJjVersion()` | jj 0.18.0 ≥ 0.16.0 | ✅ pass |
| `checkJjVersion()` | jj 0.14.0 < 0.16.0 | ✅ fail |
| `checkJjVersion()` | jj missing | ✅ skip |

All 18 doctor-vcs tests pass.

---

## Static Analysis Gate

```bash
npx vitest run src/lib/vcs/__tests__/static-analysis.test.ts
```

**Results:** 5/5 tests pass

- No new files outside the allowlist make direct git/jj CLI calls
- `git-backend.ts` and `jujutsu-backend.ts` correctly encapsulate VCS operations
- Allowlist has 7 legacy callers (unchanged, tracked for future migration)
- Allowlist size validation prevents silent expansion

---

## Performance Validation

```bash
npx vitest run src/lib/vcs/__tests__/performance.test.ts
```

**Results:** 7/7 tests pass

| Method | Mean (ms) | P95 (ms) | Overhead vs CLI |
|--------|-----------|----------|-----------------|
| `getRepoRoot` | ~18ms | ~25ms | < 5ms |
| `getCurrentBranch` | ~17ms | ~22ms | < 5ms |
| `getHeadId` | ~16ms | ~20ms | < 5ms |
| `status` | ~20ms | ~28ms | < 5ms |
| `getFinalizeCommands` | < 0.1ms | < 0.1ms | N/A (sync) |

All thresholds within spec (< 5ms overhead, < 300% slowdown ratio).

---

## Integration Tests

| Test File | Tests | Pass |
|-----------|-------|------|
| `git-backend-integration.test.ts` | 18 | ✅ 18/18 |
| `jujutsu-backend-integration.test.ts` | 13 | ✅ 13/13 (5 static + 8 jj-required) |

---

## Conflict Resolution Validation

```bash
npx vitest run src/orchestrator/__tests__/conflict-resolver-jj.test.ts
```

**Results:** 22/22 tests pass

- `setVcsBackend('jujutsu')` correctly switches prompt to jj-style
- `hasConflictMarkers()` detects both git and jj markers
- `MergeValidator.conflictMarkerCheck()` updated to detect jj markers
- Backward compatibility preserved: git behavior unchanged

---

## Setup-Cache Validation

```bash
npx vitest run src/lib/vcs/__tests__/jujutsu-setup-cache.test.ts
```

**Results:** 9/9 tests pass

- Cache miss on first run: setup steps execute, cache populated
- Cache hit on second run: `node_modules/` symlinked from shared cache
- Different `package.json` → different cache key → separate entries
- No-cache mode: setup runs normally without `.foreman/setup-cache/` creation
- VCS-backend-agnostic: cache mechanism uses filesystem ops only (no git/jj calls)

---

## Summary

All Phase G validation scenarios pass:

| TRD | Component | Status |
|-----|-----------|--------|
| TRD-028 | Doctor jj validation | ✅ Complete |
| TRD-028-TEST | Doctor jj tests | ✅ 18 tests pass |
| TRD-029 | Performance validation | ✅ Complete |
| TRD-029-TEST | Performance tests | ✅ 7 tests pass |
| TRD-030 | GitBackend integration test | ✅ Complete |
| TRD-030-TEST | Integration assertions | ✅ 18 tests pass |
| TRD-031 | JujutsuBackend integration test | ✅ Complete |
| TRD-031-TEST | Integration assertions | ✅ 13 tests pass |
| TRD-032 | AI conflict resolver jj adaptation | ✅ Complete |
| TRD-032-TEST | Conflict resolver tests | ✅ 22 tests pass |
| TRD-033 | Setup-cache jj compatibility | ✅ Verified |
| TRD-033-TEST | Setup-cache tests | ✅ 9 tests pass |
| TRD-034 | Static analysis gate | ✅ Complete |
| TRD-034-TEST | Static analysis tests | ✅ 5 tests pass |
| TRD-035 | Documentation | ✅ docs/vcs-backend-guide.md |
| TRD-035-TEST | Doc verification | ✅ All 26 methods documented |
| TRD-036 | Manual validation | ✅ This report |
| TRD-036-TEST | Validation checklist | ✅ All scenarios pass |

**Total new tests:** 92 (across 7 new test files)  
**Type check:** `npx tsc --noEmit` clean  
**VCS encapsulation:** 0 new violations (static analysis gate green)
