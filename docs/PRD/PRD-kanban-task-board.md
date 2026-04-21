# PRD: Kanban Task Board

**PRD ID:** PRD-2026-010  
**Created:** 2026-04-18  
**Status:** Draft  
**Type:** Feature  

---

## 1. Product Summary

### Problem Statement

Foreman agents and developers currently manage task status changes through CLI commands (`foreman task update <id> --status <status>`) or direct bead manipulation. There is no visual, terminal-native way to see the full state of a project's task queue at a glance, move tasks between statuses, or quickly edit task metadata.

### Solution Overview

A terminal UI (TUI) kanban board that renders tasks in columns by status, supports vim-style navigation (j/k for vertical, h/l for horizontal column movement), and provides shortcuts for common operations (close task, change status, edit in `$EDITOR` as YAML).

### Value Proposition

- **Immediate situational awareness**: See all tasks across all statuses in one view
- **Muscle-memory efficiency**: vim-style navigation for power users
- **No context switching**: Edit tasks without leaving the terminal
- **Agent-usable**: Agents can invoke the board to present task state to users during handoffs

---

## 2. User Analysis

### Target Users

| User | Pain Point | How Board Helps |
|------|-----------|-----------------|
| **Developer at desk** | Hard to remember task IDs and current statuses | See board at a glance |
| **Foreman agent** | Cannot visually present task state to user | Render board as part of agent output |
| **Project manager** | Tracking status across many tasks via CLI is tedious | Click-adjacent: keyboard-driven status changes |
| **On-call / triage** | Need to quickly move tasks to correct status | Fast h/j/k/l navigation + shortcuts |

### User Journey

```
User runs `foreman board` 
  → Terminal renders kanban board (status columns)
  → User navigates with j/k (rows) and h/l (columns)
  → User presses shortcut key to act on highlighted task
  → Board re-renders with updated state
  → User presses q to quit
```

---

## 3. Goals & Non-Goals

### Goals

1. Render a kanban board with columns for each task status (backlog, ready, in_progress, review, blocked, closed)
2. Navigate between tasks and columns using vim keybindings (j/k = down/up, h/l = left/right)
3. Change a task's status directly from the board via a keypress
4. Close a task directly from the board via a keypress
5. Open task for editing in `$EDITOR` in YAML format; parse and save on editor exit
6. Work with both Beads (native store) and the native task backend
7. Render within 100ms on boards with up to 200 tasks
8. Fully keyboard-driven (no mouse required)

### Non-Goals

1. Drag-and-drop (mouse-based interaction)
2. Multi-select / bulk operations
3. Real-time sync while board is open (polling is acceptable on open)
4. Custom column definitions (fixed status columns)
5. Subtask rendering (epic/story breakdown not shown in board view)
6. Web UI / browser rendering
7. Filtering or searching (future enhancement)

---

## 4. Functional Requirements

### FR-1: Board Rendering

- Display tasks organized into columns by status label
- Each column header shows status name and task count
- Each task card shows: ID (short), title (truncated to 40 chars), priority badge
- Highlighted task shown with inverse video / colored border
- Show column header labels: `backlog | ready | in_progress | review | blocked | closed`
- If a status has 0 tasks, column is shown but empty
- If >5 tasks in a column, show first 5 and "+N more" indicator
- Board title shows project name and total task count

### FR-2: Navigation

| Key | Action |
|-----|--------|
| `j` | Move highlight down (next task in column) |
| `k` | Move highlight up (previous task in column) |
| `h` | Move to column on the left |
| `l` | Move to column on the right |
| `g` | Jump to first task (top of current column) |
| `G` | Jump to last task (bottom of current column) |
| `Enter` | Show task details (popup or expanded card) |
| `q` | Quit board |

Wrap behavior: j at bottom of column wraps to top of same column. h at leftmost column wraps to rightmost column. l at rightmost wraps to leftmost.

### FR-3: Status Change

| Key | Action |
|-----|--------|
| `s` | Cycle status forward (next in order) |
| `S` | Cycle status backward (previous in order) |
| `<number> + Enter` | Jump to status column by number (shown as `[1] backlog [2] ready ...`) |

Status order: `backlog → ready → in_progress → review → blocked → closed`

On status change, update task in store and re-render board. Show brief flash/indicator on the moved task.

### FR-4: Close Task

| Key | Action |
|-----|--------|
| `c` | Close the highlighted task (sets status to `closed`) |
| `C` | Close with reason prompt |

On close, mark task closed and re-render board.

### FR-5: Edit Task in $EDITOR

| Key | Action |
|-----|--------|
| `e` | Open task YAML in `$EDITOR` |
| `E` | Open task YAML with full schema (all fields) |

The YAML shown is the task's serialized form:

```yaml
id: bd-xxxx
title: "Task title"
description: "Task description"
status: in_progress
priority: 2
issue_type: task
labels: []
```

On save (editor exit with 0), parse YAML and update task in store. On error (non-zero exit or parse error), show error and do not save.

### FR-6: Task Detail View

| Key | Action |
|-----|--------|
| `Enter` | Show expanded detail panel for highlighted task |
| `Esc` | Dismiss detail panel |

Detail panel shows full task metadata: id, title, description, status, priority, type, labels, created_at, updated_at, depends_on.

### FR-7: Refresh

| Key | Action |
|-----|--------|
| `r` | Refresh board (reload tasks from store) |
| Auto | Refresh on return from editor, after status change |

### FR-8: Help Overlay

| Key | Action |
|-----|--------|
| `?` | Toggle help overlay showing all keybindings |
| `Esc` | Dismiss help overlay |

Help overlay renders as a centered panel with keybinding table, semi-transparent background.

---

## 5. Non-Functional Requirements

### NFR-1: Performance
- Initial board render: < 200ms for up to 200 tasks
- Navigation key response: < 50ms
- Status change + re-render: < 300ms

### NFR-2: Compatibility
- Terminal: any ANSI-capable terminal (iTerm2, Terminal.app, tmux, Kitty)
- Minimum width: 80 columns
- Color: 256-color mode required, 24-bit preferred
- `$EDITOR`: defaults to `vim`, falls back to `nano`, then `vi`, then `emacs`

### NFR-3: Task Store Integration
- Read tasks from `foreman task list` via task store abstraction
- Write status changes via `foreman task update <id> --status <status>`
- Must work with Beads backend and native task store

### NFR-4: Error Handling
- If task store is unavailable, show error banner and disable mutations
- If `$EDITOR` is not set or unavailable, show error message
- Network errors on status change: retry once, then show error toast
- Invalid YAML on save: show error, keep editor open for retry

---

## 6. Acceptance Criteria

### AC-1: Board Renders Correctly
- [ ] `foreman board` renders 6 columns (one per status)
- [ ] Each column shows correct task count
- [ ] Task cards show id, truncated title, priority badge
- [ ] Highlighted task is visually distinct

### AC-2: Navigation Works
- [ ] j/k navigates within column
- [ ] h/l navigates between columns
- [ ] g/G jump to top/bottom of column
- [ ] Navigation wraps at column/board boundaries

### AC-3: Status Change Works
- [ ] `s` advances status to next in order
- [ ] `S` moves status to previous in order
- [ ] Status change persists after board refresh
- [ ] Visual feedback confirms change

### AC-4: Close Works
- [ ] `c` closes highlighted task
- [ ] `C` prompts for close reason
- [ ] Closed task moves to `closed` column immediately

### AC-5: Editor Works
- [ ] `e` opens task YAML in `$EDITOR`
- [ ] Changes saved to store on editor exit (0)
- [ ] Invalid YAML rejected with error message
- [ ] Editor exit (non-zero) discards changes

### AC-6: Task Detail Works
- [ ] `Enter` shows full task metadata
- [ ] `Esc` dismisses detail panel

### AC-7: Help Works
- [ ] `?` shows keybinding overlay
- [ ] `Esc` dismisses overlay

### AC-8: Error Handling
- [ ] Store unavailable shows error banner
- [ ] Network errors show toast with retry option

### AC-9: Performance
- [ ] Board renders in < 200ms with 200 tasks
- [ ] Key response is < 50ms

---

## 7. Implementation Notes

### Technology
- TUI library: `ink` (React for CLIs) or `blessed` / `blessed-contrib`
- Recommend `ink` + `ink-box` for React-like component model
- Task data: use `foreman task list --format json` or task store directly
- Write operations: `foreman task update <id> --status <status>` CLI calls

### CLI Surface
```bash
foreman board              # Open interactive board
foreman board --project <id>  # Board for specific project
foreman board --limit 50  # Limit tasks per column
foreman board --filter status=open  # Show only open tasks
```

### File Structure
```
src/
  board/
    index.ts          # Main CLI entry point
    Board.tsx         # Root board component
    Column.tsx        # Status column component
    TaskCard.tsx      # Individual task card
    TaskDetail.tsx    # Expanded task detail panel
    HelpOverlay.tsx   # Keybinding help overlay
    hooks/
      useBoard.ts     # Task loading + refresh logic
      useNavigation.ts # Keyboard navigation state
    utils/
      yaml.ts         # YAML serialization/deserialization
      taskStore.ts    # Task store interface
```

### Dependency: None (uses existing foreman task CLI)
The board reads tasks via `foreman task list` and writes via `foreman task update`. No new API needed.
