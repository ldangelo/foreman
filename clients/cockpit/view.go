package main

import (
	"fmt"
	"image/color"
	"os"
	"regexp"
	"strings"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"charm.land/lipgloss/v2/table"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/reflow/truncate"
	"github.com/muesli/reflow/wordwrap"
)

func clip(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if ansi.StringWidth(s) <= w {
		return s
	}
	return truncate.StringWithTail(s, uint(w), "…")
}

func padRow(left, right string, w int) string {
	gap := w - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

func (m model) View() tea.View {
	content := m.renderFrame()
	v := tea.NewView(content)
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	return v
}

func (m model) renderFrame() string {
	if m.width == 0 || m.height == 0 {
		return "starting cockpit…"
	}
	total := m.width
	leftW := leftPaneWidth(total)
	rightW := total - leftW - 1
	if rightW < 20 {
		rightW = 20
	}
	rightContentW := rightW - 1
	if rightContentW < 20 {
		rightContentW = 20
	}
	bodyH := m.height - 5
	if bodyH < 4 {
		bodyH = 4
	}

	leftVisual := paneVisualFor(!m.viewFocused, m.config.Cockpit.Focus)
	rightVisual := paneVisualFor(m.viewFocused, m.config.Cockpit.Focus)
	rightModel := m
	rightModel.height = bodyH + 3
	rightRaw := rightModel.renderRight(rightContentW)
	leftRaw := m.renderLeft(leftW, bodyH)
	left := leftPaneStyle.Width(leftW).Height(bodyH).MaxHeight(bodyH).MaxWidth(leftW + 1).BorderForeground(leftVisual.Border).Render(leftRaw)
	right := lipgloss.NewStyle().BorderStyle(lipgloss.NormalBorder()).BorderLeft(true).BorderForeground(rightVisual.Border).Width(rightContentW).Height(bodyH).MaxHeight(bodyH).MaxWidth(rightW).Render(rightRaw)
	row := lipgloss.JoinHorizontal(lipgloss.Top, left, right)

	out := lipgloss.JoinVertical(lipgloss.Left,
		m.renderStatusBar(total),
		row,
		m.renderNotice(total),
		m.renderKeyBar(total),
	)
	if os.Getenv("COCKPIT_DEBUG") != "" {
		writeDebugDump(m, leftW, rightW, bodyH, rightRaw, out)
	}
	return out
}

func leftPaneWidth(total int) int {
	leftW := 40
	if total-leftW-1 < 44 {
		leftW = total - 45
	}
	if leftW < 32 {
		leftW = 32
	}
	if leftW > 40 {
		leftW = 40
	}
	return leftW
}

var ansiRe = regexp.MustCompile("\x1b\\[[0-9;]*m")

func renderFieldTable(prefix string, rows [][2]string, w int) []ViewerLine {
	t := table.New().
		BorderTop(false).
		BorderBottom(false).
		BorderLeft(false).
		BorderRight(false).
		BorderHeader(false).
		BorderColumn(false).
		BorderRow(false).
		Wrap(true).
		Width(w).
		StyleFunc(func(_, col int) lipgloss.Style {
			if col == 0 {
				return dimStyle
			}
			return textStyle
		})
	for _, row := range rows {
		if row[1] == "" {
			continue
		}
		t.Row(row[0], row[1])
	}
	rendered := strings.TrimRight(t.Render(), "\n")
	if rendered == "" {
		return nil
	}
	lines := strings.Split(rendered, "\n")
	out := make([]ViewerLine, 0, len(lines))
	for i, line := range lines {
		out = append(out, ViewerLine{Key: prefix + ":" + itoa(i), Text: line})
	}
	return out
}
func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

// writeDebugDump writes model state + the exact rendered frame (ANSI stripped)
// to cockpit-debug.txt in the working dir, overwriting each render. Enabled by
// COCKPIT_DEBUG=1. Used to diagnose rendering without a local Go toolchain.
func writeDebugDump(m model, leftW, rightW, bodyH int, rightRaw, out string) {
	var b strings.Builder
	fmt.Fprintf(&b, "termW=%d termH=%d leftW=%d rightW=%d bodyH=%d\n", m.width, m.height, leftW, rightW, bodyH)
	fmt.Fprintf(&b, "runs=%d tasks=%d items=%d sel=%d tab=%s row=%d offset=%d searching=%v viewFocused=%v\n",
		len(m.runs), len(m.tasks), len(m.taskList.Items()), m.taskList.SelectedIndex(), tabNames[m.tab], m.viewer.Cursor(), m.viewer.Offset(), m.taskList.Searching(), m.viewFocused)
	if it, ok := m.selectedItem(); ok {
		fmt.Fprintf(&b, "selected: isTask=%v taskID=%q runTaskID=%q runID=%q\n",
			it.IsTask, it.Task.TaskID, it.Run.TaskID, it.Run.RunID)
	} else {
		b.WriteString("selected: NONE (out of range)\n")
	}
	rl := strings.Split(rightRaw, "\n")
	fmt.Fprintf(&b, "\n=== renderRight raw: %d lines (ansi stripped) ===\n", len(rl))
	b.WriteString(stripANSI(rightRaw))
	b.WriteString("\n\n=== final frame (ansi stripped) ===\n")
	b.WriteString(stripANSI(out))
	_ = os.WriteFile("cockpit-debug.txt", []byte(b.String()), 0o644)
}

func (m model) renderStatusBar(w int) string {
	running, recent := 0, 0
	for _, r := range m.runs {
		if r.Group == "RUNNING" {
			running++
		} else if r.Group == "RECENT" {
			recent++
		}
	}
	left := purpleStyle.Bold(true).Render("foreman") + "  " +
		greenStyle.Render(itoa(running)+" running") + dimStyle.Render(" · ") +
		yellowStyle.Render(itoa(len(m.tasks))+" ready") + dimStyle.Render(" · ") +
		dimStyle.Render(itoa(recent)+" recent")

	nvim := "nvim: inline"
	if m.editor.serverAddr() != "" {
		nvim = "nvim ⇄ attached"
	}
	spin := []string{"↻", "↺"}[m.anim%2]
	right := greenStyle.Render(nvim) + dimStyle.Render(" · "+m.taskList.Scope()+" · ") + cyanStyle.Render(spin+" live")

	return statusBarStyle.Width(w).Render(clip(padRow(left, right, w), w))
}

func (m model) renderNotice(w int) string {
	if os.Getenv("COCKPIT_DEBUG") != "" {
		sel := "none"
		if it, ok := m.selectedItem(); ok {
			if it.IsTask {
				sel = it.Task.TaskID + "(task)"
			} else {
				sel = it.Run.TaskID + "/" + it.Run.RunID
			}
		}
		dbg := fmt.Sprintf("dbg items=%d sel=%d tab=%s row=%d termW=%d termH=%d sel=%s",
			len(m.taskList.Items()), m.taskList.SelectedIndex(), tabNames[m.tab], m.viewer.Cursor(), m.width, m.height, sel)
		return lipgloss.NewStyle().Width(w).Foreground(cYellow).Render(clip(" "+dbg, w))
	}
	if m.taskList.Searching() {
		return statusBarStyle.Width(w).Render(clip(cyanStyle.Render("/")+m.taskList.Search()+"▏", w))
	}
	if m.notice == "" {
		return lipgloss.NewStyle().Width(w).Render("")
	}
	return lipgloss.NewStyle().Width(w).Foreground(cYellow).Render(clip("  "+m.notice, w))
}

func (m model) renderKeyBar(w int) string {
	focus := "focus: details"
	if !m.viewFocused {
		focus = "focus: tasks"
	}
	hints := renderHelpLine(max(1, w-utf8.RuneCountInString(focus)-4), m.viewFocused)
	return keyBarStyle.Width(w).Render(clip(" "+focus+" · "+hints, w))
}

func (m model) renderLeft(w, h int) string {
	visual := paneVisualFor(!m.viewFocused, m.config.Cockpit.Focus)
	rows := make([]string, 0, len(m.taskList.Items()))
	selectedLine := m.taskList.SelectedIndex()
	for i, it := range m.taskList.Items() {
		rows = append(rows, m.renderRow(i, it, w, visual))
	}

	section := m.taskList.ActiveSection()
	headers := []string{
		m.renderTaskSectionTabs(w, visual),
		lipgloss.NewStyle().Foreground(visual.Dim).Render(clip("filter "+section.Filter+taskQuerySuffix(m.taskList.Search()), w)),
	}
	m.taskList.SetViewportRows(headers, rows, selectedLine, w, h)
	return m.taskList.View()
}

func taskQuerySuffix(search string) string {
	if strings.TrimSpace(search) == "" {
		return ""
	}
	return " · " + search
}

func (m model) renderTaskSectionTabs(w int, visual paneVisual) string {
	counts := m.taskList.Counts(m.runs, m.tasks)
	active := m.taskList.ActiveSectionIndex()
	var tabs []string
	for i, section := range taskListSections {
		label := section.Name + " " + itoa(counts[section.Name])
		if i == active {
			tabs = append(tabs, lipgloss.NewStyle().Background(visual.ActiveBg).Foreground(visual.White).Render(" "+label+" "))
		} else {
			tabs = append(tabs, lipgloss.NewStyle().Foreground(visual.Dim).Render(" "+label+" "))
		}
	}
	return clip(strings.Join(tabs, " "), w)
}

func (m model) renderRow(i int, it Item, w int, visual paneVisual) string {
	selected := i == m.taskList.SelectedIndex()
	state, title, id, typ, pri, right := taskRowFields(it)
	gl, glc := glyph(state)
	line1Left := lipgloss.NewStyle().Foreground(visualColor(glc, visual)).Render(gl) + " " +
		lipgloss.NewStyle().Foreground(visual.Text).Render(id)
	if typ != "" {
		line1Left += lipgloss.NewStyle().Foreground(visual.Dim).Render(" · " + typ)
	}
	if pri != "" {
		line1Left += lipgloss.NewStyle().Foreground(priorityColor(pri, visual)).Render(" · " + pri)
	}
	line1 := padRow(clip(line1Left, w-8), lipgloss.NewStyle().Foreground(taskRowRightColor(it, visual)).Render(clip(right, 12)), w)
	line2 := lipgloss.NewStyle().Foreground(visual.White).Bold(true).Render(clip("  "+title, w))
	row := line1 + "\n" + line2
	st := lipgloss.NewStyle().Width(w)
	if selected {
		st = st.Background(visual.SelectedBg)
	}
	return st.Render(row)
}

func taskRowFields(it Item) (state, title, id, typ, pri, right string) {
	if it.IsTask {
		title = firstNonEmptyText(it.Task.Title, it.Task.Summary, it.Task.TaskID)
		return it.Task.Status, title, it.Task.TaskID, it.Task.TaskType, it.Task.Priority, it.Task.Status
	}
	title = firstNonEmptyText(it.Run.Title, it.Run.Summary, it.Run.TaskID)
	typ = it.Run.TaskType
	pri = it.Run.Priority
	right = it.Run.Status
	if it.Run.Group == taskGroupRunning {
		right = it.Run.Phase
	}
	return runState(it.Run), title, it.Run.TaskID, typ, pri, right
}

func firstNonEmptyText(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return "—"
}

func priorityColor(priority string, visual paneVisual) color.Color {
	switch strings.ToUpper(strings.TrimSpace(priority)) {
	case "P0", "0":
		return visual.Red
	case "P1", "1":
		return visual.Yellow
	default:
		return visual.Dim
	}
}

func taskRowRightColor(it Item, visual paneVisual) color.Color {
	if it.IsTask {
		return statusColor(it.Task.Status)
	}
	if it.Run.Group == taskGroupRunning {
		return visual.Cyan
	}
	return statusColor(it.Run.Status)
}

func (m model) renderRight(w int) string {
	visual := paneVisualFor(m.viewFocused, m.config.Cockpit.Focus)
	if m.helpVisible {
		title := lipgloss.NewStyle().Foreground(visual.White).Bold(true).Render("Cockpit keys")
		body := renderFullHelp(w, m.viewFocused)
		return strings.Join([]string{title, dimStyle.Render("press ? or esc to close"), "", body}, "\n")
	}
	var s []string
	run, isRun := m.selectedRun()
	it, ok := m.selectedItem()
	if !ok {
		return lipgloss.NewStyle().Foreground(visual.Dim).Render("No selection.")
	}

	// header
	if isRun {
		hdrLeft := lipgloss.NewStyle().Foreground(visual.White).Bold(true).Render(run.TaskID) + "  " + lipgloss.NewStyle().Foreground(visual.Dim).Render("run "+run.RunID+"…")
		status := run.Status
		if pos, ok := m.selectedMessagePosition(); ok {
			status += " · messages " + itoa(pos) + "/" + itoa(len(m.msgs))
		}
		hdrRight := lipgloss.NewStyle().Foreground(visualForStatus(run.Status, visual)).Render(status)
		s = append(s, padRow(hdrLeft, hdrRight, w))
		if run.Attention != "" {
			s = append(s, lipgloss.NewStyle().Foreground(visual.Red).Render(clip("⚠ "+run.Attention, w)))
		}
	} else {
		title := it.Task.Title
		if title == "" {
			title = it.Task.TaskID
		}
		s = append(s, padRow(lipgloss.NewStyle().Foreground(visual.White).Bold(true).Render(title), lipgloss.NewStyle().Foreground(visual.Yellow).Render(it.Task.Status), w))
	}
	s = append(s, lipgloss.NewStyle().Foreground(visual.Dim).Render(strings.Repeat("─", w)))

	// phase rail (runs only)
	if isRun {
		s = append(s, m.renderRail(run, w, visual)...)
		s = append(s, lipgloss.NewStyle().Foreground(visual.Dim).Render(strings.Repeat("─", w)))
	}

	// tabs (runs only; tasks show summary)
	if isRun {
		s = append(s, m.renderTabs(w, visual))
		s = append(s, "")
	}

	body := m.renderBody(run, it, isRun, w)
	var action []string
	if !isRun || m.openableTab() || tabNames[m.tab] == "pr" {
		if ab := m.renderAction(w); ab != "" {
			action = strings.Split(ab, "\n")
		}
	}
	bodyH := m.height - 3
	if bodyH < 4 {
		bodyH = 4
	}
	bodyWindowH := bodyH - len(s) - len(action)
	if bodyWindowH < 1 {
		bodyWindowH = 1
	}
	if m.viewerTab() {
		viewer := m.viewer
		policy := viewerPreserve
		if viewer.Len() == 0 {
			policy = viewerBottom
		}
		viewer.SetBounds(w, bodyWindowH)
		viewer.SetLines(m.renderViewerLines(run, it, isRun, w), policy, bodyWindowH)
		s = append(s, strings.Split(viewer.View(), "\n")...)
	} else {
		if len(body) > bodyWindowH {
			body = body[:bodyWindowH]
		}
		s = append(s, body...)
	}
	s = append(s, action...)
	return strings.Join(s, "\n")
}

func (m model) renderRail(run Run, w int, visual paneVisual) []string {
	var chips []string
	for i, p := range run.Pipeline {
		gl, glc := glyph(p.State)
		text := gl + " " + p.Name
		st := lipgloss.NewStyle().Foreground(visualColor(glc, visual))
		if p.State == "active" {
			st = st.Background(visual.ActiveBg)
			if m.anim%2 == 0 {
				st = st.Foreground(visual.White)
			}
		} else if p.State == "fail" {
			st = st.Background(visual.FailBg)
		}
		_ = i
		chips = append(chips, st.Render(text))
	}
	// greedy wrap
	var lines []string
	cur := ""
	curW := 0
	sep := lipgloss.NewStyle().Foreground(visual.Dim).Render(" ─ ")
	for _, c := range chips {
		cw := lipgloss.Width(c)
		add := cw
		if cur != "" {
			add += 3
		}
		if curW+add > w {
			lines = append(lines, cur)
			cur, curW = c, cw
			continue
		}
		if cur == "" {
			cur, curW = c, cw
		} else {
			cur += sep + c
			curW += add
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	return lines
}

func (m model) renderTabs(w int, visual paneVisual) string {
	var toks []string
	counts := []int{0, len(m.msgs), len(m.events), len(m.logs), len(m.reports), len(m.files), 0}
	if m.pr.URL != "" {
		counts[6] = 1
	}
	for i, name := range tabNames {
		label := name
		if i == 1 && counts[i] > 0 {
			if pos, ok := m.selectedMessagePosition(); ok {
				label += " " + itoa(pos) + "/" + itoa(counts[i])
			} else {
				label += " " + itoa(counts[i])
			}
		} else if i > 0 && counts[i] > 0 {
			label += " " + itoa(counts[i])
		}
		if tabOpenable(name) {
			label += " ⧉"
		}
		if i == m.tab {
			toks = append(toks, lipgloss.NewStyle().Background(visual.ActiveBg).Foreground(visual.White).Render(" "+label+" "))
		} else {
			toks = append(toks, lipgloss.NewStyle().Foreground(visual.Dim).Render(" "+label+" "))
		}
	}
	return clip(strings.Join(toks, ""), w)
}

func (m model) selectedMessagePosition() (int, bool) {
	if m.tab != 1 || len(m.msgs) == 0 {
		return 0, false
	}
	pos := m.viewer.Cursor()/2 + 1
	if pos < 1 {
		pos = 1
	}
	if pos > len(m.msgs) {
		pos = len(m.msgs)
	}
	return pos, true
}

func (m model) renderBody(run Run, it Item, isRun bool, w int) []string {
	lines := m.renderViewerLines(run, it, isRun, w)
	out := make([]string, len(lines))
	for i, line := range lines {
		out[i] = line.Text
	}
	return out
}

func (m model) renderViewerLines(run Run, it Item, isRun bool, w int) []ViewerLine {
	var s []ViewerLine
	add := func(key, text string, t target) {
		s = append(s, ViewerLine{Key: key, Text: text, Target: t})
	}
	kv := func(k, v string) string {
		return dimStyle.Render(clip(k, 9)) + "  " + textStyle.Render(clip(v, w-11))
	}

	if !isRun {
		desc := it.Task.Description
		if desc == "" {
			desc = it.Task.Summary
		}
		if desc == "" {
			desc = "No description."
		}
		s = append(s, renderFieldTable("task:fields", [][2]string{
			{"id", it.Task.TaskID},
			{"title", it.Task.Title},
			{"type", it.Task.TaskType},
			{"priority", it.Task.Priority},
			{"status", it.Task.Status},
			{"workflow", it.Task.Workflow},
			{"depends", it.Task.Depends},
			{"project", it.Task.ProjectID},
			{"description", desc},
		}, w)...)
		return s
	}
	switch tabNames[m.tab] {
	case "summary":
		for i, ln := range wrap(run.Summary, w) {
			add("summary:"+itoa(i), textStyle.Render(ln), target{})
		}
		add("summary:spacer", "", target{})
		add("summary:worktree", kv("worktree", run.Worktree), target{})
		add("summary:branch", kv("branch", run.Branch), target{})
		add("summary:last", kv("last", run.Last), target{})
	case "messages":
		if len(m.msgs) == 0 {
			return []ViewerLine{{Key: "messages:empty", Text: dimStyle.Render("No mail for this run.")}}
		}
		for _, mm := range m.msgs {
			base := "message:" + mm.At + ":" + mm.From + ":" + mm.To + ":" + mm.Subject
			s = append(s, ViewerLine{Key: base + ":header", Text: clip(dimStyle.Render("["+mm.At+"] ")+purpleStyle.Render(mm.From+" → "+mm.To)+" "+cyanStyle.Render(mm.Subject), w), KeepNext: true})
			s = append(s, ViewerLine{Key: base + ":body:" + mm.Body, Text: clip("  "+textStyle.Render(mm.Body), w), Unselectable: true})
		}
	case "events":
		if len(m.events) == 0 {
			return []ViewerLine{{Key: "events:empty", Text: dimStyle.Render("No events recorded.")}}
		}
		for _, e := range m.events {
			add("event:"+e.At+":"+e.Type+":"+e.Detail, clip(dimStyle.Render(e.At+" ")+yellowStyle.Render(e.Type)+" "+textStyle.Render(e.Detail), w), target{})
		}
	case "logs":
		t := target{label: "run log", path: "~/.foreman/logs/" + run.RunID + ".log", ok: true}
		add("log:target:"+run.RunID, greenStyle.Render("⧉ ")+cyanStyle.Render("~/.foreman/logs/"+run.RunID+".log"), t)
		for i, ln := range m.logs {
			prefix := dimStyle.Render(fmt.Sprintf("%4d │ ", i+1))
			add("log:"+itoa(i)+":"+ln, prefix+textStyle.Render(ln), t)
		}
	case "reports":
		if len(m.reports) == 0 {
			return []ViewerLine{{Key: "reports:empty", Text: dimStyle.Render("No reports produced yet.")}}
		}
		idx := m.selectedReportIndex()
		for _, r := range m.reports {
			sc := cGreen
			if r.Status != "done" {
				sc = cYellow
			}
			t := target{label: r.Name, path: run.Worktree + "/docs/reports/" + run.TaskID + "/" + r.Name, ok: true}
			line := padRow(greenStyle.Render("⧉ ")+cyanStyle.Render(r.Name)+dimStyle.Render(" "+r.Size),
				lipgloss.NewStyle().Foreground(sc).Render(r.Status), w)
			add("report:"+r.Name, line, t)
		}
		if idx >= 0 && m.glam != nil {
			r := m.reports[idx]
			t := target{label: r.Name, path: run.Worktree + "/docs/reports/" + run.TaskID + "/" + r.Name, ok: true}
			if out, err := m.glam.Render(r.Preview); err == nil {
				add("report-preview:"+r.Name+":spacer", "", t)
				for i, ln := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
					add("report-preview:"+r.Name+":"+itoa(i), clip(ln, w), t)
				}
			}
		}
	case "files":
		if len(m.files) == 0 {
			return []ViewerLine{{Key: "files:empty", Text: dimStyle.Render("No file changes.")}}
		}
		for _, f := range m.files {
			cc := cYellow
			switch f.Change {
			case "A":
				cc = cGreen
			case "D":
				cc = cRed
			}
			stat := dimStyle.Render(f.Stat)
			if f.Conflict {
				stat = redStyle.Render("conflict")
			}
			t := target{label: f.Path, path: run.Worktree + "/" + f.Path, isFile: true, conflict: f.Conflict, ok: true}
			line := padRow(lipgloss.NewStyle().Foreground(cc).Render(f.Change)+" "+textStyle.Render(clip(f.Path, w-14)), stat, w)
			add("file:"+f.Path, line, t)
		}
		if idx := m.selectedFileIndex(); idx >= 0 && idx < len(m.files) {
			f := m.files[idx]
			base := selectedDiffBase(m.config.Integrations)
			key := diffPreviewKey(run, f.Path, base)
			add("diff-preview:"+f.Path+":spacer", "", target{})
			if m.diffLoading[key] {
				s = append(s, ViewerLine{Key: "diff-preview:" + f.Path + ":loading", Text: dimStyle.Render("loading diff preview…"), Unselectable: true})
			} else if preview, ok := m.diffPreviews[key]; ok {
				if preview.Err != "" {
					s = append(s, ViewerLine{Key: "diff-preview:" + f.Path + ":error", Text: yellowStyle.Render("diff preview: " + preview.Err), Unselectable: true})
				}
				if len(preview.Lines) == 0 && preview.Err == "" {
					s = append(s, ViewerLine{Key: "diff-preview:" + f.Path + ":empty", Text: dimStyle.Render("No diff for selected file."), Unselectable: true})
				}
				for i, ln := range preview.Lines {
					s = append(s, ViewerLine{Key: "diff-preview:" + f.Path + ":" + itoa(i), Text: ln, Unselectable: true})
				}
			} else {
				s = append(s, ViewerLine{Key: "diff-preview:" + f.Path + ":pending", Text: dimStyle.Render("diff preview pending…"), Unselectable: true})
			}
		}
	case "pr":
		return m.renderPRLines(w)
	}
	return s
}

func (m model) renderPRLines(w int) []ViewerLine {
	pr := m.pr
	if pr.URL == "" {
		return []ViewerLine{{Key: "pr:empty", Text: dimStyle.Render("No PR for this run yet.")}}
	}
	state := pr.State
	if state == "" {
		state = "unknown"
	}
	stateColor := cCyan
	switch strings.ToLower(state) {
	case "merged":
		stateColor = cGreen
	case "closed":
		stateColor = cRed
	case "draft":
		stateColor = cDim
	}
	title := "PR"
	if pr.Number != "" {
		title += " #" + pr.Number
	}
	branch := ""
	if pr.BranchName != "" || pr.BaseBranch != "" {
		branch = pr.BranchName + " → " + pr.BaseBranch
	}
	rows := [][2]string{
		{"url", pr.URL},
		{"branch", branch},
		{"head", pr.HeadSHA},
		{"merge", pr.Mergeable},
		{"review", pr.ReviewDecision},
		{"passed", itoa(pr.Checks.Passed)},
		{"failed", itoa(pr.Checks.Failed)},
		{"pending", itoa(pr.Checks.Pending)},
	}
	lines := []ViewerLine{
		{Key: "pr:title", Text: padRow(cyanStyle.Render(title), lipgloss.NewStyle().Foreground(stateColor).Render(state), w)},
		{Key: "pr:actions", Text: cyanStyle.Render("o/enter") + dimStyle.Render(" open PR in browser  ") + cyanStyle.Render("C") + dimStyle.Render(" inspect CI in gh enhance")},
	}
	lines = append(lines, renderFieldTable("pr:fields", rows, w)...)
	if pr.Err != "" {
		lines = append(lines, ViewerLine{Key: "pr:error", Text: yellowStyle.Render("PR detail: " + pr.Err)})
	}
	return lines
}
func (m model) renderAction(w int) string {
	if task, ok := m.selectedTask(); ok {
		lines := []string{
			clip(greenStyle.Render("▸ task actions ")+whiteStyle.Render(task.TaskID)+"  "+cyanStyle.Render("y")+dimStyle.Render(" copy task id")+"  "+cyanStyle.Render("a")+dimStyle.Render(" approve")+"  "+cyanStyle.Render("e")+dimStyle.Render(" edit")+"  "+cyanStyle.Render("n")+dimStyle.Render(" new task JSON in nvim"), w),
		}
		return lipgloss.NewStyle().Background(cActionBg).Width(w).Render(strings.Join(lines, "\n"))
	}
	if tabNames[m.tab] == "pr" {
		if m.pr.URL == "" {
			return ""
		}
		lines := []string{
			clip(greenStyle.Render("▸ PR actions ")+cyanStyle.Render("o/enter")+dimStyle.Render(" open PR in browser")+"  "+cyanStyle.Render("G")+dimStyle.Render(" open gh dash")+"  "+cyanStyle.Render("C")+dimStyle.Render(" inspect CI in gh enhance"), w),
			clip(dimStyle.Render(m.pr.URL), w),
		}
		return lipgloss.NewStyle().Background(cActionBg).Width(w).Render(strings.Join(lines, "\n"))
	}
	t := resolveTarget(m)
	if !t.ok {
		return ""
	}
	diff := tabNames[m.tab] == "files"
	cmd, mode := describe(m.editor, t, diff)
	head := greenStyle.Render("▸ open ") + whiteStyle.Render(t.label) + greenStyle.Render(" in nvim")
	if t.conflict {
		head += redStyle.Render("  (conflict — 3-way)")
	}
	if tabNames[m.tab] == "files" {
		lines := []string{
			dimStyle.Render(strings.Repeat("┄", w)),
			clip(head, w),
			clip(dimStyle.Render("$ ")+cyanStyle.Render(cmd), w),
			clip(dimStyle.Render("→ "+mode), w),
			clip(cyanStyle.Render("D")+dimStyle.Render(" open run diff in diffnav"), w),
		}
		return lipgloss.NewStyle().Background(cActionBg).Width(w).MaxWidth(w).Render(strings.Join(lines, "\n"))
	}
	lines := []string{
		dimStyle.Render(strings.Repeat("┄", w)),
		clip(head, w),
		clip(dimStyle.Render("$ ")+cyanStyle.Render(cmd), w),
		clip(dimStyle.Render("→ "+mode), w),
	}
	return lipgloss.NewStyle().Background(cActionBg).Width(w).MaxWidth(w).Render(strings.Join(lines, "\n"))
}

// wrap splits text into display-cell-width-bounded lines.
func wrap(s string, w int) []string {
	if w <= 0 {
		return []string{s}
	}
	out := strings.TrimRight(wordwrap.String(s, w), "\n")
	lines := strings.Split(out, "\n")
	if len(lines) == 0 {
		return []string{""}
	}
	return lines
}

func runState(r Run) string {
	switch {
	case r.Status == "failed" || r.Status == "conflict":
		return "fail"
	case r.Status == "merged" || r.Status == "completed" || r.Status == "pr-created":
		return "done"
	case r.Verdict == "retrying" || r.Status == "cooldown":
		return "retry"
	default:
		return "active"
	}
}

func itoa(n int) string {

	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
