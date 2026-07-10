package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/glamour"
)

var tabNames = []string{"summary", "messages", "events", "logs", "reports", "files", "pr"}

type model struct {
	client Client
	config Config
	editor EditorConfig
	tools  ToolResolver
	glam   *glamour.TermRenderer

	runs     []Run
	tasks    []Task
	taskList TaskList

	// detail for the selected run
	msgs    []Message
	events  []Event
	logs    []string
	reports []Report
	files   []FileChange
	pr      PRStatus

	diffPreviews map[string]DiffPreview
	diffLoading  map[string]bool

	tab         int
	viewer      Viewer
	viewFocused bool

	width, height int
	anim          int
	notice        string
}

// messages
type tickMsg time.Time
type dataMsg struct {
	runs   []Run
	tasks  []Task
	errors []string
}
type nvimDoneMsg struct {
	err    error
	remote bool
	label  string
}
type taskActionDoneMsg struct {
	action string
	taskID string
	err    error
}
type prOpenDoneMsg struct {
	err error
}
type taskCopyDoneMsg struct {
	taskID string
	err    error
}
type viewerSavedMsg struct {
	path string
	err  error
}

func newModel(c Client) model {
	return newModelWithConfig(c, defaultConfig(), defaultTools)
}

func newModelWithConfig(c Client, cfg Config, tools ToolResolver) model {
	r := newGlamourRenderer()
	return model{
		client:       c,
		config:       cfg,
		editor:       cfg.Editor,
		tools:        tools,
		glam:         r,
		taskList:     NewTaskList(),
		tab:          0,
		diffPreviews: map[string]DiffPreview{},
		diffLoading:  map[string]bool{},
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(loadData(m.client), tick())
}

func tick() tea.Cmd {
	return tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func loadData(c Client) tea.Cmd {
	return func() tea.Msg {
		runs := c.Runs()
		tasks := c.Dispatchable()
		return dataMsg{runs: runs, tasks: tasks, errors: c.DrainErrors()}
	}
}

const mouseWheelStep = 3

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if m.viewerTab() {
			m.refreshViewer(viewerPreserve)
		}
		return m, nil
	case tea.MouseMsg:
		return m.handleMouse(msg)
	case tickMsg:

		m.anim++
		return m, tea.Batch(loadData(m.client), tick())

	case dataMsg:
		hadViewerRows := m.viewerTab() && m.rowCount() > 0
		m.runs, m.tasks = msg.runs, msg.tasks
		m.buildItems()
		m.loadDetail()
		var cmd tea.Cmd
		if m.viewerTab() {
			if hadViewerRows {
				m.refreshViewer(viewerPreserve)
			} else {
				m.refreshViewer(viewerBottom)
			}
			cmd = m.maybeLoadSelectedDiffPreview()
		}
		if len(msg.errors) > 0 {
			m.notice = formatClientErrors(msg.errors)
		}
		return m, cmd

	case nvimDoneMsg:
		if msg.err != nil {
			m.notice = "nvim: " + msg.err.Error()
		} else if msg.remote {
			m.notice = "opened " + msg.label + " in your nvim session"
		} else {
			m.notice = "closed nvim (" + msg.label + ")"
		}
		return m, nil

	case taskActionDoneMsg:
		label := msg.taskID
		if label == "" {
			label = "task"
		}
		if msg.err != nil {
			m.notice = msg.action + " " + label + ": " + msg.err.Error()
			return m, nil
		}
		m.notice = label + " " + msg.action
		return m, loadData(m.client)

	case taskCopyDoneMsg:
		if msg.err != nil {
			m.notice = "copy " + msg.taskID + ": " + msg.err.Error()
		} else {
			m.notice = "copied task id " + msg.taskID
		}
		return m, nil

	case diffnavDoneMsg:
		if msg.err != nil {
			m.notice = "diffnav: " + msg.err.Error()
		} else {
			m.notice = "closed diffnav"
		}
		return m, nil

	case ghDashDoneMsg:
		if msg.err != nil {
			m.notice = "gh dash: " + msg.err.Error()
		} else {
			m.notice = "closed gh dash"
		}
		return m, nil

	case ghEnhanceDoneMsg:
		if msg.err != nil {
			m.notice = "gh enhance: " + msg.err.Error()
		} else {
			m.notice = "closed gh enhance"
		}
		return m, nil
	case ompDoneMsg:
		if msg.err != nil {
			m.notice = "omp: " + msg.err.Error()
		} else if msg.mode == "tmux" {
			m.notice = "opened omp in tmux pane"
		} else {
			m.notice = "closed omp"
		}
		return m, nil

	case diffPreviewMsg:
		if m.diffPreviews == nil {
			m.diffPreviews = map[string]DiffPreview{}
		}
		if m.diffLoading != nil {
			delete(m.diffLoading, msg.key)
		}
		m.diffPreviews[msg.key] = msg.preview
		if m.viewerTab() {
			m.refreshViewer(viewerPreserve)
		}
		return m, nil

	case prOpenDoneMsg:
		if msg.err != nil {
			m.notice = "open PR: " + msg.err.Error()
		} else {
			m.notice = "opened PR in browser"
		}
		return m, nil

	case viewerSavedMsg:
		if msg.err != nil {
			m.notice = "save viewer: " + msg.err.Error()
		} else {
			m.notice = "saved viewer to " + msg.path
		}
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if m.taskList.Searching() || (m.taskList.Search() != "" && msg.String() == "esc") {
		changed, cmd := m.taskList.HandleSearchKey(msg)
		if changed {
			m.buildItems()
		}
		return m, cmd
	}

	if m.viewFocused && m.viewerTab() {
		if m.viewer.Searching() || msg.String() == "/" ||
			(m.viewer.FilterActive() && (msg.String() == "n" || msg.String() == "N" || msg.String() == "o" || msg.String() == "esc")) {
			return m, m.viewer.HandleKey(msg)
		}
	}

	if m.viewFocused {
		switch msg.String() {
		case "ctrl+d":
			return m, m.moveRow(max(1, m.viewerBodyWindowHeight()/2))
		case "ctrl+u":
			return m, m.moveRow(-max(1, m.viewerBodyWindowHeight()/2))
		case "left":
			m.viewer.Pan(-max(1, m.rightPaneWidth()/4))
			return m, nil
		case "right":
			m.viewer.Pan(max(1, m.rightPaneWidth()/4))
			return m, nil
		case "s":
			if m.viewerTab() {
				return m, m.saveVisibleViewer()
			}
		}
	}

	switch msg.String() {
	case "?":
		m.notice = "keys: n new task · enter focus · esc task list/clear search · ctrl+d/u page · / search · n/N match · ←/→ pan · s save · o open · G gh dash · C gh enhance"
	case "q":
		return m, tea.Quit
	case "esc":
		if m.viewFocused {
			m.viewFocused = false
		}
	case "up":
		if m.viewFocused {
			return m, m.moveRow(-1)
		}
		return m, m.moveSel(-1)
	case "down":
		if m.viewFocused {
			return m, m.moveRow(1)
		}
		return m, m.moveSel(1)
	case "k":
		if m.viewFocused {
			return m, m.moveRow(-1)
		}
		return m, m.moveSel(-1)
	case "j":
		if m.viewFocused {
			return m, m.moveRow(1)
		}
		return m, m.moveSel(1)
	case "tab":
		return m, m.selectTab((m.tab + 1) % len(tabNames))
	case "shift+tab":
		return m, m.selectTab((m.tab - 1 + len(tabNames)) % len(tabNames))
	case "1", "2", "3", "4", "5", "6", "7":
		return m, m.selectTab(int(msg.String()[0] - '1'))
	case "/":
		m.viewFocused = false
		return m, m.taskList.StartSearch(msg)
	case "g":
		m.notice = "scope: " + m.taskList.ToggleScope()
		m.buildItems()
	case " ", "space":
		m.taskList.ToggleSelectedGroup()
		m.buildItems()
	case "o":
		if tabNames[m.tab] == "pr" {
			return m, m.openSelectedPR()
		}
		if m.openableTab() {
			t := resolveTarget(m)
			return m, openInNvim(m.editor, t, false)
		}
	case "enter":
		if tabNames[m.tab] == "pr" {
			return m, m.openSelectedPR()
		}
		if m.viewerTab() {
			if !m.viewFocused {
				m.scrollToBottom()
			}
			m.viewFocused = true
			return m, m.maybeLoadSelectedDiffPreview()
		}
		if run, ok := m.selectedRun(); ok {
			m.notice = "attach → GET /api/v1/runs/" + run.RunID + "/attach"
		}
	case "n":
		return m, createTaskInNvim(m.editor, m.client)
	case "a":
		if task, ok := m.selectedTask(); ok {
			return m, approveTask(m.client, task)
		}
	case "e":
		if task, ok := m.selectedTask(); ok {
			return m, editTaskInNvim(m.editor, m.client, task)
		}
	case "y":
		if taskID, ok := m.selectedTaskID(); ok {
			return m, copyTaskID(taskID)
		}
	case "d":
		if tabNames[m.tab] == "files" {
			t := resolveTarget(m)
			return m, openInNvim(m.editor, t, true)
		}
	case "D":
		if tabNames[m.tab] == "files" {
			if run, ok := m.selectedRun(); ok {
				return m, openInDiffnav(run, m.config.Integrations, m.tools)
			}
		}
	case "G":
		return m, openGhDash(m.config.Integrations, m.tools)
	case "C":
		if run, ok := m.selectedRun(); ok {
			return m, openGhEnhance(run, m.config.Integrations, m.tools)
		}
		m.notice = "gh enhance: no run selected"
	case "p":
		if run, ok := m.selectedRun(); ok {
			return m, attachOmp(m, run, false)
		}
		m.notice = "omp: no run selected"
	case "P":
		if run, ok := m.selectedRun(); ok {
			return m, attachOmp(m, run, true)
		}
		m.notice = "omp: no run selected"
	case "r":
		if run, ok := m.selectedRun(); ok {
			m.notice = "retry queued → POST /api/v1/commands (run " + run.RunID + ")"
		}
	case "R":
		if run, ok := m.selectedRun(); ok {
			m.notice = "reset requested (confirm) → run " + run.RunID
		}
	}
	return m, nil
}

func (m model) saveVisibleViewer() tea.Cmd {
	content := strings.TrimRight(stripANSI(m.viewer.View()), "\n") + "\n"
	runID := "task"
	if run, ok := m.selectedRun(); ok && run.RunID != "" {
		runID = run.RunID
	}
	name := runID + "-" + tabNames[m.tab] + "-" + time.Now().Format("20060102-150405") + ".txt"
	return saveViewerContent(m.config.Cockpit.ExportDir, name, content)
}

func saveViewerContent(dir, name, content string) tea.Cmd {
	return func() tea.Msg {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return viewerSavedMsg{err: err}
		}
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			return viewerSavedMsg{path: path, err: err}
		}
		return viewerSavedMsg{path: path}
	}
}

func (m *model) moveSel(delta int) tea.Cmd {
	if !m.taskList.Move(delta) {
		return nil
	}
	m.resetViewerCursor()
	m.loadDetail()
	if m.viewerTab() {
		m.scrollToBottom()
	}
	return m.maybeLoadSelectedDiffPreview()
}

func (m *model) moveRow(delta int) tea.Cmd {
	m.refreshViewer(viewerPreserve)
	m.viewer.Move(delta, m.viewerBodyWindowHeight())
	if tabNames[m.tab] == "reports" || tabNames[m.tab] == "files" {
		m.refreshViewer(viewerPreserve)
	}
	return m.maybeLoadSelectedDiffPreview()
}

func (m *model) resetViewerCursor() {
	m.refreshViewer(viewerReset)
}

func (m *model) scrollToBottom() {
	m.refreshViewer(viewerBottom)
}

func (m *model) selectTab(tab int) tea.Cmd {
	m.tab = tab
	m.selectInitialViewerLine()
	m.viewFocused = m.viewerTab()
	return m.maybeLoadSelectedDiffPreview()
}

func (m *model) selectInitialViewerLine() {
	if m.viewerTab() {
		m.refreshViewer(viewerBottom)
	} else {
		m.viewer.SetLines(nil, viewerReset, m.viewerBodyWindowHeight())
	}
}

func (m *model) clampViewerCursor() {
	m.refreshViewer(viewerPreserve)
}

func (m model) viewerCursorKey() string {
	return m.viewer.SelectedKey()
}

func (m *model) selectViewerLineByKey(key string) bool {
	if key == "" {
		return false
	}
	m.refreshViewer(viewerPreserve)
	return m.viewer.SelectKey(key, m.viewerBodyWindowHeight())
}

func (m model) maxViewerScroll() int {
	return m.viewer.MaxScroll(m.viewerBodyWindowHeight())
}

func (m *model) rowCount() int {
	if !m.viewerTab() {
		return 0
	}
	m.refreshViewer(viewerPreserve)
	return m.viewer.Len()
}

func (m model) viewerBodyLines() []string {
	return m.viewer.TextLines()
}

func (m *model) refreshViewer(policy viewerRefreshPolicy) {
	w := m.rightPaneWidth()
	h := m.viewerBodyWindowHeight()
	m.viewer.SetWrapText(tabNames[m.tab] != "logs")
	m.viewer.SetBounds(w, h)
	if !m.viewerTab() {
		m.viewer.SetLines(nil, viewerReset, h)
		return
	}
	m.viewer.SetLines(m.buildViewerLines(w), policy, h)
}

func (m model) buildViewerLines(w int) []ViewerLine {
	run, isRun := m.selectedRun()
	it, ok := m.selectedItem()
	if !ok {
		return nil
	}
	return m.renderViewerLines(run, it, isRun, w)
}

func (m model) viewerBodyWindowHeight() int {
	w := m.rightPaneWidth()
	_, ok := m.selectedItem()
	if !ok {
		return 1
	}

	run, isRun := m.selectedRun()
	headerLines := 2
	if isRun {
		if run.Attention != "" {
			headerLines++
		}
		headerLines += len(m.renderRail(run, w)) + 1 // rail plus separator
		headerLines += 2                             // tab strip plus spacer
	}

	actionLines := 0
	if !isRun || m.openableTab() || tabNames[m.tab] == "pr" {
		if action := m.renderAction(w); action != "" {
			actionLines = len(strings.Split(action, "\n"))
		}
	}

	bodyH := m.height - 3
	if bodyH < 4 {
		bodyH = 4
	}
	return max(1, bodyH-headerLines-actionLines)
}
func (m model) leftPaneWidth() int {
	total := m.width
	if total < 80 {
		total = 80
	}
	if total < 92 {
		return 22
	}
	return 28
}

func (m model) rightPaneWidth() int {
	return max(20, max(80, m.width)-m.leftPaneWidth()-1)
}

func (m model) mouseOverRightPane(msg tea.MouseMsg) bool {
	mouse := msg.Mouse()
	return mouse.X > m.leftPaneWidth()
}

func (m model) handleMouse(msg tea.MouseMsg) (model, tea.Cmd) {
	ev, ok := msg.(tea.MouseWheelMsg)
	if !ok {
		return m, nil
	}

	mouse := ev.Mouse()
	delta := mouseWheelStep
	if mouse.Button == tea.MouseWheelUp {
		delta = -mouseWheelStep
	}

	if m.mouseOverRightPane(msg) && m.viewerTab() {
		m.viewFocused = true
		return m, m.moveRow(delta)
	}

	m.viewFocused = false
	return m, m.moveSel(delta)
}

func tabNameAt(tab int) string {
	if tab < 0 || tab >= len(tabNames) {
		return ""
	}
	return tabNames[tab]
}

func tabOpenable(name string) bool {
	switch name {
	case "logs", "reports", "files":
		return true
	default:
		return false
	}
}

func tabViewer(name string) bool {
	switch name {
	case "messages", "events", "logs", "reports", "files", "pr":
		return true
	default:
		return false
	}
}

func (m model) viewerTab() bool { return tabViewer(tabNameAt(m.tab)) }

func (m model) openableTab() bool { return tabOpenable(tabNameAt(m.tab)) }

func (m *model) buildItems() {
	m.taskList.SetData(m.runs, m.tasks)
}

func (m model) selectedReportIndex() int {
	if len(m.reports) == 0 {
		return -1
	}
	if line, ok := m.viewer.SelectedLine(); ok {
		if line.Target.ok {
			for i, r := range m.reports {
				if r.Name == line.Target.label {
					return i
				}
			}
		}
		if strings.HasPrefix(line.Key, "report:") {
			name := strings.TrimPrefix(line.Key, "report:")
			for i, r := range m.reports {
				if r.Name == name {
					return i
				}
			}
		}
	}
	return min(m.viewer.Cursor(), len(m.reports)-1)
}

func (m model) selectedFileIndex() int {
	if len(m.files) == 0 {
		return -1
	}
	if line, ok := m.viewer.SelectedLine(); ok {
		if line.Target.ok {
			for i, f := range m.files {
				if f.Path == line.Target.label {
					return i
				}
			}
		}
		if strings.HasPrefix(line.Key, "file:") {
			path := strings.TrimPrefix(line.Key, "file:")
			for i, f := range m.files {
				if f.Path == path {
					return i
				}
			}
		}
	}
	return min(m.viewer.Cursor(), len(m.files)-1)
}

func (m *model) loadDetail() {
	run, ok := m.selectedRun()
	if !ok {
		m.msgs, m.events, m.logs, m.reports, m.files = nil, nil, nil, nil, nil
		m.pr = PRStatus{}
		return
	}
	m.msgs = m.client.Messages(run.RunID)
	m.events = m.client.Events(run.RunID)
	m.logs = m.client.Logs(run.RunID)
	m.reports = m.client.Reports(run.RunID)
	m.files = m.client.Files(run.RunID)
	m.pr = m.client.PR(run.RunID)
	if m.pr.URL == "" {
		base := prStatusFromRun(run)
		if base.URL != "" {
			m.pr = base
		}
	}
	if errors := m.client.DrainErrors(); len(errors) > 0 {
		m.notice = formatClientErrors(errors)
	}
}
func formatClientErrors(errors []string) string {
	if len(errors) == 1 {
		return errors[0]
	}
	return strings.Join(errors, " · ")
}
func (m model) selectedItem() (Item, bool) {
	return m.taskList.SelectedItem()
}
func (m *model) maybeLoadSelectedDiffPreview() tea.Cmd {
	if tabNames[m.tab] != "files" {
		return nil
	}
	run, ok := m.selectedRun()
	if !ok {
		return nil
	}
	idx := m.selectedFileIndex()
	if idx < 0 || idx >= len(m.files) {
		return nil
	}
	path := m.files[idx].Path
	base := selectedDiffBase(m.config.Integrations)
	key := diffPreviewKey(run, path, base)
	if _, ok := m.diffPreviews[key]; ok {
		return nil
	}
	if m.diffLoading == nil {
		m.diffLoading = map[string]bool{}
	}
	if m.diffLoading[key] {
		return nil
	}
	m.diffLoading[key] = true
	return loadDiffPreview(run, path, m.config.Integrations, m.tools)
}

func (m model) openSelectedPR() tea.Cmd {
	cmd, err := openPRCommand(m.pr, m.tools)
	if err != nil {
		return func() tea.Msg { return prOpenDoneMsg{err: err} }
	}
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return prOpenDoneMsg{err: err}
	})
}

func (m model) selectedTask() (Task, bool) {
	it, ok := m.selectedItem()
	if !ok || !it.IsTask {
		return Task{}, false
	}
	return it.Task, true
}

func (m model) selectedTaskID() (string, bool) {
	it, ok := m.selectedItem()
	if !ok {
		return "", false
	}
	if it.IsTask {
		return it.Task.TaskID, it.Task.TaskID != ""
	}
	return it.Run.TaskID, it.Run.TaskID != ""
}

func (m model) selectedRun() (Run, bool) {
	it, ok := m.selectedItem()
	if !ok || it.IsTask {
		return Run{}, false
	}
	return it.Run, true
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
