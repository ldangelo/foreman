package main

import "testing"

func TestBoardColumnForTaskStatus(t *testing.T) {
	tests := []struct {
		status string
		want   BoardColumn
	}{
		{"open", BoardColumnBacklog},
		{"todo", BoardColumnBacklog},
		{"backlog", BoardColumnBacklog},
		{"ready", BoardColumnReady},
		{"pending", BoardColumnReady},
		{"running", BoardColumnInProgress},
		{"in-progress", BoardColumnInProgress},
		{"cooldown", BoardColumnInProgress},
		{"explorer", BoardColumnInProgress},
		{"developer", BoardColumnInProgress},
		{"qa", BoardColumnInProgress},
		{"reviewer", BoardColumnInProgress},
		{"finalize", BoardColumnInProgress},
		{"failed", BoardColumnBlocked},
		{"stuck", BoardColumnBlocked},
		{"conflict", BoardColumnBlocked},
		{"blocked", BoardColumnBlocked},
		{"review", BoardColumnBlocked},
		{"test-failed", BoardColumnBlocked},
		{"merged", BoardColumnDone},
		{"completed", BoardColumnDone},
		{"done", BoardColumnDone},
		{"closed", BoardColumnDone},
		{"reset", BoardColumnDone},
		{"pr-created", BoardColumnDone},
		{"mystery", BoardColumnBlocked},
	}
	for _, tt := range tests {
		t.Run(tt.status, func(t *testing.T) {
			if got := boardColumnForTaskStatus(tt.status); got != tt.want {
				t.Fatalf("boardColumnForTaskStatus(%q)=%s want %s", tt.status, got, tt.want)
			}
		})
	}
}

func TestBoardColumnAppliesAttentionAndFailedOverrides(t *testing.T) {
	tests := []struct {
		name string
		item Item
		want BoardColumn
	}{
		{name: "run attention overrides done", item: Item{Run: Run{RunID: "r1", Status: "completed", Attention: "needs-review"}}, want: BoardColumnBlocked},
		{name: "run fail verdict overrides done", item: Item{Run: Run{RunID: "r2", Status: "completed", Verdict: "fail"}}, want: BoardColumnBlocked},
		{name: "run blocked verdict overrides ready", item: Item{Run: Run{RunID: "r3", Status: "ready", Verdict: "blocked"}}, want: BoardColumnBlocked},
		{name: "run failed status blocked", item: Item{Run: Run{RunID: "r4", Status: "failed"}}, want: BoardColumnBlocked},
		{name: "task failed blocked", item: Item{IsTask: true, Task: Task{TaskID: "t1", Status: "test-failed"}}, want: BoardColumnBlocked},
		{name: "task pending ready", item: Item{IsTask: true, Task: Task{TaskID: "t2", Status: "pending"}}, want: BoardColumnReady},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := boardColumn(tt.item); got != tt.want {
				t.Fatalf("boardColumn()=%s want %s", got, tt.want)
			}
		})
	}
}

func TestBoardBucketsCountsAndOrderingByActivity(t *testing.T) {
	items := []Item{
		{Run: Run{RunID: "backlog-1", Status: "open"}},
		{Run: Run{RunID: "ready-old", Status: "ready", Last: "2026-07-10T00:00:00Z"}},
		{Run: Run{RunID: "ready-new", Status: "ready", Last: "2026-07-10T02:00:00Z"}},
		{Run: Run{RunID: "running", Status: "running"}},
		{Run: Run{RunID: "blocked", Status: "completed", Attention: "ci_failed"}},
		{Run: Run{RunID: "done", Status: "merged"}},
	}
	b := NewBoard(12)
	b.SetItems(items, "", 12)

	counts := b.Counts()
	wantCounts := map[BoardColumn]int{
		BoardColumnBacklog:    1,
		BoardColumnReady:      2,
		BoardColumnInProgress: 1,
		BoardColumnBlocked:    1,
		BoardColumnDone:       1,
	}
	for col, want := range wantCounts {
		if got := counts[col]; got != want {
			t.Fatalf("count[%s]=%d want %d", col, got, want)
		}
	}

	ready := columnState(t, b, BoardColumnReady)
	if ready.Items[0].Run.RunID != "ready-new" || ready.Items[1].Run.RunID != "ready-old" {
		t.Fatalf("expected ready sorted by Last desc, got %#v", ready.Items)
	}
}

func TestBoardPreservesStableOrderWhenActivityMissingOrTied(t *testing.T) {
	items := []Item{
		{Run: Run{RunID: "first", Status: "ready"}},
		{Run: Run{RunID: "second", Status: "ready"}},
		{Run: Run{RunID: "third", Status: "ready", Last: "not-a-timestamp"}},
	}
	b := NewBoard()
	b.SetItems(items, "", 0)

	ready := columnState(t, b, BoardColumnReady)
	for i, want := range []string{"first", "second", "third"} {
		if got := ready.Items[i].Run.RunID; got != want {
			t.Fatalf("ready item %d=%s want %s", i, got, want)
		}
	}
}

func TestBoardOverflowAndKeepSelectedVisible(t *testing.T) {
	items := make([]Item, 0, 5)
	for _, id := range []string{"one", "two", "three", "four", "five"} {
		items = append(items, Item{Run: Run{RunID: id, Status: "ready"}})
	}
	b := NewBoard(3)
	b.SetItems(items, "run:one", 3)

	ready := columnState(t, b, BoardColumnReady)
	if ready.Offset != 0 || ready.OverflowCount != 2 || len(ready.VisibleItems) != 3 {
		t.Fatalf("initial ready window offset=%d overflow=%d visible=%d", ready.Offset, ready.OverflowCount, len(ready.VisibleItems))
	}
	if key, ok := b.MoveCard(3); !ok || key != "run:four" {
		t.Fatalf("MoveCard selected key=%q ok=%v, want run:four true", key, ok)
	}
	ready = columnState(t, b, BoardColumnReady)
	if ready.SelectedIndex != 3 || ready.Offset != 1 {
		t.Fatalf("expected selected index 3 kept visible with offset 1, got index=%d offset=%d", ready.SelectedIndex, ready.Offset)
	}
	if ready.VisibleItems[0].Run.RunID != "two" || ready.VisibleItems[2].Run.RunID != "four" {
		t.Fatalf("expected visible window two..four, got %#v", ready.VisibleItems)
	}
}

func TestBoardSelectionPreservationAndClamping(t *testing.T) {
	b := NewBoard(2)
	b.SetItems([]Item{
		{Run: Run{RunID: "ready-a", Status: "ready"}},
		{Run: Run{RunID: "ready-b", Status: "ready"}},
		{Run: Run{RunID: "done-a", Status: "merged"}},
	}, "run:ready-b", 2)
	if got := b.SelectedItemKey(); got != "run:ready-b" {
		t.Fatalf("selected key=%q want run:ready-b", got)
	}

	b.SetItems([]Item{
		{Run: Run{RunID: "new-ready", Status: "ready"}},
		{Run: Run{RunID: "ready-b", Status: "ready"}},
	}, "run:ready-b", 2)
	ready := columnState(t, b, BoardColumnReady)
	if got := b.SelectedItemKey(); got != "run:ready-b" || ready.SelectedIndex != 1 {
		t.Fatalf("expected ready-b preserved at index 1, got key=%q index=%d", got, ready.SelectedIndex)
	}

	b.SetItems([]Item{{Run: Run{RunID: "new-ready", Status: "ready"}}}, "run:ready-b", 2)
	ready = columnState(t, b, BoardColumnReady)
	if got := b.SelectedItemKey(); got != "run:new-ready" || ready.SelectedIndex != 0 {
		t.Fatalf("expected selection clamped to new-ready, got key=%q index=%d", got, ready.SelectedIndex)
	}
}

func TestBoardColumnAndCardNavigation(t *testing.T) {
	b := NewBoard(12)
	b.SetItems([]Item{
		{Run: Run{RunID: "backlog", Status: "open"}},
		{Run: Run{RunID: "ready-1", Status: "ready"}},
		{Run: Run{RunID: "ready-2", Status: "ready"}},
		{Run: Run{RunID: "running", Status: "running"}},
	}, "run:backlog", 12)

	if key, ok := b.MoveColumn(1); !ok || key != "run:ready-1" {
		t.Fatalf("MoveColumn selected key=%q ok=%v, want run:ready-1 true", key, ok)
	}
	if key, ok := b.MoveCard(1); !ok || key != "run:ready-2" {
		t.Fatalf("MoveCard selected key=%q ok=%v, want run:ready-2 true", key, ok)
	}
	if key, ok := b.MoveColumn(1); !ok || key != "run:running" {
		t.Fatalf("MoveColumn selected key=%q ok=%v, want run:running true", key, ok)
	}
	if key, ok := b.MoveColumn(-1); !ok || key != "run:ready-2" {
		t.Fatalf("expected per-column ready selection to be remembered, got key=%q ok=%v", key, ok)
	}
}

func TestBoardSelectAtAndSelectKey(t *testing.T) {
	b := NewBoard(2)
	b.SetItems([]Item{
		{Run: Run{RunID: "ready-1", Status: "ready"}},
		{Run: Run{RunID: "ready-2", Status: "ready"}},
		{Run: Run{RunID: "ready-3", Status: "ready"}},
	}, "", 2)

	if key, ok := b.SelectAt(1, 1); !ok || key != "run:ready-2" {
		t.Fatalf("SelectAt key=%q ok=%v, want run:ready-2 true", key, ok)
	}
	if !b.SelectKey("run:ready-3") {
		t.Fatalf("expected SelectKey to find ready-3")
	}
	ready := columnState(t, b, BoardColumnReady)
	if ready.SelectedIndex != 2 || ready.Offset != 1 || b.SelectedKey() != "run:ready-3" {
		t.Fatalf("expected ready-3 selected and visible, key=%q index=%d offset=%d", b.SelectedKey(), ready.SelectedIndex, ready.Offset)
	}
}

func columnState(t *testing.T, b Board, col BoardColumn) BoardColumnState {
	t.Helper()
	for _, state := range b.Columns() {
		if state.Column == col {
			return state
		}
	}
	t.Fatalf("missing column %s", col)
	return BoardColumnState{}
}
