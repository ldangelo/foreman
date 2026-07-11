package main

import (
	"os"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func keyPress(text string) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Text: text, Code: []rune(text)[0]})
}

func specialKey(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code})
}

func ctrlKey(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code, Mod: tea.ModCtrl})
}

func mouseWheel(x, y int, button tea.MouseButton) tea.MouseWheelMsg {
	return tea.MouseWheelMsg(tea.Mouse{X: x, Y: y, Button: button})
}

func TestViewerUsesViewportSelectionAndIdentity(t *testing.T) {
	var viewer Viewer
	viewer.SetBounds(20, 4)
	lines := make([]ViewerLine, 12)
	for i := range lines {
		lines[i] = ViewerLine{Key: itoa(i), Text: "row " + itoa(i)}
	}

	viewer.SetLines(lines, viewerReset, 4)
	viewer.Move(8, 4)

	if viewer.Cursor() != 8 {
		t.Fatalf("expected selected row 8, got %d", viewer.Cursor())
	}
	if viewer.Offset() <= 0 {
		t.Fatalf("expected viewport to scroll selected row into view, got offset %d", viewer.Offset())
	}
	rendered := stripANSI(viewer.View())
	if !strings.Contains(rendered, "row 8") || strings.Contains(rendered, "row 0") {
		t.Fatalf("expected viewport-rendered selected window around row 8, got:\n%s", rendered)
	}

	lines[8].Text = "row 8 updated"
	viewer.SetLines(lines, viewerPreserve, 4)
	selected, ok := viewer.SelectedLine()
	if !ok || selected.Key != "8" || selected.Text != "row 8 updated" {
		t.Fatalf("expected selection identity to survive refresh, got %#v ok=%v", selected, ok)
	}
}

func TestViewerPacksUnselectableLinesWithSelectedTarget(t *testing.T) {
	var viewer Viewer
	viewer.SetBounds(36, 3)
	open := target{ok: true, label: "file", path: "src/a.go"}
	lines := []ViewerLine{
		{Key: "file:src/a.go", Text: "M src/a.go", Target: open, KeepNext: true},
		{Key: "diff:src/a.go:1", Text: "+added", Unselectable: true},
		{Key: "file:src/b.go", Text: "M src/b.go", Target: target{ok: true, label: "file", path: "src/b.go"}},
	}

	viewer.SetLines(lines, viewerReset, 3)

	selected, ok := viewer.SelectedLine()
	if !ok || selected.Target.path != "src/a.go" {
		t.Fatalf("expected selected target to stay on selectable file row, got %#v ok=%v", selected, ok)
	}
	rendered := stripANSI(viewer.View())
	if !strings.Contains(rendered, "M src/a.go") || !strings.Contains(rendered, "+added") {
		t.Fatalf("expected unselectable preview to render with selected file item, got:\n%s", rendered)
	}

	viewer.Move(1, 3)
	if viewer.Cursor() != 2 {
		t.Fatalf("expected movement to skip packed preview and select next file row, got %d", viewer.Cursor())
	}
}

func TestViewRequestsAltScreenAndMouseMode(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 100
	m.height = 12

	view := m.View()
	if !view.AltScreen {
		t.Fatalf("expected cockpit view to request alt screen")
	}
	if view.MouseMode != tea.MouseModeCellMotion {
		t.Fatalf("expected cell-motion mouse mode, got %v", view.MouseMode)
	}
	if !strings.Contains(view.Content, "foreman") {
		t.Fatalf("expected rendered cockpit content, got %q", view.Content)
	}
}

func TestClipPreservesANSIBoundaries(t *testing.T) {
	text := cyanStyle.Render("approve → POST /api/v1/commands task.approve")

	clipped := clip(text, 18)
	out := stripANSI(clipped)
	if !strings.Contains(out, "approve") || !strings.HasSuffix(out, "…") || len([]rune(out)) > 18 {
		t.Fatalf("expected visible clipped text with intact ellipsis, got %q", out)
	}
}

func TestViewDoesNotExceedTerminalHeight(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 100
	m.height = 12
	m.runs = manyRuns(30)
	m.tasks = nil
	m.buildItems()
	m.loadDetail()

	assertViewHeight(t, m)
}

func TestWideViewDoesNotExceedTerminalHeight(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 343
	m.height = 69
	m.runs = manyRuns(130)
	m.tasks = nil
	m.buildItems()
	m.loadDetail()

	assertViewHeight(t, m)
}

func TestReadyTaskViewShowsApproveEditAndCreateActions(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = nil
	m.tasks = []Task{{TaskID: "task-ready", Title: "Ready task", Status: "backlog", ProjectID: "proj-live"}}
	m.buildItems()

	out := stripANSI(m.renderFrame())
	if !strings.Contains(out, "task actions task-ready") {
		t.Fatalf("expected task action panel, got:\n%s", out)
	}
	if !strings.Contains(out, "y copy task id") || !strings.Contains(out, "a approve") || !strings.Contains(out, "e edit") || !strings.Contains(out, "n new task") {
		t.Fatalf("expected copy, approve, edit, and create action hints, got:\n%s", out)
	}
}

func TestReadyTaskRowShowsTitlePriorityAndType(t *testing.T) {
	m := newModel(NewMockClient())
	m.tasks = []Task{{TaskID: "task-ready", Title: "Create cockpit task", TaskType: "feature", Priority: "P1", Status: "backlog"}}
	m.buildItems()

	out := stripANSI(m.renderLeft(36, 8))
	if !strings.Contains(out, "Create cockpit task") || !strings.Contains(out, "P1") || !strings.Contains(out, "feature") {
		t.Fatalf("expected task title, priority, and type in left list, got:\n%s", out)
	}
	if strings.Contains(out, "task-ready") {
		t.Fatalf("expected task id to move out of the list row, got:\n%s", out)
	}
}

func TestRunRowShowsTitleWhenAvailable(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: "RUNNING", TaskID: "task-run", Title: "Fix failing CI", RunID: "run-1", Status: "running", Phase: "qa"}}
	m.tasks = nil
	m.buildItems()

	out := stripANSI(m.renderLeft(40, 6))
	if !strings.Contains(out, "Fix failing CI") || !strings.Contains(out, "qa") {
		t.Fatalf("expected run title and phase in row, got:\n%s", out)
	}
	if strings.Contains(out, "task-run") {
		t.Fatalf("expected task id to be hidden when run title is available, got:\n%s", out)
	}
}

func TestTaskListViewportShowsStickySelectedGroupHeader(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = manyRuns(20)
	m.tasks = nil
	m.buildItems()
	for range 10 {
		m.taskList.Move(1)
	}

	out := stripANSI(m.renderLeft(40, 5))
	lines := strings.Split(out, "\n")
	if len(lines) == 0 || !strings.Contains(lines[0], "RUNNING") {
		t.Fatalf("expected selected group header to stay visible, got:\n%s", out)
	}
	selected, ok := m.taskList.SelectedItem()
	if !ok || !strings.Contains(out, selected.Run.Title) {
		t.Fatalf("expected selected run to stay visible, got:\n%s", out)
	}
}

func TestTaskListViewportUpdatesStickyHeaderAcrossGroups(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1", Status: "running", Phase: "qa"}}
	for i := range 8 {
		m.tasks = append(m.tasks, Task{TaskID: "ready-" + itoa(i), Title: "Ready " + itoa(i), Status: "backlog"})
	}
	m.buildItems()
	for range 5 {
		m.taskList.Move(1)
	}

	out := stripANSI(m.renderLeft(40, 5))
	lines := strings.Split(out, "\n")
	if len(lines) == 0 || !strings.Contains(lines[0], "READY") {
		t.Fatalf("expected sticky header to follow selected ready group, got:\n%s", out)
	}
	if !strings.Contains(out, "Ready 4") {
		t.Fatalf("expected selected ready task to stay visible, got:\n%s", out)
	}
}

func TestTaskListSearchUsesViewportFilterLineAndSubstringMatching(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1", Status: "running", Phase: "qa", Title: "Fix API"}}
	m.tasks = []Task{{TaskID: "ready-special", Title: "Ship Search", Status: "backlog"}}
	m.buildItems()
	_ = m.renderLeft(40, 8)

	updated, _ := m.handleKey(keyPress("/"))
	m = updated.(model)
	for _, ch := range "READY-SPECIAL" {
		updated, _ = m.handleKey(keyPress(string(ch)))
		m = updated.(model)
	}

	if !m.taskList.Searching() || m.taskList.Search() != "READY-SPECIAL" {
		t.Fatalf("expected task-list filter input to hold query, searching=%v query=%q", m.taskList.Searching(), m.taskList.Search())
	}
	if len(m.taskList.Items()) != 1 || !m.taskList.Items()[0].IsTask {
		t.Fatalf("expected case-insensitive hidden-id substring search to keep only the ready task, got %#v", m.taskList.Items())
	}
	out := stripANSI(m.renderLeft(40, 8))
	if !strings.Contains(out, "[task]") || !strings.Contains(out, "READY-SPECIAL") {
		t.Fatalf("expected viewport filter line to render task query, got:\n%s", out)
	}

	updated, _ = m.handleKey(specialKey(tea.KeyEnter))
	m = updated.(model)
	if m.taskList.Searching() || m.taskList.Search() != "READY-SPECIAL" {
		t.Fatalf("expected enter to apply task-list search, searching=%v query=%q", m.taskList.Searching(), m.taskList.Search())
	}

	updated, _ = m.handleKey(specialKey(tea.KeyEsc))
	m = updated.(model)
	if m.taskList.Search() != "" || len(m.taskList.Items()) != 2 {
		t.Fatalf("expected escape to clear applied task-list search, query=%q items=%d", m.taskList.Search(), len(m.taskList.Items()))
	}
}

func TestTaskRowPriorityBadgeUsesPriorityOnly(t *testing.T) {
	m := newModel(NewMockClient())
	m.tasks = []Task{{TaskID: "task-p0", Title: "Fix production", TaskType: "bug", Priority: "P0", Status: "failed"}}
	m.buildItems()

	out := stripANSI(m.renderLeft(40, 6))
	if !strings.Contains(out, "P0") || !strings.Contains(out, "Fix production") || !strings.Contains(out, "bug") {
		t.Fatalf("expected separate priority badge, title, and type, got:\n%s", out)
	}
	if strings.Contains(out, "P0 bug") {
		t.Fatalf("expected priority and type to be separated by the title, got:\n%s", out)
	}
}

func TestLeftPaneWidthKeepsRightPaneUsable(t *testing.T) {
	for _, tc := range []struct {
		total int
		want  int
	}{
		{total: 120, want: 40},
		{total: 92, want: 40},
		{total: 80, want: 35},
		{total: 70, want: 32},
	} {
		if got := leftPaneWidth(tc.total); got != tc.want {
			t.Fatalf("leftPaneWidth(%d) = %d, want %d", tc.total, got, tc.want)
		}
		if right := tc.total - leftPaneWidth(tc.total) - 1; tc.total >= 77 && right < 44 {
			t.Fatalf("leftPaneWidth(%d) leaves right pane width %d", tc.total, right)
		}
	}
}

func TestReadyTaskDetailShowsFullTaskFields(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = nil
	m.tasks = []Task{{
		TaskID: "task-ready", Title: "Create cockpit task", Description: "Full task body",
		TaskType: "feature", Priority: "P1", Status: "backlog", Depends: "task-a", Workflow: "default", ProjectID: "proj-live",
	}}
	m.buildItems()

	out := stripANSI(m.renderRight(80))
	for _, want := range []string{"Create cockpit task", "id  task-ready", "type  feature", "priority  P1", "status  backlog", "workflow  default", "depends  task-a", "project  proj-live", "Full task body"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected %q in task detail, got:\n%s", want, out)
		}
	}
}

func TestNewTaskKeyLaunchesCreateCommand(t *testing.T) {
	m := newModel(NewMockClient())
	_, cmd := m.handleKey(keyPress("n"))
	if cmd == nil {
		t.Fatal("expected n to launch task create command")
	}
}

func TestEnterFocusesViewerAndScrollKeysMoveViewer(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = []Run{
		{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Summary: "first"},
		{Group: "RUNNING", TaskID: "task-2", RunID: "run-2", Status: "running", Summary: "second"},
	}
	for i := range 10 {
		m.msgs = append(m.msgs, Message{At: itoa(i), From: "a", To: "b", Subject: "subject-" + itoa(i), Body: "body-" + itoa(i)})
	}
	m.tab = 1
	m.buildItems()

	updated, cmd := m.handleKey(specialKey(tea.KeyEnter))
	if cmd != nil {
		t.Fatalf("enter should focus the view, not open a command")
	}
	m = updated.(model)
	if !m.viewFocused {
		t.Fatalf("expected enter to focus the drill-down view")
	}

	bottomRow := m.viewer.Cursor()
	updated, _ = m.handleKey(keyPress("k"))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-2 {
		t.Fatalf("expected focused k to move viewer cursor only, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-2)
	}

	updated, _ = m.handleKey(specialKey(tea.KeyUp))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-4 {
		t.Fatalf("expected focused up to move viewer cursor only, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-4)
	}

	updated, _ = m.handleKey(specialKey(tea.KeyDown))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-2 {
		t.Fatalf("expected focused down to move viewer cursor only, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-2)
	}

	updated, _ = m.handleKey(ctrlKey('d'))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() <= bottomRow-2 {
		t.Fatalf("expected focused ctrl+d to page viewer down only, got sel=%d row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor())
	}
	updated, _ = m.handleKey(ctrlKey('u'))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() >= bottomRow-2 {
		t.Fatalf("expected focused ctrl+u to page viewer up only, got sel=%d row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor())
	}

	updated, _ = m.handleKey(specialKey(tea.KeyEsc))
	m = updated.(model)
	if m.viewFocused {
		t.Fatalf("expected escape to return focus to the task list")
	}

	updated, _ = m.handleKey(keyPress("j"))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 1 || m.viewer.Cursor() != 0 {
		t.Fatalf("expected unfocused j to move task selection, got sel=%d row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor())
	}
}

func TestTabToMessagesFocusesViewerForImmediateScrolling(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = []Run{
		{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Summary: "first"},
		{Group: "RUNNING", TaskID: "task-2", RunID: "run-2", Status: "running", Summary: "second"},
	}
	for i := range 10 {
		m.msgs = append(m.msgs, Message{At: itoa(i), From: "a", To: "b", Subject: "subject-" + itoa(i), Body: "body-" + itoa(i)})
	}
	m.buildItems()

	updated, _ := m.handleKey(specialKey(tea.KeyTab))
	m = updated.(model)
	if m.tab != 1 || !m.viewFocused {
		t.Fatalf("expected tab to messages to focus the viewer, got tab=%d focused=%v", m.tab, m.viewFocused)
	}

	bottomRow := m.viewer.Cursor()
	updated, _ = m.handleKey(keyPress("k"))
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-2 {
		t.Fatalf("expected k after tabbing to messages to scroll messages, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-2)
	}
}

func TestMouseWheelOverMessagesScrollsViewerNotTasks(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 12
	m.runs = []Run{
		{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Summary: "first"},
		{Group: "RUNNING", TaskID: "task-2", RunID: "run-2", Status: "running", Summary: "second"},
	}
	for i := range 12 {
		m.msgs = append(m.msgs, Message{At: itoa(i), From: "a", To: "b", Subject: "subject-" + itoa(i), Body: "body-" + itoa(i)})
	}
	m.tab = 1
	m.buildItems()
	m.scrollToBottom()

	startRow := m.viewer.Cursor()
	updated, _ := m.Update(mouseWheel(m.leftPaneWidth()+5, 5, tea.MouseWheelUp))
	m = updated.(model)
	if !m.viewFocused {
		t.Fatalf("expected mouse wheel over messages to focus the viewer")
	}
	if m.taskList.SelectedIndex() != 0 {
		t.Fatalf("expected mouse wheel over messages to leave task selection unchanged, got %d", m.taskList.SelectedIndex())
	}
	if want := startRow - 2*mouseWheelStep; m.viewer.Cursor() != want {
		t.Fatalf("expected mouse wheel over messages to move viewer cursor, got row=%d want=%d", m.viewer.Cursor(), want)
	}
}

func TestMouseWheelOverTaskListMovesTasksNotViewer(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 12
	m.runs = []Run{
		{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Summary: "first"},
		{Group: "RUNNING", TaskID: "task-2", RunID: "run-2", Status: "running", Summary: "second"},
		{Group: "RUNNING", TaskID: "task-3", RunID: "run-3", Status: "running", Summary: "third"},
	}
	for i := range 12 {
		m.msgs = append(m.msgs, Message{At: itoa(i), From: "a", To: "b", Subject: "subject-" + itoa(i), Body: "body-" + itoa(i)})
	}
	m.tab = 1
	m.buildItems()
	m.scrollToBottom()

	updated, _ := m.Update(mouseWheel(5, 5, tea.MouseWheelDown))
	m = updated.(model)
	if m.viewFocused {
		t.Fatalf("expected mouse wheel over task list to keep task-list focus")
	}
	if m.taskList.SelectedIndex() == 0 {
		t.Fatalf("expected mouse wheel over task list to move task selection")
	}
}

func TestFocusedViewerScrollChangesRenderedBody(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 100
	m.height = 12
	m.runs = []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}}
	for i := range 12 {
		m.logs = append(m.logs, "log-line-"+itoa(i))
	}
	m.tab = 3
	m.viewFocused = true
	m.buildItems()

	before := stripANSI(m.renderRight(m.rightPaneWidth()))
	for range 5 {
		updated, _ := m.handleKey(keyPress("j"))
		m = updated.(model)
	}
	after := stripANSI(m.renderRight(m.rightPaneWidth()))

	if before == after {
		t.Fatalf("expected focused j to change the rendered viewer body")
	}
	if strings.Contains(after, "log-line-0") || !strings.Contains(after, "log-line-4") {
		t.Fatalf("expected logs view to scroll by body lines, got:\n%s", after)
	}
}

func TestFocusedViewerSlashStartsDrilldownSearch(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		logs: []string{"alpha", "needle target", "omega"},
	}
	m := newModel(client)
	m.width = 100
	m.height = 12
	m.tab = 3
	m.viewFocused = true

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	updated, _ = m.handleKey(keyPress("/"))
	m = updated.(model)

	if m.taskList.Searching() {
		t.Fatalf("expected focused slash to search the drilldown viewer, not the task list")
	}
	if !m.viewer.Searching() {
		t.Fatalf("expected viewer filter input to be focused")
	}

	for _, ch := range "needle" {
		updated, _ = m.handleKey(keyPress(string(ch)))
		m = updated.(model)
	}
	updated, _ = m.handleKey(specialKey(tea.KeyEnter))
	m = updated.(model)

	selected, ok := m.viewer.SelectedLine()
	if !ok || !strings.Contains(stripANSI(selected.Text), "needle target") {
		t.Fatalf("expected search to select matching log row, got %#v ok=%v", selected, ok)
	}
}

func TestViewerSearchSurvivesRefreshByKey(t *testing.T) {
	var viewer Viewer
	viewer.SetBounds(40, 4)
	lines := []ViewerLine{
		{Key: "a", Text: "alpha"},
		{Key: "b", Text: "needle target"},
		{Key: "c", Text: "omega"},
	}
	viewer.SetLines(lines, viewerReset, 4)
	viewer.HandleKey(keyPress("/"))
	for _, ch := range "needle" {
		viewer.HandleKey(keyPress(string(ch)))
	}
	viewer.HandleKey(specialKey(tea.KeyEnter))

	lines[1].Text = "needle target updated"
	viewer.SetLines(lines, viewerPreserve, 4)
	selected, ok := viewer.SelectedLine()
	if !ok || selected.Key != "b" || selected.Text != "needle target updated" {
		t.Fatalf("expected filtered viewer selection to survive refresh by key, got %#v ok=%v", selected, ok)
	}
}

func TestViewerSearchCanToggleMatchesOnly(t *testing.T) {
	var viewer Viewer
	viewer.SetBounds(40, 4)
	lines := []ViewerLine{
		{Key: "a", Text: "alpha"},
		{Key: "b", Text: "needle target"},
		{Key: "c", Text: "omega"},
	}
	viewer.SetLines(lines, viewerReset, 4)
	viewer.HandleKey(keyPress("/"))
	for _, ch := range "needle" {
		viewer.HandleKey(keyPress(string(ch)))
	}
	viewer.HandleKey(specialKey(tea.KeyEnter))
	viewer.HandleKey(keyPress("o"))

	rendered := stripANSI(viewer.View())
	if strings.Contains(rendered, "alpha") || strings.Contains(rendered, "omega") || !strings.Contains(rendered, "needle target") {
		t.Fatalf("expected matches-only search view, got:\n%s", rendered)
	}
}

func TestCtrlCDoesNotQuit(t *testing.T) {
	m := newModel(NewMockClient())
	if _, cmd := m.handleKey(ctrlKey('c')); cmd != nil {
		t.Fatalf("ctrl+c should not quit; q is the only quit key")
	}
	if _, cmd := m.handleKey(keyPress("q")); cmd == nil {
		t.Fatalf("expected q to quit")
	}
}

func TestDataUpdateScrollsViewerToBottom(t *testing.T) {
	client := NewMockClient()
	m := newModel(client)
	m.width = 120
	m.height = 10
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if want := m.rowCount() - 2; want <= 0 || m.viewer.Cursor() != want {
		t.Fatalf("expected messages viewer cursor at bottom message header, got row=%d want=%d", m.viewer.Cursor(), want)
	}
	selected, ok := m.viewer.SelectedLine()
	if !ok || !strings.Contains(stripANSI(m.renderRight(m.rightPaneWidth())), stripANSI(selected.Text)) {
		t.Fatalf("expected bottom message header visible, got cursor=%d offset=%d selected=%#v", m.viewer.Cursor(), m.viewer.Offset(), selected)
	}
}

func TestSelectedMessageHeaderAndBodyStayInViewport(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		messages: []Message{
			{At: "3", From: "qa", To: "developer", Subject: "third", Body: "third body"},
			{At: "2", From: "qa", To: "developer", Subject: "second", Body: "second body"},
			{At: "1", From: "qa", To: "developer", Subject: "first", Body: "first body"},
		},
	}
	m := newModel(client)
	m.width = 120
	m.height = 11
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	h := m.viewerBodyWindowHeight()
	if h < 2 {
		t.Fatalf("test setup expected at least two visible message rows, got %d", h)
	}
	if m.viewer.Cursor() != 4 {
		t.Fatalf("expected last message header selected, got row=%d", m.viewer.Cursor())
	}
	if m.viewer.Offset() > m.viewer.Cursor() || m.viewer.Cursor()+1 >= m.viewer.Offset()+h {
		t.Fatalf("expected selected message header and body visible, got cursor=%d offset=%d height=%d", m.viewer.Cursor(), m.viewer.Offset(), h)
	}
}

func TestSelectedMessageHeaderStaysVisibleInTinyViewport(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		messages: []Message{
			{At: "3", From: "qa", To: "developer", Subject: "third", Body: "third body"},
			{At: "2", From: "qa", To: "developer", Subject: "second", Body: "second body"},
			{At: "1", From: "qa", To: "developer", Subject: "first", Body: "first body"},
		},
	}
	m := newModel(client)
	m.width = 120
	m.height = 9
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if h := m.viewerBodyWindowHeight(); h != 1 {
		t.Fatalf("test setup expected a one-line viewport, got %d", h)
	}

	m.viewFocused = true
	m.resetViewerCursor()
	for range 2 {
		updated, _ = m.handleKey(keyPress("j"))
		m = updated.(model)
		selected, ok := m.viewer.SelectedLine()
		if !ok || !strings.Contains(stripANSI(m.renderRight(m.rightPaneWidth())), stripANSI(selected.Text)) {
			t.Fatalf("expected tiny viewport to show selected header while moving down, got cursor=%d offset=%d selected=%#v", m.viewer.Cursor(), m.viewer.Offset(), selected)
		}
	}
}

func TestBottomMessageHeaderAndPositionRenderInTinyViewport(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		messages: []Message{
			{At: "3", From: "qa", To: "developer", Subject: "third", Body: "third body"},
			{At: "2", From: "qa", To: "developer", Subject: "second", Body: "second body"},
			{At: "1", From: "qa", To: "developer", Subject: "first", Body: "first body"},
		},
	}
	m := newModel(client)
	m.width = 120
	m.height = 9
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	rendered := stripANSI(m.renderRight(m.rightPaneWidth()))
	if !strings.Contains(rendered, "messages 3/3") {
		t.Fatalf("expected messages tab to show selected position, got:\n%s", rendered)
	}
	if !strings.Contains(rendered, "running · messages 3/3") {
		t.Fatalf("expected header to show selected message position, got:\n%s", rendered)
	}
	if !strings.Contains(rendered, "[1] qa → developer first") {
		t.Fatalf("expected bottom selected message header to render in tiny viewport, got:\n%s", rendered)
	}
}

func TestDataUpdatePreservesMovedViewerCursor(t *testing.T) {
	client := NewMockClient()
	for _, tc := range []struct {
		name string
		tab  int
	}{
		{"messages", 1},
		{"events", 2},
		{"logs", 3},
		{"reports", 4},
		{"files", 5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newModel(client)
			m.width = 120
			m.height = 10
			m.tab = tc.tab

			updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
			m = updated.(model)
			if m.viewer.Cursor() <= 0 {
				t.Fatalf("test setup expected initial cursor at bottom, got row=%d", m.viewer.Cursor())
			}

			updated, _ = m.handleKey(specialKey(tea.KeyEnter))
			m = updated.(model)
			updated, _ = m.handleKey(keyPress("k"))
			m = updated.(model)
			movedRow, movedOffset := m.viewer.Cursor(), m.viewer.Offset()

			updated, _ = m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
			m = updated.(model)
			if m.viewer.Cursor() != movedRow || m.viewer.Offset() != movedOffset {
				t.Fatalf("expected update to preserve moved cursor, got row=%d offset=%d want row=%d offset=%d", m.viewer.Cursor(), m.viewer.Offset(), movedRow, movedOffset)
			}
		})
	}
}

func TestMessageRefreshPreservesCursorWhenNewMessagesPrepend(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		messages: []Message{
			{At: "2", From: "qa", To: "developer", Subject: "newer", Body: "newer body"},
			{At: "1", From: "explorer", To: "developer", Subject: "older", Body: "older body"},
		},
	}
	m := newModel(client)
	m.width = 120
	m.height = 10
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	updated, _ = m.handleKey(specialKey(tea.KeyEnter))
	m = updated.(model)
	updated, _ = m.handleKey(keyPress("k"))
	m = updated.(model)

	selectedKey := m.viewerCursorKey()
	movedRow := m.viewer.Cursor()
	if selectedKey == "" || !strings.Contains(selectedKey, "newer") {
		t.Fatalf("expected test setup to select newer message header, got key=%q row=%d", selectedKey, movedRow)
	}

	client.messages = append([]Message{{At: "3", From: "reviewer", To: "developer", Subject: "prepended", Body: "prepended body"}}, client.messages...)
	updated, _ = m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)

	if got := m.viewerCursorKey(); got != selectedKey {
		t.Fatalf("expected message refresh to preserve selected line key, got %q want %q", got, selectedKey)
	}
	if m.viewer.Cursor() != movedRow+2 {
		t.Fatalf("expected cursor to follow prepended message from row %d to %d, got %d", movedRow, movedRow+2, m.viewer.Cursor())
	}
}

func TestViewerAtBottomFollowsAppendedContent(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		logs: []string{"one", "two"},
	}
	m := newModel(client)
	m.width = 120
	m.height = 10
	m.tab = 3

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if got := m.viewerCursorKey(); !strings.Contains(got, "two") {
		t.Fatalf("test setup expected bottom log selected, got key %q", got)
	}

	client.logs = append(client.logs, "three")
	updated, _ = m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)

	if got := m.viewerCursorKey(); !strings.Contains(got, "three") {
		t.Fatalf("expected bottom-follow to select appended log, got key %q", got)
	}
}

func TestViewerRefreshClampsWhenContentShrinks(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		messages: []Message{
			{At: "3", From: "qa", To: "developer", Subject: "third", Body: "third body"},
			{At: "2", From: "qa", To: "developer", Subject: "second", Body: "second body"},
			{At: "1", From: "qa", To: "developer", Subject: "first", Body: "first body"},
		},
	}
	m := newModel(client)
	m.width = 120
	m.height = 10
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if m.viewer.Cursor() != 4 {
		t.Fatalf("test setup expected cursor at last selectable message header, got %d", m.viewer.Cursor())
	}

	client.messages = client.messages[:1]
	updated, _ = m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)

	selected, ok := m.viewer.SelectedLine()
	if m.viewer.Cursor() != 0 || !ok || !strings.Contains(stripANSI(m.renderRight(m.rightPaneWidth())), stripANSI(selected.Text)) {
		t.Fatalf("expected shrink to clamp to visible remaining message header, got row=%d offset=%d selected=%#v", m.viewer.Cursor(), m.viewer.Offset(), selected)
	}
}

func TestOpenTargetsFollowSelectedReportAndFileRows(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Worktree: "/tmp/work", Summary: "first"}},
		reports: []Report{
			{Name: "qa.md", Size: "1K", Status: "done", Preview: "# QA"},
			{Name: "review.md", Size: "2K", Status: "done", Preview: "# Review"},
		},
		files: []FileChange{
			{Change: "M", Path: "src/a.go", Stat: "+1 -1"},
			{Change: "M", Path: "src/b.go", Stat: "+2 -2", Conflict: true},
		},
	}

	m := newModel(client)
	m.width = 120
	m.height = 12
	m.tab = 4
	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if !m.selectViewerLineByKey("report:qa.md") {
		t.Fatalf("test setup could not select first report")
	}
	m.viewFocused = true
	updated, _ = m.handleKey(keyPress("j"))
	m = updated.(model)
	if got := resolveTarget(m); !got.ok || got.label != "review.md" || got.path != "/tmp/work/docs/reports/task-1/review.md" {
		t.Fatalf("expected report target to follow cursor, got %#v", got)
	}

	m.tab = 5
	m.selectInitialViewerLine()
	if !m.selectViewerLineByKey("file:src/a.go") {
		t.Fatalf("test setup could not select first file")
	}
	updated, _ = m.handleKey(keyPress("j"))
	m = updated.(model)
	if got := resolveTarget(m); !got.ok || got.label != "src/b.go" || got.path != "/tmp/work/src/b.go" || !got.conflict {
		t.Fatalf("expected file target to follow cursor, got %#v", got)
	}
}

func TestPRTabRendersProjectedStatusAndAction(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{
			Group:      "RUNNING",
			TaskID:     "task-1",
			RunID:      "run-1",
			Status:     "running",
			Phase:      "pr-wait",
			PRURL:      "https://github.com/acme/repo/pull/42",
			PRState:    "open",
			BranchName: "foreman/task-1",
			BaseBranch: "main",
		}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	m.tab = 6

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	out := stripANSI(m.renderFrame())
	if !strings.Contains(out, "pr 1") || !strings.Contains(out, "https://github.com/acme/repo/pull/42") || !strings.Contains(out, "open PR in browser") || !strings.Contains(out, "gh enhance") {
		t.Fatalf("expected PR tab status, browser action, and gh enhance hint, got:\n%s", out)
	}
}

func TestPRTabEnterOpensPRWithoutExtraFocusStep(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{
			Group:   "RUNNING",
			TaskID:  "task-1",
			RunID:   "run-1",
			Status:  "running",
			Phase:   "pr-wait",
			PRURL:   "https://github.com/acme/repo/pull/42",
			PRState: "open",
		}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	m.tab = 6
	m.tools = fakeTools{}

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if m.viewFocused {
		t.Fatal("test setup expected PR tab not focused")
	}
	_, cmd := m.handleKey(specialKey(tea.KeyEnter))
	if cmd == nil {
		t.Fatal("expected enter on PR tab to attempt opening the PR")
	}
	msg := cmd()
	if _, ok := msg.(prOpenDoneMsg); !ok {
		t.Fatalf("expected prOpenDoneMsg, got %T", msg)
	}
}

func TestUppercaseCLaunchesGhEnhanceForSelectedRun(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{
			Group:    "RUNNING",
			TaskID:   "task-1",
			RunID:    "run-1",
			Status:   "running",
			Phase:    "pr-wait",
			Worktree: "/tmp/work",
		}},
	}
	m := newModel(client)
	m.tools = fakeTools{"gh": true, "ext:enhance": true}

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	_, cmd := m.handleKey(keyPress("C"))
	if cmd == nil {
		t.Fatal("expected C to launch gh enhance")
	}
}

func TestUppercaseCReportsMissingEnhanceExtension(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{
			Group:    "RUNNING",
			TaskID:   "task-1",
			RunID:    "run-1",
			Status:   "running",
			Worktree: "/tmp/work",
		}},
	}
	m := newModel(client)
	m.tools = fakeTools{"gh": true}

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	_, cmd := m.handleKey(keyPress("C"))
	if cmd == nil {
		t.Fatal("expected C to return a failure command")
	}
	msg := cmd()
	done, ok := msg.(ghEnhanceDoneMsg)
	if !ok {
		t.Fatalf("expected ghEnhanceDoneMsg, got %T", msg)
	}
	if done.err == nil || !strings.Contains(done.err.Error(), "gh enhance not found") {
		t.Fatalf("expected missing extension error, got %v", done.err)
	}
}

func TestQuestionMarkShowsKeymapHelp(t *testing.T) {
	m := newModel(NewMockClient())
	updated, _ := m.handleKey(keyPress("?"))
	m = updated.(model)
	if !strings.Contains(m.notice, "ctrl+d/u") || !strings.Contains(m.notice, "G gh dash") || !strings.Contains(m.notice, "C gh enhance") {
		t.Fatalf("expected keymap help notice, got %q", m.notice)
	}
}

func TestFilesTabRendersSelectedFilePreview(t *testing.T) {
	client := &mutableClient{
		runs:  []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Worktree: "/tmp/work"}},
		files: []FileChange{{Change: "M", Path: "src/a.go", Stat: "+1 -1"}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	m.tab = 5

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	key := diffPreviewKey(client.runs[0], "src/a.go", selectedDiffBase(m.config.Integrations))
	m.diffPreviews[key] = DiffPreview{RunID: "run-1", Path: "src/a.go", Lines: []string{"diff --git a/src/a.go b/src/a.go", "+added"}}
	delete(m.diffLoading, key)
	out := stripANSI(m.renderFrame())
	if !strings.Contains(out, "diff --git a/src/a.go b/src/a.go") || !strings.Contains(out, "+added") {
		t.Fatalf("expected selected file diff preview, got:\n%s", out)
	}
}

func TestFocusedViewerPansLongLogLinesAndShowsLineNumbers(t *testing.T) {
	long := strings.Repeat("x", 80) + " TAIL"
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		logs: []string{"short", long},
	}
	m := newModel(client)
	m.width = 80
	m.height = 12
	m.tab = 3
	m.viewFocused = true

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	before := stripANSI(m.renderRight(m.rightPaneWidth()))
	if !strings.Contains(before, "   2 │ ") {
		t.Fatalf("expected log rows to render line numbers, got:\n%s", before)
	}
	if strings.Contains(before, "TAIL") {
		t.Fatalf("test setup expected long log tail to start out of view, got:\n%s", before)
	}

	for range 5 {
		updated, _ = m.handleKey(specialKey(tea.KeyRight))
		m = updated.(model)
	}
	after := stripANSI(m.renderRight(m.rightPaneWidth()))
	if !strings.Contains(after, "TAIL") || m.viewer.XOffset() == 0 {
		t.Fatalf("expected right arrow to pan long log lines into view, offset=%d:\n%s", m.viewer.XOffset(), after)
	}
}

func TestFocusedViewerSavesVisibleContent(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
		logs: []string{"alpha", "beta"},
	}
	cfg := defaultConfig()
	cfg.Cockpit.ExportDir = t.TempDir()
	m := newModelWithConfig(client, cfg, defaultTools)
	m.width = 100
	m.height = 12
	m.tab = 3
	m.viewFocused = true

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	updated, cmd := m.handleKey(keyPress("s"))
	m = updated.(model)
	if cmd == nil {
		t.Fatalf("expected save command")
	}
	msg := cmd()
	saved, ok := msg.(viewerSavedMsg)
	if !ok || saved.err != nil {
		t.Fatalf("expected successful viewerSavedMsg, got %#v ok=%v", msg, ok)
	}
	data, err := os.ReadFile(saved.path)
	if err != nil {
		t.Fatalf("expected saved viewer file, got %v", err)
	}
	out := string(data)
	if strings.Contains(out, "alpha") || !strings.Contains(out, "beta") {
		t.Fatalf("expected saved visible viewer content only, got:\n%s", out)
	}
}

type mutableClient struct {
	mockClient
	runs     []Run
	messages []Message
	logs     []string
	reports  []Report
	files    []FileChange
}

func (c *mutableClient) Runs() []Run { return c.runs }

func (c *mutableClient) Messages(string) []Message { return c.messages }

func (c *mutableClient) Logs(string) []string { return c.logs }

func (c *mutableClient) Reports(string) []Report { return c.reports }

func (c *mutableClient) Files(string) []FileChange { return c.files }

func TestPaneVisualTracksFocusStyle(t *testing.T) {
	cfg := defaultConfig().Cockpit.Focus

	left := paneVisualFor(true, cfg)
	right := paneVisualFor(false, cfg)
	if left.Border != cBorderFocus || right.Border != cBorderBlur {
		t.Fatalf("expected focused/blurred borders, got left=%v right=%v", left.Border, right.Border)
	}
	if right.Text != cDim || right.SelectedBg != cPanel {
		t.Fatalf("expected inactive pane to use muted content, got text=%v selected=%v", right.Text, right.SelectedBg)
	}

	cfg.Style = focusStyleBorder
	borderOnly := paneVisualFor(false, cfg)
	if borderOnly.Text != cText || borderOnly.Border != cBorderBlur {
		t.Fatalf("border style should keep content strong and blur border, got text=%v border=%v", borderOnly.Text, borderOnly.Border)
	}

	cfg.Style = focusStyleDim
	dimOnly := paneVisualFor(false, cfg)
	if dimOnly.Border != cPanel || dimOnly.Text != cDim {
		t.Fatalf("dim style should mute content without accent frame, got text=%v border=%v", dimOnly.Text, dimOnly.Border)
	}
}

func TestFocusLabelFollowsPaneFocus(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 100
	m.height = 16
	m.runs = NewMockClient().Runs()
	m.tasks = NewMockClient().Dispatchable()
	m.buildItems()
	m.loadDetail()

	if out := stripANSI(m.renderKeyBar(100)); !strings.Contains(out, "focus: tasks") {
		t.Fatalf("expected task-list focus label, got %q", out)
	}
	m.viewFocused = true
	if out := stripANSI(m.renderKeyBar(100)); !strings.Contains(out, "focus: details") {
		t.Fatalf("expected details focus label, got %q", out)
	}
}

func assertViewHeight(t *testing.T, m model) {
	t.Helper()
	out := stripANSI(m.renderFrame())
	lines := strings.Split(out, "\n")
	if len(lines) > m.height {
		t.Fatalf("rendered %d lines for terminal height %d\n%s", len(lines), m.height, out)
	}
}

func manyRuns(n int) []Run {
	base := NewMockClient().Runs()
	out := make([]Run, 0, n)
	for len(out) < n {
		for _, run := range base {
			if len(out) >= n {
				break
			}
			run.RunID = run.RunID + "-" + itoa(len(out))
			run.TaskID = run.TaskID + "-" + itoa(len(out))
			out = append(out, run)
		}
	}
	return out
}
