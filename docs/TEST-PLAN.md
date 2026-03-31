# Foreman Test Plan

*Created: 2026-03-10*

## Current Coverage

| Layer | Files | Tests | Coverage |
|-------|-------|-------|----------|
| Store (SQLite) | `store.ts` | 15 ✅ | Good |
| Everything else | 20 files | 0 | ❌ None |

## Test Strategy

### Layer 1: Unit Tests (no external deps)
Pure logic, mocked dependencies. Fast, reliable.

### Layer 2: Integration Tests (local deps only)
Requires filesystem + git. No Dolt/Beads/Claude.

### Layer 3: E2E Tests (full stack)
Requires Dolt running, Beads CLI, optionally Claude. Manual or CI-gated.

---

## Layer 1: Unit Tests

### 1.1 TRD Parser (`src/orchestrator/trd-parser.ts`)
**File:** `src/orchestrator/__tests__/trd-parser.test.ts`

| # | Test | What to verify |
|---|------|---------------|
| 1 | Parses sprint sections (H3/H4) | Sprint numbers and titles extracted |
| 2 | Parses story sections | Stories under each sprint |
| 3 | Parses task table rows | Task ID, title, estimates, deps, files |
| 4 | Extracts explicit dependencies | Dep column → dependency list |
| 5 | Handles missing optional fields | Missing estimates/files handled gracefully |
| 6 | Sets epic from document header | First H1/H2 → epic.title |

### 1.2 Templates (`src/orchestrator/templates.ts`)
**File:** `src/orchestrator/__tests__/templates.test.ts`

| # | Test | What to verify |
|---|------|---------------|
| 1 | Worker AGENTS.md contains bead ID | Template includes `{{BEAD_ID}}` replacement |
| 2 | Worker AGENTS.md contains bd commands | Includes `bd update`, `bd close` |
| 3 | Worker AGENTS.md contains git push | Includes push to `foreman/<bead-id>` |
| 4 | Different runtimes produce valid output | claude-code, pi, codex all generate valid templates |

### 1.3 Dispatcher — Runtime Selection (`src/orchestrator/dispatcher.ts`)
**File:** `src/orchestrator/__tests__/dispatcher.test.ts`

| # | Test | What to verify |
|---|------|---------------|
| 1 | "test" in title → pi | selectRuntime({title: "Write tests for auth"}) === "pi" |
| 2 | "doc" in title → pi | selectRuntime({title: "Update API docs"}) === "pi" |
| 3 | "fix" in title → pi | selectRuntime({title: "Fix login bug"}) === "pi" |
| 4 | "refactor" in title → claude-code | selectRuntime({title: "Refactor auth module"}) === "claude-code" |
| 5 | "architect" in title → claude-code | selectRuntime({title: "Architect the data layer"}) === "claude-code" |
| 6 | Default → claude-code | selectRuntime({title: "Implement user registration"}) === "claude-code" |
| 7 | Case insensitive | selectRuntime({title: "FIX THE BUG"}) === "pi" |

### 1.4 Sling Executor (`src/orchestrator/sling-executor.ts`)
**File:** `src/orchestrator/__tests__/sling-executor.test.ts`

Mock SeedsClient + BeadsRustClient, verify:

| # | Test | What to verify |
|---|------|---------------|
| 1 | Creates epic in both trackers | sd.create + br.create called with type: "epic" |
| 2 | Creates tasks with parent ref | Both trackers receive parent IDs |
| 3 | Sets up explicit dependencies | Dep column values wired as blocks deps |
| 4 | Returns dual TrackerResult | SlingResult has sd + br fields |
| 5 | Handles empty task list | No child tasks created, only epic |

### 1.5 Monitor (`src/orchestrator/monitor.ts`)
**File:** `src/orchestrator/__tests__/monitor.test.ts`

Mock store + beads:

| # | Test | What to verify |
|---|------|---------------|
| 1 | Detects completed runs | Bead status=closed → run marked completed |
| 2 | Detects stuck agents | started_at > timeout ago + bead still open → stuck |
| 3 | Active runs stay active | Recent start + bead open → still active |
| 4 | Recovery respects max retries | recoverStuck returns false after max retries |
| 5 | Recovery resets run status | recoverStuck sets status back to pending |
| 6 | Logs events on status change | store.logEvent called for completions/stuck |

### 1.6 Dashboard API Routes (`src/dashboard/server.ts`)
**File:** `src/dashboard/__tests__/server.test.ts`

Mock store, test Hono routes:

| # | Test | What to verify |
|---|------|---------------|
| 1 | GET /api/projects returns array | 200 + JSON array |
| 2 | GET /api/projects/:id returns project | 200 + project object with beads |
| 3 | GET /api/projects/:id 404 for unknown | 404 response |
| 4 | GET /api/metrics returns aggregates | 200 + totalCost, tasksByStatus, etc. |
| 5 | GET /api/agents returns active agents | 200 + array of active runs |
| 6 | POST /api/projects/:id/pause updates status | Status changed to paused |

### 1.7 WebSocket (`src/dashboard/ws.ts`)
**File:** `src/dashboard/__tests__/ws.test.ts`

| # | Test | What to verify |
|---|------|---------------|
| 1 | Broadcast sends to all connected clients | Multiple clients all receive event |
| 2 | Client disconnect doesn't crash broadcast | Remove client, broadcast still works |
| 3 | Events are JSON formatted | Broadcast output is valid JSON |

---

## Layer 2: Integration Tests

### 2.1 Git Worktree Manager (`src/lib/git.ts`)
**File:** `src/lib/__tests__/git.test.ts`

Requires: filesystem, git (no network)

| # | Test | What to verify |
|---|------|---------------|
| 1 | createWorktree creates directory + branch | Worktree exists, branch created |
| 2 | createWorktree uses correct naming | Branch: `foreman/<bead-id>`, path: external workspace root (default: `../.foreman-worktrees/<repo>/<bead-id>`) |
| 3 | removeWorktree cleans up | Directory and branch removed |
| 4 | listWorktrees returns all worktrees | Created worktrees appear in list |
| 5 | mergeWorktree merges cleanly | Changes appear in target branch |
| 6 | mergeWorktree detects conflicts | Conflicting changes → success=false + conflict files |
| 7 | getRepoRoot finds root from subdirectory | Nested path → repo root |

Setup: Create temp git repo with initial commit in `beforeEach`.

### 2.2 Store + Metrics (`src/lib/store.ts`)
**File:** `src/lib/__tests__/store-metrics.test.ts`

Extend existing store tests:

| # | Test | What to verify |
|---|------|---------------|
| 1 | getMetrics with date filter | Only includes costs after `since` |
| 2 | getMetrics cost by runtime | Correctly groups by agent_type |
| 3 | getRunsByStatus returns correct runs | Filter by multiple statuses |
| 4 | Concurrent reads don't block (WAL) | Parallel reads succeed |

### 2.3 CLI Commands (smoke tests)
**File:** `src/cli/__tests__/commands.test.ts`

Spawn `tsx src/cli/index.ts <command>` as child process:

| # | Test | What to verify |
|---|------|---------------|
| 1 | `--help` exits 0 | Shows all 8 commands |
| 2 | `--version` prints version | Outputs "0.1.0" |
| 3 | `status` without init exits with error | Helpful error message |
| 4 | `sling trd nonexistent.md` exits with error | File not found or error message |
| 5 | `plan --dry-run "test"` shows pipeline | 4 steps listed |
| 6 | `run --dry-run` without init exits with error | Helpful error message |

---

## Layer 3: E2E Tests (manual / CI-gated)

### 3.1 Full Pipeline Test
**Requires:** Dolt running, Beads CLI, Claude Code

```bash
# Setup
cd /tmp && mkdir foreman-e2e-test && cd foreman-e2e-test
git init && echo "# Test Project" > README.md && git add -A && git commit -m "init"

# 1. Init
foreman init --name "e2e-test"
# Verify: .beads/ exists, project in ~/.foreman/foreman.db

# 2. Sling TRD (using sample TRD)
foreman sling trd ~/Development/Fortium/foreman/docs/TRD/sling-trd.md --auto
# Verify: bd list shows beads, epic + tasks created

# 3. Status
foreman status
# Verify: Shows task counts, no active agents

# 4. Run (dry-run first)
foreman run --dry-run
# Verify: Shows which tasks would be dispatched

# 5. Run (single agent, Pi for speed)
foreman run --max-agents 1 --runtime pi
# Verify: Worktree created, agent process started, run in SQLite

# 6. Monitor
foreman monitor
# Verify: Shows active agent with elapsed time

# 7. Dashboard
foreman dashboard &
curl http://localhost:3850/api/projects
# Verify: JSON response with project data
kill %1

# Cleanup
cd / && rm -rf /tmp/foreman-e2e-test
```

### 3.2 Dashboard Visual Test
**Requires:** Browser

```bash
foreman dashboard
# Open http://localhost:3850
# Verify:
# - Projects overview loads (even if empty)
# - Navigation works (#projects, #metrics)
# - WebSocket indicator shows connected (green dot)
# - Dark theme renders correctly
# - Responsive at different widths
```

### 3.3 Plan Pipeline Test (Ensemble)
**Requires:** Dolt, Beads, Claude Code, Ensemble commands

```bash
cd /tmp/foreman-e2e-test
foreman plan "Build a simple todo API with CRUD endpoints"
# Verify:
# - 4 beads created (create-prd, refine-prd, create-trd, refine-trd)
# - Each step executes sequentially
# - PRD.md and TRD.md created in docs/
# - All steps tracked in SQLite
# - foreman status shows completed planning beads
```

---

## Implementation Priority

| Priority | Test Suite | Est. Tests | Effort |
|----------|-----------|------------|--------|
| **P0** | Decomposer unit tests | 10 | 1h |
| **P0** | Dispatcher runtime selection | 7 | 30m |
| **P0** | Git worktree integration | 7 | 1h |
| **P1** | Monitor unit tests | 6 | 1h |
| **P1** | Templates unit tests | 4 | 30m |
| **P1** | Planner unit tests | 5 | 30m |
| **P1** | CLI smoke tests | 6 | 1h |
| **P2** | Dashboard API tests | 6 | 1h |
| **P2** | WebSocket tests | 3 | 30m |
| **P2** | Store metrics extension | 4 | 30m |
| **P3** | Full pipeline E2E | Manual | 30m |
| **P3** | Dashboard visual | Manual | 15m |
| | **Total** | **~58 tests** | **~8h** |

---

## Running Tests

```bash
# All unit + integration tests
foreman test          # or: npm test

# Watch mode during development
npm run test:watch

# Specific test file
npx vitest run src/orchestrator/__tests__/trd-parser.test.ts

# With coverage
npx vitest run --coverage
```

## Test Conventions

- Test files: `__tests__/<module>.test.ts` next to source
- Use `beforeEach`/`afterEach` for setup/teardown
- Temp directories via `mkdtempSync` (auto-cleanup in afterEach)
- Mock external CLIs (bd, git, claude) — don't call real binaries in unit tests
- Integration tests can use real git (create temp repos)
- No network calls in any automated test
