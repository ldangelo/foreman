package main

import (
	"sort"
	"strings"
	"time"
)

const boardFallbackCardCap = 12

// BoardColumn is the stable Kanban column identifier used by board rendering,
// navigation, and tests. The order in boardColumnOrder is the display order.
type BoardColumn string

const (
	BoardColumnBacklog    BoardColumn = "backlog"
	BoardColumnReady      BoardColumn = "ready"
	BoardColumnInProgress BoardColumn = "in_progress"
	BoardColumnBlocked    BoardColumn = "blocked"
	BoardColumnDone       BoardColumn = "done"
)

var boardColumnOrder = []BoardColumn{
	BoardColumnBacklog,
	BoardColumnReady,
	BoardColumnInProgress,
	BoardColumnBlocked,
	BoardColumnDone,
}

// Label returns the human-facing header label for a board column.
func (c BoardColumn) Label() string {
	switch c {
	case BoardColumnBacklog:
		return "Backlog"
	case BoardColumnReady:
		return "Ready"
	case BoardColumnInProgress:
		return "In Progress"
	case BoardColumnBlocked:
		return "Blocked"
	case BoardColumnDone:
		return "Done"
	default:
		return "Blocked"
	}
}

// BoardColumnState is a render-ready snapshot for one board column. Items is
// the full sorted column; VisibleItems is the capped/offset window; OverflowCount
// is the number of cards hidden after VisibleItems. SelectedKey mirrors the
// TaskList itemKey so layout can synchronize selection without re-deriving state.
type BoardColumnState struct {
	Column        BoardColumn
	Label         string
	Items         []Item
	VisibleItems  []Item
	SelectedIndex int
	SelectedKey   string
	Offset        int
	OverflowCount int
}

// Board derives Kanban buckets from the already-filtered TaskList Items. It owns
// only board-local cursor/window state; TaskList remains the source for scope,
// search/filtering, and detail/action selection.
type Board struct {
	cardCap        int
	selectedColumn BoardColumn
	selectedKeys   map[BoardColumn]string
	offsets        map[BoardColumn]int
	columns        []BoardColumnState
}

// NewBoard creates a board model. If cardCap is omitted or invalid, the default
// cap is used; callers may also pass/refresh the cap through SetItems.
func NewBoard(cardCap ...int) Board {
	cap := boardFallbackCardCap
	if len(cardCap) > 0 && cardCap[0] > 0 {
		cap = cardCap[0]
	}
	b := Board{
		cardCap:        cap,
		selectedColumn: BoardColumnBacklog,
		selectedKeys:   map[BoardColumn]string{},
		offsets:        map[BoardColumn]int{},
	}
	b.rebuild(nil, "")
	return b
}

// SetCardCap updates the visible-card cap and reclamps existing column windows.
func (b *Board) SetCardCap(cardCap int) {
	if cardCap <= 0 {
		cardCap = boardFallbackCardCap
	}
	b.cardCap = cardCap
	b.rebuildFromCurrent("")
}

// SetItems rebuilds all columns from filtered TaskList items. selectedKey, when
// non-empty, is preferred as the board selection so TaskList and Board stay in
// lockstep after data/filter refreshes. cardCap <= 0 keeps the current cap.
func (b *Board) SetItems(items []Item, selectedKey string, cardCap int) {
	if b.selectedKeys == nil {
		*b = NewBoard()
	}
	if cardCap > 0 {
		b.cardCap = cardCap
	}
	b.rebuild(items, selectedKey)
}

// Columns returns the current render-ready column snapshots in display order.
func (b Board) Columns() []BoardColumnState {
	out := make([]BoardColumnState, len(b.columns))
	copy(out, b.columns)
	return out
}

// Counts returns true item totals by column in display order.
func (b Board) Counts() map[BoardColumn]int {
	counts := make(map[BoardColumn]int, len(b.columns))
	for _, col := range b.columns {
		counts[col.Column] = len(col.Items)
	}
	return counts
}

func (b Board) SelectedColumn() BoardColumn { return b.selectedColumn }
func (b Board) SelectedKey() string         { return b.SelectedItemKey() }
func (b Board) SelectedItemKey() string {
	if key := b.selectedKeys[b.selectedColumn]; key != "" {
		return key
	}
	for _, col := range b.columns {
		if col.Column == b.selectedColumn && col.SelectedKey != "" {
			return col.SelectedKey
		}
	}
	return ""
}

// SelectKey moves the board cursor to the item with key and returns whether it
// was visible in the current board data.
func (b *Board) SelectKey(key string) bool { return b.SelectItemKey(key) }
func (b *Board) SelectItemKey(key string) bool {
	if key == "" {
		return false
	}
	for _, col := range b.columns {
		for i, it := range col.Items {
			if itemKey(it) == key {
				b.selectedColumn = col.Column
				b.selectedKeys[col.Column] = key
				b.offsets[col.Column] = keepBoardIndexVisible(b.offsets[col.Column], i, b.cardCap, len(col.Items))
				b.rebuildFromCurrent(key)
				return true
			}
		}
	}
	return false
}

// SelectAt selects a visible row in a column index (display order) and returns
// the selected TaskList item key for detail synchronization.
func (b *Board) SelectAt(columnIndex, visibleRow int) (string, bool) {
	if columnIndex < 0 || columnIndex >= len(b.columns) || visibleRow < 0 {
		return "", false
	}
	col := b.columns[columnIndex]
	idx := col.Offset + visibleRow
	if idx < 0 || idx >= len(col.Items) {
		return "", false
	}
	key := itemKey(col.Items[idx])
	b.selectedColumn = col.Column
	b.selectedKeys[col.Column] = key
	b.offsets[col.Column] = keepBoardIndexVisible(col.Offset, idx, b.cardCap, len(col.Items))
	b.rebuildFromCurrent(key)
	return key, true
}

// MoveColumn moves horizontally in display order, clamping at the board edges.
// It returns the newly selected item key when the target column has cards.
func (b *Board) MoveColumn(delta int) (string, bool) {
	if len(b.columns) == 0 || delta == 0 {
		key := b.SelectedItemKey()
		return key, key != ""
	}
	idx := b.columnIndex(b.selectedColumn)
	if idx < 0 {
		idx = 0
	}
	idx += delta
	if idx < 0 {
		idx = 0
	}
	if idx >= len(b.columns) {
		idx = len(b.columns) - 1
	}
	b.selectedColumn = b.columns[idx].Column
	b.ensureColumnSelection(b.selectedColumn)
	b.rebuildFromCurrent("")
	key := b.SelectedItemKey()
	return key, key != ""
}

// MoveCard moves vertically inside the selected column, clamping to the first or
// last card and keeping the selected index inside the visible card window.
func (b *Board) MoveCard(delta int) (string, bool) {
	col := b.column(b.selectedColumn)
	if col == nil || len(col.Items) == 0 {
		return "", false
	}
	idx := col.SelectedIndex
	if idx < 0 {
		idx = 0
	}
	idx += delta
	if idx < 0 {
		idx = 0
	}
	if idx >= len(col.Items) {
		idx = len(col.Items) - 1
	}
	key := itemKey(col.Items[idx])
	b.selectedKeys[col.Column] = key
	b.offsets[col.Column] = keepBoardIndexVisible(col.Offset, idx, b.cardCap, len(col.Items))
	b.rebuildFromCurrent(key)
	return key, true
}

func (b *Board) rebuildFromCurrent(preferredKey string) {
	items := make([]Item, 0)
	for _, col := range b.columns {
		items = append(items, col.Items...)
	}
	b.rebuild(items, preferredKey)
}

func (b *Board) rebuild(items []Item, preferredKey string) {
	if b.cardCap <= 0 {
		b.cardCap = boardFallbackCardCap
	}
	if b.selectedKeys == nil {
		b.selectedKeys = map[BoardColumn]string{}
	}
	if b.offsets == nil {
		b.offsets = map[BoardColumn]int{}
	}

	bucketed := make(map[BoardColumn][]boardItem, len(boardColumnOrder))
	for i, it := range items {
		col := boardColumn(it)
		bucketed[col] = append(bucketed[col], boardItem{item: it, originalIndex: i, activity: boardActivityTime(it)})
	}
	for _, col := range boardColumnOrder {
		sort.SliceStable(bucketed[col], func(i, j int) bool {
			a, b := bucketed[col][i], bucketed[col][j]
			if !a.activity.IsZero() && !b.activity.IsZero() && !a.activity.Equal(b.activity) {
				return a.activity.After(b.activity)
			}
			if !a.activity.IsZero() && b.activity.IsZero() {
				return true
			}
			if a.activity.IsZero() && !b.activity.IsZero() {
				return false
			}
			return a.originalIndex < b.originalIndex
		})
	}

	if preferredKey != "" {
		if col, ok := findBoardColumnForKey(bucketed, preferredKey); ok {
			b.selectedColumn = col
			b.selectedKeys[col] = preferredKey
		}
	}
	if !validBoardColumn(b.selectedColumn) {
		b.selectedColumn = firstNonEmptyBoardColumn(bucketed)
	}
	if b.selectedColumn == "" {
		b.selectedColumn = BoardColumnBacklog
	}

	b.columns = make([]BoardColumnState, 0, len(boardColumnOrder))
	for _, col := range boardColumnOrder {
		entries := bucketed[col]
		colItems := make([]Item, len(entries))
		for i, entry := range entries {
			colItems[i] = entry.item
		}
		selectedIndex := boardSelectedIndex(colItems, b.selectedKeys[col])
		if selectedIndex < 0 && len(colItems) > 0 {
			selectedIndex = 0
			b.selectedKeys[col] = itemKey(colItems[0])
		}
		if selectedIndex < 0 {
			b.selectedKeys[col] = ""
		}
		offset := keepBoardIndexVisible(b.offsets[col], selectedIndex, b.cardCap, len(colItems))
		b.offsets[col] = offset
		visibleEnd := min(len(colItems), offset+b.cardCap)
		visible := colItems[offset:visibleEnd]
		overflow := len(colItems) - visibleEnd
		if overflow < 0 {
			overflow = 0
		}
		b.columns = append(b.columns, BoardColumnState{
			Column:        col,
			Label:         col.Label(),
			Items:         colItems,
			VisibleItems:  visible,
			SelectedIndex: selectedIndex,
			SelectedKey:   b.selectedKeys[col],
			Offset:        offset,
			OverflowCount: overflow,
		})
	}
	b.ensureColumnSelection(b.selectedColumn)
}

func (b *Board) ensureColumnSelection(col BoardColumn) {
	state := b.column(col)
	if state == nil || len(state.Items) == 0 {
		b.selectedKeys[col] = ""
		return
	}
	idx := boardSelectedIndex(state.Items, b.selectedKeys[col])
	if idx < 0 {
		idx = 0
		b.selectedKeys[col] = itemKey(state.Items[idx])
	}
	b.offsets[col] = keepBoardIndexVisible(state.Offset, idx, b.cardCap, len(state.Items))
}

func (b Board) columnIndex(col BoardColumn) int {
	for i, state := range b.columns {
		if state.Column == col {
			return i
		}
	}
	return -1
}

func (b *Board) column(col BoardColumn) *BoardColumnState {
	for i := range b.columns {
		if b.columns[i].Column == col {
			return &b.columns[i]
		}
	}
	return nil
}

// boardColumnForTaskStatus ports the proven super-tui BoardPane mapping. Unknown
// statuses intentionally map to Blocked so ambiguous states surface for humans.
func boardColumnForTaskStatus(status string) BoardColumn {
	normalized := strings.TrimSpace(strings.ToLower(normalizeStatus(status)))
	switch normalized {
	case "backlog", "open", "todo":
		return BoardColumnBacklog
	case "pending", "ready":
		return BoardColumnReady
	case "running", "in_progress", "cooldown", "explorer", "developer", "qa", "reviewer", "finalize":
		return BoardColumnInProgress
	case "failed", "fail", "stuck", "conflict", "blocked", "review", "test_failed":
		return BoardColumnBlocked
	case "merged", "completed", "done", "closed", "reset", "pr_created":
		return BoardColumnDone
	default:
		return BoardColumnBlocked
	}
}

// boardColumn classifies an Item into a board column, applying the run attention
// override and failed-task override before falling back to raw status mapping.
func boardColumn(it Item) BoardColumn {
	if it.IsTask {
		if isFailedState(it.Task.Status) {
			return BoardColumnBlocked
		}
		return boardColumnForTaskStatus(it.Task.Status)
	}
	if runNeedsAttention(it.Run) || strings.EqualFold(it.Run.Verdict, "blocked") {
		return BoardColumnBlocked
	}
	if it.Run.Phase != "" && activeRunStatus(it.Run.Status) {
		phaseColumn := boardColumnForTaskStatus(it.Run.Phase)
		if phaseColumn == BoardColumnInProgress {
			return phaseColumn
		}
	}
	return boardColumnForTaskStatus(it.Run.Status)
}

type boardItem struct {
	item          Item
	originalIndex int
	activity      time.Time
}

func boardActivityTime(it Item) time.Time {
	if it.IsTask {
		return parseBoardTime(firstNonBlank(it.Task.Updated, it.Task.Created))
	}
	return parseBoardTime(firstNonBlank(it.Run.Last, it.Run.Created))
}

func parseBoardTime(value string) time.Time {
	value = strings.TrimSpace(value)
	if value == "" || strings.Contains(value, " ago") {
		return time.Time{}
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05", "2006-01-02"} {
		if t, err := time.Parse(layout, value); err == nil {
			return t
		}
	}
	return time.Time{}
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func boardSelectedIndex(items []Item, key string) int {
	if key == "" {
		return -1
	}
	for i, it := range items {
		if itemKey(it) == key {
			return i
		}
	}
	return -1
}

func keepBoardIndexVisible(offset, selectedIndex, cap, total int) int {
	if cap <= 0 {
		cap = boardFallbackCardCap
	}
	if total <= cap || selectedIndex < 0 {
		return 0
	}
	maxOffset := total - cap
	if offset > maxOffset {
		offset = maxOffset
	}
	if offset < 0 {
		offset = 0
	}
	if selectedIndex < offset {
		return selectedIndex
	}
	if selectedIndex >= offset+cap {
		return selectedIndex - cap + 1
	}
	return offset
}

func findBoardColumnForKey(bucketed map[BoardColumn][]boardItem, key string) (BoardColumn, bool) {
	for _, col := range boardColumnOrder {
		for _, entry := range bucketed[col] {
			if itemKey(entry.item) == key {
				return col, true
			}
		}
	}
	return "", false
}

func firstNonEmptyBoardColumn(bucketed map[BoardColumn][]boardItem) BoardColumn {
	for _, col := range boardColumnOrder {
		if len(bucketed[col]) > 0 {
			return col
		}
	}
	return BoardColumnBacklog
}

func validBoardColumn(col BoardColumn) bool {
	for _, candidate := range boardColumnOrder {
		if candidate == col {
			return true
		}
	}
	return false
}
