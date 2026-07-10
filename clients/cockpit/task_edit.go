package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"

	tea "github.com/charmbracelet/bubbletea"
)

type taskDraft struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Type        string `json:"type"`
	Priority    string `json:"priority"`
	Status      string `json:"status"`
}

func draftFromTask(task Task) taskDraft {
	return taskDraft{
		ID:          task.TaskID,
		Title:       task.Title,
		Description: task.Description,
		Type:        task.TaskType,
		Priority:    task.Priority,
		Status:      task.Status,
	}
}

func taskFromDraft(task Task, draft taskDraft) (Task, error) {
	if draft.ID == "" {
		return task, fmt.Errorf("task JSON must include id")
	}
	if draft.ID != task.TaskID {
		return task, fmt.Errorf("task id changed from %s to %s", task.TaskID, draft.ID)
	}
	if draft.Title == "" {
		return task, fmt.Errorf("task JSON must include title")
	}
	task.Title = draft.Title
	task.Description = draft.Description
	task.TaskType = draft.Type
	task.Priority = draft.Priority
	task.Status = draft.Status
	return task, nil
}

func newTaskID() string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("task-%d", os.Getpid())
	}
	return "task-" + hex.EncodeToString(b[:])
}

func draftFromNewTask() taskDraft {
	return taskDraft{
		ID:       newTaskID(),
		Type:     "task",
		Priority: "2",
		Status:   "backlog",
	}
}

func taskFromCreateDraft(draft taskDraft) (Task, error) {
	if draft.ID == "" {
		return Task{}, fmt.Errorf("task JSON must include id")
	}
	if draft.Title == "" {
		return Task{}, fmt.Errorf("task JSON must include title")
	}
	if draft.Type == "" {
		draft.Type = "task"
	}
	if draft.Priority == "" {
		draft.Priority = "2"
	}
	if draft.Status == "" {
		draft.Status = "backlog"
	}
	return Task{
		TaskID:      draft.ID,
		Title:       draft.Title,
		Description: draft.Description,
		TaskType:    draft.Type,
		Priority:    draft.Priority,
		Status:      draft.Status,
		Summary:     draft.Title,
	}, nil
}

func approveTask(c Client, task Task) tea.Cmd {
	return func() tea.Msg {
		return taskActionDoneMsg{action: "approved", taskID: task.TaskID, err: c.ApproveTask(task)}
	}
}

func editTaskInNvim(e EditorConfig, c Client, task Task) tea.Cmd {
	tmp, err := os.CreateTemp("", "foreman-task-*.json")
	if err != nil {
		return func() tea.Msg { return taskActionDoneMsg{action: "edit", taskID: task.TaskID, err: err} }
	}
	path := tmp.Name()
	data, err := json.MarshalIndent(draftFromTask(task), "", "  ")
	if err == nil {
		_, err = tmp.Write(append(data, '\n'))
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(path)
		return func() tea.Msg { return taskActionDoneMsg{action: "edit", taskID: task.TaskID, err: err} }
	}

	cmd := exec.Command(e.Cmd, path)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		defer os.Remove(path)
		if err != nil {
			return taskActionDoneMsg{action: "edit", taskID: task.TaskID, err: err}
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return taskActionDoneMsg{action: "edit", taskID: task.TaskID, err: err}
		}
		var draft taskDraft
		if err := json.Unmarshal(body, &draft); err != nil {
			return taskActionDoneMsg{action: "edit", taskID: task.TaskID, err: fmt.Errorf("parse edited task JSON: %w", err)}
		}
		updated, err := taskFromDraft(task, draft)
		if err != nil {
			return taskActionDoneMsg{action: "edit", taskID: task.TaskID, err: err}
		}
		return taskActionDoneMsg{action: "edited", taskID: task.TaskID, err: c.UpdateTask(updated)}
	})
}

func createTaskInNvim(e EditorConfig, c Client) tea.Cmd {
	tmp, err := os.CreateTemp("", "foreman-task-new-*.json")
	if err != nil {
		return func() tea.Msg { return taskActionDoneMsg{action: "create", err: err} }
	}
	path := tmp.Name()
	data, err := json.MarshalIndent(draftFromNewTask(), "", "  ")
	if err == nil {
		_, err = tmp.Write(append(data, '\n'))
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(path)
		return func() tea.Msg { return taskActionDoneMsg{action: "create", err: err} }
	}

	cmd := exec.Command(e.Cmd, path)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		defer os.Remove(path)
		if err != nil {
			return taskActionDoneMsg{action: "create", err: err}
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return taskActionDoneMsg{action: "create", err: err}
		}
		var draft taskDraft
		if err := json.Unmarshal(body, &draft); err != nil {
			return taskActionDoneMsg{action: "create", err: fmt.Errorf("parse new task JSON: %w", err)}
		}
		task, err := taskFromCreateDraft(draft)
		if err != nil {
			return taskActionDoneMsg{action: "create", taskID: draft.ID, err: err}
		}
		return taskActionDoneMsg{action: "created", taskID: task.TaskID, err: c.CreateTask(task)}
	})
}
