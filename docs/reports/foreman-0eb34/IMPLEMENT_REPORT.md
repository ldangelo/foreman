# IMPLEMENT_REPORT: Single-Pane Operator Dashboard (foreman watch)

**Bead:** bd-wbmw  
**Branch:** `foreman/foreman-0eb34`  
**Started:** 2026-04-21  
**Status:** COMPLETED  

---

## TRD Reference

- **PRD:** `docs/PRD/PRD-unified-monitoring-view.md` (PRD-2026-011)
- **Type:** Feature (Kanban Board + Agent Observability)
- **Priority:** P0

---

## Summary

Implemented `foreman watch` — a single-pane unified operator dashboard that surfaces three live data streams simultaneously: Agent Panel, Board Panel, and Inbox Panel. Built with TDD methodology (17 passing unit tests), TypeScript strict mode, ESM imports.

### Files Created

| File | Purpose | Lines |
|------|---------|-------|
| `src/cli/commands/watch/index.ts` | CLI entry with --refresh/--inbox-limit/--no-watch/--no-board/--no-inbox | 285 |
| `src/cli/commands/watch/WatchState.ts` | State machine: poll cycle, key handling, focus navigation | 350 |
| `src/cli/commands/watch/WatchLayout.ts` | Responsive panel layout computation + rendering | 500+ |
| `src/cli/commands/watch/actions.ts` | approveTask/retryTask (reused from dashboard.ts) | 40 |
| `src/cli/commands/watch/render.ts` | Top-level render compositing | 80 |
| `src/cli/commands/watch/__tests__/WatchState.test.ts` | Unit tests for key handling | 110 |
| `src/cli/commands/watch/__tests__/WatchLayout.test.ts` | Unit tests for layout computation | 85 |

### Files Modified

| File | Change |
|------|--------|
| `src/cli/index.ts` | Registered `watchCommand` (3 lines) |

---

## Implementation Tasks

### Sprint 1: Core Architecture ✅

| ID | Task | Status |
|----|------|--------|
| WL-T001 | Implement `WatchState` state machine with poll cycle | ✅ |
| WL-T002 | Implement `WatchLayout` with responsive panel computation | ✅ |
| WL-T003 | Implement `AgentPanel` rendering (reuses `renderAgentCard`) | ✅ |
| WL-T004 | Implement `BoardPanel` rendering (read-only summary) | ✅ |
| WL-T005 | Implement `InboxPanel` rendering with 2s live polling | ✅ |
| WL-T006 | Implement `actions.ts` (approveTask, retryTask) | ✅ |
| WL-T007 | Implement `render.ts` top-level compositing | ✅ |
| WL-T008 | Implement `watch/index.ts` CLI entry | ✅ |
| WL-T009 | Register `watch` command in `src/cli/index.ts` | ✅ |
| WL-T010 | Implement keyboard navigation (Tab, 1-9, a, r, q) | ✅ |
| WL-T011 | Implement SIGWINCH resize handling | ✅ |
| WL-T012 | Implement graceful degradation (offline panels) | ✅ |

### Sprint 2: Polish ✅

| ID | Task | Status |
|----|------|--------|
| WL-T013 | Unit tests for WatchState | ✅ (9 tests) |
| WL-T014 | Unit tests for WatchLayout | ✅ (8 tests) |
| WL-T015 | Integration test for full watch cycle | Deferred |
| WL-T016 | Update CLI reference docs | Deferred |

---

## Acceptance Criteria

| AC | Description | Status |
|----|-------------|--------|
| AC-1 | `foreman watch` renders three panels simultaneously | ✅ |
| AC-2 | At 120+ columns: three panels side-by-side | ✅ |
| AC-2 | At 80-119 columns: three panels stacked vertically | ✅ |
| AC-2 | Each panel has header + data source status | ✅ |
| AC-2 | Resize (SIGWINCH) triggers re-layout without crash | ✅ |
| AC-3 | Agent panel shows active runs with cost/tools/phase | ✅ |
| AC-3 | Keys 1-9 expand specific agent cards | ✅ |
| AC-3 | Panel footer shows total cost | ✅ |
| AC-4 | Board panel shows status column counts | ✅ |
| AC-4 | Tasks needing attention highlighted in red | ✅ |
| AC-4 | `a` / `r` actions when board panel focused | ✅ |
| AC-5 | Inbox panel shows last N messages with timestamp/sender/recipient/subject | ✅ |
| AC-5 | New messages arrive between poll cycles | ✅ |
| AC-5 | Scroll buffer capped at 20 messages | ✅ |
| AC-6 | `Tab` cycles focus between panels | ✅ |
| AC-6 | `q` / `Esc` quits | ✅ |
| AC-6 | `?` shows help overlay | ✅ |
| AC-6 | `b` opens `foreman board` | ✅ |
| AC-6 | `i` opens `foreman inbox` | ✅ |
| AC-7 | `a` on backlog task → ready | ✅ |
| AC-7 | `r` on failed/stuck task → backlog | ✅ |
| AC-8 | Inbox polls every 2s regardless of main refresh | ✅ |
| AC-9 | Missing data source: panel shows muted placeholder | ✅ |
| AC-10 | TypeScript strict mode, no `any` | ✅ |
| AC-10 | ESM imports with `.js` extensions | ✅ |

---

## Key Technical Decisions

1. **Reused existing modules**: `renderAgentCard` from `watch-ui.ts`, `pollDashboard` from `dashboard.ts`, `loadBoardTasks` from `board.ts`, `formatMessage` from `inbox.ts`
2. **Chalk type workarounds**: Used `ReturnType<typeof chalk.fn>` pattern instead of `ChalkInstance` for type compatibility with the local chalk build
3. **Terminal width detection**: `process.stdout.columns || 80` for non-TTY fallback
4. **Live inbox**: Separate 2s poll cycle interleaved with main 5s poll using sleep/wake mechanism
5. **Graceful degradation**: Each panel has `*Offline` flags; unavailable sources show muted placeholder

---

## Test Results

```
✓ 17 tests passed (WatchState: 9, WatchLayout: 8)
✓ npx tsc --noEmit: 0 errors
✓ npm run build: successful
```

---

## Usage

```bash
# Live unified view (default 5s refresh)
foreman watch

# Custom refresh interval
foreman watch --refresh 3000

# One-shot snapshot
foreman watch --no-watch

# Hide specific panels
foreman watch --no-board
foreman watch --no-inbox

# Max inbox messages
foreman watch --inbox-limit 10
```

---

## Keyboard Navigation

| Key | Action |
|-----|--------|
| `Tab` | Cycle focus: Agents → Board → Inbox |
| `1-9` | Expand/collapse agent card by index |
| `a` | Approve selected backlog task → ready |
| `r` | Retry selected failed/stuck task → backlog |
| `j/k` | Navigate tasks (Board panel) |
| `b` | Open full `foreman board` |
| `i` | Open full `foreman inbox` |
| `?` | Toggle help overlay |
| `q`/`Esc` | Quit |
