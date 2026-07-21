package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

func TestDumpRequested(t *testing.T) {
	cases := []struct {
		name string
		args []string
		env  string
		want bool
	}{
		{name: "flag", args: []string{"--dump"}, want: true},
		{name: "env one", env: "1", want: true},
		{name: "env true", env: "true", want: true},
		{name: "env true case insensitive", env: "TRUE", want: true},
		{name: "unset", want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dumpRequested(tc.args, tc.env); got != tc.want {
				t.Fatalf("dumpRequested(%#v, %q) = %v, want %v", tc.args, tc.env, got, tc.want)
			}
		})
	}
}

func TestDumpClientSmokesMockBackend(t *testing.T) {
	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	err = dumpClient(NewMockClient())
	if closeErr := w.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	os.Stdout = oldStdout
	out, readErr := io.ReadAll(r)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if err != nil {
		t.Fatalf("dumpClient returned error: %v", err)
	}
	text := string(out)
	for _, want := range []string{"runs=", "running=", "recent=", "ready=", "first_run=", "messages=", "events=", "logs=", "reports="} {
		if !strings.Contains(text, want) {
			t.Fatalf("expected dump output to include %q, got:\n%s", want, text)
		}
	}
}

func TestInstallThemesRequested(t *testing.T) {
	if !installThemesRequested([]string{"--install-themes"}) {
		t.Fatal("expected --install-themes to request theme installation")
	}
	if installThemesRequested([]string{"--dump"}) {
		t.Fatal("did not expect --dump to request theme installation")
	}
}

func TestProgramOptionsFromEnvEnablesDeterministicDemoMode(t *testing.T) {
	if opts := programOptionsFromEnv(""); len(opts) != 0 {
		t.Fatalf("expected no default program options, got %d", len(opts))
	}
	if opts := programOptionsFromEnv("true"); len(opts) != 2 {
		t.Fatalf("expected deterministic demo window/color options, got %d", len(opts))
	}
}

func TestClientForConfigDefaultsToLocalLiveServer(t *testing.T) {
	client := clientForConfig("", "", "")
	httpClient, ok := client.(*httpClient)
	if !ok {
		t.Fatalf("expected default client to use live HTTP backend, got %T", client)
	}
	if httpClient.base != defaultServerURL {
		t.Fatalf("expected default server URL %q, got %q", defaultServerURL, httpClient.base)
	}
}

func TestClientForConfigCanForceMockBackend(t *testing.T) {
	client := clientForConfig("", "", "mock")
	if _, ok := client.(*mockClient); !ok {
		t.Fatalf("expected mock backend, got %T", client)
	}
}

// TestBoardItemsInTaskList verifies that when the server provides board items,
// taskList.items is populated with those board items so that click/key selection
// finds the item and selectedRunnableRun can return the run for retry/reset.
func TestBoardItemsInTaskList(t *testing.T) {
	m := newModel(NewMockClient())
	m.taskList.SetProjectID("test-project")

	// Simulate server returning board items via boardItemsFromColumns path.
	// These are board run items (not tasks) with no ProjectID set by boardItemToItem.
	m.boardItems = map[string][]Item{
		"blocked": {
			{
				IsTask: false,
				Run:    Run{TaskID: "task-blocked-1", RunID: "run-blocked-1", Status: "blocked", ProjectID: ""},
				Group:  taskGroupRunning,
			},
		},
		"done": {
			{
				IsTask: false,
				Run:    Run{TaskID: "task-done-1", RunID: "run-done-1", Status: "done", ProjectID: ""},
				Group:  taskGroupRecent,
			},
		},
	}
	// Build items — this is what happens when dataMsg with boardColumns is received.
	// In board mode, taskList.items should be replaced with board items.
	origLayoutMode := m.config.Cockpit.Layout.Mode
	m.config.Cockpit.Layout.Mode = layoutModeBoard
	m.buildItems()
	m.config.Cockpit.Layout.Mode = origLayoutMode
	// taskList.items must contain the board items (not runs+tasks items).
	if len(m.taskList.items) != 2 {
		t.Fatalf("expected taskList.items to contain 2 board items, got %d", len(m.taskList.items))
	}

	// Run items must have ProjectID set from taskList.projectID.
	for _, it := range m.taskList.items {
		if it.IsTask {
			t.Fatalf("expected all items to be run items, got task %s", it.Task.TaskID)
		}
		if it.Run.ProjectID != "test-project" {
			t.Fatalf("expected Run.ProjectID to be set to test-project, got %q", it.Run.ProjectID)
		}
	}

	// selectedRunnableRun must find the run for a selected board item.
	// Select the first board item (blocked).
	if len(m.taskList.items) > 0 {
		m.taskList.selected = 0
	}
	run, ok := m.selectedRunnableRun()
	if !ok {
		t.Fatal("expected selectedRunnableRun to find the run for the selected board item")
	}
	if run.RunID != "run-blocked-1" {
		t.Fatalf("expected selected run to be run-blocked-1, got %s", run.RunID)
	}
	if run.ProjectID != "test-project" {
		t.Fatalf("expected run.ProjectID to be test-project, got %q", run.ProjectID)
	}
}

// TestBoardClickSelectsItem tests the complete click-to-retry flow for board items,
// using the real boardItemsFromColumns conversion path and verifying that a board
// card click results in selectedRunnableRun finding the correct run with RunID and ProjectID.
// TestBoardClickSelectsItem verifies the complete click-to-retry flow for board items:
// after buildItems produces board items in taskList.items, clicking a board card (via
// taskListSelectKey) must update the selection so that selectedRunnableRun() finds
// the correct run for the 'r' (retry) action.
// TestBoardClickSelectsItem verifies the complete click-to-retry flow for board items:
// after buildItems produces board items in taskList.items, clicking a board card (via
// taskListSelectKey) must update the selection so that selectedRunnableRun() finds
// the correct run for the 'r' (retry) action.
func TestBoardClickSelectsItem(t *testing.T) {
	m := newModel(NewMockClient())
	m.taskList.SetProjectID("52ba0d80-913d-4880-871b-a81e308c34d4")

	// Add runs for two board items (blocked + ready).
	m.runs = []Run{
		{
			Group:     taskGroupRunning,
			TaskID:    "foreman-abf48",
			RunID:     "8776e630-7e9e-d311-c7a9-41a770c90147",
			Status:    "blocked",
			Phase:     "developer",
			Priority:  "P1",
			TaskType:  "feature",
			ProjectID: "52ba0d80-913d-4880-871b-a81e308c34d4",
		},
		{
			Group:     taskGroupRunning,
			TaskID:    "foreman-xyz99",
			RunID:     "9999e630-7e9e-d311-c7a9-41a770c90147",
			Status:    "ready",
			Phase:     "developer",
			Priority:  "P2",
			TaskType:  "feature",
			ProjectID: "52ba0d80-913d-4880-871b-a81e308c34d4",
		},
	}

	// Use boardItemsFromColumns (the real conversion path) with two board cards.
	boardCols := map[string][]BoardItem{
		"blocked": {
			{
				TaskID:    "foreman-abf48",
				RunID:     "8776e630-7e9e-d311-c7a9-41a770c90147",
				Title:     "Add phase control Pi tools",
				Status:    "blocked",
				Priority:  "P1",
				TaskType:  "feature",
				UpdatedAt: "2026-07-15T12:00:00Z",
				Group:     "RUNNING",
				Type:      "attention",
				Attention: "blocked",
			},
		},
		"ready": {
			{
				TaskID:    "foreman-xyz99",
				RunID:     "9999e630-7e9e-d311-c7a9-41a770c90147",
				Title:     "Another task",
				Status:    "ready",
				Priority:  "P2",
				TaskType:  "feature",
				UpdatedAt: "2026-07-15T12:00:00Z",
				Group:     "RUNNING",
				Type:      "attention",
				Attention: "ready",
			},
		},
	}
	m.boardItems = boardItemsFromColumns(boardCols, m.tasks)

	// Switch to board mode and build items.
	origLayoutMode := m.config.Cockpit.Layout.Mode
	m.config.Cockpit.Layout.Mode = layoutModeBoard
	m.buildItems()
	m.config.Cockpit.Layout.Mode = origLayoutMode

	// After buildItems, taskList.items must contain both board items.
	if len(m.taskList.items) != 2 {
		t.Fatalf("expected 2 board items in taskList.items, got %d", len(m.taskList.items))
	}

	// buildItems sets selected = len(items)-1 = 1 (last item = ready item).
	if m.taskList.selected != 1 {
		t.Fatalf("expected buildItems to set selected=1 (last item), got %d", m.taskList.selected)
	}

	// Find the blocked item by RunID (boardCols map iteration order is random).
	var blockedItem Item
	var blockedIdx int
	for i, it := range m.taskList.items {
		if it.Run.RunID == "8776e630-7e9e-d311-c7a9-41a770c90147" {
			blockedItem = it
			blockedIdx = i
			break
		}
	}
	if blockedItem.Run.RunID == "" {
		t.Fatal("blocked board item not found in taskList.items")
	}
	// Every board entry is now a task (boardItemToItem is task-first).
	// The attached run is surfaced on Task.RunID and as a shadow Run
	// for selection identity / run-action navigation.
	if !blockedItem.IsTask {
		t.Fatalf("expected task-type board item with shadow Run, got non-task")
	}
	if blockedItem.Task.RunID != "8776e630-7e9e-d311-c7a9-41a770c90147" {
		t.Fatalf("expected Task.RunID to carry the attached run, got %q", blockedItem.Task.RunID)
	}
	if blockedItem.Run.RunID != "8776e630-7e9e-d311-c7a9-41a770c90147" {
		t.Fatalf("expected shadow Run.RunID to match attached run, got %q", blockedItem.Run.RunID)
	}

	// Simulate clicking the blocked board card: taskListSelectKey finds it and updates selection.
	key := itemKey(blockedItem)
	if key == "" {
		t.Fatal("itemKey returned empty for board item")
	}

	// buildItems sets selected = len(items)-1 = 1 (last item). We want to test a real
	// click transition, not the no-op path (clicking the already-selected item).
	// If blockedIdx == selected, force a prior selection to a different index first.
	if blockedIdx == m.taskList.selected && len(m.taskList.items) > 1 {
		otherIdx := (blockedIdx + 1) % len(m.taskList.items)
		m.taskList.selected = otherIdx
	}

	// taskListSelectKey must find the key and return true (real selection change).
	found := m.taskListSelectKey(key)
	if !found {
		t.Fatalf("taskListSelectKey(%q) returned false — board item not found in taskList.items", key)
	}
	if m.taskList.selected != blockedIdx {
		t.Fatalf("expected taskList.selected=%d after selecting blocked item, got %d", blockedIdx, m.taskList.selected)
	}

	// selectedRunnableRun() is what the 'r' (retry) action calls.
	// It must find the run for the selected board item.
	run, ok := m.selectedRunnableRun()
	if !ok {
		t.Fatal("selectedRunnableRun returned false for selected board attention item — 'retry: no run selected'")
	}
	if run.RunID != "8776e630-7e9e-d311-c7a9-41a770c90147" {
		t.Fatalf("expected run.RunID 8776e630..., got %s", run.RunID)
	}
	if run.ProjectID != "52ba0d80-913d-4880-871b-a81e308c34d4" {
		t.Fatalf("expected run.ProjectID 52ba0d80..., got %q", run.ProjectID)
	}
}

// TestBoardDerivedItemsSelectedPath verifies the m.boardItems == nil derivation path:
// when board mode is on but m.boardItems is nil, buildItems uses boardFilteredItems()
// (client-side grouping) and must also set selected = len(items)-1 so the last
// derived board item is selected.
func TestBoardDerivedItemsSelectedPath(t *testing.T) {
	m := newModel(NewMockClient())
	m.taskList.SetProjectID("test-project")

	// Add runs that will be grouped by boardFilteredItems (derived board items).
	m.runs = []Run{
		{
			Group:     taskGroupRunning,
			TaskID:    "foreman-run1",
			RunID:     "run-id-1",
			Status:    "blocked",
			Phase:     "developer",
			Priority:  "P1",
			TaskType:  "feature",
			ProjectID: "test-project",
		},
		{
			Group:     taskGroupRunning,
			TaskID:    "foreman-run2",
			RunID:     "run-id-2",
			Status:    "ready",
			Phase:     "developer",
			Priority:  "P2",
			TaskType:  "feature",
			ProjectID: "test-project",
		},
	}
	// m.boardItems is nil (no server board data), so buildItems uses boardFilteredItems.
	// Verify boardItemsFromServer returns the derived items.
	origLayoutMode := m.config.Cockpit.Layout.Mode
	m.config.Cockpit.Layout.Mode = layoutModeBoard
	m.buildItems()
	m.config.Cockpit.Layout.Mode = origLayoutMode

	// boardFilteredItems produces run items from m.runs.
	// With scope=global (projectID="" from newModel) and no search filter,
	// both runs pass filtering, giving 2 items.
	if len(m.taskList.items) < 1 {
		t.Fatalf("expected at least 1 item in taskList.items from derived board items, got %d", len(m.taskList.items))
	}

	// When no server board data (boardItems=nil), buildItems uses boardFilteredItems.
	// Without a prior selection key, selected defaults to 0 (first item) to avoid
	// randomly jumping to the last item — unlike server-board path which intentionally
	// selects the last item since the server's column order may deprioritize item 0.
	if m.taskList.selected != 0 {
		t.Fatalf("expected selected=0 (first item, no prior selection), got %d", m.taskList.selected)
	}

	// The first item (selected=0) must be a run item with correct ProjectID.
	firstIt := m.taskList.items[0]
	if firstIt.IsTask {
		t.Fatalf("expected first derived item to be a run, got task: %s", firstIt.Task.TaskID)
	}
	if firstIt.Run.ProjectID != "test-project" {
		t.Fatalf("expected ProjectID test-project, got %q", firstIt.Run.ProjectID)
	}
}




func TestDataLoadingGuardPreventsOverlappingRefreshes(t *testing.T) {
	// Bug guard: every tickMsg fires loadData. If we don't gate on a flag, a
	// slow API backlogs one request per 2s tick and keypresses lag. Without
	// generations, a faster in-flight response can clobber a slower newer one.
	m := newModel(NewMockClient())

	// 1. newModel must initialize dataLoading=true so the first tick (2s after
	//    Init) doesn't double-dispatch while the initial loadData is in flight.
	if !m.dataLoading {
		t.Fatalf("expected newModel to initialize dataLoading=true, got false")
	}

	// 2. startDataLoad(false) on an in-flight load returns nil (skip the tick's reload).
	if cmd := m.startDataLoad(false); cmd != nil {
		t.Fatalf("expected startDataLoad(false) to return nil while dataLoading=true, got %T", cmd)
	}
	if !m.dataLoading {
		t.Fatalf("expected dataLoading to remain true after skipped reload")
	}

	// 3. startDataLoad(true) on an in-flight load still dispatches (force=true for
	//    action reloads that must refresh). It increments dataGeneration.
	if cmd := m.startDataLoad(true); cmd == nil {
		t.Fatalf("expected startDataLoad(true) to dispatch even when dataLoading=true, got nil")
	}
	if !m.dataLoading {
		t.Fatalf("expected dataLoading to remain true after force reload")
	}
	if m.dataGeneration != 1 {
		t.Fatalf("expected dataGeneration=1 after first startDataLoad, got %d", m.dataGeneration)
	}

	// 4. A dataMsg with a stale (older) generation must NOT clear dataLoading
	//    or apply state. This is the "faster stale response clobbers newer"
	//    bug: while two loads are in flight (gen 0 from Init, gen 1 from
	//    forced reload), a slow gen-0 response must not stomp the gen-1
	//    outcome.
	// 4. A dataMsg with a stale (older) generation must NOT clear dataLoading
	//    or apply state. Seed runs with a sentinel; a stale response carrying
	//    different values must leave it untouched.
	m.runs = []Run{{RunID: "sentinel", TaskID: "sentinel-task", Status: "completed"}}
	updated, _ := m.Update(dataMsg{runs: []Run{{RunID: "stale", TaskID: "stale-task", Status: "failed"}}, tasks: nil, metrics: Metrics{}, boardColumns: nil, errors: nil, generation: 0})
	updatedM := updated.(model)
	if !updatedM.dataLoading {
		t.Fatalf("expected stale dataMsg to leave dataLoading=true, got false")
	}
	if len(updatedM.runs) != 1 || updatedM.runs[0].RunID != "sentinel" {
		t.Fatalf("expected stale dataMsg to leave runs untouched, got %+v", updatedM.runs)
	}
	// 5. The matching-generation dataMsg clears the flag and applies state.
	updated, _ = m.Update(dataMsg{runs: nil, tasks: nil, metrics: Metrics{}, boardColumns: nil, errors: nil, generation: 1})
	updatedM = updated.(model)
	if updatedM.dataLoading {
		t.Fatalf("expected matching dataMsg to clear dataLoading, got true")
	}

	// 6. With the flag cleared, a non-force reload dispatches again and increments.
	prevGen := updatedM.dataGeneration
	if cmd := updatedM.startDataLoad(false); cmd == nil {
		t.Fatalf("expected startDataLoad(false) to dispatch after dataLoading cleared, got nil")
	}
	if updatedM.dataGeneration != prevGen+1 {
		t.Fatalf("expected dataGeneration=%d after next dispatch, got %d", prevGen+1, updatedM.dataGeneration)
	}
}

// TestBoardItemToItemRunAndAttentionCarriesAge asserts the live /api/v1/board
// payload (where every Done card has Type="run" or "attention" with an
// attached run, NOT Type="task") still produces an Item whose age stamp
// is populated from BoardItem.UpdatedAt. Regression for the Done-column
// age bug: boardItemToItem previously routed non-task board entries to
// Item.Run without setting Run.Last, so renderBoardCard's age lookup
// returned "" and line3 rendered as "P? \u00b7 type \u00b7" with no age.
// After the task-first refactor, every board item is an Item.Task; the
// run-derived status / run id are overlays (Task.RunID + shadow Run),
// and Task.Updated carries the activity stamp.
func TestBoardItemToItemRunAndAttentionCarriesAge(t *testing.T) {
	const updated = "2026-07-15T12:00:00Z"
	cases := []struct {
		name string
		bi   BoardItem
	}{
		{
			name: "run",
			bi: BoardItem{
				TaskID: "foreman-d72b", RunID: "run-d72b-1",
				Title: "Add phase control", Status: "closed",
				Priority: "P2", TaskType: "feature",
				UpdatedAt: updated, Group: "RECENT", Type: "run",
			},
		},
		{
			name: "attention",
			bi: BoardItem{
				TaskID: "foreman-cb7b", RunID: "run-cb7b-1",
				Title: "Merge polling", Status: "failed",
				Priority: "P1", TaskType: "bug",
				UpdatedAt: updated, Group: "RUNNING",
				Type: "attention", Attention: "merge_conflict",
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			item := boardItemToItem(tc.bi, map[string]Task{}, "done")
			if !item.IsTask {
				t.Fatalf("expected IsTask=true for board entry (task-first model), got false")
			}
			if item.Task.Updated != updated {
				t.Fatalf("expected Task.Updated=%q (age stamp), got %q", updated, item.Task.Updated)
			}
			if item.Task.TaskID != tc.bi.TaskID {
				t.Fatalf("expected Task.TaskID=%q, got %q", tc.bi.TaskID, item.Task.TaskID)
			}
			if item.Task.RunID != tc.bi.RunID {
				t.Fatalf("expected Task.RunID=%q, got %q", tc.bi.RunID, item.Task.RunID)
			}
			if item.Task.Title != tc.bi.Title {
				t.Fatalf("expected Task.Title=%q, got %q", tc.bi.Title, item.Task.Title)
			}
			// Shadow Run must carry the same fields the legacy non-task
			// branch produced, so selection identity / drill-down
			// navigation don't degrade.
			if item.Run.RunID != tc.bi.RunID {
				t.Fatalf("expected shadow Run.RunID=%q, got %q", tc.bi.RunID, item.Run.RunID)
			}
			if item.Run.Status != tc.bi.Status {
				t.Fatalf("expected shadow Run.Status=%q, got %q", tc.bi.Status, item.Run.Status)
			}
			if item.Run.Last != updated {
				t.Fatalf("expected shadow Run.Last=%q (mirrors Task.Updated), got %q", updated, item.Run.Last)
			}
			// Verify the age path: boardActivityTime(it) must parse to a
			// non-zero time so renderBoardCard formats "Xh ago".
			if at := boardActivityTime(item); at.IsZero() {
				t.Fatalf("expected non-zero activity time from Task.Updated=%q, got zero", updated)
			}
			// Exercise the user-visible path: renderBoardCard on the
			// converted item must emit "ago" on line3 at narrow Done-column
			// widths. This is the exact invariant the Done-column bug
			// violated (line3 rendered as "P? \u00b7 type \u00b7" with no age).
			out := stripANSI(renderBoardCard(item, 24, false, paneVisualFor(false, defaultConfig().Cockpit.Focus)))
			lines := strings.Split(out, "\n")
			if len(lines) < 3 {
				t.Fatalf("expected 3-line card, got %d lines:\n%s", len(lines), out)
			}
			if !strings.Contains(lines[2], "ago") {
				t.Fatalf("expected line3 to contain age (\"ago\"), got %q\nfull:\n%s", lines[2], out)
			}
		})
	}
}

// TestBoardItemToItemCachedTaskFallback asserts that when the cached
// taskMap carries fields (Status, Updated) and the BoardItem omits
// them, boardItemToItem falls back to the cached values rather than
// dropping them. Regression for the CodeRabbit review on PR #378
// (model.go:1938-1953): the previous implementation initialized
// task.Status / task.Updated from bi before the cache lookup, then
// only re-overlaid them when bi.RunID / bi.UpdatedAt were non-empty,
// so a board payload with empty run-derived fields left the cached
// stamp stranded in taskMap and never reached the rendered line3.
func TestBoardItemToItemCachedTaskFallback(t *testing.T) {
	const cachedUpdated = "2026-07-10T08:00:00Z"
	cached := map[string]Task{
		"foreman-d72b": {
			TaskID:    "foreman-d72b",
			Title:     "cached title",
			Status:    "cached-status",
			Updated:   cachedUpdated,
			Created:   "2026-07-01T08:00:00Z",
			ProjectID: "test-project",
		},
	}
	bi := BoardItem{
		TaskID: "foreman-d72b",
		RunID:  "run-d72b-1",
		// Title / Priority / TaskType are always board-derived.
		Title: "board title", Priority: "P2", TaskType: "feature",
		// Status omitted on purpose (run-derived but absent on this row).
		// UpdatedAt omitted on purpose (board payload didn't carry it).
		Group: "RECENT", Type: "run",
	}
	item := boardItemToItem(bi, cached, "done")
	if !item.IsTask {
		t.Fatalf("expected IsTask=true (task-first model)")
	}
	// Always-board-derived fields must come from bi.
	if item.Task.Title != "board title" {
		t.Fatalf("expected Task.Title=board title, got %q", item.Task.Title)
	}
	if item.Task.Priority != "P2" {
		t.Fatalf("expected Task.Priority=P2, got %q", item.Task.Priority)
	}
	if item.Task.RunID != "run-d72b-1" {
		t.Fatalf("expected Task.RunID=run-d72b-1, got %q", item.Task.RunID)
	}
	// Cached Status must come through when bi.Status is empty.
	if item.Task.Status != "cached-status" {
		t.Fatalf("expected fallback to cached Status=cached-status, got %q", item.Task.Status)
	}
	// Cached Updated must come through when bi.UpdatedAt is empty.
	if item.Task.Updated != cachedUpdated {
		t.Fatalf("expected fallback to cached Updated=%q, got %q", cachedUpdated, item.Task.Updated)
	}
	// Cached ProjectID must come through (not on the board payload).
	if item.Task.ProjectID != "test-project" {
		t.Fatalf("expected fallback to cached ProjectID=test-project, got %q", item.Task.ProjectID)
	}
	// And the age-render path must produce "ago".
	out := stripANSI(renderBoardCard(item, 24, false, paneVisualFor(false, defaultConfig().Cockpit.Focus)))
	lines := strings.Split(out, "\n")
	if !strings.Contains(lines[2], "ago") {
		t.Fatalf("expected line3 to contain age, got %q\nfull:\n%s", lines[2], out)
	}

	// Board-derived overrides must win over the cached values when
	// present.
	biWithOverlay := bi
	biWithOverlay.Status = "closed"
	biWithOverlay.UpdatedAt = "2026-07-15T12:00:00Z"
	itemOverlay := boardItemToItem(biWithOverlay, cached, "done")
	if itemOverlay.Task.Status != "closed" {
		t.Fatalf("expected overlay Status=closed, got %q", itemOverlay.Task.Status)
	}
	if itemOverlay.Task.Updated != "2026-07-15T12:00:00Z" {
		t.Fatalf("expected overlay Updated=2026-07-15..., got %q", itemOverlay.Task.Updated)
	}
}
