# PRD: Unified Foreman Monitoring View

**PRD ID:** PRD-2026-011  
**Created:** 2026-04-21  
**Status:** Draft  
**Type:** Feature  
**Related Issues:** Distinct from existing task `foreman-1c1d6` (which covers kanban board), explicitly requires running tasks + board + inbox visible in the same monitoring surface  
**Project:** Foreman / Fortium Ensemble

---

## 1. Product Summary

### Problem Statement

Foreman operators currently must switch between multiple views to monitor active work:

- `foreman dashboard` or `foreman status --live` — shows active agents and run state
- `foreman board` — shows kanban board with task/board state
- `foreman inbox --all --watch` — shows agent message stream

Switching between these views creates context loss: an operator sees a stuck agent in the dashboard but must mentally cross-reference the board and inbox to understand triage priority. There is no single surface that shows **what is running**, **where tasks stand**, and **what agents are communicating** simultaneously.

### Solution Overview

A single unified monitoring view (CLI command `foreman watch`) that combines three live data streams into one terminal-optimized panel:

1. **Agent Panel** — Active running agents with phase, cost, tool activity (from `dashboard.ts` / `watch-ui.ts`)
2. **Board Panel** — Compact task status columns (summary from `board.ts`, read-only)
3. **Inbox Panel** — Recent agent mail messages with streaming new arrivals (from `inbox.ts`)

The layout is designed for terminal output at 80+ columns with a split-pane or stacked layout optimized for fast operator triage.

### Value Proposition

| Before | After |
|--------|-------|
| `foreman dashboard` → switch → `foreman board` → switch → `foreman inbox` | `foreman watch` (single pane) |
| Operator must remember state from 3 separate views | Unified context in one pane |
| Inbox messages arrive unnoticed until operator switches views | Live inbox stream visible alongside agents |
| No cross-panel triage signals | "Needs attention" tasks visible next to stuck agents |

---

## 2. User Analysis

### Target Users

| User | Pain Point | How Unified Watch Helps |
|------|-----------|------------------------|
| **Active operator** | Switching between 3 views during a pipeline wave | One pane, no switching |
| **Triage operator** | Can't see why an agent is stuck without cross-referencing | Agent status + inbox message + board state side-by-side |
| **Debugging operator** | Missed inbox messages about phase transitions | Live message stream always visible |
| **Project manager** | Wants a single terminal snapshot of all work | One command shows complete state |

### User Journey

```
operator runs: foreman watch --refresh 5
  → Terminal shows split layout:
    ┌─ Agents ──────────┬─ Board ────────────┬─ Inbox ─────────┐
    │ ● developer P2   │ backlog(8) ready(3)│ 14:23 explorer→ │
    │   $0.042 32 tools │ in_prog(2) review..│ 14:22 qa→rev... │
    │ ● qa P3          │ blocked(1) closed..│ 14:21 dev→qa... │
    └──────────────────┴───────────────────┴─────────────────┘
  → 14:23 inbox: new message from qa (PASS verdict)
  → Agent panel updates to show phase complete
  → 14:25 inbox: new message from reviewer (FAIL verdict)
  → Board highlights task needing rework
  → operator presses 'a' to approve backlog task
  → Board and inbox update in next poll cycle
```

### Key Distinction from Existing Work

| Existing Feature | Scope | Unified Watch Addition |
|-----------------|-------|-----------------------|
| `foreman dashboard` (`status --live`) | Active runs + events | Adds board summary + inbox stream to same pane |
| `foreman board` | Kanban board, full interactive | Board shown read-only in compact summary form |
| `foreman inbox --all --watch` | Message stream | Shown alongside agent + board state |
| `foreman status` | Task counts + agents | Already consumed by unified watch |

The unified view does **not** replace these commands — it provides a single command that surfaces all three data streams simultaneously. Operators can still use individual commands when they need the full interactive version (e.g., `foreman board` for kanban board editing, `foreman inbox --watch` for message detail).

---

## 3. Goals & Non-Goals

### Goals

1. **Single command** `foreman watch` that renders all three panels (agents, board, inbox) in one terminal view
2. **Live polling** at configurable refresh interval (default 5s) with immediate inbox message arrival
3. **Terminal-optimized layout** — designed for 80+ columns, stacked layout on narrow terminals
4. **Read-only board summary** — status column counts visible without entering full kanban mode
5. **Live inbox stream** — new messages appear between poll cycles without re-rendering the full pane
6. **Keyboard navigation** — vim-style keys to switch focus between panels
7. **Operator actions** — approve backlog tasks (`a`), retry failed tasks (`r`) directly from the view
8. **Graceful degradation** — when any data source is unavailable, its panel shows a muted state without crashing

### Non-Goals

1. **Full kanban board editing** — use `foreman board` for that (board in unified watch is summary only)
2. **Full inbox message viewer** — use `foreman inbox` for that (unified watch shows last 3-5 messages, not full detail)
3. **Web UI** — terminal-only, no browser rendering
4. **Multi-project drill-down** — single project only (scope to current working directory)
5. **Custom column definitions** — board columns are the 6 fixed statuses
6. **File-based persistence** — no save/load of watch session state

---

## 4. Functional Requirements

### FR-1: Command Interface

```bash
foreman watch                    # Live unified view, 5s refresh
foreman watch --refresh 3        # Custom refresh interval (seconds)
foreman watch --no-watch         # One-shot snapshot, then exit
foreman watch --project <id>     # Scope to specific project
foreman watch --inbox-limit 10   # Max inbox messages shown (default: 5)
foreman watch --no-inbox         # Hide inbox panel
foreman watch --no-board         # Hide board summary panel
```

### FR-2: Layout

The terminal is divided into three panels:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ FOREMAN WATCH — project-name                    [refresh: 5s] [Ctrl+C quit] │
├──────────────────────────┬───────────────────────┬───────────────────────────┤
│  AGENTS                  │  BOARD                │  INBOX (live)             │
│  ─────────────          │  ────────             │  ─────────────────        │
│  ● developer bd-abc123  │  backlog(8) ready(3)  │  14:23 explorer → dev    │
│    Phase: developer     │  in_prog(2) review(1) │    currentPhase: develop..│
│    $0.042 32t 4tools    │  blocked(1) closed(..│  14:22 qa → reviewer    │
│    Files: 4 (3 .ts .rs) │                       │    verdict: PASS         │
│  ● qa bd-def456         │  ⚠ 1 task needs attn │  14:21 developer → qa   │
│    Phase: qa            │                       │    phase: qa             │
│    $0.018 12t 2tools   │                       │  14:20 reviewer → qa    │
│  ─────────────          │                       │    verdict: FAIL         │
│  Total: 2 active       │  Total: 16 tasks      │  ─────────────────────  │
│  Cost: $0.060           │  Ready: 3            │  5 messages (last 2min) │
└──────────────────────────┴───────────────────────┴───────────────────────────┘
```

**Narrow terminal fallback** (columns < 90): Stack panels vertically:
```
┌─ AGENTS ────────────────────────────────────────────────────────┐
│  [same as above]                                                │
├─ BOARD ─────────────────────────────────────────────────────────┤
│  backlog(8) ready(3) in_prog(2) review(1) blocked(1) closed(.. │
├─ INBOX ─────────────────────────────────────────────────────────┤
│  14:23 explorer → dev  14:22 qa → reviewer  14:21 dev → qa    │
└───────────────────────────────────────────────────────────────┘
```

### FR-3: Agent Panel

- Show all active runs from SQLite (`status = 'pending' | 'running'`)
- Each agent card shows: status icon, seed_id, status, phase, cost, turn count, tool count, last tool call
- Collapsed by default (single line per agent)
- Press number key (1-9) to expand a specific agent card inline
- Show cost total at panel bottom

### FR-4: Board Summary Panel

- Read-only summary: one line per status column with task count
- Format: `backlog(8) ready(3) in_prog(2) review(1) blocked(1) closed(47)`
- Highlight tasks needing human attention (conflict, failed, stuck, backlog)
- Clicking a task ID does nothing (read-only in unified watch)
- Total task count and ready count shown

### FR-5: Inbox Panel

- Show last N messages (configurable via `--inbox-limit`, default 5)
- New messages arrive live between poll cycles (append to bottom, no full re-render)
- Each message shows: timestamp, sender → recipient, subject, one-line preview
- Use `foreman inbox` for full message body
- "Live" indicator blinks when actively receiving messages
- Show message count and age of oldest message

### FR-6: Keyboard Navigation

| Key | Action |
|-----|--------|
| `Tab` | Cycle focus: Agents → Board → Inbox → Agents |
| `1-9` | Expand agent card by index (in Agents panel) |
| `a` | Approve highlighted backlog task (in Board panel when focused) |
| `r` | Retry failed/stuck task (in Board panel when focused) |
| `i` | Open full inbox for current run (`foreman inbox`) |
| `b` | Open full board (`foreman board`) |
| `s` | Open full dashboard (`foreman dashboard`) |
| `q` / `Esc` | Quit |
| `?` | Toggle help overlay |

### FR-7: Operator Actions

- **`a`** — Approve a backlog task (changes `backlog` → `ready`), re-poll board summary
- **`r`** — Retry a failed/stuck task (changes `failed`/`stuck` → `backlog`), re-poll board summary
- Actions require panel focus (Tab to navigate)
- Confirmation prompt: "Approve task bd-xyz? [y/N]"
- On success: board summary re-renders with updated counts
- On failure: error toast shown at bottom of panel

### FR-8: Live Inbox Streaming

The inbox panel shows new messages as they arrive:

1. **Between poll cycles**: Use a background timer (100ms) to check the SQLite inbox for new messages since last poll
2. **Append-only display**: New messages append to the bottom of the inbox panel without flickering the rest of the display
3. **Scroll buffer**: Only keep last 20 messages in the scroll buffer; older messages are trimmed
4. **Visual indicator**: When a new message arrives, briefly flash/highlight the new line, then return to normal
5. **Run filtering**: Show messages for currently active runs only (not all runs)

### FR-9: Graceful Degradation

| Data Source Unavailable | Panel Behavior |
|------------------------|----------------|
| SQLite runs table missing | Agents panel shows "DB unavailable — agents unknown" |
| Task store (br) unavailable | Board panel shows "Task backend unavailable — board unknown" |
| Inbox table missing | Inbox panel shows "Inbox unavailable — messages unknown" |
| All sources unavailable | Full-screen error message, exit on any key |

---

## 5. Non-Functional Requirements

### NFR-1: Performance

- Initial render: < 500ms for full three-panel display
- Poll cycle: < 300ms for all three data sources
- Key response: < 50ms for navigation actions
- Memory: < 50MB resident set (no accumulation of message history)

### NFR-2: Terminal Compatibility

- Minimum width: 80 columns
- Recommended width: 120 columns
- Colors: 256-color mode required (chalk)
- Unicode: Required for panel borders and status icons
- Resize handling: Re-render on SIGWINCH (terminal resize signal)

### NFR-3: Data Freshness

- Agent panel: Polls every N seconds (configurable, default 5s)
- Board panel: Polls every N seconds (configurable, default 5s)
- Inbox panel: Polls every 2 seconds for new messages (fixed, faster than main poll)
- Last poll timestamp shown in panel header

### NFR-4: Dependencies

- Consumes existing modules: `dashboard.ts`, `board.ts`, `inbox.ts`, `watch-ui.ts`
- No new external dependencies required
- Reuses SQLite schema for runs and messages (already in `store.ts`)
- Reuses `NativeTaskStore` for board data

---

## 6. File Structure

```
src/cli/commands/
  watch.ts          # New unified watch command (FR-1)
  dashboard.ts      # Existing — Agent panel + event rendering
  board.ts          # Existing — Board rendering (read-only summary)
  inbox.ts          # Existing — Message formatting (abbreviated)
  watch-ui.ts       # Existing — renderAgentCard, renderWatchDisplay
```

**New files:**

```
src/cli/commands/watch/
  index.ts           # Main CLI entry: watchCommand
  WatchLayout.ts     # Panel layout computation + rendering
  AgentPanel.ts      # Agent panel rendering
  BoardPanel.ts      # Board summary panel rendering
  InboxPanel.ts      # Live inbox streaming panel
  WatchState.ts      # State machine for poll + render cycle
  actions.ts         # approveTask, retryTask helpers (reused from dashboard.ts)
  render.ts          # Top-level renderWatch() compositing all panels
```

---

## 7. Acceptance Criteria

### AC-1: Single Command
- [ ] `foreman watch` renders three panels simultaneously
- [ ] `foreman watch --help` shows all options including `--refresh`, `--no-watch`, `--inbox-limit`, `--no-inbox`, `--no-board`, `--project`

### AC-2: Layout
- [ ] At 120+ columns: three panels side-by-side
- [ ] At 80-119 columns: three panels stacked vertically
- [ ] Each panel has a header with panel name and data source status
- [ ] Resize (SIGWINCH) triggers re-layout without crash

### AC-3: Agent Panel
- [ ] Shows all active runs (pending/running) with status icon, seed_id, phase, cost, turns, tools
- [ ] Keys 1-9 expand specific agent cards
- [ ] Panel footer shows total cost across all agents
- [ ] Shows "No agents running" when appropriate

### AC-4: Board Summary Panel
- [ ] Shows one status column per status with task count: `backlog(8) ready(3) in_prog(2) ...`
- [ ] Tasks needing attention (conflict/failed/stuck/backlog) are highlighted in red
- [ ] Total task count and ready count shown at panel bottom
- [ ] Pressing `a` or `r` when board panel is focused attempts the action

### AC-5: Inbox Panel
- [ ] Shows last 5 messages (configurable) with timestamp, sender → recipient, subject, one-line preview
- [ ] New messages arrive between poll cycles without re-rendering the full pane
- [ ] New message arrival is visually indicated (brief flash)
- [ ] Shows message count and age of oldest message

### AC-6: Keyboard Navigation
- [ ] `Tab` cycles focus between panels
- [ ] `q` / `Esc` quits
- [ ] `?` shows help overlay
- [ ] `a` attempts task approval when board panel is focused
- [ ] `r` attempts task retry when board panel is focused
- [ ] `b` opens `foreman board` and exits
- [ ] `i` opens `foreman inbox` for the current run and exits

### AC-7: Operator Actions
- [ ] `a` on a backlog task changes status to `ready` and re-renders board panel
- [ ] `r` on a failed/stuck task changes status to `backlog` and re-renders board panel
- [ ] Failed action shows error toast, does not crash

### AC-8: Live Inbox
- [ ] Inbox panel polls every 2 seconds regardless of main refresh interval
- [ ] New messages append to bottom without flickering agent or board panels
- [ ] Scroll buffer is capped at 20 messages
- [ ] New message arrival is visually indicated

### AC-9: Graceful Degradation
- [ ] Missing SQLite runs: agent panel shows muted placeholder, does not crash
- [ ] Missing task backend: board panel shows muted placeholder, does not crash
- [ ] Missing inbox table: inbox panel shows muted placeholder, does not crash
- [ ] All sources unavailable: full-screen error, exit on keypress

### AC-10: Performance
- [ ] Initial render completes in < 500ms
- [ ] Poll cycle completes in < 300ms
- [ ] No memory accumulation over time (message buffer capped)
- [ ] Key response is < 50ms

---

## 8. Dependencies & Integration Points

### Integration with Existing Modules

| Module | How It's Used |
|--------|---------------|
| `dashboard.ts` | `pollDashboard()`, `readProjectSnapshot()` for agent state |
| `watch-ui.ts` | `renderAgentCard()`, `renderWatchDisplay()` for agent panel rendering |
| `board.ts` | `loadBoardTasks()` for board data; read-only summary only |
| `inbox.ts` | `formatMessage()`, `formatTimestamp()` for abbreviated inbox rendering |
| `NativeTaskStore` | Board data access for task counts |
| `ForemanStore` | SQLite runs and messages queries |
| `fetchTaskCounts()` | br task counts for board summary |

### No New Dependencies

The unified watch command uses only existing code:
- No new npm packages
- No new external binaries
- Reuses `chalk` for colors (already a dependency)
- Reuses `commander` for CLI (already a dependency)

---

## 9. Edge Cases

| Edge Case | Handling |
|-----------|----------|
| 0 active runs | Agent panel shows "No agents running" — rest of display normal |
| 0 tasks in all statuses | Board panel shows all columns with count 0 |
| Very long agent list (>10) | Scroll within agent panel, show "+N more" indicator |
| Very long inbox (>20 messages) | Trim oldest messages from scroll buffer |
| Task backend (br) not installed | Board panel shows "br unavailable — counts unknown" in muted state |
| SQLite database locked | Retry once, then show "DB locked — retrying..." status |
| Terminal too narrow (< 60 cols) | Show warning: "Terminal too narrow for unified view. Use `foreman dashboard` instead." |
| New inbox message arrives during key input | Queue message for display on next render cycle |
| `a` action on non-backlog task | Show "Task must be in backlog status to approve" |
| `r` action on non-failed/stuck task | Show "Task must be failed or stuck to retry" |

---

## 10. Success Metrics

| Metric | Target |
|--------|--------|
| Single-command usage | Operators can triage without switching views |
| Poll cycle time | < 300ms for all three panels |
| Keyboard response | < 50ms |
| Crash-free operation | 100% uptime during active pipeline |
| Code reuse | >80% of rendering code from existing modules |

---

## 11. Future Enhancements (Post-MVP)

- **Narrow-terminal mode** — hide inbox panel by default on < 100 columns
- **Audio alerts** — audible ping when new inbox message arrives from QA/reviewer (PASS/FAIL)
- **Configurable panel weights** — operator can resize panels in terminal
- **Message threading** — group inbox messages by runId with expandable groups
- **Export snapshot** — `foreman watch --export` writes snapshot to file for debugging
- **Multi-project watch** — `foreman watch --all` across all registered projects

---

*Related PRDs:*
- [[PRD-2026-010: Kanban Task Board]] — Full interactive kanban board (unified watch consumes read-only summary)
- [[PRD-2026-005: Mid-Pipeline Rebase]] — Uses monitoring views for rebase state visibility
- [[PRD: Multi-Agent Coding Orchestrator (Foreman)]] — Top-level PRD, dashboard specification in §5
