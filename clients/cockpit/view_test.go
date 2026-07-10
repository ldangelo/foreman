package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestViewerCentersSelectedRowWhenPossible(t *testing.T) {
	var viewer Viewer
	lines := make([]ViewerLine, 30)
	for i := range lines {
		lines[i] = ViewerLine{Key: itoa(i), Text: itoa(i)}
	}

	viewer.SetLines(lines, viewerReset, 7)
	viewer.Move(10, 7)

	if viewer.Cursor() != 10 {
		t.Fatalf("expected selected row 10, got %d", viewer.Cursor())
	}
	if viewer.Offset() != 7 {
		t.Fatalf("expected selected row centered with offset 7, got %d", viewer.Offset())
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

func TestReadyTaskViewShowsApproveAndEditActions(t *testing.T) {
	m := newModel(NewMockClient())
	m.width = 120
	m.height = 20
	m.runs = nil
	m.tasks = []Task{{TaskID: "task-ready", Title: "Ready task", Status: "backlog", ProjectID: "proj-live"}}
	m.buildItems()

	out := stripANSI(m.View())
	if !strings.Contains(out, "task actions task-ready") {
		t.Fatalf("expected task action panel, got:\n%s", out)
	}
	if !strings.Contains(out, "y copy task id") || !strings.Contains(out, "a approve") || !strings.Contains(out, "e edit") {
		t.Fatalf("expected copy, approve, and edit action hints, got:\n%s", out)
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

	updated, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Fatalf("enter should focus the view, not open a command")
	}
	m = updated.(model)
	if !m.viewFocused {
		t.Fatalf("expected enter to focus the drill-down view")
	}

	bottomRow := m.viewer.Cursor()
	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-2 {
		t.Fatalf("expected focused k to move viewer cursor only, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-2)
	}

	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyUp})
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-4 {
		t.Fatalf("expected focused up to move viewer cursor only, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-4)
	}

	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	m = updated.(model)
	if m.taskList.SelectedIndex() != 0 || m.viewer.Cursor() != bottomRow-2 {
		t.Fatalf("expected focused down to move viewer cursor only, got sel=%d row=%d want row=%d", m.taskList.SelectedIndex(), m.viewer.Cursor(), bottomRow-2)
	}

	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	m = updated.(model)
	if m.viewFocused {
		t.Fatalf("expected escape to return focus to the task list")
	}

	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
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

	updated, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyTab})
	m = updated.(model)
	if m.tab != 1 || !m.viewFocused {
		t.Fatalf("expected tab to messages to focus the viewer, got tab=%d focused=%v", m.tab, m.viewFocused)
	}

	bottomRow := m.viewer.Cursor()
	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
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
	updated, _ := m.Update(tea.MouseMsg{
		X:      m.leftPaneWidth() + 5,
		Y:      5,
		Type:   tea.MouseWheelUp,
		Button: tea.MouseButtonWheelUp,
		Action: tea.MouseActionPress,
	})
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

	updated, _ := m.Update(tea.MouseMsg{
		X:      5,
		Y:      5,
		Type:   tea.MouseWheelDown,
		Button: tea.MouseButtonWheelDown,
		Action: tea.MouseActionPress,
	})
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
		updated, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
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

func TestCtrlCDoesNotQuit(t *testing.T) {
	m := newModel(NewMockClient())
	if _, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyCtrlC}); cmd != nil {
		t.Fatalf("ctrl+c should not quit; q is the only quit key")
	}
	if _, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}}); cmd == nil {
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
	if h := m.viewerBodyWindowHeight(); m.viewer.Offset() > m.viewer.Cursor() || m.viewer.Cursor() >= m.viewer.Offset()+h {
		t.Fatalf("expected bottom message header visible, got cursor=%d offset=%d height=%d", m.viewer.Cursor(), m.viewer.Offset(), h)
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

	m.resetViewerCursor()
	for range 2 {
		updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
		m = updated.(model)
		if m.viewer.Offset() != m.viewer.Cursor() {
			t.Fatalf("expected tiny viewport to show selected header while moving down, got cursor=%d offset=%d", m.viewer.Cursor(), m.viewer.Offset())
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

			updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
			m = updated.(model)
			updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
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
	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = updated.(model)
	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
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

	if m.viewer.Cursor() != 0 || m.viewer.Offset() != 0 {
		t.Fatalf("expected shrink to clamp to remaining message header, got row=%d offset=%d", m.viewer.Cursor(), m.viewer.Offset())
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
	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	m = updated.(model)
	if got := resolveTarget(m); !got.ok || got.label != "review.md" || got.path != "/tmp/work/docs/reports/task-1/review.md" {
		t.Fatalf("expected report target to follow cursor, got %#v", got)
	}

	m.tab = 5
	m.selectInitialViewerLine()
	if !m.selectViewerLineByKey("file:src/a.go") {
		t.Fatalf("test setup could not select first file")
	}
	updated, _ = m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
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
	out := stripANSI(m.View())
	if !strings.Contains(out, "pr 1") || !strings.Contains(out, "https://github.com/acme/repo/pull/42") || !strings.Contains(out, "open PR in browser") {
		t.Fatalf("expected PR tab status and browser action, got:\n%s", out)
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
	_, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected enter on PR tab to attempt opening the PR")
	}
	msg := cmd()
	if _, ok := msg.(prOpenDoneMsg); !ok {
		t.Fatalf("expected prOpenDoneMsg, got %T", msg)
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
	out := stripANSI(m.View())
	if !strings.Contains(out, "diff --git a/src/a.go b/src/a.go") || !strings.Contains(out, "+added") {
		t.Fatalf("expected selected file diff preview, got:\n%s", out)
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

func assertViewHeight(t *testing.T, m model) {
	t.Helper()
	out := stripANSI(m.View())
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
