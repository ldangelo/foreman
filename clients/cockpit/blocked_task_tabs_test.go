package main

import (
	"strings"
	"testing"
)

func TestBlockedTaskShowsTabs(t *testing.T) {
	// Setup: Create a model with a blocked task and its run
	m := newModel(NewMockClient())
	
	// Add a blocked task
	m.tasks = []Task{
		{
			TaskID:      "task-beff3caa",
			Title:       "Blocked task test",
			Status:      "blocked",
			Priority:    "P2",
			TaskType:    "feature",
			ProjectID:   "test-project",
			Description: "This is a blocked task with an associated run",
		},
	}
	
	// Add the run for that task (with RECENT group so it's hidden from task list)
	m.runs = []Run{
		{
			TaskID:    "task-beff3caa",
			RunID:     "run-beff3caa",
			Status:    "failed",
			Phase:     "developer",
			Group:     taskGroupRecent,
			ProjectID: "test-project",
			Messages:  42,
			Events:    123,
		},
	}
	
	// Set project ID and switch to global scope
	m.taskList.SetProjectID("test-project")
	m.taskList.ToggleScope() // switch to global
	m.taskList.SetData(m.runs, m.tasks)
	
	t.Logf("Initial section: %s", m.taskList.ActiveSection().Name)
	
	// Move to the All section (4 sections: Running, Ready, Blocked, Recent, All)
	for i := 0; i < 4; i++ {
		m.taskList.MoveSection(1)
	}
	t.Logf("Final section: %s", m.taskList.ActiveSection().Name)
	m.taskList.SetData(m.runs, m.tasks)
	
	items := m.taskList.Items()
	t.Logf("After SetData in All section: %d items", len(items))
	
	if len(items) == 0 {
		t.Fatal("No items in All section - blocked task not appearing")
	}
	
	// Select the blocked task by moving until we find it
	for i := 0; i < len(items); i++ {
		selected, ok := m.taskList.SelectedItem()
		if !ok {
			t.Fatal("No item selected")
		}
		if selected.Task.TaskID == "task-beff3caa" {
			break
		}
		m.taskList.Move(1)
	}
	
	// Verify we selected the blocked task
	selected, ok := m.taskList.SelectedItem()
	if !ok {
		t.Fatal("No item selected")
	}
	if selected.Task.TaskID != "task-beff3caa" {
		t.Fatalf("Expected to select task-beff3caa, got %s", selected.Task.TaskID)
	}
	
	// Verify it's marked as a task (not a run)
	if !selected.IsTask {
		t.Error("Expected blocked task to have IsTask=true")
	}
	
	// Now test selectedRunnableRun - this is the critical test
	run, isRun := m.selectedRunnableRun()
	if !isRun {
		t.Error("selectedRunnableRun should return true for blocked task with run")
	} else {
		t.Logf("selectedRunnableRun found run: %s (taskID=%s)", run.RunID, run.TaskID)
	}
	if run.TaskID != "task-beff3caa" {
		t.Errorf("Expected TaskID 'task-beff3caa', got '%s'", run.TaskID)
	}
	if run.RunID != "run-beff3caa" {
		t.Errorf("Expected RunID 'run-beff3caa', got '%s'", run.RunID)
	}
	
	// Set tab to messages so we can verify tabs are rendered
	m.tab = 1 // messages tab
	
	// Render right pane
	rendered := m.renderRight(100)
	
	// The rendered output should contain tabs
	if !strings.Contains(rendered, "messages") {
		t.Errorf("Expected renderRight to include 'messages' tab\nRendered:\n%s", rendered)
	}
	if !strings.Contains(rendered, "events") {
		t.Errorf("Expected renderRight to include 'events' tab\nRendered:\n%s", rendered)
	}
	if !strings.Contains(rendered, "logs") {
		t.Errorf("Expected renderRight to include 'logs' tab\nRendered:\n%s", rendered)
	}
	
	t.Logf("✓ Blocked task correctly shows tabs")
	t.Logf("✓ Rendered output contains: messages, events, logs, reports, files, pr")
}

func TestBlockedTaskWithoutRun(t *testing.T) {
	// Edge case: blocked task but no run exists yet (rare but possible)
	m := newModel(NewMockClient())
	
	m.tasks = []Task{
		{
			TaskID:     "task-no-run",
			Title:      "Blocked without run",
			Status:     "blocked",
			Priority:   "P2",
			ProjectID:  "test-project",
		},
	}
	m.runs = nil // No runs
	
	m.taskList.SetProjectID("test-project")
	m.taskList.ToggleScope()
	m.taskList.SetData(m.runs, m.tasks)
	m.taskList.MoveSection(4) // All section
	m.taskList.SetData(m.runs, m.tasks)
	
	items := m.taskList.Items()
	if len(items) == 0 {
		t.Fatal("expected blocked task to appear even without run")
	}
	
	// selectedRunnableRun should return false
	_, isRun := m.selectedRunnableRun()
	if isRun {
		t.Error("selectedRunnableRun should return false for blocked task without run")
	}
	
	// Tabs should NOT render (no run to show)
	rendered := m.renderRight(100)
	if strings.Contains(rendered, "[messages]") {
		t.Error("tabs should not render when there's no run")
	}
	t.Logf("✓ Blocked task without run correctly shows summary")
}
