package main

import "testing"

func TestTaskListBuildsRunningReadyRecentAndExcludesActiveReady(t *testing.T) {
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
	items := list.Items()
	if len(items) != 3 {
		t.Fatalf("expected active run, ready task, and recent run, got %d items: %#v", len(items), items)
	}
	if items[0].Group != taskGroupRunning || items[0].Run.RunID != "run-active" {
		t.Fatalf("expected RUNNING run first, got %#v", items[0])
	}
	if items[1].Group != taskGroupReady || !items[1].IsTask || items[1].Task.TaskID != "ready-task" {
		t.Fatalf("expected non-active READY task second, got %#v", items[1])
	}
	if items[2].Group != taskGroupRecent || items[2].Run.RunID != "run-done" {
		t.Fatalf("expected RECENT run third, got %#v", items[2])
	}

	counts := list.Counts(runs, tasks)
	if counts[taskGroupRunning] != 1 || counts[taskGroupReady] != 1 || counts[taskGroupRecent] != 1 {
		t.Fatalf("expected visible group counts to exclude active ready task, got %#v", counts)
	}
}

func TestTaskListCollapseKeepsSelectionVisible(t *testing.T) {
	list := NewTaskList()
	list.SetData([]Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1"}}, []Task{{TaskID: "ready-1"}, {TaskID: "ready-2"}})
	list.Move(1)
	if it, _ := list.SelectedItem(); it.Task.TaskID != "ready-1" {
		t.Fatalf("expected ready-1 selected before collapse, got %#v", it)
	}

	list.ToggleSelectedGroup()
	list.SetData([]Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1"}}, []Task{{TaskID: "ready-1"}, {TaskID: "ready-2"}})

	if list.Collapsed(taskGroupReady) {
		if got := len(list.Items()); got != 1 {
			t.Fatalf("expected collapsed READY rows hidden, got %d items", got)
		}
		if list.SelectedIndex() != 0 {
			t.Fatalf("expected selection clamped to visible run, got index %d", list.SelectedIndex())
		}
	} else {
		t.Fatalf("expected READY group collapsed")
	}
}

func TestTaskListPreservesSelectionByStableIdentity(t *testing.T) {
	list := NewTaskList()
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
	list.SetData(nil, []Task{{TaskID: "alpha", Summary: "first"}, {TaskID: "beta", Summary: "second"}})
	list.Move(1)

	list.StartSearch()
	if changed := list.HandleSearchKey("a", []rune{'a'}); !changed {
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

	if changed := list.HandleSearchKey("l", []rune{'l'}); !changed {
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

	if changed := list.HandleSearchKey("esc", nil); !changed {
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
