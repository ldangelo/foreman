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
	createFormProject
	createFormType
	createFormPriority
	createFormFieldCount
)

type taskCreateForm struct {
	id               string
	quick            bool
	focus            int
	title            textinput.Model
	description      textarea.Model
	projectIndex     int
	projectOpen      bool
	projects         []Project
	taskType         textinput.Model
	priority         textinput.Model
	status           string // initial status from draft
	currentProjectID string // project to assign when none explicitly selected
}

func newTaskCreateForm(projects []Project, currentProjectID string) taskCreateForm {
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

	// Default to current project if known
	projectIndex := 0
	if currentProjectID != "" {
		for i, p := range projects {
			if p.ProjectID == currentProjectID {
				projectIndex = i
				break
			}
		}
	}

	form := taskCreateForm{
		id:               draft.ID,
		focus:            createFormTitle,
		title:            title,
		description:      description,
		projects:         projects,
		projectIndex:     projectIndex,
		taskType:         taskType,
		priority:         priority,
		status:           draft.Status,
		currentProjectID: currentProjectID,
	}
	_ = form.focusField(createFormTitle)
	return form
}

func newTaskQuickAddForm(projects []Project, currentProjectID string) taskCreateForm {
	form := newTaskCreateForm(projects, currentProjectID)
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
	f.projectOpen = false
	f.title.Blur()
	f.description.Blur()
	f.taskType.Blur()
	f.priority.Blur()
	switch f.focus {
	case createFormTitle:
		return f.title.Focus()
	case createFormDescription:
		return f.description.Focus()
	case createFormProject:
		return nil // not a textinput; handled via Enter in Update
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

	// Project dropdown navigation: only active when project field is focused
	if f.focus == createFormProject {
		switch msg.String() {
		case "tab":
			// Tab always skips the project dropdown (it's optional/display-only)
			f.focusField(f.focus + 1)
			return nil
		case "down":
			if f.projectOpen {
				f.projectIndex++
				if f.projectIndex >= len(f.projects) {
					f.projectIndex = 0
				}
				return nil
			}
			f.focusField(f.focus + 1)
			return nil
		case "up":
			if f.projectOpen {
				f.projectIndex--
				if f.projectIndex < 0 {
					f.projectIndex = len(f.projects) - 1
				}
				return nil
			}
			f.focusField(f.focus - 1)
			return nil
		case "enter":
			if f.projectOpen {
				f.projectOpen = false
				return f.focusField(f.focus + 1)
			}
			// First Enter on project field opens the dropdown
			f.projectOpen = true
			return nil
		case "esc":
			if f.projectOpen {
				f.projectOpen = false
				return nil
			}
		default:
			// Character key on project dropdown: skip to next field and forward the key
			if !f.projectOpen && msg.String() != "shift+tab" {
				f.focusField(f.focus + 1)
				// Forward the key to the newly focused field so it processes immediately
				var cmd tea.Cmd
				switch f.focus {
				case createFormType:
					f.taskType, cmd = f.taskType.Update(msg)
				case createFormPriority:
					f.priority, cmd = f.priority.Update(msg)
				}
				return cmd
			}
		}
		return nil
	}

	switch msg.String() {
	case "tab":
		return f.focusField(f.focus + 1)
	case "shift+tab":
		return f.focusField(f.focus - 1)
	case "enter":
		if f.focus == createFormProject {
			// Open dropdown on project field
			f.projectOpen = true
			return nil
		}
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
	var projectID string
	if len(f.projects) > 0 && f.projectIndex >= 0 && f.projectIndex < len(f.projects) {
		projectID = f.projects[f.projectIndex].ProjectID
	}
	// Fall back to currentProjectID when the dropdown is at index 0 (not been
	// navigated) and the listed project doesn't match — i.e. the current project
	// is not in the project list.
	if projectID == "" || (f.projectIndex == 0 && projectID != f.currentProjectID && f.currentProjectID != "") {
		projectID = f.currentProjectID
	}
	return taskFromCreateDraft(taskDraft{
		ID:          f.id,
		Title:       strings.TrimSpace(f.title.Value()),
		Description: strings.TrimSpace(f.description.Value()),
		Type:        strings.TrimSpace(f.taskType.Value()),
		Priority:    strings.TrimSpace(f.priority.Value()),
		Status:      f.status,
		ProjectID:   projectID,
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
	descH := h - 11 - len(f.projects) - 1 // account for project dropdown options
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

	selectedProjectName := ""
	if len(f.projects) > 0 && f.projectIndex >= 0 && f.projectIndex < len(f.projects) {
		selectedProjectName = f.projects[f.projectIndex].Name
	}
	if selectedProjectName == "" {
		selectedProjectName = "(no project)"
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

	// Build project dropdown display
	projectLabel := label(createFormProject, "project")
	projectValue := dimStyle.Render(selectedProjectName)
	if f.focus == createFormProject {
		projectValue = cyanStyle.Render(selectedProjectName)
	}
	indicator := " ▾"
	if f.projectOpen {
		indicator = " ▴"
	}
	projectField := projectLabel + " " + projectValue + dimStyle.Render(indicator)

	// Build dropdown options when open
	var dropdownLines []string
	if f.projectOpen && len(f.projects) > 0 {
		for i, p := range f.projects {
			prefix := "  "
			marker := "  "
			if i == f.projectIndex {
				prefix = "› "
				marker = "▶"
			}
			line := dimStyle.Render(prefix+marker) + dimStyle.Render(" "+p.Name)
			dropdownLines = append(dropdownLines, dimStyle.Render("   "+line))
		}
		dropdownLines = append(dropdownLines, dimStyle.Render("  ↑↓ navigate · enter select"))
	}

	lines := []string{
		whiteStyle.Render("Create new task") + dimStyle.Render("  "+f.id),
		dimStyle.Render("tab/shift+tab fields · enter next field · ↑↓ project ▾ open · ctrl+s create · esc cancel"),
		"",
		label(createFormTitle, "title"),
		f.title.View(),
		label(createFormDescription, "description"),
		f.description.View(),
		projectField,
	}
	lines = append(lines, dropdownLines...)
	lines = append(lines,
		label(createFormType, "type"),
		f.taskType.View(),
		label(createFormPriority, "priority"),
		f.priority.View(),
	)
	return strings.Join(lines, "\n")
}
