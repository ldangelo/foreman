package main

import (
	"fmt"
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
		{TaskID: "active-task", Status: "in_progress", Priority: "P0", Summary: "should not duplicate"},
		{TaskID: "pending-task", Status: "pending", Priority: "P0", Summary: "active without run"},
		{TaskID: "ready-task", Status: "backlog", Priority: "P1", Summary: "ready summary"},
	}

	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 2 || items[0].Run.RunID != "run-active" || !items[1].IsTask || items[1].Task.TaskID != "pending-task" {
		t.Fatalf("expected default Running section to show active run and active task-only row, got %#v", items)
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
	if got := len(list.Items()); got != 4 {
		t.Fatalf("expected All section to include active run, active task, ready task, and recent run, got %d items: %#v", got, list.Items())
	}

	counts := list.Counts(runs, tasks)
	if counts[taskSectionRunning] != 2 || counts[taskSectionReady] != 1 || counts[taskSectionRecent] != 1 || counts[taskSectionAll] != 4 {
		t.Fatalf("expected section counts to classify active task-only rows as running, got %#v", counts)
	}
}

func TestTaskListTreatsAttentionRunsAsFailedAndSearchesVisibleMetadata(t *testing.T) {
	list := NewTaskList()
	runs := []Run{
		{Group: taskGroupRecent, TaskID: "task-needs-review", RunID: "run-needs-review", Status: "completed", PRState: "open", Messages: 2, Attention: "needs-review"},
		{Group: taskGroupRecent, TaskID: "task-clean", RunID: "run-clean", Status: "completed", PRState: "closed"},
	}

	list.MoveSection(2) // Failed
	list.SetData(runs, nil)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-needs-review" {
		t.Fatalf("expected attention run in Failed section, got %#v", items)
	}

	list.MoveSection(2) // All
	list.search = "pr:open"
	list.SetData(runs, nil)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-needs-review" {
		t.Fatalf("expected pr metadata search to find open run only, got %#v", items)
	}

	list.search = "✉2"
	list.SetData(runs, nil)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-needs-review" {
		t.Fatalf("expected visible message-count metadata search to find open run only, got %#v", items)
	}

	list.search = "messages:2"
	list.SetData(runs, nil)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-needs-review" {
		t.Fatalf("expected messages field-token search to find message-count metadata, got %#v", items)
	}
}

func TestFailedSectionIncludesFailedLikeTaskAndRunStatuses(t *testing.T) {
	for _, status := range []string{"failed", "stuck", "conflict", "test-failed"} {
		t.Run("task_"+status, func(t *testing.T) {
			list := NewTaskList()
			list.MoveSection(2) // Failed
			list.SetData(nil, []Task{{TaskID: "task-" + status, Status: status}})
			if items := list.Items(); len(items) != 1 || !items[0].IsTask || items[0].Task.Status != status {
				t.Fatalf("expected %s task in Failed section, got %#v", status, items)
			}
		})

		t.Run("run_"+status, func(t *testing.T) {
			list := NewTaskList()
			list.MoveSection(2) // Failed
			list.SetData([]Run{{Group: taskGroupRecent, RunID: "run-" + status, Status: status}}, nil)
			if items := list.Items(); len(items) != 1 || items[0].Run.Status != status {
				t.Fatalf("expected %s run in Failed section, got %#v", status, items)
			}
		})
	}
}

func TestRecentSectionIsMostRecentFirstAndCapped(t *testing.T) {
	list := NewTaskList()
	list.MoveSection(3) // Recent
	runs := make([]Run, 0, defaultRecentSectionLimit+5)
	for i := 0; i < defaultRecentSectionLimit+5; i++ {
		runs = append(runs, Run{
			Group:  taskGroupRecent,
			TaskID: fmt.Sprintf("task-%02d", i),
			RunID:  fmt.Sprintf("run-%02d", i),
			Status: "merged",
			Last:   fmt.Sprintf("2026-07-10T00:%02d:00Z", i),
		})
	}

	list.SetData(runs, nil)
	items := list.Items()
	if len(items) != defaultRecentSectionLimit {
		t.Fatalf("expected Recent section cap %d, got %d", defaultRecentSectionLimit, len(items))
	}
	if items[0].Run.RunID != "run-19" || items[len(items)-1].Run.RunID != "run-05" {
		t.Fatalf("expected most recent capped window run-19..run-05, got first=%s last=%s", items[0].Run.RunID, items[len(items)-1].Run.RunID)
	}
	counts := list.Counts(runs, nil)
	if counts[taskSectionRecent] != defaultRecentSectionLimit+5 {
		t.Fatalf("expected Recent count to report full matching total, got %#v", counts)
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

func TestTaskListActiveSectionCollapseKeepsSelectionVisible(t *testing.T) {
	list := NewTaskList()
	runs := []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1"}}
	list.SetData(runs, nil)
	if got := len(list.Items()); got != 1 {
		t.Fatalf("expected running row before collapse, got %d", got)
	}

	if collapsed := list.ToggleActiveSectionCollapse(); !collapsed {
		t.Fatalf("expected active section to collapse")
	}
	list.SetData(runs, nil)
	if !list.Collapsed(taskSectionRunning) {
		t.Fatalf("expected Running section collapsed")
	}
	if got := len(list.Items()); got != 0 {
		t.Fatalf("expected collapsed active section to hide rows, got %d", got)
	}
	if list.SelectedIndex() != 0 {
		t.Fatalf("expected collapsed section to keep selection clamped at 0, got %d", list.SelectedIndex())
	}

	if collapsed := list.ToggleActiveSectionCollapse(); collapsed {
		t.Fatalf("expected active section to expand")
	}
	list.SetData(runs, nil)
	if got := len(list.Items()); got != 1 {
		t.Fatalf("expected expanded section to restore row, got %d", got)
	}
}

func TestTaskListSpaceKeyTogglesActiveSectionCollapse(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1"}}
	m.tasks = nil
	m.buildItems()

	updated, _ := m.handleKey(keyPress(" "))
	m = updated.(model)
	if !m.taskList.Collapsed(taskSectionRunning) {
		t.Fatalf("expected space to collapse active task section")
	}
	if got := len(m.taskList.Items()); got != 0 {
		t.Fatalf("expected collapsed section to hide rows, got %d", got)
	}

	updated, _ = m.handleKey(keyPress(" "))
	m = updated.(model)
	if m.taskList.Collapsed(taskSectionRunning) {
		t.Fatalf("expected second space to expand active task section")
	}
	if got := len(m.taskList.Items()); got != 1 {
		t.Fatalf("expected expanded section to restore row, got %d", got)
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

func TestTaskListSelectItemByKey(t *testing.T) {
	list := NewTaskList()
	list.MoveSection(4) // All
	list.SetData([]Run{
		{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a"},
		{Group: taskGroupRecent, TaskID: "task-b", RunID: "run-b"},
	}, nil)

	if !list.SelectItemByKey("run:run-b") {
		t.Fatalf("expected run-b key to be selectable")
	}
	if got := list.SelectedItemKey(); got != "run:run-b" {
		t.Fatalf("expected selected key run:run-b, got %q", got)
	}
	if list.SelectItemByKey("run:missing") {
		t.Fatalf("expected missing key selection to fail")
	}
	if got := list.SelectedItemKey(); got != "run:run-b" {
		t.Fatalf("expected missing key lookup to preserve current selection, got %q", got)
	}
}

func TestTaskListCustomSectionsUseFieldFilters(t *testing.T) {
	list := NewTaskListWithSections([]TaskSection{
		{Name: "P0 Failed", Filter: "priority:p0 state:failed"},
		{Name: "Features", Filter: "type:feature -status:failed"},
		{Name: "Done", Filter: "state:done"},
	})
	runs := []Run{{Group: taskGroupRecent, TaskID: "run-task", RunID: "run-1", Priority: "P0", Status: "failed"}}
	tasks := []Task{
		{TaskID: "task-feature", TaskType: "feature", Priority: "P1", Status: "backlog"},
		{TaskID: "task-bug", TaskType: "bug", Priority: "P0", Status: "backlog"},
		{TaskID: "task-closed", TaskType: "task", Priority: "P2", Status: "closed"},
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
	list.MoveSection(1)
	list.SetData(runs, tasks)
	if items := list.Items(); len(items) != 1 || items[0].Task.TaskID != "task-closed" {
		t.Fatalf("expected custom done section to match closed task, got %#v", items)
	}
}

func TestTaskListFiltersAttentionAndIgnoresUnknownFields(t *testing.T) {
	list := NewTaskListWithSections([]TaskSection{
		{Name: "Attention", Filter: "attention:true unknown:ignored"},
		{Name: "No Attention", Filter: "attention:false"},
	})
	runs := []Run{
		{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a", Attention: "ci_failed"},
		{Group: taskGroupRunning, TaskID: "task-b", RunID: "run-b"},
	}

	list.SetData(runs, nil)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-a" {
		t.Fatalf("expected attention:true to match only attention run and ignore unknown field, got %#v", items)
	}
	list.MoveSection(1)
	list.SetData(runs, nil)
	if items := list.Items(); len(items) != 1 || items[0].Run.RunID != "run-b" {
		t.Fatalf("expected attention:false to match only run without attention, got %#v", items)
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
