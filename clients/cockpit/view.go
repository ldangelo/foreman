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
	"github.com/charmbracelet/x/ansi"
)

func clip(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if ansi.StringWidth(s) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return ansi.Truncate(s, w, "…")
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
	bodyH := m.height - 3
	if bodyH < 4 {
		bodyH = 4
	}

	rightRaw := fitBlock(m.renderRight(rightW), bodyH)
	leftRaw := fitBlock(m.renderLeft(leftW, bodyH), bodyH)
	left := leftPaneStyle.Width(leftW).Height(bodyH).MaxHeight(bodyH).MaxWidth(leftW + 1).Render(leftRaw)
	right := lipgloss.NewStyle().Height(bodyH).MaxHeight(bodyH).MaxWidth(rightW).Render(rightRaw)
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
	hints := "↑↓/j/k scroll · ctrl+d/u page · esc task list · ⇥ tab · o open · p omp · D diffnav · G gh dash · C gh enhance · ? help · q quit"
	if !m.viewFocused {
		hints = "↑↓/j/k task · enter view · ⇥ tab · o open · p omp · D diffnav · G gh dash · C gh enhance · / search · ? help · q quit"
	}
	return keyBarStyle.Width(w).Render(clip(" "+hints, w))
}

func (m model) renderLeft(w, h int) string {
	var lines []string
	selectedLine := 0
	gcolor := map[string]color.Color{taskGroupRunning: cGreen, taskGroupReady: cYellow, taskGroupRecent: cDim}
	count := m.taskList.Counts(m.runs, m.tasks)

	for _, g := range taskListGroups {
		caret := "▾"
		if m.taskList.Collapsed(g) {
			caret = "▸"
		}
		header := lipgloss.NewStyle().Foreground(gcolor[g]).Bold(true).
			Render(clip(caret+" "+g+" ("+itoa(count[g])+")", w))
		lines = append(lines, header)
		if m.taskList.Collapsed(g) {
			continue
		}
		for i, it := range m.taskList.Items() {
			if it.Group != g {
				continue
			}
			if i == m.taskList.SelectedIndex() {
				selectedLine = len(lines)
			}
			lines = append(lines, m.renderRow(i, it, w))
		}
	}
	return strings.Join(windowLines(lines, selectedLine, h), "\n")
}

func windowLines(lines []string, selected, h int) []string {
	if h <= 0 {
		return nil
	}
	if len(lines) <= h {
		return padLines(lines, h)
	}
	start := selected - h/2
	if start < 0 {
		start = 0
	}
	if start+h > len(lines) {
		start = len(lines) - h
	}
	return lines[start : start+h]
}

func scrollWindowLines(lines []string, offset, h int) []string {
	if h <= 0 {
		return nil
	}
	if len(lines) <= h {
		return padLines(lines, h)
	}
	if offset < 0 {
		offset = 0
	}
	if offset+h > len(lines) {
		offset = len(lines) - h
	}
	return lines[offset : offset+h]
}

func fitBlock(s string, h int) string {
	return strings.Join(padLines(strings.Split(s, "\n"), h), "\n")
}

func padLines(lines []string, h int) []string {
	if h <= 0 {
		return nil
	}
	out := append([]string(nil), lines...)
	if len(out) > h {
		out = out[:h]
	}
	for len(out) < h {
		out = append(out, "")
	}
	return out
}

func (m model) renderRow(i int, it Item, w int) string {
	selected := i == m.taskList.SelectedIndex()
	var state, left, right string
	var rightColor color.Color
	idColor := cText
	if it.IsTask {
		state = it.Task.Status
		left = strings.TrimSpace(strings.TrimSpace(it.Task.Priority) + " " + it.Task.Title)
		if left == "" {
			left = strings.TrimSpace(strings.TrimSpace(it.Task.Priority) + " " + it.Task.Summary)
		}
		if left == "" {
			left = strings.TrimSpace(strings.TrimSpace(it.Task.Priority) + " " + it.Task.TaskID)
		}
		right = it.Task.TaskType
		rightColor = cYellow
	} else {
		state = runState(it.Run)
		left = it.Run.Title
		if left == "" {
			left = it.Run.TaskID
		}
		if it.Run.Group == "RUNNING" {
			right, rightColor = it.Run.Phase, cCyan
		} else {
			right, rightColor = it.Run.Status, statusColor(it.Run.Status)
		}
		if it.Run.Status == "failed" {
			idColor = cRed
		}
	}
	gl, glc := glyph(state)
	left = clip(left, w-6)
	phaseMax := w - 3 - utf8.RuneCountInString(left)
	if phaseMax < 3 {
		phaseMax = 3
	}
	right = clip(right, phaseMax)

	if selected {
		idColor = cWhite
	}
	leftStr := lipgloss.NewStyle().Foreground(glc).Render(gl) + " " +
		lipgloss.NewStyle().Foreground(idColor).Render(left)
	rightStr := lipgloss.NewStyle().Foreground(rightColor).Render(right)
	line := padRow(leftStr, rightStr, w)

	st := lipgloss.NewStyle().Width(w)
	if selected {
		st = st.Background(cSelBg)
	}
	return st.Render(line)
}

func (m model) renderRight(w int) string {
	var s []string
	run, isRun := m.selectedRun()
	it, ok := m.selectedItem()
	if !ok {
		return dimStyle.Render("No selection.")
	}

	// header
	if isRun {
		hdrLeft := whiteStyle.Render(run.TaskID) + "  " + dimStyle.Render("run "+run.RunID+"…")
		status := run.Status
		if pos, ok := m.selectedMessagePosition(); ok {
			status += " · messages " + itoa(pos) + "/" + itoa(len(m.msgs))
		}
		hdrRight := lipgloss.NewStyle().Foreground(statusColor(run.Status)).Render(status)
		s = append(s, padRow(hdrLeft, hdrRight, w))
		if run.Attention != "" {
			s = append(s, redStyle.Render(clip("⚠ "+run.Attention, w)))
		}
	} else {
		title := it.Task.Title
		if title == "" {
			title = it.Task.TaskID
		}
		s = append(s, padRow(whiteStyle.Render(title), yellowStyle.Render(it.Task.Status), w))
	}
	s = append(s, dimStyle.Render(strings.Repeat("─", w)))

	// phase rail (runs only)
	if isRun {
		s = append(s, m.renderRail(run, w)...)
		s = append(s, dimStyle.Render(strings.Repeat("─", w)))
	}

	// tabs (runs only; tasks show summary)
	if isRun {
		s = append(s, m.renderTabs(w))
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
		s = append(s, windowLines(body, 0, bodyWindowH)...)
	}
	s = append(s, action...)
	return strings.Join(s, "\n")
}

func (m model) renderRail(run Run, w int) []string {
	var chips []string
	for i, p := range run.Pipeline {
		gl, glc := glyph(p.State)
		text := gl + " " + p.Name
		st := lipgloss.NewStyle().Foreground(glc)
		if p.State == "active" {
			st = st.Background(cActBg)
			if m.anim%2 == 0 {
				st = st.Foreground(cWhite)
			}
		} else if p.State == "fail" {
			st = st.Background(cFailBg)
		}
		_ = i
		chips = append(chips, st.Render(text))
	}
	// greedy wrap
	var lines []string
	cur := ""
	curW := 0
	sep := dimStyle.Render(" ─ ")
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

func (m model) renderTabs(w int) string {
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
			toks = append(toks, lipgloss.NewStyle().Background(lipgloss.Color("#1f6feb")).Foreground(cWhite).Render(" "+label+" "))
		} else {
			toks = append(toks, dimStyle.Render(" "+label+" "))
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
		add("task:id", kv("id", it.Task.TaskID), target{})
		add("task:title", kv("title", it.Task.Title), target{})
		add("task:type", kv("type", it.Task.TaskType), target{})
		add("task:priority", kv("priority", it.Task.Priority), target{})
		add("task:status", kv("status", it.Task.Status), target{})
		add("task:workflow", kv("workflow", it.Task.Workflow), target{})
		add("task:depends", kv("depends", it.Task.Depends), target{})
		add("task:project", kv("project", it.Task.ProjectID), target{})
		add("task:spacer", "", target{})
		desc := it.Task.Description
		if desc == "" {
			desc = it.Task.Summary
		}
		if desc == "" {
			desc = "No description."
		}
		for i, ln := range wrap(desc, w) {
			add("task:description:"+itoa(i), textStyle.Render(ln), target{})
		}
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
	lines := []ViewerLine{
		{Key: "pr:title", Text: padRow(cyanStyle.Render(title), lipgloss.NewStyle().Foreground(stateColor).Render(state), w)},
		{Key: "pr:url", Text: dimStyle.Render("url      ") + textStyle.Render(clip(pr.URL, w-9))},
	}
	if pr.BranchName != "" || pr.BaseBranch != "" {
		lines = append(lines, ViewerLine{Key: "pr:branch", Text: dimStyle.Render("branch   ") + textStyle.Render(clip(pr.BranchName+" → "+pr.BaseBranch, w-9))})
	}
	if pr.HeadSHA != "" {
		lines = append(lines, ViewerLine{Key: "pr:head", Text: dimStyle.Render("head     ") + textStyle.Render(clip(pr.HeadSHA, w-9))})
	}
	if pr.Mergeable != "" {
		lines = append(lines, ViewerLine{Key: "pr:mergeable", Text: dimStyle.Render("merge    ") + textStyle.Render(clip(pr.Mergeable, w-9))})
	}
	if pr.ReviewDecision != "" {
		lines = append(lines, ViewerLine{Key: "pr:review", Text: dimStyle.Render("review   ") + textStyle.Render(clip(pr.ReviewDecision, w-9))})
	}
	checks := greenStyle.Render("✓ "+itoa(pr.Checks.Passed)) + dimStyle.Render("  ") + redStyle.Render("✗ "+itoa(pr.Checks.Failed)) + dimStyle.Render("  ") + yellowStyle.Render("● "+itoa(pr.Checks.Pending))
	lines = append(lines, ViewerLine{Key: "pr:checks", Text: dimStyle.Render("checks   ") + checks})
	if pr.Err != "" {
		lines = append(lines, ViewerLine{Key: "pr:error", Text: yellowStyle.Render("PR detail: " + pr.Err)})
	}
	return lines
}

func (m model) renderAction(w int) string {
	if task, ok := m.selectedTask(); ok {
		lines := []string{
			dimStyle.Render(strings.Repeat("┄", w)),
			clip(greenStyle.Render("▸ task actions ")+whiteStyle.Render(task.TaskID), w),
			clip(cyanStyle.Render("y")+dimStyle.Render(" copy task id to clipboard")+"  "+cyanStyle.Render("n")+dimStyle.Render(" new task JSON in nvim"), w),
			clip(cyanStyle.Render("a")+dimStyle.Render(" approve → POST /api/v1/commands task.approve")+"  "+cyanStyle.Render("e")+dimStyle.Render(" edit JSON → POST /api/v1/commands task.update"), w),
		}
		return lipgloss.NewStyle().Background(cActionBg).Width(w).Render(strings.Join(lines, "\n"))
	}
	if tabNames[m.tab] == "pr" {
		if m.pr.URL == "" {
			return ""
		}
		lines := []string{
			dimStyle.Render(strings.Repeat("┄", w)),
			clip(greenStyle.Render("▸ PR actions ")+whiteStyle.Render(m.pr.URL), w),
			clip(cyanStyle.Render("o/enter")+dimStyle.Render(" open PR in browser")+"  "+cyanStyle.Render("G")+dimStyle.Render(" open gh dash")+"  "+cyanStyle.Render("C")+dimStyle.Render(" inspect CI in gh enhance"), w),
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

// wrap splits text into width-bounded lines (returns colored-ready plain lines).
func wrap(s string, w int) []string {
	if w <= 0 {
		return []string{s}
	}
	words := strings.Fields(s)
	var lines []string
	cur := ""
	for _, word := range words {
		if cur == "" {
			cur = word
		} else if utf8.RuneCountInString(cur)+1+utf8.RuneCountInString(word) <= w {
			cur += " " + word
		} else {
			lines = append(lines, cur)
			cur = word
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if len(lines) == 0 {
		lines = []string{""}
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
