package main

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestTaskFromCreateDraftBuildsTaskPayload(t *testing.T) {
	task, err := taskFromCreateDraft(taskDraft{
		ID:          "task-new",
		Title:       "Create cockpit task",
		Description: "body",
		Type:        "feature",
		Priority:    "1",
		Status:      "backlog",
	})
	if err != nil {
		t.Fatalf("taskFromCreateDraft: %v", err)
	}
	if task.TaskID != "task-new" || task.Title != "Create cockpit task" || task.Description != "body" || task.TaskType != "feature" || task.Priority != "P1" || task.Status != "backlog" || task.Summary != "Create cockpit task" {
		t.Fatalf("unexpected task payload: %#v", task)
	}
}

func TestDraftFromNewTaskDefaultsToP2(t *testing.T) {
	draft := draftFromNewTask()
	if draft.Priority != "P2" {
		t.Fatalf("expected new task draft priority P2, got %q", draft.Priority)
	}
}

func TestTaskFromCreateDraftRequiresTitle(t *testing.T) {
	if _, err := taskFromCreateDraft(taskDraft{ID: "task-new"}); err == nil {
		t.Fatal("expected missing title to be rejected")
	}
}

func TestTaskCreateFormTitleSupportsCursorEditAndPaste(t *testing.T) {
	form := newTaskCreateForm()
	form.Update(keyPress("Tsk"))
	form.Update(specialKey(tea.KeyLeft))
	form.Update(specialKey(tea.KeyBackspace))
	form.Update(keyPress("as"))

	task, err := form.Task()
	if err != nil {
		t.Fatalf("Task: %v", err)
	}
	if task.Title != "Task" {
		t.Fatalf("expected editable pasted title, got %q", task.Title)
	}
}
