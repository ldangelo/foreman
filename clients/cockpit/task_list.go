package main

import (
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	fvpkg "github.com/robinovitch61/viewport/filterableviewport"
	vpkg "github.com/robinovitch61/viewport/viewport"
	"github.com/robinovitch61/viewport/viewport/item"
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

type TaskSection struct {
	Name   string
	Filter string
}

var taskListSections = []TaskSection{
	{Name: taskSectionRunning, Filter: "state:running"},
	{Name: taskSectionReady, Filter: "state:ready"},
	{Name: taskSectionFailed, Filter: "state:failed"},
	{Name: taskSectionRecent, Filter: "state:recent"},
	{Name: taskSectionAll, Filter: "all"},
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

var taskListGroups = []string{taskGroupRunning, taskGroupReady, taskGroupRecent}

// Item is one selectable row in the left column.
type Item struct {
	Group  string
	IsTask bool
	Run    Run
	Task   Task
}

// TaskList owns the left-pane sectioning, filtering, scope, and selected item
// cursor. The root model supplies fresh projections and reacts to selection
// changes.
type TaskList struct {
	items     []Item
	selected  int
	section   int
	scope     string // current | global
	search    string
	searching bool
	viewport  *vpkg.Model[taskListObject]
	filter    *fvpkg.Model[taskListObject]
}

func NewTaskList() TaskList {
	return TaskList{
		scope: "current",
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

func (l *TaskList) SetData(runs []Run, tasks []Task) {
	selectedKey := ""
	if it, ok := l.SelectedItem(); ok {
		selectedKey = itemKey(it)
	}

	all := buildTaskListItems(runs, tasks)
	section := l.ActiveSection()
	items := make([]Item, 0, len(all))
	for _, it := range all {
		if !matchesTaskSection(it, section.Name) {
			continue
		}
		if !matchesTaskQuery(it, l.search) {
			continue
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

func (l *TaskList) ToggleSelectedGroup() {}

func (l *TaskList) MoveSection(delta int) string {
	before := l.section
	l.section = (l.section + delta + len(taskListSections)) % len(taskListSections)
	if l.section != before {
		l.selected = 0
	}
	return l.ActiveSection().Name
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
	if l.section < 0 || l.section >= len(taskListSections) {
		return taskListSections[0]
	}
	return taskListSections[l.section]
}
func (l TaskList) ActiveSectionIndex() int { return l.section }
func (l TaskList) SelectedItem() (Item, bool) {
	if l.selected < 0 || l.selected >= len(l.items) {
		return Item{}, false
	}
	return l.items[l.selected], true
}
func (l TaskList) Collapsed(group string) bool { return false }
func (l TaskList) Scope() string               { return l.scope }
func (l TaskList) Search() string              { return l.search }
func (l TaskList) Searching() bool             { return l.searching }

func (l TaskList) Counts(runs []Run, tasks []Task) map[string]int {
	count := map[string]int{}
	all := buildTaskListItems(runs, tasks)
	for _, section := range taskListSections {
		for _, it := range all {
			if matchesTaskSection(it, section.Name) {
				count[section.Name]++
			}
		}
	}
	return count
}

func buildTaskListItems(runs []Run, tasks []Task) []Item {
	items := make([]Item, 0, len(runs)+len(tasks))
	activeRuns := map[string]bool{}
	for _, r := range runs {
		if r.Group != taskGroupRunning {
			continue
		}
		activeRuns[r.TaskID] = true
		items = append(items, Item{Group: r.Group, Run: r})
	}
	for _, t := range tasks {
		if activeRuns[t.TaskID] {
			continue
		}
		items = append(items, Item{Group: taskGroupReady, IsTask: true, Task: t})
	}
	for _, r := range runs {
		if r.Group != taskGroupRecent {
			continue
		}
		items = append(items, Item{Group: r.Group, Run: r})
	}
	return items
}

func matchesTaskSection(it Item, section string) bool {
	switch section {
	case taskSectionRunning:
		return !it.IsTask && it.Run.Group == taskGroupRunning
	case taskSectionReady:
		return it.IsTask && !isFailedState(it.Task.Status)
	case taskSectionFailed:
		if it.IsTask {
			return isFailedState(it.Task.Status)
		}
		return isFailedState(it.Run.Status) || strings.EqualFold(it.Run.Verdict, "fail") || strings.Contains(strings.ToLower(it.Run.Attention), "fail")
	case taskSectionRecent:
		return !it.IsTask && it.Run.Group == taskGroupRecent
	case taskSectionAll:
		return true
	default:
		return true
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

func matchesTaskQuery(it Item, query string) bool {
	terms := normalizedTaskFilterTerms(query)
	if len(terms) == 0 {
		return true
	}
	haystack := taskSearchText(it)
	for _, term := range terms {
		if !strings.Contains(haystack, term) {
			return false
		}
	}
	return true
}

func normalizedTaskFilterTerms(query string) []string {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(query)))
	terms := make([]string, 0, len(fields))
	for _, field := range fields {
		if strings.Contains(field, ":") {
			parts := strings.SplitN(field, ":", 2)
			if parts[1] == "" || parts[1] == "false" {
				continue
			}
			field = parts[1]
		}
		if field != "" && field != "all" && field != "true" {
			terms = append(terms, field)
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
		it.Run.Attention, it.Run.Last,
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
