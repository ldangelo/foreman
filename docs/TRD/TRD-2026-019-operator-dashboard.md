# TRD: Single-Pane Operator Dashboard

**Document ID:** TRD-2026-019  
**PRD Reference:** PRD-2026-019-operator-dashboard  
**Created:** 2026-04-21  
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
8. [Sprint Planning](#8-sprint-planning)
9. [Acceptance Criteria](#9-acceptance-criteria)
10. [File Structure](#10-file-structure)
11. [Cross-References](#11-cross-references)
12. [Open Questions](#12-open-questions)

---

## 1. Overview

### 1.1 Purpose

This TRD specifies the technical implementation of a **Single-Pane Operator Dashboard** for Foreman — a unified terminal UI (TUI) that consolidates three operational views into one cohesive interface:

1. **Running Tasks View** — Hierarchical display of active pipeline runs with phase progress
2. **Board View** — Kanban-style visualization of task states (Ready | In Progress | Blocked | Done)
3. **Inbox View** — Agent mail display with unread badges and message previews

The dashboard replaces the need to switch between `foreman status`, `foreman board`, and `foreman inbox` commands, providing real-time updates and vim-style navigation.

### 1.2 Relationship to Existing Commands

| Existing Command | What It Does | Dashboard Integration |
|-----------------|--------------|---------------------|
| `foreman dashboard` | Multi-project agent observability | **Replaces** with single-pane 3-view TUI |
| `foreman board` | Kanban board (6 columns via Ink) | **Incorporates** 4-column board view |
| `foreman inbox` | Agent mail viewer | **Incorporates** inbox with unread badges |
| `foreman status` | Run status table | **Replaced by** Running Tasks hierarchy |

**Key Difference from `foreman dashboard` (existing):**
- Current dashboard uses multiline ANSI text output with polling
- New dashboard uses terminal pane multiplexing (WezTerm/Zellij/tmux)
- New dashboard unifies three views with vim-style navigation
- New dashboard uses collapsible sections per view

### 1.3 Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| TUI Framework | Pure ANSI + Node.js readline | Lightweight, no React dependency, supports raw terminal mode |
| Terminal Panes | Existing multiplexer adapters | Reuse `ensemble-multiplexer-adapters` for WezTerm/Zellij/tmux |
| State Management | `StateManager` class | Aggregates data from SQLite stores, calculates cross-references |
| Real-time Updates | Signal file polling | Signal files in `.foreman/signals/` for state change notifications |
| Data Sources | Existing SQLite stores | `ForemanStore` for runs, `NativeTaskStore` for tasks, mail from messages table |
| Keyboard Input | Node.js `readline` raw mode | Vim-style navigation with debouncing |

### 1.4 Constraints

- **No new native API**: Uses existing store types and methods
- **Minimum terminal size**: 100x30 characters
- **Color support**: 256-color ANSI minimum
- **Keyboard-only operation**: Full functionality via vim bindings
- **Backward compatibility**: Existing `foreman dashboard` command preserved

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLI Entry Point                                  │
│                         `foreman operator-dashboard`                           │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Dashboard Orchestrator                                 │
│                              (index.ts)                                       │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────────────────┐   │
│  │ StateManager    │  │ ViewRenderer      │  │ KeyboardNavigation         │   │
│  │ (aggregator)    │  │ (unified output)  │  │ (vim-style handler)        │   │
│  └────────┬────────┘  └─────────┬─────────┘  └────────────────────────────┘   │
│           │                    │                                              │
│           ├────────────────────┼──────────────────────┐                       │
│           ▼                    ▼                      ▼                       │
│  ┌────────────────┐   ┌─────────────────┐   ┌──────────────────────┐        │
│  │ RunStore       │   │ TaskStore        │   │ MailStore             │        │
│  │ (ForemanStore) │   │ (NativeTaskStore)│   │ (SqliteMailClient)   │        │
│  └────────────────┘   └─────────────────┘   └──────────────────────┘        │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                         Signal File Watcher                              │  │
│  │  .foreman/signals/*.signal  →  StateManager.onChange()  →  Re-render   │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Component Hierarchy

```
OperatorDashboard (root)
├── DashboardHeader (title, global badges)
├── ViewContainer
│   ├── RunningTasksView (collapsible)
│   │   ├── RunSummaryCard[]
│   │   │   ├── PhaseTree (expandable)
│   │   │   ├── ProgressBar
│   │   │   └── MailBadge
│   │   └── RunningTasksFooter (count, sort controls)
│   ├── BoardView (collapsible)
│   │   ├── BoardColumn[] (4 columns: Ready, In Progress, Blocked, Done)
│   │   │   ├── ColumnHeader (name, count)
│   │   │   └── BeadCard[]
│   │   └── BoardFooter (navigation hints)
│   └── InboxView (collapsible)
│       ├── MessageList[]
│       │   ├── MessageHeader (subject, from, timestamp)
│       │   ├── MessagePreview (first 3 lines when focused)
│       │   └── UnreadBadge
│       └── InboxFooter (count, filter controls)
├── NavigationFooter (j/k/1/2/3 hints, refresh indicator)
└── HelpOverlay (shown on ?)
```

### 2.3 State Management

```typescript
// src/dashboard/types.ts

export type ViewId = 'tasks' | 'board' | 'inbox';

export interface DashboardState {
  /** Currently focused view */
  activeView: ViewId;
  
  /** Cursor position within each view */
  cursor: CursorPosition;
  
  /** Expanded/collapsed state for each view */
  collapsedViews: Set<ViewId>;
  
  /** Expanded runs in Running Tasks view */
  expandedRuns: Set<string>;
  
  /** Last successful data refresh */
  lastRefresh: Date;
  
  /** Whether a refresh is in progress */
  refreshing: boolean;
  
  /** Aggregate data from all stores */
  views: {
    tasks: RunningTasksView;
    board: BoardView;
    inbox: InboxView;
  };
}

export interface CursorPosition {
  view: ViewId;
  row: number;      // Vertical position within view
  col: number;      // For board: column index (0-3)
  itemId?: string;  // Optional: ID of focused item
}

export interface RunningTasksView {
  runs: RunSummary[];
  totalCount: number;
  runningCount: number;
  failedCount: number;
}

export interface RunSummary {
  runId: string;
  beadId: string;
  priority: number;
  status: 'running' | 'paused' | 'failed' | 'completed';
  startedAt: Date;
  durationMs: number;
  progress: number;  // 0-100
  phases: PhaseSummary[];
  worktreePath?: string;
  mailCount: number;
}

export interface PhaseSummary {
  name: string;
  status: 'pending' | 'running' | 'completed' | 'failed';
  startedAt?: Date;
  completedAt?: Date;
  durationMs?: number;
}

export interface BoardView {
  columns: {
    ready: BeadItem[];
    in_progress: BeadItem[];
    blocked: BeadItem[];
    done: BeadItem[];
  };
  totalCount: number;
}

export interface BeadItem {
  beadId: string;
  title: string;
  priority: number;
  status: string;
  blockedBy: string[];
  runId?: string;  // Linked run if active
}

export interface InboxView {
  messages: MailMessage[];
  unreadCount: number;
  totalCount: number;
}

export interface MailMessage {
  id: string;
  subject: string;
  from: string;
  to: string;
  body: string;
  preview: string;  // First 100 chars
  timestamp: Date;
  isRead: boolean;
  runId?: string;
  beadId?: string;
}
```

### 2.4 View Column Configuration

The dashboard uses 4 Kanban columns (different from existing board's 6):

```typescript
// Board columns match PRD: Ready | In Progress | Blocked | Done
const BOARD_COLUMNS = [
  'ready',
  'in_progress', 
  'blocked',
  'done'
] as const;
type BoardColumn = typeof BOARD_COLUMNS[number];

// Status mapping from NativeTaskStore to board columns
const STATUS_TO_COLUMN: Record<string, BoardColumn> = {
  'backlog': 'ready',      // Backlog → Ready
  'ready': 'ready',
  'in_progress': 'in_progress',
  'blocked': 'blocked',
  'review': 'in_progress', // Review → In Progress (QA phase)
  'closed': 'done',
  'completed': 'done',
  'merged': 'done',
};
```

---

## 3. Component Specifications

### 3.1 StateManager

**File:** `src/dashboard/state-manager.ts`

**Responsibilities:**
- Aggregate data from ForemanStore (runs), NativeTaskStore (tasks), SqliteMailClient (messages)
- Calculate cross-references (run → bead, mail → run, bead → run)
- Maintain unified DashboardState
- Trigger re-renders on state changes

**Public API:**

```typescript
export class StateManager {
  constructor(projectPath: string);
  
  /** Get current dashboard state */
  getState(): DashboardState;
  
  /** Refresh all data from stores */
  async refresh(): Promise<void>;
  
  /** Subscribe to state changes */
  onChange(callback: (state: DashboardState) => void): () => void;
  
  /** Get runs filtered by status */
  getRuns(status?: RunStatus[]): RunSummary[];
  
  /** Get tasks filtered by column */
  getTasksByColumn(column: BoardColumn): BeadItem[];
  
  /** Get mail messages with cross-references */
  getMessages(options?: { unreadOnly?: boolean }): MailMessage[];
  
  /** Close all store connections */
  close(): void;
}
```

### 3.2 ViewRenderer

**File:** `src/dashboard/view-renderer.ts`

**Responsibilities:**
- Convert DashboardState to ANSI-escaped terminal output
- Manage cursor positioning and highlighting
- Render collapsible sections
- Format progress bars, badges, and color codes

**ANSI Color Palette:**

```typescript
// From PRD specification
const COLORS = {
  // Dashboard Frame
  FRAME: '\033[36m',           // Cyan
  HEADER: '\033[1;97m',         // Bold white
  
  // Status Colors
  RUNNING: '\033[32m',          // Green
  FAILED: '\033[31m',           // Red
  PAUSED: '\033[33m',          // Yellow
  COMPLETED: '\033[90m',       // Dim gray
  
  // Priority Colors
  P0: '\033[41m\033[97m',      // Red bg, white text
  P1: '\033[43m\033[30m',      // Orange bg, black text
  P2: '\033[33m',               // Yellow
  P3: '\033[32m',               // Green
  P4: '\033[90m',               // Dim gray
  
  // Progress Bar
  PROGRESS_FILL: '\033[42m',   // Green
  PROGRESS_EMPTY: '\033[100m', // Gray
  
  // Interactive
  HIGHLIGHT: '\033[1;4;36m',   // Bold, underline, cyan
  CURSOR: '\033[7m',            // Inverse video
  SELECTED: '\033[44m',         // Blue background
  
  // Utility
  RESET: '\033[0m',
  BOLD: '\033[1m',
  DIM: '\033[2m',
};
```

### 3.3 RunningTasksView

**File:** `src/dashboard/views/running-tasks.ts`

**Responsibilities:**
- Display active runs with phase hierarchy
- Show progress bars and duration
- Expand/collapse phases on Enter
- Cross-reference to related mail

**Output Format:**

```
▼ foreman-001  [P1] ●running                         [████░░] 60%
  ├─ ✓ Explorer  [12m 30s]
  ├─ → Developer [5m 15s]
  ├─ ○ QA        [pending]
  └─ ○ Finalize  [pending]

▶ foreman-002  [P0] ●failed                           [██░░░░░] 40%
  └─ ✗ Developer [3m 42s] Error: TypeError at src/foo.ts
```

**Symbols:**
- `▼` / `▶` — Run expanded / collapsed
- `✓` — Phase completed
- `→` — Phase currently running
- `○` — Phase pending
- `✗` — Phase failed
- `●` — Status indicator (●running, ●failed, ●paused, ●completed)

### 3.4 BoardView

**File:** `src/dashboard/views/board.ts`

**Responsibilities:**
- Display 4-column Kanban board
- Navigate between columns (h/l)
- Show task cards with priority badges
- Navigate within column (j/k)

**Output Format:**

```
┌─────────────┬─────────────┬─────────────┬─────────────┐
│   READY     │ IN PROGRESS │   BLOCKED   │    DONE     │
│    (4)      │     (2)     │     (1)     │     (7)     │
├─────────────┼─────────────┼─────────────┼─────────────┤
│ [P1] Task A │ [P0] Task D │ [P2] Task G │ [P3] Task J │
│ [P2] Task B │ [P1] Task E │             │ [P3] Task K │
│ [P3] Task C │             │             │ [P3] Task L │
└─────────────┴─────────────┴─────────────┴─────────────┘
```

**Navigation:**
- `h` / `l` — Move between columns
- `j` / `k` — Move within column
- `Enter` — Open task detail (run-related info)

### 3.5 InboxView

**File:** `src/dashboard/views/inbox.ts`

**Responsibilities:**
- Display mail messages chronologically
- Show unread badges
- Expand message preview on focus
- Cross-reference to related runs

**Output Format:**

```
✉ 4 unread ─────────────────────────────────────────────────────
┌────────────────────────────────────────────────────────────────┐
│ [●] Phase Complete          developer → qa        2m ago      │
│     Developer finished phase 'explorer', ready for QA.       │
├────────────────────────────────────────────────────────────────┤
│ [○] Build Failed            qa → foreman         5m ago      │
│     Tests failed in src/utils/parser.ts:42                     │
└────────────────────────────────────────────────────────────────┘
```

**Symbols:**
- `[●]` — Unread message
- `[○]` — Read message
- `→` — Direction indicator (from → to)

### 3.6 KeyboardNavigation

**File:** `src/dashboard/navigation/keyboard-nav.ts`

**Responsibilities:**
- Handle raw terminal input
- Implement vim-style keybindings
- Debounce rapid keypresses
- Manage cursor state

**Keybindings:**

| Key | Action | View |
|-----|--------|------|
| `j` / `↓` | Move cursor down | All |
| `k` / `↑` | Move cursor up | All |
| `h` / `←` | Move left / previous view | All |
| `l` / `→` | Move right / next column | All |
| `1` | Focus Running Tasks | All |
| `2` | Focus Board | All |
| `3` | Focus Inbox | All |
| `Enter` / `Space` | Expand/collapse / toggle | All |
| `gg` | Jump to first item | All |
| `G` | Jump to last item | All |
| `Ctrl+d` | Page down | All |
| `Ctrl+u` | Page up | All |
| `/` | Open search | All |
| `n` | Next search result | All |
| `N` | Previous search result | All |
| `r` | Refresh now | All |
| `?` | Show help overlay | All |
| `q` | Quit dashboard | All |

**Sequence Detection (for `gg`):**

```typescript
// Debounce and sequence detection
const keySequence: string[] = [];
const SEQUENCE_TIMEOUT = 500; // ms

function handleKey(key: string): void {
  keySequence.push(key);
  
  // Check for 'gg' sequence
  if (keySequence.length >= 2) {
    const lastTwo = keySequence.slice(-2).join('');
    if (lastTwo === 'gg') {
      jumpToFirst();
      keySequence.length = 0;
      return;
    }
  }
  
  // Timeout: clear sequence
  setTimeout(() => {
    if (keySequence.length > 0) {
      keySequence.length = 0;
    }
  }, SEQUENCE_TIMEOUT);
}
```

### 3.7 SignalFileWatcher

**File:** `src/dashboard/signal-watcher.ts`

**Responsibilities:**
- Watch `.foreman/signals/` directory for signal files
- Debounce rapid successive updates (100ms window)
- Notify StateManager on changes
- Handle graceful shutdown

**Signal File Format:**

```
# .foreman/signals/<type>_<timestamp>_<pid>.signal
type:run_progress
run_id:foreman-001
timestamp:2026-04-21T10:30:00Z
```

**Watched Signal Types:**

| Signal Type | Trigger |
|-------------|---------|
| `run_start` | New run dispatched |
| `run_progress` | Phase change or heartbeat |
| `run_complete` | Run finished (success/fail) |
| `mail_received` | New message in inbox |
| `bead_update` | Task status changed |

---

## 4. CLI Interface

### 4.1 Command Definition

**File:** `src/cli/commands/operator-dashboard.ts`

```typescript
export const operatorDashboardCommand = new Command("operator-dashboard")
  .alias("opdash")
  .description("Single-pane operator dashboard with running tasks, board, and inbox")
  .option("--refresh <ms>", "Auto-refresh interval (default: 5000, min: 1000)", "5000")
  .option("--no-watch", "Single snapshot, no polling")
  .option("--project <id>", "Filter to specific project ID")
  .option("--default-view <view>", "Initial view: tasks|board|inbox", "tasks")
  .option("--pane-direction <dir>", "Pane direction: right|bottom|left|top", "right")
  .option("--pane-size <pct>", "Pane size percentage (10-50)", "40")
  .action(async (opts) => {
    // Implementation...
  });
```

### 4.2 Usage Examples

```bash
# Launch full dashboard with live updates
foreman operator-dashboard

# Launch with 2s refresh
foreman operator-dashboard --refresh 2000

# Single snapshot (no polling)
foreman operator-dashboard --no-watch

# Start on board view
foreman operator-dashboard --default-view board

# Shortcut alias
foreman opdash
```

### 4.3 Exit Behavior

- `q` — Clean exit, restore cursor, show summary
- `Ctrl+C` — Detach (agents continue), clean exit
- Terminal close — Graceful cleanup via signal handler

---

## 5. Data Flow

### 5.1 Initialization Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLI Entry                                 │
│                    operator-dashboard                             │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     DashboardOrchestrator                        │
│                          .init()                                 │
│                                                                  │
│  1. Parse CLI options                                            │
│  2. Create StateManager                                          │
│  3. Create ViewRenderer                                          │
│  4. Create SignalFileWatcher                                     │
│  5. Initialize keyboard handler                                  │
│  6. Show terminal cursor (hidden during render)                  │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Main Loop                                 │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  StateManager.refresh()  ──────────────────────────────────│►│
│  │  ViewRenderer.render(state)  ─────────────────────────────│►│
│  │  Write to terminal (ANSI)                                  │ │
│  │  Wait for keyboard input OR refresh interval               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│              ┌───────────────┼───────────────┐                 │
│              │               │               │                 │
│              ▼               ▼               ▼                 │
│         [keyboard]     [signal]      [timeout]                  │
│              │               │               │                 │
│              └───────────────┼───────────────┘                 │
│                              │                                   │
│                      back to refresh                             │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Cross-Reference Calculation

```typescript
// In StateManager.refresh()

// 1. Load all runs
const runs = store.getActiveRuns(projectId);

// 2. Load all tasks
const tasks = taskStore.getAllTasks();

// 3. Load all messages
const messages = store.getAllMessagesGlobal(100);

// 4. Calculate cross-references
const runToMail = new Map<string, MailMessage[]>();
for (const msg of messages) {
  const existing = runToMail.get(msg.run_id) ?? [];
  existing.push(msg);
  runToMail.set(msg.run_id, existing);
}

const taskToRun = new Map<string, string>();
for (const run of runs) {
  if (run.seed_id) {
    taskToRun.set(run.seed_id, run.id);
  }
}

// 5. Build unified state
const state: DashboardState = {
  views: {
    tasks: {
      runs: runs.map(run => ({
        ...run,
        mailCount: runToMail.get(run.id)?.length ?? 0,
        phases: extractPhases(run.progress),
      })),
      totalCount: runs.length,
      runningCount: runs.filter(r => r.status === 'running').length,
      failedCount: runs.filter(r => r.status === 'failed').length,
    },
    board: {
      columns: {
        ready: tasks.filter(t => STATUS_TO_COLUMN[t.status] === 'ready'),
        in_progress: tasks.filter(t => STATUS_TO_COLUMN[t.status] === 'in_progress'),
        blocked: tasks.filter(t => STATUS_TO_COLUMN[t.status] === 'blocked'),
        done: tasks.filter(t => STATUS_TO_COLUMN[t.status] === 'done'),
      },
      totalCount: tasks.length,
    },
    inbox: {
      messages: messages.map(msg => ({
        ...msg,
        preview: msg.body.slice(0, 100),
        isRead: msg.read === 1,
        runId: msg.run_id,
        beadId: run?.seed_id,
      })),
      unreadCount: messages.filter(m => m.read === 0).length,
      totalCount: messages.length,
    },
  },
};
```

---

## 6. Implementation Details

### 6.1 Terminal Output Strategy

**No external TUI library** — pure ANSI escape codes via Node.js:

```typescript
// src/dashboard/ansi.ts

export const ANSI = {
  CLEAR_SCREEN: '\x1B[2J\x1B[H',
  HIDE_CURSOR: '\x1b[?25l',
  SHOW_CURSOR: '\x1b[?25h',
  CURSOR_POSITION: (row: number, col: number) => `\x1B[${row};${col}H`,
  SAVE_CURSOR: '\x1b[s',
  RESTORE_CURSOR: '\x1b[u',
  ERASE_LINE: '\x1B[2K',
  ERASE_TO_END: '\x1B[0J',
};

// Example: render a progress bar
export function renderProgressBar(progress: number, width: number): string {
  const filled = Math.round((progress / 100) * width);
  const empty = width - filled;
  return `${COLORS.PROGRESS_FILL}${'█'.repeat(filled)}${COLORS.PROGRESS_EMPTY}${'░'.repeat(empty)}${COLORS.RESET}`;
}
```

### 6.2 Keyboard Input Handling

```typescript
// src/dashboard/navigation/keyboard-nav.ts

export class KeyboardNavigator {
  private stdin: Readable;
  private handlers: Map<string, () => void>;
  
  constructor(onKey: (key: string) => void) {
    this.stdin = process.stdin;
    this.handlers = new Map();
    
    if (this.stdin.isTTY) {
      this.stdin.setRawMode(true);
    }
    
    this.stdin.on('data', (chunk: Buffer) => {
      const key = this.decodeKey(chunk);
      onKey(key);
    });
  }
  
  private decodeKey(chunk: Buffer): string {
    const str = chunk.toString();
    
    // Handle escape sequences (arrow keys, etc.)
    if (str.startsWith('\x1B[')) {
      const seq = str.slice(2);
      switch (seq) {
        case 'A': return 'UP';
        case 'B': return 'DOWN';
        case 'C': return 'RIGHT';
        case 'D': return 'LEFT';
        default: return str;
      }
    }
    
    // Handle special keys
    switch (chunk[0]) {
      case 13: return 'ENTER';
      case 32: return 'SPACE';
      case 3:  return 'CTRL_C';
      default: return str;
    }
  }
  
  destroy(): void {
    this.stdin.removeAllListeners('data');
    if (this.stdin.isTTY) {
      this.stdin.setRawMode(false);
    }
  }
}
```

### 6.3 Real-Time Update Strategy

```typescript
// src/dashboard/signal-watcher.ts

import { watch } from 'node:fs';
import { watchFile } from 'node:fs';

export class SignalFileWatcher {
  private watcher: ReturnType<typeof watch> | null = null;
  private debounceTimer: NodeJS.Timeout | null = null;
  private readonly DEBOUNCE_MS = 100;
  
  constructor(
    private signalDir: string,
    private onChange: () => void,
  ) {}
  
  start(): void {
    // Use fs.watch for directory watching
    this.watcher = watch(this.signalDir, (eventType, filename) => {
      if (filename?.endsWith('.signal')) {
        this.debounce();
      }
    });
  }
  
  private debounce(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.onChange();
      this.debounceTimer = null;
    }, this.DEBOUNCE_MS);
  }
  
  stop(): void {
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
    }
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }
  }
}
```

### 6.4 Existing Store Integration

**ForemanStore** (runs, events, messages):
```typescript
// Get active runs
const activeRuns = store.getActiveRuns(projectId);

// Get run progress
const progress = store.getRunProgress(runId);

// Get messages for a run
const messages = store.getAllMessagesGlobal(100);
```

**NativeTaskStore** (tasks):
```typescript
// Get all tasks
const taskStore = new NativeTaskStore(store.getDb(), { projectKey });
const tasks = taskStore.getAllTasks();
```

**SqliteMailClient** (agent mail):
```typescript
// Get messages with unread status
const messages = store.getAllMessagesGlobal(100)
  .map(m => ({
    ...m,
    isRead: m.read === 1,
  }));
```

### 6.5 Performance Considerations

| Metric | Target | Implementation |
|--------|--------|----------------|
| Initial render | <1s | Concurrent store reads |
| Update latency | <500ms | Signal file + debounce |
| Memory usage | <20MB | No caching of large payloads |
| Keyboard latency | <50ms | Raw mode, no debounce |

---

## 7. Testing Strategy

### 7.1 Unit Tests

**Files:** `src/dashboard/__tests__/`

| Test File | Coverage |
|-----------|----------|
| `state-manager.test.ts` | Data aggregation, cross-reference calculation |
| `view-renderer.test.ts` | ANSI output formatting, progress bars |
| `keyboard-nav.test.ts` | Key sequence detection, cursor movement |
| `signal-watcher.test.ts` | Debouncing, file change detection |

**Example Test:**

```typescript
// src/dashboard/__tests__/state-manager.test.ts
describe('StateManager', () => {
  describe('crossReferenceCalculation', () => {
    it('should link mail messages to runs by run_id', async () => {
      const manager = new StateManager(testProjectPath);
      await manager.refresh();
      
      const state = manager.getState();
      const runWithMail = state.views.tasks.runs.find(r => r.mailCount > 0);
      
      expect(runWithMail).toBeDefined();
      expect(runWithMail!.mailCount).toBeGreaterThan(0);
    });
  });
});
```

### 7.2 Integration Tests

**Files:** `src/integration/__tests__/operator-dashboard.e2e.test.ts`

```typescript
describe('Operator Dashboard E2E', () => {
  it('should launch and render all three views', async () => {
    // Start dashboard in background
    const proc = spawn('node', ['dist/foreman-bundle.js', 'operator-dashboard', '--no-watch']);
    
    // Wait for initial render
    await waitForOutput(proc, 'Running Tasks');
    await waitForOutput(proc, 'Board');
    await waitForOutput(proc, 'Inbox');
    
    proc.kill();
  });
  
  it('should update within 500ms of signal', async () => {
    // Start dashboard
    // Trigger a run phase change
    // Measure time to update
  });
});
```

### 7.3 Test Coverage Targets

| Type | Target | Critical Paths |
|------|--------|---------------|
| Unit | >=80% | StateManager, ViewRenderer, KeyboardNav |
| Integration | >=70% | Full render cycle, keyboard navigation |
| E2E | Smoke only | Launch, view switching, refresh |

---

## 8. Sprint Planning

### 8.1 Task Breakdown

| Task ID | Description | Est. Hours | Dependencies |
|---------|-------------|------------|--------------|
| **DASH-001** | Create dashboard module structure and types | 2 | — |
| **DASH-002** | Implement StateManager with data aggregation | 4 | DASH-001 |
| **DASH-003** | Implement ANSI rendering helpers | 2 | DASH-001 |
| **DASH-004** | Implement ViewRenderer with collapsible sections | 6 | DASH-002, DASH-003 |
| **DASH-005** | Implement RunningTasksView | 4 | DASH-004 |
| **DASH-006** | Implement BoardView (4 columns) | 4 | DASH-004 |
| **DASH-007** | Implement InboxView | 4 | DASH-004 |
| **DASH-008** | Implement KeyboardNavigator with vim bindings | 6 | DASH-004 |
| **DASH-009** | Implement SignalFileWatcher for real-time updates | 3 | DASH-002 |
| **DASH-010** | Create CLI command entry point | 2 | DASH-004, DASH-008 |
| **DASH-011** | Add unit tests for StateManager | 2 | DASH-002 |
| **DASH-012** | Add unit tests for ViewRenderer | 2 | DASH-004 |
| **DASH-013** | Add unit tests for KeyboardNavigator | 2 | DASH-008 |
| **DASH-014** | Integration test with mock stores | 3 | DASH-010 |
| **DASH-015** | Documentation and help text | 1 | — |

### 8.2 Sprint Organization

**Sprint 1: Core Infrastructure (8 hours)**
- DASH-001: Module structure
- DASH-002: StateManager
- DASH-003: ANSI helpers
- DASH-009: SignalFileWatcher

**Sprint 2: View Rendering (14 hours)**
- DASH-004: ViewRenderer
- DASH-005: RunningTasksView
- DASH-006: BoardView
- DASH-007: InboxView

**Sprint 3: Navigation & CLI (11 hours)**
- DASH-008: KeyboardNavigator
- DASH-010: CLI command
- DASH-015: Documentation

**Sprint 4: Testing & Polish (10 hours)**
- DASH-011: StateManager tests
- DASH-012: ViewRenderer tests
- DASH-013: KeyboardNavigator tests
- DASH-014: Integration tests

---

## 9. Acceptance Criteria

### 9.1 Launch Criteria

| ID | Criteria | Test Method |
|----|----------|-------------|
| AC1.1 | `foreman operator-dashboard` command exists | CLI help |
| AC1.2 | Dashboard renders within 1 second | Timer measurement |
| AC1.3 | Three views visible in default state | Visual inspection |
| AC1.4 | `q` quits cleanly, restores cursor | Manual test |

### 9.2 Running Tasks View Criteria

| ID | Criteria | Test Method |
|----|----------|-------------|
| AC2.1 | Active runs display with runId and priority | Unit test |
| AC2.2 | Phase hierarchy shows Explorer → Developer → QA → ... | Unit test |
| AC2.3 | Current phase shows `→` indicator | Visual inspection |
| AC2.4 | Completed phases show `✓` with duration | Visual inspection |
| AC2.5 | Progress bar reflects actual completion % | Unit test |
| AC2.6 | Failed runs show `✗` with error summary | E2E test |

### 9.3 Board View Criteria

| ID | Criteria | Test Method |
|----|----------|-------------|
| AC3.1 | Four columns render: Ready, In Progress, Blocked, Done | Visual inspection |
| AC3.2 | Tasks appear in correct column by status | Unit test |
| AC3.3 | Priority badges show P0-P4 color coding | Visual inspection |
| AC3.4 | Column counts match actual task counts | Unit test |
| AC3.5 | `h`/`l` navigates between columns | Manual test |

### 9.4 Inbox View Criteria

| ID | Criteria | Test Method |
|----|----------|-------------|
| AC4.1 | Messages display with subject, from, preview | Visual inspection |
| AC4.2 | Unread count badge shows in header | Visual inspection |
| AC4.3 | Unread messages bold/highlighted | Visual inspection |
| AC4.4 | Focused message shows expanded preview (3 lines) | Manual test |
| AC4.5 | Messages link to related runs | Unit test |

### 9.5 Navigation Criteria

| ID | Criteria | Test Method |
|----|----------|-------------|
| AC5.1 | `j`/`k` moves cursor in all views | Manual test |
| AC5.2 | `1`/`2`/`3` switches views | Manual test |
| AC5.3 | `Enter` expands/collapses sections | Manual test |
| AC5.4 | `gg`/`G` jumps to first/last | Manual test |
| AC5.5 | `r` triggers manual refresh | Manual test |

### 9.6 Real-Time Update Criteria

| ID | Criteria | Test Method |
|----|----------|-------------|
| AC6.1 | Dashboard updates when run status changes | E2E test |
| AC6.2 | Dashboard updates when new mail arrives | E2E test |
| AC6.3 | Update latency <500ms | Performance test |
| AC6.4 | Debouncing prevents render thrashing | Unit test |

---

## 10. File Structure

```
foreman/src/
├── cli/commands/
│   └── operator-dashboard.ts       # CLI entry point
├── dashboard/
│   ├── index.ts                    # Main orchestrator
│   ├── state-manager.ts            # Data aggregation
│   ├── view-renderer.ts            # ANSI output rendering
│   ├── ansi.ts                     # ANSI escape code helpers
│   ├── signal-watcher.ts           # Real-time update watcher
│   ├── types.ts                    # DashboardState types
│   ├── views/
│   │   ├── running-tasks.ts        # Running tasks view
│   │   ├── board.ts                # Kanban board view
│   │   └── inbox.ts                # Inbox view
│   ├── navigation/
│   │   └── keyboard-nav.ts        # Vim-style keyboard handler
│   └── __tests__/
│       ├── state-manager.test.ts
│       ├── view-renderer.test.ts
│       ├── keyboard-nav.test.ts
│       └── signal-watcher.test.ts
└── integration/
    └── __tests__/
        └── operator-dashboard.e2e.test.ts
```

---

## 11. Cross-References

### 11.1 Dependencies

| Module | Integration Point | Method |
|--------|-------------------|--------|
| `ForemanStore` | Run data | `store.getActiveRuns()` |
| `ForemanStore` | Mail messages | `store.getAllMessagesGlobal()` |
| `ForemanStore` | Run progress | `store.getRunProgress()` |
| `NativeTaskStore` | Task data | `taskStore.getAllTasks()` |
| ` multiplexer-adapters` | Terminal panes | Future enhancement |

### 11.2 Related Commands

| Command | Relationship |
|---------|--------------|
| `foreman dashboard` | Existing, will remain separate |
| `foreman board` | BoardView mirrors its functionality |
| `foreman inbox` | InboxView mirrors its functionality |
| `foreman status` | Replaced by RunningTasksView |

### 11.3 PRD Requirements Mapping

| PRD Requirement | Implementation | Task ID |
|-----------------|----------------|---------|
| FR1: Dashboard Container | ViewRenderer, ViewContainer | DASH-004 |
| FR2: Running Tasks View | RunningTasksView | DASH-005 |
| FR3: Board View | BoardView | DASH-006 |
| FR4: Inbox View | InboxView | DASH-007 |
| FR5: Unified Navigation | KeyboardNavigator | DASH-008 |
| FR6: Real-Time Updates | SignalFileWatcher | DASH-009 |
| FR7: Configuration | CLI options | DASH-010 |

---

## 12. Open Questions

### 12.1 Terminal Multiplexer Integration

**Q:** Should the dashboard spawn as a terminal pane (WezTerm/Zellij/tmux) or render inline?

**Decision:** MVP renders inline (ANSI). Multiplexer pane integration is **out of scope** for MVP but documented for future enhancement.

**Rationale:** Simpler implementation, works everywhere. Multiplexer integration adds complexity without adding core functionality.

### 12.2 Collapsed View Default State

**Q:** Should all views start expanded or should one be defaulted?

**Decision:** All views start **expanded** by default.

**Rationale:** More information visible immediately. Users can collapse what they don't need.

### 12.3 Search Scope

**Q:** Should `/` search work across all views simultaneously or just the active view?

**Decision:** `/` searches **all views** and cycles through results across views.

**Rationale:** Matches PRD specification for "global search across all views".

### 12.4 Message Threading

**Q:** Should inbox group related messages into threads?

**Decision:** **Out of scope** for MVP. Message threading is P2 in the PRD.

**Rationale:** Simpler implementation. Threading adds UI complexity.

### 12.5 Sound Notifications

**Q:** Should failures trigger optional sound notifications?

**Decision:** **Out of scope** for MVP. Sound is P2 in PRD.

**Rationale:** Terminal sound can be disruptive. Can be added as future enhancement.

---

## Appendix A: Signal File Format

```
# Format: .foreman/signals/<type>_<timestamp>_<pid>.signal

# Example: run_progress
type:run_progress
run_id:foreman-001
phase:developer
status:completed
timestamp:2026-04-21T10:30:00Z

# Example: mail_received
type:mail_received
message_id:msg-123
run_id:foreman-001
subject:Phase Complete
timestamp:2026-04-21T10:30:00Z
```

## Appendix B: ANSI Escape Sequence Reference

| Sequence | Action |
|----------|--------|
| `\x1B[2J\x1B[H` | Clear screen, move to (1,1) |
| `\x1B[{row};{col}H` | Move cursor to position |
| `\x1B[?25l` | Hide cursor |
| `\x1B[?25h` | Show cursor |
| `\x1B[7` | Save cursor position |
| `\x1B[8` | Restore cursor position |
| `\x1B[2K` | Erase current line |
| `\x1B[0m` | Reset formatting |

---

**Document Status:** Draft — Awaiting Implementation Approval

**Next Steps:**
1. Stakeholder review of TRD
2. Implementation sprint planning
3. Begin Sprint 1: Core Infrastructure
