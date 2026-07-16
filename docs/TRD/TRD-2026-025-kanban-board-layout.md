# TRD-2026-025: Kanban Board Layout for Go Cockpit

---
document_id: TRD-2026-025
version: 1.0.0
status: Draft
date: 2026-07-15
architecture: "Top/Bottom Layout + Kanban Columns"
design_readiness_score: 9.0
total_tasks: 12
---

## TRD Health Summary

| Metric | Value |
|--------|-------|
| Implementation tasks | 7 |
| Test tasks | 5 |
| Sprint 1 (Column Mapping + Frame) | 5 tasks |
| Sprint 2 (Board + Navigation) | 4 tasks |
| Sprint 3 (Fallback + Mouse + Docs) | 3 tasks |
| REQ coverage | 6/6 (100%) |
| Orphaned annotations | 0 |

---

## Overview

Refactor the Go cockpit from a **left/right** split (task list | details) to a **top/bottom** split:

- **Top — task board (Kanban):** Tasks/runs as cards in 5 columns: Backlog · Ready · In Progress · Blocked · Done
- **Bottom — activities:** The existing drill-down (summary / messages / events / logs / reports / files / pr) for the selected card

**Spec source:** `docs/design/cockpit-kanban-layout-design.md` (Proposed)
**Proof point:** `src/cli/super-tui/panes/BoardPane.ts` (existing Foreman Kanban — validated mapping already exists)

---

## Architecture Decision

### Chosen Approach: Top/Bottom + Kanban Columns

Reuse the section-tab/task-list work as a column-based Kanban board. The left/right split becomes top/bottom; the section-tab list becomes 5 columns (or the narrow-terminal fallback).

**Key component boundaries:**

```
┌─────────────────────────────────────────────────────────────────┐
│  model.go                                                       │
│  owns: m.viewFocused (board=true / activities=false)           │
│  boardColumn, boardCardIndex — board navigation state          │
│  loadDetail() — unchanged; same API, triggered by card select  │
└───────────────────┬─────────────────────────────────────────────┘
                    │ drives
    ┌───────────────▼──────────────────────┐
    │  board.go                            │
    │  board.New(boardWidth, bodyHeight)   │
    │  5 columns via lipgloss.JoinHorizontal│
    │  per-column Viewport, cardCap,       │
    │  boardColumnForTaskStatus() mapping   │
    └───────────────┬──────────────────────┘
                    │ column items
    ┌───────────────▼──────────────────────────────────────────┐
    │  client.go — boardColumnForTaskStatus(status, attention)   │
    │  pure mapping: status → Backlog|Ready|InProgress|Blocked|  │
    │  Done, with attention override                            │
    └───────────────────────────────────────────────────────────┘
```

**What changes vs current:**

| Component | Change |
|-----------|--------|
| `view.go` | `renderBody()` switches left/right → top/bottom; `layout.split` controls height fraction |
| `model.go` | `viewFocused` semantics unchanged; `boardColumn` + `boardCardIndex` for board nav; `m.selectedItem` drives `loadDetail()` |
| `client.go` | add `boardColumnForTaskStatus(status, attentionReason)` pure function + tests |
| `task_list.go` | section-tab list becomes narrow-terminal fallback; active when `layout.mode: list` |
| `board.go` | new file: top/bottom frame, column rendering, card renderer, `… N more` |
| `mouse.go` / `handleMouse` | extend to map (x,y) → column + card |
| `config.go` | `layout.mode`, `layout.split`, `board.columns`, `board.cardCap` |

**What stays identical:** rich-row renderer, state classifiers, filter/scope, drill-down viewer, focus affordance, theme tokens, nvim/diffnav/omp handoffs, PR tab, metrics tab.

---

## Column Mapping

Port `boardColumnForTaskStatus()` + attention override from `BoardPane.ts`:

| Column | BoardPane source | Foreman statuses |
|--------|-----------------|-----------------|
| Backlog | `backlog` | `open`, `todo` |
| Ready | `ready` | `ready`, `pending` |
| In Progress | `in_progress` | `running`, `in_progress`, `cooldown` + live phase names |
| Blocked | `needs_attention` | `failed`, `stuck`, `conflict`, `blocked`, `review`, `test_failed`, plus attention override |
| Done | `closed` | `merged`, `completed`, `done`, `closed`, `reset`, `pr_created` |

**Attention override:** any card with non-empty `attentionReason` OR `verdict ∈ {fail, blocked}` goes to Blocked regardless of raw status.

**Sort:** last-activity desc (most recent first). `cockpit.board.order: activity | priority` is future; not in this TRD.

---

## Sprint 1: Column Mapping + Frame

### TRD-001: Port `boardColumnForTaskStatus()` + attention override to Go [satisfies REQ-001]
**File:** `clients/cockpit/board.go`
**Estimate:** 3h
**Validates:** cockpit-kanban-layout-design.md §2, §5

Implement pure function:

```go
// Column is one of the five Kanban columns.
type Column string

const (
    ColumnBacklog     Column = "Backlog"
    ColumnReady       Column = "Ready"
    ColumnInProgress  Column = "In Progress"
    ColumnBlocked     Column = "Blocked"
    ColumnDone        Column = "Done"
)

// boardColumnForTaskStatus returns the Kanban column for a task/run.
// attentionReason non-empty or verdict fail/blocked forces Blocked.
func boardColumnForTaskStatus(status string, attentionReason string, verdict string) Column
```

Unit tests table-driven against BoardPane cases:
- `open`, `todo` → Backlog
- `ready`, `pending` → Ready
- `running`, `in_progress`, `cooldown` → In Progress
- `failed`, `stuck`, `conflict`, `blocked`, `review`, `test_failed` → Blocked
- `merged`, `completed`, `done`, `closed`, `reset`, `pr_created` → Done
- attentionReason non-empty → Blocked (any status)
- verdict `fail` → Blocked
- verdict `blocked` → Blocked
- unknown status → Blocked (per spec)

**Implementation AC checklist:**
- [ ] Given `boardColumnForTaskStatus("open", "", "")`, when called, then returns `ColumnBacklog`
- [ ] Given `boardColumnForTaskStatus("ready", "", "")`, when called, then returns `ColumnReady`
- [ ] Given `boardColumnForTaskStatus("running", "", "")`, when called, then returns `ColumnInProgress`
- [ ] Given `boardColumnForTaskStatus("failed", "", "")`, when called, then returns `ColumnBlocked`
- [ ] Given `boardColumnForTaskStatus("merged", "", "")`, when called, then returns `ColumnDone`
- [ ] Given `boardColumnForTaskStatus("open", "merge_conflict", "")`, when called, then returns `ColumnBlocked` (attention override)
- [ ] Given `boardColumnForTaskStatus("ready", "", "fail")`, when called, then returns `ColumnBlocked` (verdict override)
- [ ] Given `boardColumnForTaskStatus("unknown", "", "")`, when called, then returns `ColumnBlocked` (unknown → blocked per spec)

---

### TRD-001-TEST: Test `boardColumnForTaskStatus()` [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]
**File:** `clients/cockpit/board_test.go`
**Estimate:** 2h

Table-driven test with all cases above. Use `testing.Table` style.

```go
func TestBoardColumnForTaskStatus(t *testing.T) {
    cases := []struct {
        name              string
        status            string
        attentionReason   string
        verdict           string
        want              Column
    }{
        {"open maps to Backlog", "open", "", "", ColumnBacklog},
        {"todo maps to Backlog", "todo", "", "", ColumnBacklog},
        {"ready maps to Ready", "ready", "", "", ColumnReady},
        {"pending maps to Ready", "pending", "", "", ColumnReady},
        {"running maps to InProgress", "running", "", "", ColumnInProgress},
        {"in_progress maps to InProgress", "in_progress", "", "", ColumnInProgress},
        {"cooldown maps to InProgress", "cooldown", "", "", ColumnInProgress},
        {"failed maps to Blocked", "failed", "", "", ColumnBlocked},
        {"stuck maps to Blocked", "stuck", "", "", ColumnBlocked},
        {"conflict maps to Blocked", "conflict", "", "", ColumnBlocked},
        {"blocked maps to Blocked", "blocked", "", "", ColumnBlocked},
        {"review maps to Blocked", "review", "", "", ColumnBlocked},
        {"test_failed maps to Blocked", "test_failed", "", "", ColumnBlocked},
        {"merged maps to Done", "merged", "", "", ColumnDone},
        {"completed maps to Done", "completed", "", "", ColumnDone},
        {"done maps to Done", "done", "", "", ColumnDone},
        {"closed maps to Done", "closed", "", "", ColumnDone},
        {"reset maps to Done", "reset", "", "", ColumnDone},
        {"pr_created maps to Done", "pr_created", "", "", ColumnDone},
        {"attentionReason forces Blocked", "open", "merge_conflict", "", ColumnBlocked},
        {"verdict fail forces Blocked", "ready", "", "fail", ColumnBlocked},
        {"verdict blocked forces Blocked", "running", "", "blocked", ColumnBlocked},
        {"unknown status maps to Blocked", "unknown", "", "", ColumnBlocked},
    }
    // ...
}
```

---

### TRD-002: Top/bottom frame with `layout.split` [satisfies REQ-002]
**File:** `clients/cockpit/view.go` (renderBody changes)
**Estimate:** 3h
**Validates:** cockpit-kanban-layout-design.md §4

Change `renderBody()` from left/right `JoinHorizontal` to top/bottom `JoinVertical`:

```go
// board takes ~55%, activities ~45% by default; configurable via layout.split
func (v *View) renderBody(m *Model, w *viewport.Viewport) string {
    split := v.cfg.Layout.Split // default 0.55
    // compute boardHeight from bodyHeight * split
    // compute activitiesHeight from bodyHeight * (1 - split)
    board := v.renderBoardPane(m, boardWidth, boardHeight)
    activities := v.renderActivitiesPane(m, bodyWidth, activitiesHeight)
    return lipgloss.JoinVertical(lipgloss.Top, board, activities)
}
```

- `renderBoardPane()` renders the Kanban board (board mode) or section-tab task list (list mode)
- `renderActivitiesPane()` is the existing drill-down; unchanged
- Both regions use `paneVisual` (focus/blur style) from the focus affordance work
- When `layout.mode: list` or narrow terminal, skip board entirely and use existing section-tab layout

---

### TRD-002-TEST: Test body split rendering [verifies TRD-002] [satisfies REQ-002] [depends: TRD-002]
**File:** `clients/cockpit/view_test.go`
**Estimate:** 1h

- Test `renderBody()` proportions match `layout.split` (0.55 default)
- Test board pane height + activities pane height = body height
- Test split sanitized to safe range [0.3, 0.7]
- Test narrow-terminal degrades to list mode (COCKPIT_DUMP with small terminal)

---

### TRD-003: Config for layout mode, split, narrow threshold [satisfies REQ-003]
**File:** `clients/cockpit/config.go`
**Estimate:** 2h
**Validates:** cockpit-kanban-layout-design.md §13

Add to `LayoutConfig`:

```go
type LayoutConfig struct {
    Mode           string  // "board" | "list" | "auto" (default "board")
    Split          float64 // board height fraction; default 0.55; sanitized [0.3, 0.7]
    NarrowThreshold int    // cols below which auto uses list; default 100
}
type BoardConfig struct {
    Columns  []ColumnDef  // optional override; defaults from boardColumnForTaskStatus
    CardCap  int         // cards per column before "... N more"; default 12
    Order    string      // "activity" | "priority"; default "activity"
}
```

Environment overrides: `COCKPIT_LAYOUT_MODE`, `COCKPIT_LAYOUT_SPLIT`, `COCKPIT_LAYOUT_NARROW_THRESHOLD`.

---

## Sprint 2: Board Rendering + Navigation

### TRD-004: Board render — 5 columns via `JoinHorizontal` [satisfies REQ-004]
**File:** `clients/cockpit/board.go`
**Estimate:** 4h
**Validates:** cockpit-kanban-layout-design.md §4, §5, §6

Render 5 columns as `lipgloss.JoinHorizontal`:

- Column header: label + true count (`Backlog 12`), colored per semantic token
- Cards: 2–3 compact lines reusing rich-row work
  - Line 1: state glyph + `foreman-<id>` (+ project when global)
  - Line 2: bold truncated title
  - Line 3 (space permitting): `P<pri> · <type>` or for In Progress `phase · elapsed`
- Selected card: full-width band (`cSelBg`); selected column header highlighted
- Card cap: show N visible cards, then `… N more` overflow row
- Each column is a `viewport` for independent vertical scroll

**Implementation AC checklist:**
- [ ] Given 5 columns with counts, when rendered, then all column headers visible with correct counts
- [ ] Given cards within column width, when rendered, then no overflow artifacts
- [ ] Given selected card, when rendered, then full-width band visible in that column
- [ ] Given column exceeds cardCap, when rendered, then "... N more" row visible

---

### TRD-004-TEST: Test board column rendering [verifies TRD-004] [satisfies REQ-004] [depends: TRD-004]
**File:** `clients/cockpit/board_test.go`
**Estimate:** 2h

- Test column bucketing: items land in correct column
- Test column counts match bucketed items
- Test `… N more` appears when column exceeds cardCap
- Test column header rendering within column width
- Test card rendering within column width

---

### TRD-005: Board navigation (`←/→`/`h/l`, `↑/↓`/`j/k`, enter/esc) [satisfies REQ-005]
**File:** `clients/cockpit/model.go` (handleKey changes)
**Estimate:** 3h
**Validates:** cockpit-kanban-layout-design.md §7

Keys when board focused:

| Key | Action |
|-----|--------|
| `←`/`→`, `h`/`l` | move between columns |
| `↑`/`↓`, `j`/`k` | move card within column |
| `enter` | focus activities for selected card; `loadDetail()` |
| `esc` | (from activities) return focus to board |

Navigation state:
```go
type Model struct {
    // ... existing fields
    boardColumn    int     // 0-4 (Backlog..Done)
    boardCardIndex int     // selected card within column
}
```

When column has 0 cards: `↑/↓` wraps or no-ops gracefully.

When switching columns: `boardCardIndex` clamps to available cards in new column.

**Implementation AC checklist:**
- [ ] Given board focused, when `→` pressed, then boardColumn increments (wraps 4→0)
- [ ] Given board focused, when `←` pressed, then boardColumn decrements (wraps 0→4)
- [ ] Given column 2 focused, when `↑` pressed, then boardCardIndex decrements (clamped ≥ 0)
- [ ] Given last card in column, when `↓` pressed, then boardCardIndex clamped to max
- [ ] Given column 2 with 3 cards, when switching to column 0 (5 cards), then cardIndex clamped to 4
- [ ] Given board with card selected, when `enter` pressed, then viewFocused=true and loadDetail() called

---

### TRD-005-TEST: Test board navigation [verifies TRD-005] [satisfies REQ-005] [depends: TRD-005]
**File:** `clients/cockpit/model_test.go`
**Estimate:** 1h

- Test `boardColumn` wraps at boundaries
- Test `boardCardIndex` clamps within column card count
- Test `enter` sets `viewFocused = true`
- Test `esc` (from activities) sets `viewFocused = false`

---

## Sprint 3: Fallback + Mouse + Docs

### TRD-006: Narrow-terminal fallback (list mode) + mode config [satisfies REQ-006]
**File:** `clients/cockpit/view.go`, `clients/cockpit/model.go`
**Estimate:** 2h
**Validates:** cockpit-kanban-layout-design.md §12

When `layout.mode: list` or terminal width < `narrowThreshold`:
- Render the existing section-tab task list (already shipped)
- Fallback is the section-tab list, not a compact single-column board

When `layout.mode: auto`:
- Width ≥ `narrowThreshold` (default 100 cols) → board mode
- Width < `narrowThreshold` → list mode

**Implementation AC checklist:**
- [ ] Given `layout.mode: list`, when rendered, then section-tab list renders (not board)
- [ ] Given `layout.mode: auto` + width ≥ threshold, when rendered, then board renders
- [ ] Given `layout.mode: auto` + width < threshold, when rendered, then list renders
- [ ] Given startup in list mode, when focus key pressed, then appropriate list key handled

---

### TRD-007: Mouse hit-testing for columns and cards [satisfies REQ-007]
**File:** `clients/cockpit/handle_mouse.go` (or `model.go` mouse handler)
**Estimate:** 3h
**Validates:** cockpit-kanban-layout-design.md §10

Extend existing native pane hit-testing:

1. **Board region:** map (x, y) → column index (0–4) + card index within column
2. **Activities region:** existing behavior (logs/events/messages tabs etc.)
3. Click in board → select card + load detail + focus activities
4. Click in activities → existing tab/action behavior

```go
// boardMouseTarget returns (column, cardIndex, hit) for a mouse event in the board region.
func (m *Model) boardMouseTarget(x, y int) (col int, card int, hit bool)
```

**Implementation AC checklist:**
- [ ] Given mouse click on card in column 2, when clicked, then boardColumn=2, boardCardIndex=card, viewFocused=true
- [ ] Given mouse click in activities region, when clicked, then existing tab/action behavior fires
- [ ] Given mouse click on column header, when clicked, then column selected (no card)
- [ ] Given mouse click below last card in column, when clicked, then no target (ignore)

---

### TRD-007-TEST: Test mouse hit-testing [verifies TRD-007] [satisfies REQ-007] [depends: TRD-007]
**File:** `clients/cockpit/board_test.go`
**Estimate:** 1h

- Test `boardMouseTarget` maps coordinates to correct column
- Test card index within column bounds
- Test out-of-bounds coordinates return hit=false
- Test coordinates in activities region vs board region

---

## Master Task List

### Sprint 1: Column Mapping + Frame (5 tasks)

- [ ] **TRD-001**: Port `boardColumnForTaskStatus()` + attention override to Go (`clients/cockpit/board.go`) [satisfies REQ-001]
- [ ] **TRD-001-TEST**: Test `boardColumnForTaskStatus()` (`clients/cockpit/board_test.go`) [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]
- [ ] **TRD-002**: Top/bottom frame with `layout.split` (`clients/cockpit/view.go`) [satisfies REQ-002]
- [ ] **TRD-002-TEST**: Test body split rendering (`clients/cockpit/view_test.go`) [verifies TRD-002] [satisfies REQ-002] [depends: TRD-002]
- [ ] **TRD-003**: Config for layout mode, split, narrow threshold (`clients/cockpit/config.go`) [satisfies REQ-003]

### Sprint 2: Board Rendering + Navigation (4 tasks)

- [ ] **TRD-004**: Board render — 5 columns via `JoinHorizontal` (`clients/cockpit/board.go`) [satisfies REQ-004]
- [ ] **TRD-004-TEST**: Test board column rendering (`clients/cockpit/board_test.go`) [verifies TRD-004] [satisfies REQ-004] [depends: TRD-004]
- [ ] **TRD-005**: Board navigation (`←/→`, `↑/↓`, enter/esc) (`clients/cockpit/model.go`) [satisfies REQ-005]
- [ ] **TRD-005-TEST**: Test board navigation (`clients/cockpit/model_test.go`) [verifies TRD-005] [satisfies REQ-005] [depends: TRD-005]

### Sprint 3: Fallback + Mouse + Docs (3 tasks)

- [ ] **TRD-006**: Narrow-terminal fallback (list mode) + mode config (`clients/cockpit/view.go`, `clients/cockpit/model.go`) [satisfies REQ-006]
- [ ] **TRD-007**: Mouse hit-testing for columns and cards (`clients/cockpit/handle_mouse.go`) [satisfies REQ-007]
- [ ] **TRD-007-TEST**: Test mouse hit-testing (`clients/cockpit/board_test.go`) [verifies TRD-007] [satisfies REQ-007] [depends: TRD-007]

---

## Open Decisions (from cockpit-kanban-layout-design.md §12)

These are already resolved in this TRD (use defaults from design doc):

1. **Column label:** "Blocked" (not "Needs Attention") — per design doc recommendation
2. **Default mode:** board primary with list fallback — board when width ≥ threshold
3. **Narrow-terminal behavior:** list fallback (section-tab list, not compact column)
4. **Drag-to-move:** action-driven only in v1 (no drag)

---

## Acceptance Criteria

| ID | Criterion | Verified by |
|----|-----------|-------------|
| AC-1 | Startup shows board (focus: board) with all 5 columns and true counts | TRD-002-TEST |
| AC-2 | attention/failed cards land in Blocked column | TRD-001-TEST |
| AC-3 | `←/→` move between columns, `↑/↓` move cards | TRD-005-TEST |
| AC-4 | `enter` focuses activities for selected card, `esc` returns | TRD-005-TEST |
| AC-5 | Selecting a card updates bottom activities | TRD-005-TEST |
| AC-6 | Columns scroll independently with `… N more` | TRD-004-TEST |
| AC-7 | Global scope + filter narrow all columns | TRD-004-TEST |
| AC-8 | Narrow terminals degrade to section-tab list | TRD-006-TEST |
| AC-9 | `go build ./... && go vet ./... && go test ./...` clean | CI |
| AC-10 | Mouse click on card selects and focuses activities | TRD-007-TEST |
| AC-11 | Mock backend (`COCKPIT_BACKEND=mock`) shows board with demo data | Smoke test |

---

## Requirements

| ID | Requirement | TRD |
|----|-------------|-----|
| REQ-001 | Port `boardColumnForTaskStatus()` + attention override to Go with table-driven tests | TRD-001 |
| REQ-002 | Top/bottom frame with configurable `layout.split` | TRD-002 |
| REQ-003 | Config: `layout.mode`, `layout.split`, `layout.narrowThreshold`, `board.columns`, `board.cardCap` | TRD-003 |
| REQ-004 | Board render: 5 columns, per-column scroll, `… N more`, card caps | TRD-004 |
| REQ-005 | Board navigation: `←/→` columns, `↑/↓` cards, enter/esc focus | TRD-005 |
| REQ-006 | Narrow-terminal list fallback; `auto` mode with threshold | TRD-006 |

---

## Dependencies

- **Blocked by:** None — `clients/cockpit/` is self-contained; existing `BoardPane.ts` provides the mapping reference
- **Prerequisites:** `cockpit-task-list-gh-dash-style-handoff.md` (implemented), `cockpit-focus-affordance-handoff.md` (implemented)
- **Side effects:** No backend changes; no new API endpoints; read-only projection client preserved

## Source

`docs/design/cockpit-kanban-layout-design.md` — proof point: `src/cli/super-tui/panes/BoardPane.ts`
