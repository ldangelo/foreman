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
