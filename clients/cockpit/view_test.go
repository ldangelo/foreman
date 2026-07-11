package main

import (
	"charm.land/bubbles/v2/spinner"
	"charm.land/lipgloss/v2"
	"os"
	"strings"
	"testing"
	"time"

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

func mouseClick(x, y int) tea.MouseClickMsg {
	return tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft})
}

func linesText(lines []ViewerLine) []string {
	out := make([]string, len(lines))
	for i, line := range lines {
		out[i] = line.Text
	}
	return out
}

func lineContaining(out, needle string) string {
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	return ""
}

func labelColumn(line, label string) int {
	idx := strings.Index(line, label)
	if idx < 0 {
		return -1
	}
	for i, r := range line[idx+len(label):] {
		if r != ' ' {
			return idx + len(label) + i
		}
	}
	return -1
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

func TestWrapUsesDisplayCellWidthForWideGlyphs(t *testing.T) {
	for _, line := range wrap("wide 你好 ok", 8) {
		if lipgloss.Width(line) > 8 {
			t.Fatalf("expected wrapped line %q to fit 8 cells, got width %d", line, lipgloss.Width(line))
		}
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
	m.taskList.MoveSection(1)
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
	m.taskList.MoveSection(1)
	m.buildItems()

	out := stripANSI(m.renderLeft(36, 8))
	if !strings.Contains(out, "task-ready") || !strings.Contains(out, "Create cockpit task") || !strings.Contains(out, "P1") || !strings.Contains(out, "feature") {
		t.Fatalf("expected rich task row with id, title, priority, and type, got:\n%s", out)
	}
}

func TestRunRowShowsTitleWhenAvailable(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: "RUNNING", TaskID: "task-run", Title: "Fix failing CI", RunID: "run-1", Status: "running", Phase: "qa", PRState: "open", Verdict: "retrying", Last: time.Now().Add(-2 * time.Hour).Format(time.RFC3339), Messages: 2, Events: 4, Checks: CheckSummary{Passed: 3, Failed: 1}, DiffAdded: 12, DiffRemoved: 5}}
	m.tasks = nil
	m.buildItems()

	out := stripANSI(m.renderLeft(90, 6))
	for _, want := range []string{"task-run", "Fix failing CI", "qa", "✉2", "◇4", "✓3", "✗1", "pr:open", "+12 -5", "retrying", "u2h"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected rich run row metadata %q, got:\n%s", want, out)
		}
	}
}

func TestPhaseRailCollapsesOnVeryNarrowWidth(t *testing.T) {
	m := newModel(NewMockClient())
	run := Run{Phase: "qa", Pipeline: pipe(3, -1)}

	out := stripANSI(strings.Join(m.renderRail(run, 20, paneVisualFor(true, defaultConfig().Cockpit.Focus)), "\n"))
	if !strings.Contains(out, "4/10 · qa") {
		t.Fatalf("expected compact phase badge on narrow width, got:\n%s", out)
	}
	if strings.Contains(out, "explorer") || strings.Contains(out, "developer") {
		t.Fatalf("expected compact rail to omit full phase names, got:\n%s", out)
	}
}

func TestActivePhaseRailUsesMotionFrameUnlessReduced(t *testing.T) {
	run := Run{Phase: "developer", Pipeline: []Phase{
		{Name: "explorer", State: "done"},
		{Name: "developer", State: "active"},
		{Name: "qa", State: "pending"},
	}}
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: "RUNNING", RunID: "run-1", Status: "running"}}
	m.liveSpinner, _ = m.liveSpinner.Update(spinner.TickMsg{})

	out := stripANSI(strings.Join(m.renderRail(run, 80, paneVisualFor(true, defaultConfig().Cockpit.Focus)), "\n"))
	if strings.Contains(out, "● developer") || !strings.Contains(out, "developer") {
		t.Fatalf("expected active phase rail to replace static glyph with motion frame, got:\n%s", out)
	}

	cfg := defaultConfig()
	cfg.Cockpit.ReducedMotion = true
	reduced := newModelWithConfig(NewMockClient(), cfg, defaultTools)
	out = stripANSI(strings.Join(reduced.renderRail(run, 80, paneVisualFor(true, cfg.Cockpit.Focus)), "\n"))
	if strings.Contains(out, "⠋") || !strings.Contains(out, "● developer") {
		t.Fatalf("expected reduced motion to keep static active rail glyph, got:\n%s", out)
	}
}

func TestTaskListViewportShowsSectionTabsAndSelectedRow(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = manyRuns(20)
	m.tasks = nil
	m.buildItems()
	for range 10 {
		m.taskList.Move(1)
	}

	out := stripANSI(m.renderLeft(40, 5))
	if !strings.Contains(out, "Running") || !strings.Contains(out, "Ready 0") {
		t.Fatalf("expected section tab counts to stay visible, got:\n%s", out)
	}
	selected, ok := m.taskList.SelectedItem()
	if !ok || !strings.Contains(out, selected.Run.Title) {
		t.Fatalf("expected selected run to stay visible, got:\n%s", out)
	}
}

func TestTaskListViewportUpdatesRowsAcrossSections(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1", Status: "running", Phase: "qa"}}
	for i := range 8 {
		m.tasks = append(m.tasks, Task{TaskID: "ready-" + itoa(i), Title: "Ready " + itoa(i), Status: "backlog"})
	}
	m.buildItems()
	m.taskList.MoveSection(1)
	m.buildItems()
	for range 4 {
		m.taskList.Move(1)
	}

	out := stripANSI(m.renderLeft(40, 5))
	if !strings.Contains(out, "Ready 8") || !strings.Contains(out, "filter state:ready") {
		t.Fatalf("expected ready section header and filter, got:\n%s", out)
	}
	if !strings.Contains(out, "Ready 4") {
		t.Fatalf("expected selected ready task to stay visible, got:\n%s", out)
	}
}

func TestTaskListSearchUsesViewportFilterLineAndSubstringMatching(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.taskList.MoveSection(4)
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
	m.taskList.MoveSection(2)
	m.buildItems()

	out := stripANSI(m.renderLeft(40, 6))
	if !strings.Contains(out, "P0") || !strings.Contains(out, "Fix production") || !strings.Contains(out, "bug") {
		t.Fatalf("expected separate priority badge, title, and type, got:\n%s", out)
	}
	if strings.Contains(out, "P0 bug") {
		t.Fatalf("expected priority and type to stay separately delimited, got:\n%s", out)
	}
}

func TestTaskListFocusMarkerSurvivesNoColor(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: "RUNNING", TaskID: "task-run", RunID: "run-1", Status: "running"}}
	m.tasks = nil
	m.buildItems()

	leftFocused := stripANSI(m.renderLeft(40, 6))
	if !strings.Contains(leftFocused, "▶ filter state:running") {
		t.Fatalf("expected non-color focus marker while task list focused, got:\n%s", leftFocused)
	}
	m.viewFocused = true
	rightFocused := stripANSI(m.renderLeft(40, 6))
	if strings.Contains(rightFocused, "▶ filter state:running") {
		t.Fatalf("expected task list marker to clear when detail pane focused, got:\n%s", rightFocused)
	}
}

func TestSpaceDoesNotMutateSectionList(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "task-run", RunID: "run-1", Status: "running"}}
	m.tasks = nil
	m.buildItems()

	updated, _ := m.handleKey(keyPress(" "))
	m = updated.(model)
	if m.taskList.ActiveSection().Name != taskSectionRunning || m.taskList.SelectedIndex() != 0 {
		t.Fatalf("space should be retired for task-list grouping, got section=%s selected=%d", m.taskList.ActiveSection().Name, m.taskList.SelectedIndex())
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
	m.taskList.MoveSection(1)
	m.buildItems()

	out := stripANSI(m.renderRight(80))
	for _, want := range []string{"Create cockpit task", "id", "task-ready", "type", "feature", "priority", "P1", "status", "backlog", "workflow", "default", "depends", "task-a", "project", "proj-live", "description", "Full task body"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected %q in task detail, got:\n%s", want, out)
		}
	}
}

func TestReadyTaskDetailRendersFieldsAsAlignedTable(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = nil
	m.tasks = []Task{{
		TaskID: "task-ready", Title: "Create cockpit task", Description: "Full task body",
		TaskType: "feature", Priority: "P1", Status: "backlog", Depends: "task-a", Workflow: "default", ProjectID: "proj-live",
	}}
	m.taskList.MoveSection(1)
	m.buildItems()

	out := stripANSI(m.renderRight(80))
	desc := lineContaining(out, "description")
	if !strings.Contains(desc, "Full task body") {
		t.Fatalf("expected description row to include body, got:\n%s", out)
	}
	if labelColumn(desc, "description") != labelColumn(lineContaining(out, "id"), "id") {
		t.Fatalf("expected task field value columns to align, got:\n%s", out)
	}
}

func TestNewTaskKeyOpensCreateForm(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 24

	updated, _ := m.Update(keyPress("n"))
	m = updated.(model)

	out := stripANSI(m.renderRight(80))
	for _, want := range []string{"Create new task", "title", "description", "ctrl+s create", "esc cancel"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected create form to show %q, got:\n%s", want, out)
		}
	}
}

func TestCreateTaskFormSubmitsTypedTask(t *testing.T) {
	client := &mutableClient{}
	m := newModel(client)
	m.width = 120
	m.height = 24

	updated, _ := m.Update(keyPress("n"))
	m = updated.(model)
	for _, r := range "Ship cockpit form" {
		updated, _ = m.Update(keyPress(string(r)))
		m = updated.(model)
	}
	updated, _ = m.Update(specialKey(tea.KeyTab))
	m = updated.(model)
	for _, r := range "Detailed body" {
		updated, _ = m.Update(keyPress(string(r)))
		m = updated.(model)
	}
	updated, cmd := m.Update(ctrlKey('s'))
	m = updated.(model)
	if cmd == nil {
		t.Fatal("expected create command")
	}
	msg := cmd()
	done, ok := msg.(taskActionDoneMsg)
	if !ok || done.err != nil {
		t.Fatalf("expected successful create result, got %#v ok=%v", msg, ok)
	}
	if m.taskForm != nil {
		t.Fatal("expected create form to close after submit")
	}
	if len(client.created) != 1 {
		t.Fatalf("expected one created task, got %#v", client.created)
	}
	if client.created[0].Title != "Ship cockpit form" || client.created[0].Description != "Detailed body" {
		t.Fatalf("unexpected created task: %#v", client.created[0])
	}
}

func TestQuickAddTaskSubmitsTitleOnEnter(t *testing.T) {
	client := &mutableClient{}
	m := newModel(client)
	m.width = 120
	m.height = 24

	updated, _ := m.Update(keyPress("N"))
	m = updated.(model)
	if m.taskForm == nil || !m.taskForm.quick {
		t.Fatal("expected quick-add form")
	}
	for _, r := range "Quick cockpit task" {
		updated, _ = m.Update(keyPress(string(r)))
		m = updated.(model)
	}
	updated, cmd := m.Update(specialKey(tea.KeyEnter))
	m = updated.(model)
	if cmd == nil {
		t.Fatal("expected quick-add create command")
	}
	msg := cmd()
	done, ok := msg.(taskActionDoneMsg)
	if !ok || done.err != nil {
		t.Fatalf("expected successful quick-add result, got %#v ok=%v", msg, ok)
	}
	if m.taskForm != nil {
		t.Fatal("expected quick-add form to close after submit")
	}
	if len(client.created) != 1 || client.created[0].Title != "Quick cockpit task" || client.created[0].TaskType != "task" || client.created[0].Priority != "P2" {
		t.Fatalf("unexpected quick-add task: %#v", client.created)
	}
}

func TestPRChecksRenderAsAlignedRows(t *testing.T) {
	m := newModel(NewMockClient())
	m.pr = PRStatus{URL: "https://github.com/acme/repo/pull/42", State: "open", Checks: CheckSummary{Passed: 3, Failed: 1, Pending: 2}}

	out := stripANSI(strings.Join(linesText(m.renderPRLines(80, paneVisualFor(true, defaultConfig().Cockpit.Focus))), "\n"))
	for _, want := range []string{"passed", "failed", "pending"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected PR checks table row %q, got:\n%s", want, out)
		}
	}
	if labelColumn(lineContaining(out, "passed"), "passed") != labelColumn(lineContaining(out, "failed"), "failed") {
		t.Fatalf("expected check value columns to align, got:\n%s", out)
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
	m.height = 12
	m.tab = 1

	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	h := m.viewerBodyWindowHeight()
	if h < 3 {
		t.Fatalf("test setup expected room for selected message body, got %d", h)
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

func TestQuestionMarkShowsGeneratedKeymapHelp(t *testing.T) {
	m := newModel(NewMockClient())
	updated, _ := m.handleKey(keyPress("?"))
	m = updated.(model)
	if !m.helpVisible {
		t.Fatalf("expected help view to become visible")
	}
	out := stripANSI(m.renderRight(80))
	for _, want := range []string{"task section", "new task", "omp triage", "gh dash", "gh enhance", "quit"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected generated help to include %q, got:\n%s", want, out)
		}
	}
	updated, _ = m.handleKey(specialKey(tea.KeyEsc))
	m = updated.(model)
	if m.helpVisible {
		t.Fatalf("expected esc to close help view")
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

func TestMotionStatusAndDiffLoadingRespectReducedMotion(t *testing.T) {
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
	m.diffLoading[key] = true

	out := stripANSI(m.renderFrame())
	if !strings.Contains(out, "⠋ live") {
		t.Fatalf("expected status bar to use spinner-backed live indicator, got:\n%s", out)
	}
	if !strings.Contains(out, "⠋ loading diff preview") {
		t.Fatalf("expected diff preview loading state to use spinner, got:\n%s", out)
	}

	cfg := defaultConfig()
	cfg.Cockpit.ReducedMotion = true
	reduced := newModelWithConfig(client, cfg, defaultTools)
	reduced.width = 120
	reduced.height = 20
	reduced.tab = 5
	updated, _ = reduced.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	reduced = updated.(model)
	reduced.diffLoading[key] = true
	out = stripANSI(reduced.renderFrame())
	if strings.Contains(out, "⠋") {
		t.Fatalf("expected reduced motion to suppress spinner frames, got:\n%s", out)
	}
	if !strings.Contains(out, "live") || !strings.Contains(out, "loading diff preview") {
		t.Fatalf("expected reduced motion to keep static status/loading text, got:\n%s", out)
	}
}

func TestSelectedRunningRunShowsLiveClock(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	m = updated.(model)
	if !m.runClockActive || m.runClockRunID != "run-1" {
		t.Fatalf("expected selected running run to arm stopwatch, active=%v run=%q", m.runClockActive, m.runClockRunID)
	}
	out := stripANSI(m.renderRight(80))
	if !strings.Contains(out, "running · 0s") {
		t.Fatalf("expected running header to include live clock, got:\n%s", out)
	}

	cfg := defaultConfig()
	cfg.Cockpit.ReducedMotion = true
	reduced := newModelWithConfig(client, cfg, defaultTools)
	reduced.width = 120
	reduced.height = 20
	updated, _ = reduced.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable()})
	reduced = updated.(model)
	if reduced.runClockActive {
		t.Fatalf("expected reduced motion to avoid arming stopwatch")
	}
	out = stripANSI(reduced.renderRight(80))
	if strings.Contains(out, "running · 0s") {
		t.Fatalf("expected reduced motion header to omit live clock, got:\n%s", out)
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
	created  []Task
	retried  []Run
	reset    []Run
	attached []Run
}

func (c *mutableClient) Runs() []Run { return c.runs }

func (c *mutableClient) Messages(string) []Message { return c.messages }

func TestMetricsTabShowsLoadingStateDuringRefresh(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	m.tab = 7
	updated, _ := m.Update(dataMsg{runs: client.runs, tasks: client.tasks})
	m = updated.(model)
	m.metricsLoading = true
	m.liveSpinner, _ = m.liveSpinner.Update(spinner.TickMsg{})

	out := stripANSI(m.renderRight(80))
	if !strings.Contains(out, "loading metrics") || strings.Contains(out, "• loading metrics") {
		t.Fatalf("expected metrics loading line to use spinner motion frame, got:\n%s", out)
	}

	cfg := defaultConfig()
	cfg.Cockpit.ReducedMotion = true
	reduced := newModelWithConfig(client, cfg, defaultTools)
	reduced.width = 120
	reduced.height = 20
	reduced.tab = 7
	updated, _ = reduced.Update(dataMsg{runs: client.runs, tasks: client.tasks})
	reduced = updated.(model)
	reduced.metricsLoading = true
	out = stripANSI(reduced.renderRight(80))
	if strings.Contains(out, "⠋") || !strings.Contains(out, "loading metrics") {
		t.Fatalf("expected reduced-motion metrics loading text, got:\n%s", out)
	}
}

func (c *mutableClient) Logs(string) []string { return c.logs }

func (c *mutableClient) Reports(string) []Report { return c.reports }

func (c *mutableClient) Files(string) []FileChange { return c.files }

func (c *mutableClient) CreateTask(task Task) error {
	c.created = append(c.created, task)
	return nil
}

func (c *mutableClient) RetryRun(run Run) error {
	c.retried = append(c.retried, run)
	return nil
}

func (c *mutableClient) ResetRun(run Run) error {
	c.reset = append(c.reset, run)
	return nil
}

func (c *mutableClient) AttachRun(run Run) error {
	c.attached = append(c.attached, run)
	return nil
}

func TestMetricsTabRendersOperationalCounters(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Summary: "first"}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	m.tab = 7
	metrics := Metrics{
		Counters: map[string]int{"phases_started": 3, "failures": 1},
		Gauges:   map[string]int{"projection_lag": 0},
		PhaseDuration: []PhaseDuration{
			{RunID: "run-1", PhaseID: "developer", Status: "completed", DurationMS: 90000},
		},
		EmittedAt: "2026-07-11T00:00:00Z",
	}
	updated, _ := m.Update(dataMsg{runs: client.Runs(), tasks: client.Dispatchable(), metrics: metrics})
	m = updated.(model)

	out := strings.Join(linesText(renderMetricsLines(metrics, 80, paneVisualFor(true, defaultConfig().Cockpit.Focus))), "\n")
	for _, want := range []string{"fleet metrics", "phases started", "projection lag", "developer", "compl", "90"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected metrics view to include %q, got:\n%s", want, out)
		}
	}
}

func TestMouseClickSelectsTaskSection(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "run-task", RunID: "run-1"}}
	m.tasks = []Task{{TaskID: "ready-task"}}
	m.buildItems()

	updated, _ := m.Update(mouseClick(14, 2))
	m = updated.(model)
	if section := m.taskList.ActiveSection().Name; section != taskSectionReady {
		t.Fatalf("expected click on Ready tab to select Ready, got %q", section)
	}
	if items := m.taskList.Items(); len(items) != 1 || !items[0].IsTask {
		t.Fatalf("expected Ready click to show ready task, got %#v", items)
	}
}

func TestMouseClickSelectsTaskRow(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = []Run{
		{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a"},
		{Group: taskGroupRunning, TaskID: "task-b", RunID: "run-b"},
	}
	m.tasks = nil
	m.buildItems()

	updated, _ := m.Update(mouseClick(3, 6))
	m = updated.(model)
	if it, ok := m.selectedItem(); !ok || it.Run.RunID != "run-b" {
		t.Fatalf("expected click on second visible row to select run-b, got ok=%v item=%#v", ok, it)
	}
}

func TestMouseClickTaskRowAccountsForScrolledViewport(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 12
	m.runs = nil
	m.tasks = nil
	for i := 0; i < 12; i++ {
		m.runs = append(m.runs, Run{Group: taskGroupRunning, TaskID: "task-" + itoa(i), RunID: "run-" + itoa(i)})
	}
	m.buildItems()
	m.taskList.selected = 9
	want := m.taskListTopIndex()
	if want <= 0 {
		t.Fatalf("expected viewport to scroll before click, top index=%d", want)
	}

	updated, _ := m.Update(mouseClick(3, 4))
	m = updated.(model)
	if got := m.taskList.SelectedIndex(); got != want {
		t.Fatalf("expected click on first visible row to select index %d, got %d", want, got)
	}
}

func TestMouseClickSelectsRunDetailTab(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = []Run{{Group: taskGroupRunning, TaskID: "task-a", RunID: "run-a", Pipeline: pipe(1, -1)}}
	m.tasks = nil
	m.msgs = []Message{{From: "qa", To: "dev", Body: "body"}}
	m.buildItems()

	tabY := m.rightTabLineY()
	messagesX := m.leftPaneWidth() + 12
	updated, _ := m.Update(mouseClick(messagesX, tabY))
	m = updated.(model)
	if tabNameAt(m.tab) != "messages" || !m.viewFocused {
		t.Fatalf("expected click on messages tab to select focused messages tab, got tab=%s focused=%v", tabNameAt(m.tab), m.viewFocused)
	}
}

func TestMouseActionHitTestingCoversTaskActions(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = nil
	m.tasks = []Task{{TaskID: "task-ready", Title: "Ready task", Status: "backlog"}}
	m.taskList.MoveSection(1)
	m.buildItems()

	startY := m.height - 3 - m.actionLineCount()
	x := m.leftPaneWidth() + 2
	copyX := x + len("▸ task actions task-ready  ")
	if key := m.actionKeyAt(copyX, startY); key != "y" {
		t.Fatalf("expected first task action segment to copy id, got %q", key)
	}
	if key := m.actionKeyAt(x, startY+1); key != "a" {
		t.Fatalf("expected second task action line to approve, got %q", key)
	}
	if key := m.actionKeyAt(x+len("a approve  "), startY+1); key != "e" {
		t.Fatalf("expected edit task action segment, got %q", key)
	}
	if key := m.actionKeyAt(x+len("a approve  e edit  n new task form  "), startY+1); key != "N" {
		t.Fatalf("expected quick-add task action segment, got %q", key)
	}
}

func TestMouseActionHitTestingCoversFilesPRAndRunActions(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 22
	m.runs = []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer", Worktree: "/tmp/work"}}
	m.files = []FileChange{{Change: "M", Path: "src/a.go"}}
	m.buildItems()
	m.tab = 5 // files
	m.refreshViewer(viewerReset)

	startY := m.height - 3 - m.actionLineCount()
	x := m.leftPaneWidth() + 2
	if key := m.actionKeyAt(x, startY+1); key != "o" {
		t.Fatalf("expected files open action, got %q", key)
	}
	if key := m.actionKeyAt(x, startY+4); key != "D" {
		t.Fatalf("expected full diff action, got %q", key)
	}
	if key := m.actionKeyAt(x+len("▸ run actions run-1  A attach  "), startY+5); key != "r" {
		t.Fatalf("expected run retry action segment, got %q", key)
	}

	m.tab = 6 // pr
	m.pr = PRStatus{URL: "https://github.com/Fortium/foreman/pull/42"}
	startY = m.height - 3 - m.actionLineCount()
	if key := m.actionKeyAt(x+len("▸ PR actions o/enter open PR in browser  "), startY); key != "G" {
		t.Fatalf("expected gh dash PR action segment, got %q", key)
	}
	if key := m.actionKeyAt(x+len("▸ PR actions o/enter open PR in browser  G open gh dash  "), startY); key != "C" {
		t.Fatalf("expected gh enhance PR action segment, got %q", key)
	}
}

func TestRunActionKeysExecuteCockpitCommands(t *testing.T) {
	client := &mutableClient{
		runs: []Run{{Group: "RUNNING", TaskID: "task-1", RunID: "run-1", Status: "running", Phase: "developer"}},
	}
	m := newModel(client)
	m.width = 120
	m.height = 20
	m.runs = client.runs
	m.tasks = nil
	m.buildItems()

	updated, cmd := m.handleKey(keyPress("A"))
	m = updated.(model)
	if cmd == nil {
		t.Fatal("expected attach command")
	}
	if msg, ok := cmd().(runActionDoneMsg); !ok || msg.err != nil || msg.action != "attach requested" {
		t.Fatalf("expected attach done message, got %#v", msg)
	}
	if len(client.attached) != 1 || client.attached[0].RunID != "run-1" {
		t.Fatalf("expected attach to target selected run, got %#v", client.attached)
	}

	updated, cmd = m.handleKey(keyPress("r"))
	m = updated.(model)
	if cmd == nil {
		t.Fatal("expected retry command")
	}
	if msg, ok := cmd().(runActionDoneMsg); !ok || msg.err != nil || msg.action != "retry requested" {
		t.Fatalf("expected retry done message, got %#v", msg)
	}
	if len(client.retried) != 1 || client.retried[0].TaskID != "task-1" {
		t.Fatalf("expected retry to target selected task, got %#v", client.retried)
	}

	_, cmd = m.handleKey(keyPress("R"))
	if cmd == nil {
		t.Fatal("expected reset command")
	}
	if msg, ok := cmd().(runActionDoneMsg); !ok || msg.err != nil || msg.action != "reset requested" {
		t.Fatalf("expected reset done message, got %#v", msg)
	}
	if len(client.reset) != 1 || client.reset[0].TaskID != "task-1" {
		t.Fatalf("expected reset to target selected task, got %#v", client.reset)
	}
}
func TestAutoTaskListWidthUsesDashLikeProportion(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 160
	if got := m.leftPaneWidth(); got != 92 {
		t.Fatalf("expected auto task list width to use 58%% dash-like width at 160 columns, got %d", got)
	}
}

func TestConfiguredTaskListWidthUsesPercentage(t *testing.T) {
	cfg := defaultConfig()
	cfg.Cockpit.TaskList.Width = "58%"
	m := newModelWithConfig(NewMockClient(), cfg, defaultTools)
	m.width = 160
	if got := m.leftPaneWidth(); got != 92 {
		t.Fatalf("expected 58%% configured left pane width to be 92 columns, got %d", got)
	}
}

func TestFocusedTaskDetailUsesScrollableViewer(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 12
	m.runs = nil
	m.tasks = []Task{{TaskID: "task-ready", Title: "Ready task", Description: strings.Repeat("line\n", 30), Status: "backlog"}}
	m.taskList.MoveSection(1)
	m.buildItems()
	updated, _ := m.handleKey(specialKey(tea.KeyEnter))
	m = updated.(model)
	if !m.viewFocused || !m.detailUsesViewer() {
		t.Fatalf("expected enter on task to focus scrollable detail viewer")
	}
	m.refreshViewer(viewerReset)
	start := m.viewer.Cursor()
	updated, _ = m.handleKey(specialKey(tea.KeyDown))
	m = updated.(model)
	if m.viewer.Cursor() <= start {
		t.Fatalf("expected focused task detail viewer to scroll, cursor %d -> %d", start, m.viewer.Cursor())
	}
}

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

func TestInactiveViewerBodyUsesMutedVisual(t *testing.T) {
	m := newModel(NewMockClient())
	m.runs = NewMockClient().Runs()
	m.tasks = NewMockClient().Dispatchable()
	m.buildItems()
	m.loadDetail()
	run, isRun := m.selectedRun()
	it, ok := m.selectedItem()
	if !ok || !isRun {
		t.Fatal("expected selected run")
	}

	active := strings.Join(linesText(m.renderViewerLines(run, it, isRun, 80, paneVisualFor(true, m.config.Cockpit.Focus))), "\n")
	inactive := strings.Join(linesText(m.renderViewerLines(run, it, isRun, 80, paneVisualFor(false, m.config.Cockpit.Focus))), "\n")
	if stripANSI(active) != stripANSI(inactive) {
		t.Fatalf("focus dimming should not change visible text:\nactive=%s\ninactive=%s", active, inactive)
	}
	if active == inactive {
		t.Fatalf("expected inactive viewer body to use different ANSI styling")
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
