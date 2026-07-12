package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/stopwatch"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/glamour"
)

var tabNames = []string{"summary", "messages", "events", "logs", "reports", "files", "pr", "metrics"}

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
	msgs           []Message
	events         []Event
	logs           []string
	reports        []Report
	files          []FileChange
	pr             PRStatus
	metrics        Metrics
	metricsLoading bool

	diffPreviews   map[string]DiffPreview
	diffLoading    map[string]bool
	liveSpinner    spinner.Model
	spinnerActive  bool
	runClock       stopwatch.Model
	runClockRunID  string
	runClockActive bool

	tab         int
	viewer      Viewer
	viewFocused bool
	helpVisible bool
	taskForm    *taskCreateForm

	width, height int
	notice        string
}

// messages
type tickMsg time.Time
type dataMsg struct {
	projectID string
	runs      []Run
	tasks     []Task
	metrics   Metrics
	errors    []string
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
type runActionDoneMsg struct {
	action string
	runID  string
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
		client:         c,
		config:         cfg,
		editor:         cfg.Editor,
		tools:          tools,
		glam:           r,
		taskList:       NewTaskListWithSections(cfg.Cockpit.TaskList.Sections),
		metricsLoading: true,
		liveSpinner:    newLiveSpinner(),
		runClock:       stopwatch.New(stopwatch.WithInterval(time.Second)),
		tab:            0,
		diffPreviews:   map[string]DiffPreview{},
		diffLoading:    map[string]bool{},
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(loadData(m.client), tick(), m.syncMotionCmd())
}

func tick() tea.Cmd {
	return tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func loadData(c Client) tea.Cmd {
	return func() tea.Msg {
		runs := c.Runs()
		tasks := c.Dispatchable()
		metrics := c.Metrics()
		return dataMsg{projectID: c.ProjectID(), runs: runs, tasks: tasks, metrics: metrics, errors: c.DrainErrors()}
	}
}

const mouseWheelStep = 3

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if m.detailUsesViewer() {
			m.refreshViewer(viewerPreserve)
		}
		return m, nil
	case tea.MouseMsg:
		return m.handleMouse(msg)
	case tickMsg:
		m.metricsLoading = true
		return m, tea.Batch(loadData(m.client), tick(), m.syncMotionCmd())

	case spinner.TickMsg:
		if !m.shouldAnimate() {
			m.spinnerActive = false
			return m, nil
		}
		var cmd tea.Cmd
		m.liveSpinner, cmd = m.liveSpinner.Update(msg)
		m.spinnerActive = true
		return m, cmd

	case stopwatch.StartStopMsg, stopwatch.ResetMsg, stopwatch.TickMsg:
		var cmd tea.Cmd
		m.runClock, cmd = m.runClock.Update(msg)
		if !m.shouldRunClock() {
			m.runClockActive = false
			if m.runClock.Running() {
				return m, m.runClock.Stop()
			}
			return m, nil
		}
		return m, cmd

	case dataMsg:
		hadViewerRows := m.detailUsesViewer() && m.rowCount() > 0
		m.runs, m.tasks, m.metrics = msg.runs, msg.tasks, msg.metrics
		m.metricsLoading = false
		m.taskList.SetProjectID(msg.projectID)
		m.buildItems()
		m.loadDetail()
		var cmds []tea.Cmd
		if m.detailUsesViewer() {
			if hadViewerRows {
				m.refreshViewer(viewerPreserve)
			} else {
				m.refreshViewer(viewerBottom)
			}
			cmds = append(cmds, m.maybeLoadSelectedDiffPreview())
		}
		if len(msg.errors) > 0 {
			m.notice = formatClientErrors(msg.errors)
		}
		cmds = append(cmds, m.syncMotionCmd())
		return m, tea.Batch(cmds...)

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
	case runActionDoneMsg:
		label := msg.taskID
		if label == "" {
			label = msg.runID
		}
		if label == "" {
			label = "run"
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
		if m.detailUsesViewer() {
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
func newLiveSpinner() spinner.Model {
	return spinner.New(
		spinner.WithSpinner(spinner.MiniDot),
		spinner.WithStyle(lipgloss.NewStyle().Foreground(cCyan)),
	)
}

func (m model) shouldAnimate() bool {
	if m.config.Cockpit.ReducedMotion {
		return false
	}
	if m.hasRunningRuns() {
		return true
	}
	if m.metricsLoading {
		return true
	}
	for _, loading := range m.diffLoading {
		if loading {
			return true
		}
	}
	return false
}

func (m model) hasRunningRuns() bool {
	for _, run := range m.runs {
		if run.Group == taskGroupRunning || strings.EqualFold(run.Status, "running") {
			return true
		}
	}
	return false
}

func (m model) shouldRunClock() bool {
	return !m.config.Cockpit.ReducedMotion && m.selectedRunningRunID() != ""
}

func (m model) selectedRunningRunID() string {
	run, ok := m.selectedRun()
	if !ok {
		return ""
	}
	if run.Group == taskGroupRunning || strings.EqualFold(run.Status, "running") {
		return run.RunID
	}
	return ""
}

func (m model) liveIndicator() string {
	if m.config.Cockpit.ReducedMotion {
		return "live"
	}
	if m.shouldAnimate() {
		return m.liveSpinner.View() + " live"
	}
	return "idle"
}

func (m model) selectedRunClock() string {
	if !m.shouldRunClock() {
		return ""
	}
	if elapsed := strings.TrimSpace(m.runClock.View()); elapsed != "" && elapsed != "0s" {
		return elapsed
	}
	return "0s"
}

func (m *model) syncMotionCmd() tea.Cmd {
	var cmds []tea.Cmd
	if m.shouldAnimate() {
		if !m.spinnerActive {
			m.spinnerActive = true
			cmds = append(cmds, func() tea.Msg { return m.liveSpinner.Tick() })
		}
	} else {
		m.spinnerActive = false
	}

	runID := m.selectedRunningRunID()
	if !m.config.Cockpit.ReducedMotion && runID != "" {
		if runID != m.runClockRunID {
			m.runClockRunID = runID
			m.runClockActive = true
			cmds = append(cmds, m.runClock.Reset(), m.runClock.Start())
		} else if !m.runClockActive {
			m.runClockActive = true
			cmds = append(cmds, m.runClock.Start())
		}
	} else {
		m.runClockRunID = ""
		if m.runClockActive {
			m.runClockActive = false
			cmds = append(cmds, m.runClock.Stop())
		}
	}
	return tea.Batch(cmds...)
}

func (m model) handleTaskFormKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if m.taskForm == nil {
		return m, nil
	}
	switch msg.String() {
	case "esc":
		m.taskForm = nil
		m.notice = "new task cancelled"
		return m, nil
	case "enter":
		if !m.taskForm.quick {
			return m, m.taskForm.Update(msg)
		}
		return m.submitTaskForm()
	case "ctrl+s":
		return m.submitTaskForm()
	default:
		return m, m.taskForm.Update(msg)
	}
}

func (m model) submitTaskForm() (tea.Model, tea.Cmd) {
	task, err := m.taskForm.Task()
	if err != nil {
		m.notice = "create task: " + err.Error()
		return m, nil
	}
	m.taskForm = nil
	return m, createTask(m.client, task)
}

func (m model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if m.taskForm != nil {
		return m.handleTaskFormKey(msg)
	}
	if m.taskList.Searching() || (m.taskList.Search() != "" && msg.String() == "esc") {
		changed, cmd := m.taskList.HandleSearchKey(msg)
		if changed {
			m.buildItems()
		}
		return m, cmd
	}

	if m.viewFocused && m.detailUsesViewer() {
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
			if m.detailAllowsHorizontalPan() {
				m.viewer.Pan(-max(1, m.rightPaneWidth()/4))
			}
			return m, nil
		case "right":
			if m.detailAllowsHorizontalPan() {
				m.viewer.Pan(max(1, m.rightPaneWidth()/4))
			}
			return m, nil
		case "s":
			if m.detailUsesViewer() {
				return m, m.saveVisibleViewer()
			}
		}
	}

	switch msg.String() {
	case "?":
		m.helpVisible = !m.helpVisible
		if m.helpVisible {
			m.notice = "help: generated keymap"
		} else {
			m.notice = ""
		}
	case "q":
		return m, tea.Quit
	case "esc":
		if m.helpVisible {
			m.helpVisible = false
			return m, nil
		}
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
	case "[", "H":
		if m.viewFocused {
			return m, nil
		}
		return m, m.moveTaskSection(-1)
	case "]", "L":
		if m.viewFocused {
			return m, nil
		}
		return m, m.moveTaskSection(1)
	case "tab":
		return m, m.selectTab((m.tab + 1) % len(tabNames))
	case "shift+tab":
		return m, m.selectTab((m.tab - 1 + len(tabNames)) % len(tabNames))
	case "1", "2", "3", "4", "5", "6", "7", "8":
		return m, m.selectTab(int(msg.String()[0] - '1'))
	case "/":
		m.viewFocused = false
		return m, m.taskList.StartSearch(msg)
	case "g":
		m.notice = "scope: " + m.taskList.ToggleScope()
		m.buildItems()
		return m, m.reloadSelectedDetail()
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
		if m.detailUsesViewer() {
			if !m.viewFocused {
				m.scrollToBottom()
			}
			m.viewFocused = true
			return m, m.maybeLoadSelectedDiffPreview()
		}
		if run, ok := m.selectedRun(); ok {
			return m, attachRun(m.client, run)
		}
	case "n":
		if m.viewFocused {
			return m, nil
		}
		form := newTaskCreateForm()
		m.taskForm = &form
		m.viewFocused = true
		m.notice = "new task: ctrl+s create · esc cancel"
		return m, nil
	case "N":
		if m.viewFocused {
			return m, nil
		}
		form := newTaskQuickAddForm()
		m.taskForm = &form
		m.viewFocused = true
		m.notice = "quick task: enter create · esc cancel"
		return m, nil
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
	case "A":
		if run, ok := m.selectedRun(); ok {
			return m, attachRun(m.client, run)
		}
		m.notice = "attach: no run selected"
	case "r":
		if run, ok := m.selectedRun(); ok {
			return m, retryRun(m.client, run)
		}
		m.notice = "retry: no run selected"
	case "R":
		if run, ok := m.selectedRun(); ok {
			return m, resetRun(m.client, run)
		}
		m.notice = "reset: no run selected"
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
	return m.reloadSelectedDetail()
}

func (m *model) moveTaskSection(delta int) tea.Cmd {
	m.notice = "section: " + m.taskList.MoveSection(delta)
	m.buildItems()
	return m.reloadSelectedDetail()
}

func (m *model) reloadSelectedDetail() tea.Cmd {
	m.resetViewerCursor()
	m.loadDetail()
	if m.detailUsesViewer() {
		m.scrollToBottom()
	}
	return tea.Batch(m.maybeLoadSelectedDiffPreview(), m.syncMotionCmd())
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
	m.viewFocused = m.detailUsesViewer()
	return tea.Batch(m.maybeLoadSelectedDiffPreview(), m.syncMotionCmd())
}

func (m *model) selectInitialViewerLine() {
	if m.detailUsesViewer() {
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

func (m *model) rowCount() int {
	if !m.detailUsesViewer() {
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
	if !m.detailUsesViewer() {
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
	return m.renderViewerLines(run, it, isRun, w, paneVisualFor(m.viewFocused, m.config.Cockpit.Focus))
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
		headerLines += len(m.renderRail(run, w, paneVisualFor(m.viewFocused, m.config.Cockpit.Focus))) + 1 // rail plus separator
		headerLines += 2                                                                                   // tab strip plus spacer
	}

	actionLines := 0
	if action := m.renderAction(w, paneVisualFor(m.viewFocused, m.config.Cockpit.Focus)); action != "" {
		actionLines = len(strings.Split(action, "\n"))
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
	return configuredLeftPaneWidth(total, m.config.Cockpit.TaskList)
}

func (m model) rightPaneWidth() int {
	return max(20, max(80, m.width)-m.leftPaneWidth()-1)
}

func (m model) mouseOverRightPane(msg tea.MouseMsg) bool {
	mouse := msg.Mouse()
	return mouse.X > m.leftPaneWidth()
}

func (m model) handleMouse(msg tea.MouseMsg) (model, tea.Cmd) {
	mouse := msg.Mouse()
	if click, ok := msg.(tea.MouseClickMsg); ok && click.Button == tea.MouseLeft {
		if mouse.X <= m.leftPaneWidth() && mouse.Y >= 1 && mouse.Y <= 3 {
			if idx := m.taskSectionIndexAt(mouse.X - 1); idx >= 0 {
				m.taskList.section = idx
				m.taskList.selected = 0
				m.viewFocused = false
				m.notice = "section: " + m.taskList.ActiveSection().Name
				m.buildItems()
				return m, m.reloadSelectedDetail()
			}
		} else if mouse.X <= m.leftPaneWidth() {
			if idx := m.taskRowIndexAt(mouse.Y); idx >= 0 {
				m.taskList.selected = idx
				m.viewFocused = false
				m.loadDetail()
				return m, nil
			}
		}
		if m.mouseOverRightPane(msg) && mouse.Y == m.rightTabLineY() {
			if idx := m.rightTabIndexAt(mouse.X); idx >= 0 {
				return m, m.selectTab(idx)
			}
		}
		if key := m.actionKeyAt(mouse.X, mouse.Y); key != "" {
			updated, cmd := m.handleKey(actionKeyPress(key))
			return updated.(model), cmd
		}
		if m.mouseOverRightPane(msg) && m.detailUsesViewer() {
			m.viewFocused = true
			return m, nil
		}
		m.viewFocused = false
		return m, nil
	}

	_, ok := msg.(tea.MouseWheelMsg)
	if !ok {
		return m, nil
	}

	delta := mouseWheelStep
	if mouse.Button == tea.MouseWheelUp {
		delta = -mouseWheelStep
	}

	if m.mouseOverRightPane(msg) && m.detailUsesViewer() {
		m.viewFocused = true
		return m, m.moveRow(delta)
	}

	m.viewFocused = false
	return m, m.moveSel(delta)
}

func (m model) taskSectionIndexAt(x int) int {
	if x < 0 {
		return -1
	}
	counts := m.taskList.Counts(m.runs, m.tasks)
	pos := 0
	for i, section := range m.taskList.Sections() {
		label := " " + section.Name + " " + itoa(counts[section.Name]) + " "
		if x >= pos && x < pos+len(label) {
			return i
		}
		pos += len(label) + 1
	}
	return -1
}

func (m model) taskRowIndexAt(y int) int {
	// Status bar plus pane border/header lines place the first visible task row at
	// terminal row 4. Rows are rendered as two-line items. Prefer the task-list
	// viewport's top item when available; derive the same centered window from the
	// selected row otherwise because Bubble Tea View() mutates only a render copy.
	if y < 4 {
		return -1
	}
	row := (y - 4) / 2
	top := m.taskListTopIndex()
	idx := top + row
	if idx < 0 || idx >= len(m.taskList.Items()) {
		return -1
	}
	return idx
}

func (m model) taskListTopIndex() int {
	if m.taskList.viewport != nil {
		top, _ := m.taskList.viewport.GetTopItemIdxAndLineOffset()
		return top
	}
	itemCount := len(m.taskList.Items())
	if itemCount == 0 {
		return 0
	}
	bodyH := m.height - 3
	if bodyH < 4 {
		bodyH = 4
	}
	visibleItems := max(1, (bodyH-2)/2)
	top := m.taskList.SelectedIndex() - visibleItems/2
	if top < 0 {
		return 0
	}
	maxTop := max(0, itemCount-visibleItems)
	if top > maxTop {
		return maxTop
	}
	return top
}

func (m model) rightTabLineY() int {
	run, ok := m.selectedRun()
	if !ok {
		return -1
	}
	w := m.rightPaneWidth() - 1
	if w < 20 {
		w = 20
	}
	railLines := len(m.renderRail(run, w, paneVisualFor(m.viewFocused, m.config.Cockpit.Focus)))
	return 5 + railLines
}

func (m model) rightTabIndexAt(x int) int {
	rel := x - m.leftPaneWidth() - 2
	if rel < 0 {
		return -1
	}
	counts := []int{0, len(m.msgs), len(m.events), len(m.logs), len(m.reports), len(m.files), 0, metricsCount(m.metrics)}
	if m.pr.URL != "" {
		counts[6] = 1
	}
	pos := 0
	for i, name := range tabNames {
		label := name
		if i == 1 && counts[i] > 0 {
			if msgPos, ok := m.selectedMessagePosition(); ok {
				label += " " + itoa(msgPos) + "/" + itoa(counts[i])
			} else {
				label += " " + itoa(counts[i])
			}
		} else if i > 0 && counts[i] > 0 {
			label += " " + itoa(counts[i])
		}
		if tabOpenable(name) {
			label += " ?"
		}
		labelLen := utf8.RuneCountInString(" " + label + " ")
		if rel >= pos && rel < pos+labelLen {
			return i
		}

		pos += labelLen
	}
	return -1
}

func actionKeyPress(key string) tea.KeyPressMsg {
	r := []rune(key)
	if len(r) == 0 {
		return tea.KeyPressMsg(tea.Key{})
	}
	return tea.KeyPressMsg(tea.Key{Text: key, Code: r[0]})
}

func (m model) actionKeyAt(x, y int) string {
	if x <= m.leftPaneWidth() {
		return ""
	}
	actionLines := m.actionLineCount()
	if actionLines == 0 {
		return ""
	}
	startY := m.height - 3 - actionLines
	if y < startY || y >= startY+actionLines {
		return ""
	}
	relX := x - m.leftPaneWidth() - 2
	if relX < 0 {
		return ""
	}
	line := y - startY
	if task, ok := m.selectedTask(); ok {
		if line == 0 {
			prefix := "▸ task actions " + task.TaskID + "  "
			return actionSegmentKey(relX, prefix, []actionSegment{
				{label: "y copy task id", key: "y"},
			})
		}
		if line == 1 {
			return actionSegmentKey(relX, "", []actionSegment{
				{label: "a approve", key: "a"},
				{label: "e edit", key: "e"},
				{label: "n new task form", key: "n"},
				{label: "N quick add", key: "N"},
			})
		}
		return ""
	}
	if run, ok := m.selectedRun(); ok && tabNameAt(m.tab) != "pr" && line == actionLines-1 {
		prefix := "▸ run actions " + run.RunID + "  "
		return actionSegmentKey(relX, prefix, []actionSegment{
			{label: "A attach", key: "A"},
			{label: "r retry", key: "r"},
			{label: "R reset", key: "R"},
			{label: "p omp", key: "p"},
			{label: "P plain omp", key: "P"},
			{label: "G gh dash", key: "G"},
			{label: "C enhance", key: "C"},
		})
	}
	switch tabNameAt(m.tab) {
	case "pr":
		if m.pr.URL == "" {
			return ""
		}
		if line == 1 {
			return "o"
		}
		return actionSegmentKey(relX, "▸ PR actions ", []actionSegment{
			{label: "o/enter open PR in browser", key: "o"},
			{label: "G open gh dash", key: "G"},
			{label: "C inspect CI in gh enhance", key: "C"},
		})
	case "files":
		if line == 1 {
			return "o"
		}
		if line == 4 {
			return actionSegmentKey(relX, "", []actionSegment{
				{label: "o open plain", key: "o"},
				{label: "d open selected diff", key: "d"},
				{label: "D open run diff in diffnav", key: "D"},
			})
		}
	default:
		if m.openableTab() && line == 1 {
			return "o"
		}
	}
	return ""
}

func (m model) actionLineCount() int {
	if action := m.renderAction(m.rightPaneWidth(), paneVisualFor(m.viewFocused, m.config.Cockpit.Focus)); action != "" {
		return len(strings.Split(action, "\n"))
	}
	return 0
}

type actionSegment struct {
	label string
	key   string
}

func actionSegmentKey(x int, prefix string, segments []actionSegment) string {
	pos := utf8.RuneCountInString(prefix)
	for i, segment := range segments {
		start := pos
		end := start + utf8.RuneCountInString(segment.label)
		if x >= start && x < end {
			return segment.key
		}
		pos = end
		if i < len(segments)-1 {
			pos += 2
		}
	}
	return ""
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
	case "messages", "events", "logs", "reports", "files", "pr", "metrics":
		return true
	default:
		return false
	}
}

func (m model) viewerTab() bool { return tabViewer(tabNameAt(m.tab)) }
func (m model) detailUsesViewer() bool {
	if _, ok := m.selectedItem(); ok {
		return true
	}
	return m.viewerTab()
}

func (m model) detailAllowsHorizontalPan() bool { return tabNameAt(m.tab) == "logs" }

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
	base := selectedDiffBase(run, m.config.Integrations)
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
