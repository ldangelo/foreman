package main

import (
	"strings"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// Valid task types matching the TypeScript board.ts implementation
var validTaskTypes = []string{"task", "bug", "feature", "epic", "chore", "docs", "question"}

// Valid priorities with P0=critical, P1=high, P2=medium, P3=low, P4=backlog
var validPriorities = []string{"P0", "P1", "P2", "P3", "P4"}

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
	typeIndex        int    // selected index in validTaskTypes
	typeOpen         bool   // dropdown open state for type
	priorityIndex    int    // selected index in validPriorities
	priorityOpen     bool   // dropdown open state for priority
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

	// Find the default type index (default: "task" at index 0)
	typeIndex := 0
	for i, t := range validTaskTypes {
		if t == draft.Type {
			typeIndex = i
			break
		}
	}

	// Find the default priority index (default: "P2" at index 2)
	priorityIndex := 2
	for i, p := range validPriorities {
		if p == draft.Priority {
			priorityIndex = i
			break
		}
	}

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
		typeIndex:        typeIndex,
		priorityIndex:   priorityIndex,
		status:           draft.Status,
		currentProjectID: currentProjectID,
	}
	// Initialize focus to title field
	form.focus = createFormTitle
	_ = form.title.Focus()
	return form
}

func newTaskQuickAddForm(projects []Project, currentProjectID string) taskCreateForm {
	form := newTaskCreateForm(projects, currentProjectID)
	form.quick = true
	return form
}

func (f *taskCreateForm) focusField(delta int) tea.Cmd {
	next := f.focus + delta
	if next < 0 {
		next = createFormFieldCount - 1
	}
	if next >= createFormFieldCount {
		next = 0
	}
	// Only close dropdowns that are currently open
	// Don't reset dropdowns that were just opened in the same Update cycle
	prevFocus := f.focus
	f.focus = next

	// Close project dropdown when leaving that field
	if prevFocus == createFormProject {
		f.projectOpen = false
	}
	// Close type dropdown when leaving that field
	if prevFocus == createFormType {
		f.typeOpen = false
	}
	// Close priority dropdown when leaving that field
	if prevFocus == createFormPriority {
		f.priorityOpen = false
	}

	f.title.Blur()
	f.description.Blur()
	switch f.focus {
	case createFormTitle:
		return f.title.Focus()
	case createFormDescription:
		return f.description.Focus()
	case createFormProject:
		return nil // not a textinput; handled via Enter in Update
	case createFormType:
		return nil // dropdown; handled via Enter in Update
	case createFormPriority:
		return nil // dropdown; handled via Enter in Update
	}
	return nil
}

// dropdownNav handles navigation for dropdown fields (project, type, priority)
// Returns focus delta: +1 for forward, -1 for backward, 0 to stay in field
func (f *taskCreateForm) dropdownNav(msg tea.KeyPressMsg, optionsLen int, currentIndex *int, open *bool) int {
	switch msg.String() {
	case "tab":
		// Tab always skips to next field; close any open dropdowns first
		if *open {
			*open = false
		}
		// Also close other dropdowns that might be stuck open
		if f.typeOpen {
			f.typeOpen = false
		}
		if f.priorityOpen {
			f.priorityOpen = false
		}
		return 1
	case "shift+tab":
		// Shift+Tab moves to previous field; close any open dropdowns first
		if *open {
			*open = false
		}
		if f.typeOpen {
			f.typeOpen = false
		}
		if f.priorityOpen {
			f.priorityOpen = false
		}
		// Always move backward for Shift+Tab
		return -1
	case "down":
		if *open {
			*currentIndex++
			if *currentIndex >= optionsLen {
				*currentIndex = 0
			}
			return 0 // stay in dropdown
		}
		// When closed, do nothing (let other handlers move focus)
		return 0
	case "up":
		if *open {
			*currentIndex--
			if *currentIndex < 0 {
				*currentIndex = optionsLen - 1
			}
			return 0 // stay in dropdown
		}
		// When closed, do nothing (let other handlers move focus)
		return 0
	case "enter":
		if *open {
			*open = false
			return 1 // select and move to next field
		}
		// First Enter opens the dropdown
		*open = true
		return 0
	case "esc":
		if *open {
			*open = false
			return 0
		}
	default:
		// Any other key when dropdown is closed: skip to next field
		if !*open {
			*open = false
			return 1
		}
	}
	return 0
}

func (f *taskCreateForm) Update(msg tea.KeyPressMsg) tea.Cmd {
	if f.quick {
		var cmd tea.Cmd
		f.title, cmd = f.title.Update(msg)
		return cmd
	}

	// Dropdown navigation for project field
	if f.focus == createFormProject {
		if delta := f.dropdownNav(msg, len(f.projects), &f.projectIndex, &f.projectOpen); delta != 0 {
			f.focusField(delta)
		}
		return nil
	}

	// Dropdown navigation for type field
	if f.focus == createFormType {
		if delta := f.dropdownNav(msg, len(validTaskTypes), &f.typeIndex, &f.typeOpen); delta != 0 {
			f.focusField(delta)
		}
		return nil
	}

	// Dropdown navigation for priority field
	if f.focus == createFormPriority {
		if delta := f.dropdownNav(msg, len(validPriorities), &f.priorityIndex, &f.priorityOpen); delta != 0 {
			f.focusField(delta)
		}
		return nil
	}

	switch msg.String() {
	case "tab":
		return f.focusField(1)
	case "shift+tab":
		return f.focusField(-1)
	case "enter":
		if f.focus == createFormProject {
			f.projectOpen = true
			return nil
		}
		if f.focus == createFormType {
			f.typeOpen = true
			return nil
		}
		if f.focus == createFormPriority {
			f.priorityOpen = true
			return nil
		}
		if f.focus != createFormDescription {
			return f.focusField(1)
		}
	}

	var cmd tea.Cmd
	switch f.focus {
	case createFormTitle:
		f.title, cmd = f.title.Update(msg)
	case createFormDescription:
		f.description, cmd = f.description.Update(msg)
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
		Type:        validTaskTypes[f.typeIndex],
		Priority:    validPriorities[f.priorityIndex],
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
	if f.quick {
		f.title.SetWidth(inputW)
		return
	}
	dropdownRows := 0
	switch {
	case f.projectOpen && len(f.projects) > 0:
		dropdownRows = len(f.projects) + 1
	case f.typeOpen:
		dropdownRows = len(validTaskTypes) + 1
	case f.priorityOpen:
		dropdownRows = len(validPriorities) + 1
	}
	descH := h - 13 - dropdownRows
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

	// Build type dropdown display
	typeLabel := label(createFormType, "type")
	typeValue := dimStyle.Render(validTaskTypes[f.typeIndex])
	if f.focus == createFormType {
		typeValue = cyanStyle.Render(validTaskTypes[f.typeIndex])
	}
	typeIndicator := " ▾"
	if f.typeOpen {
		typeIndicator = " ▴"
	}
	typeField := typeLabel + " " + typeValue + dimStyle.Render(typeIndicator)

	// Build type dropdown options when open
	var typeDropdownLines []string
	if f.typeOpen {
		for i, t := range validTaskTypes {
			prefix := "  "
			marker := "  "
			if i == f.typeIndex {
				prefix = "› "
				marker = "▶"
			}
			typeDropdownLines = append(typeDropdownLines, dimStyle.Render("   "+prefix+marker+" "+t))
		}
		typeDropdownLines = append(typeDropdownLines, dimStyle.Render("  ↑↓ navigate · enter select"))
	}

	// Build priority dropdown display
	priorityLabel := label(createFormPriority, "priority")
	priorityValue := dimStyle.Render(validPriorities[f.priorityIndex])
	if f.focus == createFormPriority {
		priorityValue = cyanStyle.Render(validPriorities[f.priorityIndex])
	}
	priorityIndicator := " ▾"
	if f.priorityOpen {
		priorityIndicator = " ▴"
	}
	priorityField := priorityLabel + " " + priorityValue + dimStyle.Render(priorityIndicator)

	// Build priority dropdown options when open
	var priorityDropdownLines []string
	if f.priorityOpen {
		for i, p := range validPriorities {
			prefix := "  "
			marker := "  "
			if i == f.priorityIndex {
				prefix = "› "
				marker = "▶"
			}
			priorityDropdownLines = append(priorityDropdownLines, dimStyle.Render("   "+prefix+marker+" "+p))
		}
		priorityDropdownLines = append(priorityDropdownLines, dimStyle.Render("  ↑↓ navigate · enter select"))
	}

	lines := []string{
		whiteStyle.Render("Create new task") + dimStyle.Render("  "+f.id),
		dimStyle.Render("tab/shift+tab fields · enter next field · ↑↓ navigate ▾ open · ctrl+s create · esc cancel"),
		"",
		label(createFormTitle, "title"),
		f.title.View(),
		label(createFormDescription, "description"),
		f.description.View(),
		projectField,
	}
	lines = append(lines, dropdownLines...)
	lines = append(lines,
		typeField,
	)
	lines = append(lines, typeDropdownLines...)
	lines = append(lines,
		priorityField,
	)
	lines = append(lines, priorityDropdownLines...)
	return strings.Join(lines, "\n")
}
