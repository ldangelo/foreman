package main

import "strings"

const (
	taskGroupRunning = "RUNNING"
	taskGroupReady   = "READY"
	taskGroupRecent  = "RECENT"
)

var taskListGroups = []string{taskGroupRunning, taskGroupReady, taskGroupRecent}

// Item is one selectable row in the left column.
type Item struct {
	Group  string
	IsTask bool
	Run    Run
	Task   Task
}

// TaskList owns the left-pane grouping, filtering, collapsed-group state, and
// selected item cursor. The root model supplies fresh projections and reacts to
// selection changes.
type TaskList struct {
	items     []Item
	selected  int
	collapsed map[string]bool
	scope     string // current | global
	search    string
	searching bool
}

func NewTaskList() TaskList {
	return TaskList{
		collapsed: map[string]bool{},
		scope:     "current",
	}
}

func (l *TaskList) SetData(runs []Run, tasks []Task) {
	selectedKey := ""
	if it, ok := l.SelectedItem(); ok {
		selectedKey = itemKey(it)
	}

	q := strings.ToLower(l.search)
	items := make([]Item, 0, len(runs)+len(tasks))
	activeRuns := map[string]bool{}
	add := func(group, id, text string, it Item) {
		if q != "" && !strings.Contains(strings.ToLower(id+" "+text), q) {
			return
		}
		if l.collapsed[group] {
			return
		}
		items = append(items, it)
	}

	for _, r := range runs {
		if r.Group != taskGroupRunning {
			continue
		}
		activeRuns[r.TaskID] = true
		add(r.Group, r.TaskID, r.Phase+" "+r.Summary, Item{Group: r.Group, Run: r})
	}
	for _, t := range tasks {
		if activeRuns[t.TaskID] {
			continue
		}
		add(taskGroupReady, t.TaskID, t.Priority+" "+t.Summary, Item{Group: taskGroupReady, IsTask: true, Task: t})
	}
	for _, r := range runs {
		if r.Group != taskGroupRecent {
			continue
		}
		add(r.Group, r.TaskID, r.Status+" "+r.Summary, Item{Group: r.Group, Run: r})
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

func (l *TaskList) ToggleSelectedGroup() {
	if it, ok := l.SelectedItem(); ok {
		l.collapsed[it.Group] = !l.collapsed[it.Group]
	}
}

func (l *TaskList) ToggleScope() string {
	if l.scope == "current" {
		l.scope = "global"
	} else {
		l.scope = "current"
	}
	return l.scope
}

func (l *TaskList) StartSearch() { l.searching = true }

func (l *TaskList) HandleSearchKey(key string, runes []rune) bool {
	switch key {
	case "enter":
		l.searching = false
		return false
	case "esc":
		l.searching = false
		if l.search == "" {
			return false
		}
		l.search = ""
		return true
	case "backspace":
		if l.search != "" {
			l.search = l.search[:len(l.search)-1]
			return true
		}
	default:
		if len(runes) == 1 {
			l.search += string(runes)
			return true
		}
	}
	return false
}

func (l TaskList) Items() []Item      { return l.items }
func (l TaskList) SelectedIndex() int { return l.selected }
func (l TaskList) SelectedItem() (Item, bool) {
	if l.selected < 0 || l.selected >= len(l.items) {
		return Item{}, false
	}
	return l.items[l.selected], true
}
func (l TaskList) Collapsed(group string) bool { return l.collapsed[group] }
func (l TaskList) Scope() string               { return l.scope }
func (l TaskList) Search() string              { return l.search }
func (l TaskList) Searching() bool             { return l.searching }

func (l TaskList) Counts(runs []Run, tasks []Task) map[string]int {
	count := map[string]int{}
	activeRuns := map[string]bool{}
	for _, r := range runs {
		count[r.Group]++
		if r.Group == taskGroupRunning {
			activeRuns[r.TaskID] = true
		}
	}
	for _, t := range tasks {
		if !activeRuns[t.TaskID] {
			count[taskGroupReady]++
		}
	}
	return count
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
