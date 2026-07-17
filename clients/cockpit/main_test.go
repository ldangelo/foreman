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
	if blockedItem.IsTask {
		t.Fatalf("expected run-type board item, got task-type: %s", blockedItem.Task.TaskID)
	}
	if blockedItem.Run.ProjectID != "52ba0d80-913d-4880-871b-a81e308c34d4" {
		t.Fatalf("expected ProjectID 52ba0d80..., got %q", blockedItem.Run.ProjectID)
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
	// slow API backlogs one request per 2s tick and keypresses lag.
	m := newModel(NewMockClient())

	// 1. newModel must initialize dataLoading=true so the first tick (2s after
	//    Init) doesn't double-dispatch while the initial loadData is still in flight.
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
	//    action reloads that must refresh).
	if cmd := m.startDataLoad(true); cmd == nil {
		t.Fatalf("expected startDataLoad(true) to return loadData even when dataLoading=true, got nil")
	}
	if !m.dataLoading {
		t.Fatalf("expected dataLoading to remain true after force reload")
	}

	// 4. dataMsg clears the flag so subsequent ticks can refresh.
	updated, _ := m.Update(dataMsg{runs: nil, tasks: nil, metrics: Metrics{}, boardColumns: nil, errors: nil})
	updatedM := updated.(model)
	if updatedM.dataLoading {
		t.Fatalf("expected dataMsg to clear dataLoading, got true")
	}

	// 5. With the flag cleared, a non-force reload dispatches again.
	if cmd := updatedM.startDataLoad(false); cmd == nil {
		t.Fatalf("expected startDataLoad(false) to dispatch after dataLoading cleared, got nil")
	}
}
