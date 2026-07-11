package main

import (
	"strings"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

const (
	createFormTitle = iota
	createFormDescription
	createFormType
	createFormPriority
	createFormFieldCount
)

type taskCreateForm struct {
	id          string
	quick       bool
	focus       int
	title       textinput.Model
	description textarea.Model
	taskType    textinput.Model
	priority    textinput.Model
}

func newTaskCreateForm() taskCreateForm {
	draft := draftFromNewTask()
	title := textinput.New()
	title.Prompt = ""
	title.Placeholder = "What should Foreman do?"

	description := textarea.New()
	description.Prompt = ""
	description.Placeholder = "Add context, constraints, and acceptance criteria"
	description.ShowLineNumbers = false
	description.SetHeight(5)

	taskType := textinput.New()
	taskType.Prompt = ""
	taskType.SetValue(draft.Type)

	priority := textinput.New()
	priority.Prompt = ""
	priority.SetValue(draft.Priority)

	form := taskCreateForm{
		id:          draft.ID,
		focus:       createFormTitle,
		title:       title,
		description: description,
		taskType:    taskType,
		priority:    priority,
	}
	_ = form.focusField(createFormTitle)
	return form
}

func newTaskQuickAddForm() taskCreateForm {
	form := newTaskCreateForm()
	form.quick = true
	return form
}

func (f *taskCreateForm) focusField(next int) tea.Cmd {
	if next < 0 {
		next = createFormFieldCount - 1
	}
	if next >= createFormFieldCount {
		next = 0
	}
	f.focus = next
	f.title.Blur()
	f.description.Blur()
	f.taskType.Blur()
	f.priority.Blur()
	switch f.focus {
	case createFormTitle:
		return f.title.Focus()
	case createFormDescription:
		return f.description.Focus()
	case createFormType:
		return f.taskType.Focus()
	case createFormPriority:
		return f.priority.Focus()
	}
	return nil
}

func (f *taskCreateForm) Update(msg tea.KeyPressMsg) tea.Cmd {
	if f.quick {
		var cmd tea.Cmd
		f.title, cmd = f.title.Update(msg)
		return cmd
	}
	switch msg.String() {
	case "tab":
		return f.focusField(f.focus + 1)
	case "shift+tab":
		return f.focusField(f.focus - 1)
	case "enter":
		if f.focus != createFormDescription {
			return f.focusField(f.focus + 1)
		}
	}

	var cmd tea.Cmd
	switch f.focus {
	case createFormTitle:
		f.title, cmd = f.title.Update(msg)
	case createFormDescription:
		f.description, cmd = f.description.Update(msg)
	case createFormType:
		f.taskType, cmd = f.taskType.Update(msg)
	case createFormPriority:
		f.priority, cmd = f.priority.Update(msg)
	}
	return cmd
}

func (f taskCreateForm) Task() (Task, error) {
	return taskFromCreateDraft(taskDraft{
		ID:          f.id,
		Title:       strings.TrimSpace(f.title.Value()),
		Description: strings.TrimSpace(f.description.Value()),
		Type:        strings.TrimSpace(f.taskType.Value()),
		Priority:    strings.TrimSpace(f.priority.Value()),
		Status:      "backlog",
	})
}

func (f *taskCreateForm) SetBounds(w, h int) {
	if w < 20 {
		w = 20
	}
	inputW := w - 14
	if inputW < 8 {
		inputW = 8
	}
	f.title.SetWidth(inputW)
	f.taskType.SetWidth(inputW)
	f.priority.SetWidth(inputW)
	if f.quick {
		f.title.SetWidth(inputW)
		return
	}
	descH := h - 11
	if descH < 3 {
		descH = 3
	}
	if descH > 8 {
		descH = 8
	}
	f.description.SetWidth(inputW)
	f.description.SetHeight(descH)
}

func (f taskCreateForm) View(w, h int) string {
	f.SetBounds(w, h)
	label := func(idx int, name string) string {
		prefix := "  "
		style := dimStyle
		if f.focus == idx {
			prefix = "› "
			style = cyanStyle
		}
		return style.Render(prefix + name)
	}
	if f.quick {
		return strings.Join([]string{
			whiteStyle.Render("Quick add task") + dimStyle.Render("  "+f.id),
			dimStyle.Render("enter create · esc cancel"),
			"",
			label(createFormTitle, "title"),
			f.title.View(),
		}, "\n")
	}
	return strings.Join([]string{
		whiteStyle.Render("Create new task") + dimStyle.Render("  "+f.id),
		dimStyle.Render("tab/shift+tab fields · enter next field · ctrl+s create · esc cancel"),
		"",
		label(createFormTitle, "title"),
		f.title.View(),
		label(createFormDescription, "description"),
		f.description.View(),
		label(createFormType, "type"),
		f.taskType.View(),
		label(createFormPriority, "priority"),
		f.priority.View(),
	}, "\n")
}
