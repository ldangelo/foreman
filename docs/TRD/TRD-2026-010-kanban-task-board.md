# TRD: Kanban Task Board

**Document ID:** TRD-2026-010  
**PRD Reference:** PRD-2026-010  
**Created:** 2026-04-19  
**Status:** Draft  
**Type:** Feature  

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Component Specifications](#3-component-specifications)
4. [CLI Interface](#4-cli-interface)
5. [Data Flow](#5-data-flow)
6. [Implementation Details](#6-implementation-details)
7. [Testing Strategy](#7-testing-strategy)
8. [Acceptance Criteria](#8-acceptance-criteria)
9. [File Structure](#9-file-structure)
10. [Open Questions](#10-open-questions)

---

## 1. Overview

### 1.1 Purpose

This TRD specifies the technical implementation of a terminal UI (TUI) kanban board for Foreman. The board renders tasks organized by status in columns, supports vim-style navigation, and enables quick task operations without leaving the terminal.

### 1.2 Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| TUI Framework | `ink` (React for CLIs) | Lightweight, component-based, compatible with existing TS patterns |
| State Management | React hooks (`useState`, `useReducer`) | Simple state, no external library needed |
| Task Data | `br list --status=open --format=json` | Uses existing br client, no new API |
| Task Mutations | `br update <id> --status <status>` | Uses existing br CLI |
| YAML Parsing | `js-yaml` (already in dependencies) | Parse task YAML for editor |

### 1.3 Constraints

- **No new native API**: The board uses existing `br` CLI commands
- **ANSI terminal support**: Must work with iTerm2, Terminal.app, tmux, Kitty
- **Minimum width**: 80 columns
- **Color**: 256-color mode required

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     CLI Entry Point                         │
│                     (board.ts)                              │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Board Component                           │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┬─────┐│
│  │ Backlog │  Ready  │Progress │ Review  │ Blocked │Close ││
│  │         │         │         │         │         │      ││
│  │ Task[]  │ Task[]  │ Task[]  │ Task[]  │ Task[]  │Task[]││
│  └─────────┴─────────┴─────────┴─────────┴─────────┴─────┘│
│                      ▲                                      │
│                      │                                     │
│  ┌───────────────────┴───────────────────────────────┐   │
│  │              Navigation State                       │   │
│  │  - currentColumn (0-5)                             │   │
│  │  - currentRow (0-N in column)                      │   │
│  └───────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Component Hierarchy

```
Board (root)
├── Header (board title, task count, status numbers)
├── Columns (6 columns, one per status)
│   ├── ColumnHeader (status name, count)
│   └── TaskCards[] (each task in column)
│       └── TaskCard (id, title, priority badge)
├── TaskDetail (expanded view, shown on Enter)
├── HelpOverlay (keybindings, shown on ?)
└── StatusBar (current mode, messages)
```

### 2.3 State Management

```typescript
interface BoardState {
  // Task data
  columns: Map<Status, Task[]>;
  
  // Navigation
  currentColumn: number;  // 0-5 (backlog to closed)
  currentRow: number;    // index in current column's task list
  
  // UI modes
  showDetail: boolean;
  showHelp: boolean;
  
  // Error handling
  errorMessage: string | null;
  successMessage: string | null;
}
```

### 2.4 Status Column Order

The 6 status columns in order (for navigation cycling):

```typescript
const STATUS_ORDER = [
  'backlog',
  'ready', 
  'in_progress',
  'review',
  'blocked',
  'closed'
] as const;
type Status = typeof STATUS_ORDER[number];
```

---

## 3. Component Specifications

### 3.1 Board Component

**File:** `src/board/Board.tsx` (or .tsx)

**Props:** `None` (reads tasks via hook)

**Responsibilities:**
- Render full board layout
- Handle keyboard events
- Manage navigation state
- Coordinate between sub-components

**Layout:**
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Foreman Board — 42 tasks                                     [1]backlog[2]... │
├──────────────────────────────────────────────────────────────────────────────┤
│ [1] backlog (3)    [2] ready (5)     [3] in_progress   [4] review    [5] bl..│
│ ┌────────────┐    ┌────────────┐   ┌────────────┐     ┌────────────┐  ┌────┐│
│ │bd-xxx P1  │    │bd-yyy P2   │   │bd-zzz P0   │     │bd-www P2   │  │    ││
│ │Task title │    │Task title  │   │Task title  │     │Task title  │  │    ││
│ └────────────┘    └────────────┘   └────────────┘     └────────────┘  └────┘│
│ [1] backlog [2] ready [3] in_progress [4] review [5] blocked [6] closed      │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Column Component

**File:** `src/board/Column.tsx`

**Props:**
```typescript
interface ColumnProps {
  status: Status;
  tasks: Task[];
  isSelected: boolean;
  selectedIndex: number;
  maxVisible: number;  // 5 (show +N more if > 5)
}
```

**Render Logic:**
- Column header shows `status (count)`
- Task cards rendered up to `maxVisible`
- If `tasks.length > maxVisible`, show `+{tasks.length - maxVisible} more`
- Highlighted task has inverse colors or border

### 3.3 TaskCard Component

**File:** `src/board/TaskCard.tsx`

**Props:**
```typescript
interface TaskCardProps {
  task: Task;
  isHighlighted: boolean;
  truncated?: boolean;  // force truncation for compact view
}
```

**Display:**
- **ID:** Short ID (last 4 chars, e.g., "bd-a1")
- **Title:** Truncated to 40 characters
- **Priority Badge:** Color-coded (P0=red, P1=orange, P2=yellow, P3=green, P4=gray)

**Color Scheme:**
```
P0: red (bg 1; bold)
P1: orange (bg 208)
P2: yellow (bg 226)
P3: green (bg 34)
P4: gray (dim)
```

### 3.4 TaskDetail Component

**File:** `src/board/TaskDetail.tsx`

**Trigger:** `Enter` key when task is highlighted

**Dismiss:** `Esc` key

**Display:**
```
┌─────────────────────────────────────────────────────┐
│ bd-xxxx                                            │
│ ─────────────────────────────────────────────────── │
│ Title:    Task title here                          │
│ Status:   in_progress                             │
│ Priority: P2                                       │
│ Type:     task                                    │
│ Labels:   [frontend] [bug]                        │
│ ─────────────────────────────────────────────────── │
│ Description:                                       │
│ This is the full task description text that may   │
│ span multiple lines...                             │
│ ─────────────────────────────────────────────────── │
│ Created:  2026-04-15 14:32                        │
│ Updated:  2026-04-18 09:45                        │
│ Depends:  bd-yyyy                                  │
└─────────────────────────────────────────────────────┘
│ Press Esc to close                                 │
└─────────────────────────────────────────────────────┘
```

### 3.5 HelpOverlay Component

**File:** `src/board/HelpOverlay.tsx`

**Trigger:** `?` key

**Dismiss:** `Esc` or `?`

**Layout:**
```
┌─────────────────────────────────────────────────────┐
│                 KEYBOARD SHORTCUTS                  │
├─────────────────────────────────────────────────────┤
│ Navigation                                          │
│   j / k        Move down / up                      │
│   h / l        Move left / right                    │
│   g / G        Jump to top / bottom                │
│   1-6 + Enter  Jump to column by number             │
├─────────────────────────────────────────────────────┤
│ Task Actions                                        │
│   Enter       Show task details                    │
│   s / S       Cycle status forward / backward      │
│   c           Close task                           │
│   C           Close with reason                   │
│   e / E       Edit task in $EDITOR (basic/full)   │
├─────────────────────────────────────────────────────┤
│ General                                             │
│   r           Refresh board                        │
│   ?           Toggle this help                     │
│   q           Quit board                           │
└─────────────────────────────────────────────────────┘
              Press ? or Esc to close
```

---

## 4. CLI Interface

### 4.1 Command Definition

**File:** `src/cli/commands/board.ts`

**Usage:**
```bash
foreman board              # Open interactive board
foreman board --limit 5    # Limit tasks per column (default: 5)
foreman board --project x  # Board for specific project (future)
```

**Flags:**
| Flag | Description | Default |
|------|-------------|---------|
| `--limit <n>` | Max tasks visible per column | 5 |
| `--project <id>` | Filter by project (future) | all |

### 4.2 Keyboard Bindings

| Key | Action | State Change |
|-----|--------|--------------|
| `j` | Move highlight down | `currentRow + 1` (wrap to 0) |
| `k` | Move highlight up | `currentRow - 1` (wrap to last) |
| `h` | Move to left column | `currentColumn - 1` (wrap to 5) |
| `l` | Move to right column | `currentColumn + 1` (wrap to 0) |
| `g` | Jump to top | `currentRow = 0` |
| `G` | Jump to bottom | `currentRow = column.length - 1` |
| `Enter` | Show task details | `showDetail = true` |
| `q` | Quit board | Exit process |
| `s` | Cycle status forward | `status = nextStatus(status)` |
| `S` | Cycle status backward | `status = prevStatus(status)` |
| `[1-6]` + `Enter` | Jump to column | `currentColumn = n - 1` |
| `c` | Close task | `status = 'closed'` |
| `C` | Close with reason | `status = 'closed'`, prompt reason |
| `e` | Edit in $EDITOR | Open YAML, parse on exit |
| `E` | Edit with full schema | Open full YAML |
| `r` | Refresh | Reload from br |
| `?` | Toggle help | `showHelp = !showHelp` |
| `Esc` | Dismiss detail/help | `showDetail = false` or `showHelp = false` |

### 4.3 Status Cycle Order

```
backlog → ready → in_progress → review → blocked → closed
   ↑                                                          │
   └──────────────────────────────────────────────────────────┘
```

Forward (s): next in order (closed wraps to backlog)  
Backward (S): previous in order (backlog wraps to closed)

---

## 5. Data Flow

### 5.1 Read Flow (Task Loading)

```
Board.tsx mounts
    │
    ▼
useBoard hook (useEffect)
    │
    ▼
br list --status=open --format=json
    │
    ▼
Parse JSON → Task[]
    │
    ▼
Group by status → Map<Status, Task[]>
    │
    ▼
Update state.columns
```

### 5.2 Write Flow (Status Change)

```
User presses 's'
    │
    ▼
calculateNextStatus(currentStatus)
    │
    ▼
br update <taskId> --status <newStatus>
    │
    ▼
On success: refresh board (go to step 5.1)
On failure: show error toast
```

### 5.3 Editor Flow (YAML Edit)

```
User presses 'e'
    │
    ▼
Serialize task to YAML
    │
    ▼
Write to temp file (/tmp/foreman-board-edit-XXXXX.yaml)
    │
    ▼
Spawn $EDITOR on temp file
    │
    ▼
On editor exit (0):
    │
    ▼
Parse YAML from temp file
    │
    ▼
For each changed field:
    │
    ▼
br update <taskId> --<field> <value>
    │
    ▼
Refresh board, remove temp file
On editor exit (non-0):
    │
    ▼
Discard changes, remove temp file
On parse error:
    │
    ▼
Show error, keep temp file for retry
```

### 5.4 Task Data Model

```typescript
interface Task {
  id: string;           // "bd-xxxx" format
  title: string;
  description?: string;
  status: Status;
  priority: 'P0' | 'P1' | 'P2' | 'P3' | 'P4';
  issue_type: 'task' | 'bug' | 'feature' | 'epic' | 'chore' | 'docs' | 'question';
  labels?: string[];
  created_at?: string;
  updated_at?: string;
  depends_on?: string[];
}
```

---

## 6. Implementation Details

### 6.1 ink Component Structure

```typescript
import React from 'react';
import { Box, Text } from 'ink';

export const Board: React.FC = () => {
  const [state, dispatch] = useReducer(boardReducer, initialState);
  
  // Handle keyboard events
  useInput((input, key) => {
    // Dispatch actions based on key
  });
  
  return (
    <Box flexDirection="column">
      <Header taskCount={totalTasks} />
      <Box>
        {STATUS_ORDER.map((status, colIdx) => (
          <Column
            status={status}
            tasks={state.columns.get(status) || []}
            isSelected={state.currentColumn === colIdx}
            selectedIndex={state.currentColumn === colIdx ? state.currentRow : -1}
          />
        ))}
      </Box>
      {state.showDetail && <TaskDetail task={getSelectedTask()} />}
      {state.showHelp && <HelpOverlay />}
      <StatusBar message={state.successMessage || state.errorMessage} />
    </Box>
  );
};
```

### 6.2 Keyboard Handling

```typescript
import { useInput } from 'ink';

useInput((input, key) => {
  if (state.showDetail) {
    if (key.escape) dispatch({ type: 'HIDE_DETAIL' });
    return;
  }
  
  if (state.showHelp) {
    if (key.escape || input === '?') dispatch({ type: 'HIDE_HELP' });
    return;
  }
  
  switch (input) {
    case 'j': dispatch({ type: 'MOVE_DOWN' }); break;
    case 'k': dispatch({ type: 'MOVE_UP' }); break;
    case 'h': dispatch({ type: 'MOVE_LEFT' }); break;
    case 'l': dispatch({ type: 'MOVE_RIGHT' }); break;
    case 'g': dispatch({ type: 'JUMP_TOP' }); break;
    case 'G': dispatch({ type: 'JUMP_BOTTOM' }); break;
    case 's': dispatch({ type: 'CYCLE_FORWARD' }); break;
    case 'S': dispatch({ type: 'CYCLE_BACKWARD' }); break;
    case 'c': dispatch({ type: 'CLOSE_TASK' }); break;
    case 'C': dispatch({ type: 'CLOSE_WITH_REASON' }); break;
    case 'e': dispatch({ type: 'EDIT_TASK', fullSchema: false }); break;
    case 'E': dispatch({ type: 'EDIT_TASK', fullSchema: true }); break;
    case 'r': dispatch({ type: 'REFRESH' }); break;
    case '?': dispatch({ type: 'TOGGLE_HELP' }); break;
    case 'q': process.exit(0); break;
  }
  
  // Handle Enter for details
  if (key.return) {
    dispatch({ type: 'SHOW_DETAIL' });
  }
  
  // Handle number keys for column jump
  if (/^[1-6]$/.test(input)) {
    dispatch({ type: 'JUMP_TO_COLUMN', column: parseInt(input) - 1 });
  }
});
```

### 6.3 Task Store Interface

```typescript
// src/board/utils/taskStore.ts

export interface TaskStore {
  listTasks(): Promise<Task[]>;
  updateTask(id: string, updates: Partial<Task>): Promise<void>;
  closeTask(id: string, reason?: string): Promise<void>;
}

export class BrTaskStore implements TaskStore {
  async listTasks(): Promise<Task[]> {
    const result = execFileSync('br', ['list', '--status=open', '--format=json'], {
      encoding: 'utf-8',
    });
    return JSON.parse(result);
  }
  
  async updateTask(id: string, updates: Partial<Task>): Promise<void> {
    const args = ['update', id];
    if (updates.status) args.push('--status', updates.status);
    if (updates.priority) args.push('--priority', updates.priority);
    if (updates.title) args.push('--title', updates.title);
    execFileSync('br', args, { encoding: 'utf-8' });
  }
  
  async closeTask(id: string, reason?: string): Promise<void> {
    const args = ['close', id];
    if (reason) args.push('--reason', reason);
    execFileSync('br', args, { encoding: 'utf-8' });
  }
}
```

### 6.4 YAML Serialization

```typescript
// src/board/utils/yaml.ts

import yaml from 'js-yaml';

export function taskToYaml(task: Task, fullSchema: boolean): string {
  if (fullSchema) {
    return yaml.dump(task, { indent: 2 });
  }
  
  // Basic schema (FR-5)
  return yaml.dump({
    id: task.id,
    title: task.title,
    description: task.description,
    status: task.status,
    priority: task.priority,
    issue_type: task.issue_type,
    labels: task.labels || [],
  }, { indent: 2 });
}

export function yamlToTask(yamlStr: string): Partial<Task> {
  const parsed = yaml.load(yamlStr) as Record<string, unknown>;
  return {
    title: parsed.title as string,
    description: parsed.description as string | undefined,
    status: parsed.status as Status,
    priority: parsed.priority as Task['priority'],
    issue_type: parsed.issue_type as Task['issue_type'],
    labels: parsed.labels as string[] | undefined,
  };
}
```

### 6.5 Editor Integration

```typescript
// src/board/utils/editor.ts

import { writeFileSync, unlinkSync, readFileSync } from 'fs';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';
import { join } from 'path';

export function editInEditor(
  content: string,
  filename: string
): { success: boolean; content?: string; error?: string } {
  const tmpPath = join(tmpdir(), filename);
  
  // Write initial content
  writeFileSync(tmpPath, content, 'utf-8');
  
  // Get editor (FR-NFR-2)
  const editor = process.env.EDITOR || 
    findExecutable(['vim', 'nano', 'vi', 'emacs']) ||
    'vi';
  
  try {
    // Spawn editor
    execFileSync(editor, [tmpPath], {
      stdio: 'inherit',
      timeout: 300_000, // 5 minute timeout
    });
    
    // Read back modified content
    const modified = readFileSync(tmpPath, 'utf-8');
    return { success: true, content: modified };
  } catch (err) {
    // Non-zero exit (user cancelled or error)
    return { success: false, error: String(err) };
  } finally {
    // Clean up temp file
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

function findExecutable(candidates: string[]): string | null {
  const path = process.env.PATH || '';
  for (const exe of candidates) {
    if (path.split(':').some(dir => {
      try {
        execFileSync('test', ['-x', `${dir}/${exe}`]);
        return true;
      } catch {
        return false;
      }
    })) {
      return exe;
    }
  }
  return null;
}
```

### 6.6 Navigation Reducer

```typescript
// src/board/hooks/useNavigation.ts

type Action =
  | { type: 'MOVE_DOWN' }
  | { type: 'MOVE_UP' }
  | { type: 'MOVE_LEFT' }
  | { type: 'MOVE_RIGHT' }
  | { type: 'JUMP_TOP' }
  | { type: 'JUMP_BOTTOM' }
  | { type: 'JUMP_TO_COLUMN'; column: number }
  | { type: 'CYCLE_FORWARD' }
  | { type: 'CYCLE_BACKWARD' }
  | { type: 'REFRESH' };

function boardReducer(state: BoardState, action: Action): BoardState {
  switch (action.type) {
    case 'MOVE_DOWN': {
      const column = getColumn(state);
      const nextRow = (state.currentRow + 1) % column.length;
      return { ...state, currentRow: nextRow };
    }
    case 'MOVE_UP': {
      const column = getColumn(state);
      const prevRow = state.currentRow === 0 
        ? column.length - 1 
        : state.currentRow - 1;
      return { ...state, currentRow: prevRow };
    }
    case 'MOVE_LEFT': {
      const nextCol = state.currentColumn === 0 
        ? STATUS_ORDER.length - 1 
        : state.currentColumn - 1;
      const maxRow = (state.columns.get(STATUS_ORDER[nextCol])?.length || 1) - 1;
      return { 
        ...state, 
        currentColumn: nextCol,
        currentRow: Math.min(state.currentRow, Math.max(0, maxRow))
      };
    }
    case 'MOVE_RIGHT': {
      const nextCol = (state.currentColumn + 1) % STATUS_ORDER.length;
      const maxRow = (state.columns.get(STATUS_ORDER[nextCol])?.length || 1) - 1;
      return { 
        ...state, 
        currentColumn: nextCol,
        currentRow: Math.min(state.currentRow, Math.max(0, maxRow))
      };
    }
    case 'JUMP_TOP':
      return { ...state, currentRow: 0 };
    case 'JUMP_BOTTOM':
      const col = getColumn(state);
      return { ...state, currentRow: Math.max(0, col.length - 1) };
    case 'JUMP_TO_COLUMN':
      return { ...state, currentColumn: action.column, currentRow: 0 };
    case 'CYCLE_FORWARD':
    case 'CYCLE_BACKWARD':
      // Status changes handled separately (requires API call)
      return state;
    default:
      return state;
  }
}
```

---

## 7. Testing Strategy

### 7.1 Unit Tests

| File | What to Test |
|------|--------------|
| `utils/yaml.test.ts` | `taskToYaml`, `yamlToTask` |
| `utils/taskStore.test.ts` | Task store interface methods (mocked) |
| `hooks/useNavigation.test.ts` | All navigation reducer cases |
| `Board.test.tsx` | Component rendering (mock state) |

### 7.2 Integration Tests

| File | What to Test |
|------|--------------|
| `commands/board.test.ts` | CLI argument parsing, flag handling |
| `board.e2e.test.ts` | Full keyboard flow simulation |

### 7.3 Test Cases for Navigation Reducer

```typescript
describe('boardReducer', () => {
  it('MOVE_DOWN wraps to top at column end', () => {
    const state = { ...initialState, currentRow: 2, currentColumn: 0 };
    const column = state.columns.get('backlog')!;
    const nextState = boardReducer(state, { type: 'MOVE_DOWN' });
    expect(nextState.currentRow).toBe(0); // Wrapped
  });
  
  it('MOVE_LEFT wraps from first column to last', () => {
    const state = { ...initialState, currentColumn: 0 };
    const nextState = boardReducer(state, { type: 'MOVE_LEFT' });
    expect(nextState.currentColumn).toBe(5); // Wrapped to 'closed'
  });
  
  it('JUMP_TO_COLUMN sets column and resets row', () => {
    const state = { ...initialState, currentRow: 5 };
    const nextState = boardReducer(state, { type: 'JUMP_TO_COLUMN', column: 3 });
    expect(nextState.currentColumn).toBe(3);
    expect(nextState.currentRow).toBe(0);
  });
});
```

### 7.4 Test Cases for YAML Serialization

```typescript
describe('taskToYaml', () => {
  it('serializes basic schema correctly', () => {
    const task: Task = {
      id: 'bd-1234',
      title: 'Test task',
      status: 'in_progress',
      priority: 'P2',
      issue_type: 'task',
    };
    const yaml = taskToYaml(task, false);
    expect(yaml).toContain('id: bd-1234');
    expect(yaml).toContain('title: Test task');
    expect(yaml).not.toContain('created_at'); // not in basic schema
  });
  
  it('serializes full schema when requested', () => {
    const task = createFullTask();
    const yaml = taskToYaml(task, true);
    expect(yaml).toContain('created_at:');
    expect(yaml).toContain('depends_on:');
  });
});

describe('yamlToTask', () => {
  it('parses valid YAML', () => {
    const yaml = `
id: bd-1234
title: Updated title
status: review
`;
    const updates = yamlToTask(yaml);
    expect(updates.title).toBe('Updated title');
    expect(updates.status).toBe('review');
  });
  
  it('throws on invalid YAML', () => {
    expect(() => yamlToTask('not: [valid: yaml')).toThrow();
  });
});
```

---

## 8. Acceptance Criteria

### AC-1: Board Renders Correctly
- [ ] Board displays 6 columns (backlog, ready, in_progress, review, blocked, closed)
- [ ] Each column shows correct task count in header
- [ ] Task cards display: short ID, truncated title (40 chars), priority badge
- [ ] Highlighted task has distinct visual styling (inverse video or border)

### AC-2: Navigation Works
- [ ] `j` moves highlight down within column (wraps)
- [ ] `k` moves highlight up within column (wraps)
- [ ] `h` moves to left column (wraps from backlog to closed)
- [ ] `l` moves to right column (wraps from closed to backlog)
- [ ] `g` jumps to first task in current column
- [ ] `G` jumps to last task in current column
- [ ] Number keys 1-6 jump directly to respective columns

### AC-3: Status Change Works
- [ ] `s` advances status to next in order
- [ ] `S` moves status to previous in order
- [ ] Status wraps (closed→backlog, backlog→closed)
- [ ] Status change persists after `r` refresh
- [ ] Visual feedback (brief highlight) on moved task

### AC-4: Close Works
- [ ] `c` closes highlighted task immediately
- [ ] `C` prompts for reason, then closes
- [ ] Closed task appears in closed column immediately

### AC-5: Editor Works
- [ ] `e` opens basic task YAML in `$EDITOR`
- [ ] `E` opens full schema YAML in `$EDITOR`
- [ ] Changes saved on editor exit (code 0)
- [ ] Changes discarded on editor error (non-zero exit)
- [ ] Invalid YAML shows error, does not save

### AC-6: Task Detail Works
- [ ] `Enter` shows expanded task detail panel
- [ ] `Esc` dismisses detail panel

### AC-7: Help Works
- [ ] `?` shows keybinding help overlay
- [ ] `Esc` or `?` dismisses help overlay

### AC-8: Error Handling
- [ ] Store unavailable shows error banner
- [ ] Editor not set shows helpful error message
- [ ] Network errors show toast with retry option

### AC-9: Performance
- [ ] Board renders < 200ms with 200 tasks
- [ ] Key response < 50ms
- [ ] Status change + re-render < 300ms

---

## 9. File Structure

```
src/
  board/
    index.ts           # CLI entry point (board.ts command)
    Board.tsx          # Root component
    Column.tsx         # Status column component
    TaskCard.tsx       # Individual task card
    TaskDetail.tsx     # Expanded task detail panel
    HelpOverlay.tsx    # Keybinding help overlay
    StatusBar.tsx      # Bottom status bar
    Header.tsx         # Board header with title
    hooks/
      useBoard.ts      # Task loading + refresh logic
      useNavigation.ts # Keyboard navigation + reducer
    utils/
      taskStore.ts     # Task store interface (br client)
      yaml.ts          # YAML serialization/deserialization
      editor.ts        # $EDITOR integration
      constants.ts     # STATUS_ORDER, etc.
    types.ts           # TypeScript interfaces
  cli/
    commands/
      board.ts         # Commander command definition
```

### 9.1 New Dependencies

No new dependencies required:
- `ink` - likely already in Foreman's TUI components (or add it)
- `js-yaml` - already in dependencies

---

## 10. Open Questions

| # | Question | Resolution |
|---|----------|------------|
| OQ-1 | Should we use ink or blessed? | ink (React patterns match codebase) |
| OQ-2 | Do we need to handle `closed` tasks in the board view? | Yes, show closed column for completeness |
| OQ-3 | Should `C` (close with reason) prompt inline or use $EDITOR? | Inline prompt is faster |
| OQ-4 | How do we handle very long task titles? | Truncate to 40 chars with ellipsis |
| OQ-5 | Should we persist navigation position between refreshes? | No, reset to first column on refresh |
| OQ-6 | Do we need to support multiple projects? | Not in v1, focus on single project |
| OQ-7 | How to handle br not installed? | Show error with install instructions |

---

## Appendix: Command Flag Specification

```typescript
// src/cli/commands/board.ts
export const boardCommand = new Command('board')
  .description('Interactive kanban board for task management')
  .option(
    '--limit <n>',
    'Maximum tasks shown per column (default: 5)',
    parseInt,
    5
  )
  .option(
    '--no-color',
    'Disable color output'
  )
  .action(async ({ limit }) => {
    // Initialize board
    await render(<Board limit={limit} />);
  });
```

---

*Document created: 2026-04-19*  
*Next: Implementation via /ensemble:implement-trd*