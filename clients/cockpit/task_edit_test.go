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

func TestTaskFromDraftBuildsUpdatePayloadWithoutChangingIdentity(t *testing.T) {
	existing := Task{
		TaskID:      "task-1",
		Title:       "Old title",
		Description: "old body",
		TaskType:    "bug",
		Priority:    "P0",
		Status:      "backlog",
	}

	task, err := taskFromDraft(existing, taskDraft{
		ID:          "task-1",
		Title:       "New title",
		Description: "new body",
		Type:        "feature",
		Priority:    "2",
		Status:      "ready",
	})
	if err != nil {
		t.Fatalf("taskFromDraft: %v", err)
	}
	if task.TaskID != "task-1" || task.Title != "New title" || task.Description != "new body" || task.TaskType != "feature" || task.Priority != "P2" || task.Status != "ready" {
		t.Fatalf("unexpected updated task: %#v", task)
	}
}

func TestTaskFromDraftRejectsIdentityChangesAndMissingTitle(t *testing.T) {
	existing := Task{TaskID: "task-1", Title: "Old title"}
	if _, err := taskFromDraft(existing, taskDraft{ID: "task-2", Title: "New title"}); err == nil {
		t.Fatal("expected changed task id to be rejected")
	}
	if _, err := taskFromDraft(existing, taskDraft{ID: "task-1"}); err == nil {
		t.Fatal("expected missing title to be rejected")
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
