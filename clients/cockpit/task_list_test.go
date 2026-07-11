package main

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestTaskListSectionsBuildCountsAndExcludeActiveReady(t *testing.T) {
	list := NewTaskList()
	runs := []Run{
		{Group: taskGroupRunning, TaskID: "active-task", RunID: "run-active", Status: "running", Phase: "developer", Summary: "active summary"},
		{Group: taskGroupRecent, TaskID: "done-task", RunID: "run-done", Status: "merged", Summary: "done summary"},
	}
	tasks := []Task{
		{TaskID: "active-task", Priority: "P0", Summary: "should not duplicate"},
		{TaskID: "ready-task", Priority: "P1", Summary: "ready summary"},
	}

	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-active" {
		t.Fatalf("expected default Running section to show active run only, got %#v", items)
	}

	list.MoveSection(1) // Ready
	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 1 || !items[0].IsTask || items[0].Task.TaskID != "ready-task" {
		t.Fatalf("expected Ready section to show non-active ready task, got %#v", items)
	}

	list.MoveSection(2) // Recent
	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-done" {
		t.Fatalf("expected Recent section to show recent run, got %#v", items)
	}

	list.MoveSection(1) // All
	list.SetData(runs, tasks)
	if got := len(list.Items()); got != 3 {
		t.Fatalf("expected All section to include active run, ready task, and recent run, got %d items: %#v", got, list.Items())
	}

	counts := list.Counts(runs, tasks)
	if counts[taskSectionRunning] != 1 || counts[taskSectionReady] != 1 || counts[taskSectionRecent] != 1 || counts[taskSectionAll] != 3 {
		t.Fatalf("expected section counts to exclude active ready task, got %#v", counts)
	}
}

func TestTaskListSectionSwitchKeepsSelectionVisible(t *testing.T) {
	list := NewTaskList()
	runs := []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1"}}
	tasks := []Task{{TaskID: "ready-1"}, {TaskID: "ready-2"}}
	list.SetData(runs, tasks)

	if it, _ := list.SelectedItem(); it.Run.RunID != "run-1" {
		t.Fatalf("expected running row selected before section switch, got %#v", it)
	}
	list.MoveSection(1)
	list.SetData(runs, tasks)
	if got := len(list.Items()); got != 2 {
		t.Fatalf("expected ready rows after section switch, got %d", got)
	}
	if list.SelectedIndex() != 0 {
		t.Fatalf("expected selection reset to first visible row, got index %d", list.SelectedIndex())
	}
}

func TestTaskListPreservesSelectionByStableIdentity(t *testing.T) {
	list := NewTaskList()
	list.MoveSection(4) // All
	list.SetData([]Run{
		{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a"},
		{Group: taskGroupRecent, TaskID: "task-b", RunID: "run-b"},
	}, nil)
	list.Move(1)

	list.SetData([]Run{
		{Group: taskGroupRunning, TaskID: "task-new", RunID: "run-new"},
		{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a"},
		{Group: taskGroupRecent, TaskID: "task-b", RunID: "run-b"},
	}, nil)

	it, ok := list.SelectedItem()
	if !ok || it.Run.RunID != "run-b" {
		t.Fatalf("expected selection to stay on run-b after prepend, got ok=%v item=%#v", ok, it)
	}
}

func TestTaskListSearchFiltersAndClampsSelection(t *testing.T) {
	list := NewTaskList()
	list.MoveSection(1) // Ready
	list.SetData(nil, []Task{{TaskID: "alpha", Summary: "first"}, {TaskID: "beta", Summary: "second"}})
	list.Move(1)

	list.StartSearch(keyPress("/"))
	if changed, _ := list.HandleSearchKey(keyPress("a")); !changed {
		t.Fatalf("expected search input to change filter")
	}
	list.SetData(nil, []Task{{TaskID: "alpha", Summary: "first"}, {TaskID: "beta", Summary: "second"}})

	items := list.Items()
	if len(items) != 2 {
		t.Fatalf("expected both task IDs to match search 'a', got %#v", items)
	}
	if list.SelectedIndex() != 1 {
		t.Fatalf("expected beta selection preserved while visible, got %d", list.SelectedIndex())
	}

	if changed, _ := list.HandleSearchKey(keyPress("l")); !changed {
		t.Fatalf("expected second search input to change filter")
	}
	list.SetData(nil, []Task{{TaskID: "alpha", Summary: "first"}, {TaskID: "beta", Summary: "second"}})
	items = list.Items()
	if len(items) != 1 || items[0].Task.TaskID != "alpha" {
		t.Fatalf("expected search 'al' to leave only alpha, got %#v", items)
	}
	if list.SelectedIndex() != 0 {
		t.Fatalf("expected selection clamped to visible filtered row, got %d", list.SelectedIndex())
	}

	if changed, _ := list.HandleSearchKey(specialKey(tea.KeyEsc)); !changed {
		t.Fatalf("expected escape to clear active search")
	}
	list.SetData(nil, []Task{{TaskID: "alpha", Summary: "first"}, {TaskID: "beta", Summary: "second"}})
	if got := list.Search(); got != "" {
		t.Fatalf("expected escape to clear search text, got %q", got)
	}
	if len(list.Items()) != 2 {
		t.Fatalf("expected cleared search to restore both rows, got %#v", list.Items())
	}
}

func TestTaskListCustomSectionsUseFieldFilters(t *testing.T) {
	list := NewTaskListWithSections([]TaskSection{
		{Name: "P0 Failed", Filter: "priority:p0 state:failed"},
		{Name: "Features", Filter: "type:feature -status:failed"},
	})
	runs := []Run{{Group: taskGroupRecent, TaskID: "run-task", RunID: "run-1", Priority: "P0", Status: "failed"}}
	tasks := []Task{
		{TaskID: "task-feature", TaskType: "feature", Priority: "P1", Status: "backlog"},
		{TaskID: "task-bug", TaskType: "bug", Priority: "P0", Status: "backlog"},
	}

	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-1" {
		t.Fatalf("expected custom failed/P0 section to match failed run, got %#v", items)
	}
	list.MoveSection(1)
	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 1 || items[0].Task.TaskID != "task-feature" {
		t.Fatalf("expected custom feature section to match feature task only, got %#v", items)
	}
}

func TestTaskListCurrentScopeFiltersToProjectID(t *testing.T) {
	list := NewTaskList()
	list.SetProjectID("proj-a")
	list.MoveSection(4) // All
	runs := []Run{
		{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a", ProjectID: "proj-a"},
		{Group: taskGroupRunning, TaskID: "task-b", RunID: "run-b", ProjectID: "proj-b"},
	}
	tasks := []Task{
		{TaskID: "ready-a", ProjectID: "proj-a"},
		{TaskID: "ready-b", ProjectID: "proj-b"},
	}

	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 2 || items[0].Run.RunID != "run-a" || items[1].Task.TaskID != "ready-a" {
		t.Fatalf("expected current scope to show only proj-a items, got %#v", items)
	}
	counts := list.Counts(runs, tasks)
	if counts[taskSectionAll] != 2 || counts[taskSectionRunning] != 1 || counts[taskSectionReady] != 1 {
		t.Fatalf("expected current-scope counts for proj-a only, got %#v", counts)
	}

	list.ToggleScope()
	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 4 {
		t.Fatalf("expected global scope to include all projects, got %#v", items)
	}
}
