package main

import (
	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	fvpkg "github.com/robinovitch61/viewport/filterableviewport"
	vpkg "github.com/robinovitch61/viewport/viewport"
	"github.com/robinovitch61/viewport/viewport/item"
	"sort"
	"strings"
)

const (
	taskGroupRunning = "RUNNING"
	taskGroupReady   = "READY"
	taskGroupRecent  = "RECENT"

	taskSectionRunning = "Running"
	taskSectionReady   = "Ready"
	taskSectionFailed  = "Failed"
	taskSectionRecent  = "Recent"
	taskSectionAll     = "All"
)

const defaultRecentSectionLimit = 15

type TaskSection struct {
	Name   string `yaml:"name"`
	Filter string `yaml:"filter"`
}

func defaultTaskListSections() []TaskSection {
	return []TaskSection{
		{Name: taskSectionRunning, Filter: "state:running"},
		{Name: taskSectionReady, Filter: "state:ready"},
		{Name: taskSectionFailed, Filter: "state:failed"},
		{Name: taskSectionRecent, Filter: "state:recent"},
		{Name: taskSectionAll, Filter: "all"},
	}
}

func normalizeTaskSections(sections []TaskSection) []TaskSection {
	out := make([]TaskSection, 0, len(sections))
	for _, section := range sections {
		name := strings.TrimSpace(section.Name)
		filter := strings.TrimSpace(section.Filter)
		if name == "" || filter == "" {
			continue
		}
		out = append(out, TaskSection{Name: name, Filter: filter})
	}
	if len(out) == 0 {
		return defaultTaskListSections()
	}
	return out
}

const taskListFilterModeName fvpkg.FilterModeName = "task"

func taskListFilterMode() fvpkg.FilterMode {
	return fvpkg.FilterMode{
		Name:  taskListFilterModeName,
		Key:   key.NewBinding(key.WithKeys("/"), key.WithHelp("/", "search")),
		Label: "[task]",
		GetMatchFunc: func(filterText string) (fvpkg.MatchFunc, error) {
			terms := normalizedTaskFilterTerms(filterText)
			return func(content string) []item.ByteRange {
				if len(terms) == 0 {
					return nil
				}
				lower := strings.ToLower(content)
				for _, term := range terms {
					if !strings.Contains(lower, term) {
						return nil
					}
				}
				return []item.ByteRange{{Start: 0, End: len(content)}}
			}, nil
		},
	}
}

// Item is one selectable row in the left column.
type Item struct {
	Group  string
	IsTask bool
	Run    Run
	Task   Task
}

// TaskList owns the left-pane sectioning, filtering, scope, and selected item
// cursor. The root model supplies fresh projections and reacts to selection
// changes. Current scope filters by projectID when it is known; global scope
// shows every projected task/run.
type TaskList struct {
	items     []Item
	selected  int
	section   int
	sections  []TaskSection
	collapsed map[string]bool
	scope     string // current | global
	projectID string
	search    string
	searching bool
	viewport  *vpkg.Model[taskListObject]
	filter    *fvpkg.Model[taskListObject]
}

func NewTaskList() TaskList {
	return NewTaskListWithSections(nil)
}

func NewTaskListWithSections(sections []TaskSection) TaskList {
	return TaskList{
		scope:     "current",
		sections:  normalizeTaskSections(sections),
		collapsed: map[string]bool{},
	}
}

type taskListObject struct {
	lines []string
}

func (o taskListObject) GetItem() item.Item {
	items := make([]item.SingleItem, 0, len(o.lines))
	for _, line := range o.lines {
		items = append(items, item.NewItem(line))
	}
	if len(items) == 1 {
		return items[0]
	}
	return item.NewMultiLineItem(items...)
}

func (l *TaskList) SetViewportRows(headers []string, rows []string, selectedRow, width, height int) {
	if height < 1 {
		height = 1
	}
	if width < 1 {
		width = 1
	}
	l.ensureViewport(width, height)
	l.filter.SetWidth(width)
	l.filter.SetHeight(height)
	l.filter.SetWrapText(true)
	l.filter.SetHeader(headers)

	objects := make([]taskListObject, len(rows))
	for i, row := range rows {
		objects[i] = taskListObject{lines: strings.Split(row, "\n")}
	}
	l.filter.SetObjects(objects)
	if len(objects) == 0 {
		return
	}
	selectedRow = max(0, min(selectedRow, len(objects)-1))
	l.filter.SetSelectedItemIdx(selectedRow)
	l.viewport.EnsureItemInView(selectedRow, 0, width, max(0, height/2), 0)
}

func (l TaskList) View() string {
	if l.filter == nil {
		return ""
	}
	return l.filter.View()
}

func (l *TaskList) ensureViewport(width, height int) {
	if l.viewport != nil {
		return
	}
	styles := vpkg.DefaultStyles()
	styles.SelectedItemStyle = lipgloss.NewStyle().Background(cSelBg)
	l.viewport = vpkg.New[taskListObject](
		width,
		height,
		vpkg.WithWrapText[taskListObject](true),
		vpkg.WithSelectionEnabled[taskListObject](true),
		vpkg.WithFooterEnabled[taskListObject](false),
		vpkg.WithProgressBarEnabled[taskListObject](false),
		vpkg.WithSelectionStyleOverridesItemStyle[taskListObject](false),
		vpkg.WithStyles[taskListObject](styles),
	)
	l.filter = fvpkg.New[taskListObject](
		l.viewport,
		fvpkg.WithCanToggleMatchingItemsOnly[taskListObject](false),
		fvpkg.WithFilterModes[taskListObject]([]fvpkg.FilterMode{taskListFilterMode()}),
		fvpkg.WithFilterLinePosition[taskListObject](fvpkg.FilterLineBottom),
		fvpkg.WithItemDescriptor[taskListObject]("tasks"),
	)
	if l.search != "" {
		l.filter.SetFilter(l.search, taskListFilterModeName)
	}
}

func (l *TaskList) SetProjectID(projectID string) {
	l.projectID = strings.TrimSpace(projectID)
}

func (l *TaskList) SetData(runs []Run, tasks []Task) {
	selectedKey := ""
	if it, ok := l.SelectedItem(); ok {
		selectedKey = itemKey(it)
	}

	all := buildTaskListItems(runs, tasks)
	section := l.ActiveSection()
	if l.collapsed[section.Name] {
		l.items = nil
		l.selected = 0
		return
	}
	capRecent := sectionUsesRecentCap(section)
	items := make([]Item, 0, len(all))
	for _, it := range all {
		if !l.matchesScope(it) {
			continue
		}
		if !matchesTaskFilter(it, section.Filter) {
			continue
		}
		if !matchesTaskFilter(it, l.search) {
			continue
		}
		if capRecent && len(items) >= defaultRecentSectionLimit {
			break
		}
		items = append(items, it)
	}

	l.items = items
	if selectedKey != "" {
		for i, it := range l.items {
			if itemKey(it) == selectedKey {
				l.selected = i
				return
			}
		}
	}
	l.selected = 0
	l.keepSelectedVisible()
}

func (l *TaskList) Move(delta int) bool {
	if len(l.items) == 0 {
		return false
	}
	before := l.selected
	l.selected += delta
	l.keepSelectedVisible()
	return l.selected != before
}

func (l *TaskList) MoveSection(delta int) string {
	before := l.section
	sections := l.Sections()
	l.section = (l.section + delta + len(sections)) % len(sections)
	if l.section != before {
		l.selected = 0
	}
	return l.ActiveSection().Name
}

func (l *TaskList) ToggleActiveSectionCollapse() bool {
	section := l.ActiveSection().Name
	l.collapsed[section] = !l.collapsed[section]
	l.selected = 0
	return l.collapsed[section]
}

func (l *TaskList) ToggleScope() string {
	if l.scope == "current" {
		l.scope = "global"
	} else {
		l.scope = "current"
	}
	return l.scope
}

func (l *TaskList) StartSearch(msg tea.KeyPressMsg) tea.Cmd {
	l.ensureViewport(1, 1)
	var cmd tea.Cmd
	l.filter, cmd = l.filter.Update(msg)
	l.syncSearchFromFilter()
	return cmd
}

func (l *TaskList) HandleSearchKey(msg tea.KeyPressMsg) (bool, tea.Cmd) {
	beforeSearch := l.search
	beforeSearching := l.searching
	l.ensureViewport(1, 1)
	var cmd tea.Cmd
	l.filter, cmd = l.filter.Update(msg)
	l.syncSearchFromFilter()
	return l.search != beforeSearch || l.searching != beforeSearching, cmd
}

func (l *TaskList) syncSearchFromFilter() {
	if l.filter == nil {
		l.searching = false
		return
	}
	l.search = l.filter.GetFilterText()
	l.searching = l.filter.FilterFocused()
}

func (l TaskList) Items() []Item      { return l.items }
func (l TaskList) SelectedIndex() int { return l.selected }
func (l TaskList) ActiveSection() TaskSection {
	sections := l.Sections()
	if l.section < 0 || l.section >= len(sections) {
		return sections[0]
	}
	return sections[l.section]
}
func (l TaskList) ActiveSectionIndex() int { return l.section }
func (l TaskList) Sections() []TaskSection {
	if len(l.sections) == 0 {
		return defaultTaskListSections()
	}
	return l.sections
}
func (l TaskList) SelectedItem() (Item, bool) {
	if l.selected < 0 || l.selected >= len(l.items) {
		return Item{}, false
	}
	return l.items[l.selected], true
}

func (l TaskList) SelectedItemKey() string {
	if it, ok := l.SelectedItem(); ok {
		return itemKey(it)
	}
	return ""
}

func (l *TaskList) SelectItemByKey(key string) bool {
	if key == "" {
		return false
	}
	for i, it := range l.items {
		if itemKey(it) == key {
			l.selected = i
			return true
		}
	}
	return false
}
func (l TaskList) Collapsed(section string) bool { return l.collapsed[section] }
func (l TaskList) Scope() string                 { return l.scope }
func (l TaskList) Search() string                { return l.search }
func (l TaskList) Searching() bool               { return l.searching }

func (l TaskList) Counts(runs []Run, tasks []Task) map[string]int {
	count := map[string]int{}
	all := buildTaskListItems(runs, tasks)
	for _, section := range l.Sections() {
		for _, it := range all {
			if !l.matchesScope(it) {
				continue
			}
			if matchesTaskFilter(it, section.Filter) {
				count[section.Name]++
			}
		}
	}
	return count
}

func sectionUsesRecentCap(section TaskSection) bool {
	return strings.EqualFold(strings.TrimSpace(section.Name), taskSectionRecent) &&
		strings.EqualFold(strings.TrimSpace(section.Filter), "state:recent")
}

func (l TaskList) matchesScope(it Item) bool {
	// Non-current scope always passes
	if l.scope != "current" {
		return true
	}
	// Empty projectID means no project filter active → show all
	if l.projectID == "" {
		return true
	}
	// Filter: item must have matching projectID or be unscoped
	itemProjectID := ""
	if it.IsTask {
		itemProjectID = it.Task.ProjectID
	} else {
		itemProjectID = it.Run.ProjectID
	}
	return itemProjectID == "" || itemProjectID == l.projectID
}

func buildTaskListItems(runs []Run, tasks []Task) []Item {
	items := make([]Item, 0, len(runs)+len(tasks))
	taskIDs := make(map[string]bool, len(tasks))
	for _, t := range tasks {
		if t.TaskID != "" {
			taskIDs[t.TaskID] = true
		}
	}
	activeRuns := map[string]bool{}
	recentRuns := make([]Run, 0, len(runs))
	for _, r := range runs {
		switch r.Group {
		case taskGroupRunning:
			activeRuns[r.TaskID] = true
			items = append(items, Item{Group: r.Group, Run: r})
		case taskGroupRecent:
			if !taskIDs[r.TaskID] {
				recentRuns = append(recentRuns, r)
			}
		}
	}
	for _, t := range tasks {
		if activeRuns[t.TaskID] {
			continue
		}
		group := taskGroupReady
		if activeTaskStatus(t.Status) {
			group = taskGroupRunning
		}
		items = append(items, Item{Group: group, IsTask: true, Task: t})
	}
	sort.SliceStable(recentRuns, func(i, j int) bool {
		return recentRuns[i].Last > recentRuns[j].Last
	})
	for _, r := range recentRuns {
		items = append(items, Item{Group: r.Group, Run: r})
	}
	return items
}

func matchesTaskSection(it Item, section string) bool {
	for _, configured := range defaultTaskListSections() {
		if strings.EqualFold(section, configured.Name) {
			return matchesTaskFilter(it, configured.Filter)
		}
	}
	return matchesTaskFilter(it, section)
}

func matchesTaskFilter(it Item, query string) bool {
	tokens := parseTaskFilter(query)
	if len(tokens) == 0 {
		return true
	}
	for _, token := range tokens {
		matched := matchesTaskToken(it, token.field, token.value)
		if token.negated {
			matched = !matched
		}
		if !matched {
			return false
		}
	}
	return true
}

type taskFilterToken struct {
	field   string
	value   string
	negated bool
}

func parseTaskFilter(query string) []taskFilterToken {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(query)))
	tokens := make([]taskFilterToken, 0, len(fields))
	for _, raw := range fields {
		if raw == "" || raw == "all" {
			continue
		}
		negated := false
		for strings.HasPrefix(raw, "-") || strings.HasPrefix(raw, "!") {
			negated = true
			raw = strings.TrimLeft(raw, "-!")
		}
		if raw == "" {
			continue
		}
		field, value := "text", raw
		if strings.Contains(raw, ":") {
			parts := strings.SplitN(raw, ":", 2)
			field, value = parts[0], parts[1]
		}
		if value == "" {
			continue
		}
		tokens = append(tokens, taskFilterToken{field: field, value: value, negated: negated})
	}
	return tokens
}

func matchesTaskToken(it Item, field, value string) bool {
	if value == "" {
		return true
	}
	switch field {
	case "state", "is":
		switch value {
		case "running", "active":
			if it.IsTask {
				return activeTaskStatus(it.Task.Status)
			}
			return it.Run.Group == taskGroupRunning
		case "ready", "open", "backlog":
			return it.IsTask && readyTaskStatus(it.Task.Status) && !isFailedState(it.Task.Status)
		case "failed", "fail", "stuck", "conflict":
			if it.IsTask {
				return isFailedState(it.Task.Status)
			}
			return runNeedsAttention(it.Run)
		case "recent":
			return !it.IsTask && it.Run.Group == taskGroupRecent
		case "done", "closed":
			if it.IsTask {
				return doneTaskStatus(it.Task.Status)
			}
			return it.Run.Group == taskGroupRecent && doneTaskStatus(it.Run.Status) && !runNeedsAttention(it.Run)
		default:
			return strings.Contains(fieldValue(it, "status"), value)
		}
	case "text":
		return strings.Contains(taskSearchText(it), value)
	case "status", "priority", "type", "project", "phase", "verdict", "id", "task", "run", "title", "pr", "messages":
		return strings.Contains(fieldValue(it, field), value)
	case "attention":
		hasAttention := false
		if it.IsTask {
			hasAttention = isFailedState(it.Task.Status)
		} else {
			attention := strings.TrimSpace(it.Run.Attention)
			hasAttention = attention != "" && attention != "-"
		}
		switch value {
		case "true", "yes", "1":
			return hasAttention
		case "false", "no", "0":
			return !hasAttention
		default:
			return strings.Contains(fieldValue(it, field), value)
		}
	default:
		return true
	}
}

func fieldValue(it Item, field string) string {
	if it.IsTask {
		switch field {
		case "status":
			return strings.ToLower(it.Task.Status)
		case "priority":
			return strings.ToLower(normalizePriorityLabel(it.Task.Priority))
		case "type":
			return strings.ToLower(it.Task.TaskType)
		case "project":
			return strings.ToLower(it.Task.ProjectID)
		case "id", "task":
			return strings.ToLower(it.Task.TaskID)
		case "title":
			return strings.ToLower(it.Task.Title)
		default:
			return ""
		}
	}
	switch field {
	case "status":
		return strings.ToLower(it.Run.Status)
	case "priority":
		return strings.ToLower(normalizePriorityLabel(it.Run.Priority))
	case "type":
		return strings.ToLower(it.Run.TaskType)
	case "project":
		return strings.ToLower(it.Run.ProjectID)
	case "phase":
		return strings.ToLower(it.Run.Phase)
	case "verdict":
		return strings.ToLower(it.Run.Verdict)
	case "id", "task":
		return strings.ToLower(it.Run.TaskID)
	case "run":
		return strings.ToLower(it.Run.RunID)
	case "title":
		return strings.ToLower(it.Run.Title)
	case "pr":
		return strings.ToLower(it.Run.PRState)
	case "messages":
		return strings.ToLower(itoa(it.Run.Messages))
	default:
		return ""
	}
}

func isFailedState(state string) bool {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "failed", "fail", "stuck", "conflict", "test-failed":
		return true
	default:
		return false
	}
}

func runNeedsAttention(run Run) bool {
	attention := strings.TrimSpace(run.Attention)
	return isFailedState(run.Status) ||
		strings.EqualFold(run.Verdict, "fail") ||
		(attention != "" && attention != "-")
}

func normalizedTaskFilterTerms(query string) []string {
	tokens := parseTaskFilter(query)
	terms := make([]string, 0, len(tokens))
	for _, token := range tokens {
		if token.value != "" {
			terms = append(terms, token.value)
		}
	}
	return terms
}

func taskSearchText(it Item) string {
	if it.IsTask {
		return strings.ToLower(strings.Join([]string{
			it.Task.TaskID, it.Task.Title, it.Task.Summary, it.Task.Description,
			it.Task.TaskType, it.Task.Priority, it.Task.Status, it.Task.Workflow,
			it.Task.ProjectID, it.Task.Depends,
		}, " "))
	}
	return strings.ToLower(strings.Join([]string{
		it.Run.TaskID, it.Run.RunID, it.Run.Title, it.Run.Summary, it.Run.TaskType,
		it.Run.Priority, it.Run.Status, it.Run.Phase, it.Run.Verdict, it.Run.ProjectID,
		it.Run.Attention, it.Run.PRState, it.Run.Last, runRightMetadata(it.Run),
	}, " "))
}

func (l *TaskList) keepSelectedVisible() {
	if l.selected >= len(l.items) {
		l.selected = len(l.items) - 1
	}
	if l.selected < 0 {
		l.selected = 0
	}
}

func itemKey(it Item) string {
	if it.IsTask {
		return "task:" + it.Task.TaskID
	}
	if it.Run.RunID != "" {
		return "run:" + it.Run.RunID
	}
	return "run-task:" + it.Run.TaskID
}
