package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
)

type ompDoneMsg struct {
	err   error
	mode  string
	brief string
	plain bool
}

func resolveOmpMode(cfg OmpConfig, run Run, tools ToolResolver, env []string) (string, error) {
	if normalizeEnable(cfg.Enable) == "off" {
		return "", errToolDisabled("omp")
	}
	cmd := cfg.Cmd
	if cmd == "" {
		cmd = "omp"
	}
	if !tools.Available(cmd) {
		return "", errToolMissing("omp", "omp.sh")
	}
	worktree := strings.TrimSpace(run.Worktree)
	if worktree == "" || worktree == "(cleaned)" {
		return "", errors.New("no worktree available for omp")
	}
	if runHasActiveWorker(run) {
		return "", errors.New("run is active — reset/stop it before attaching omp")
	}
	switch normalizeOmpMode(cfg.Mode) {
	case "tmux":
		return "tmux", nil
	case "window":
		return "tmux", nil
	case "inline":
		return "inline", nil
	default:
		if envHas(env, "TMUX=") {
			return "tmux", nil
		}
		return "inline", nil
	}
}

func runHasActiveWorker(run Run) bool {
	if strings.EqualFold(run.Group, taskGroupRunning) {
		return true
	}
	switch normalizeStatus(run.Status) {
	case "running", "in_progress", "pending", "cooldown":
		return true
	default:
		return false
	}
}

func briefMessageLines(msg Message) []string {
	lines := make([]string, 0, 2)
	subject := strings.TrimSpace(msg.Subject)
	body := firstNonEmptyLine(msg.Body)
	if subject != "" {
		lines = append(lines, subject)
	}
	if body != "" && !strings.EqualFold(body, subject) {
		lines = append(lines, body)
	}
	return lines
}

func firstNonEmptyLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func envHas(env []string, prefix string) bool {
	if len(env) == 0 {
		env = os.Environ()
	}
	for _, item := range env {
		if strings.HasPrefix(item, prefix) {
			return true
		}
	}
	return false
}

func ompInlineCommand(run Run, brief string, cfg OmpConfig) (*exec.Cmd, error) {
	wt := strings.TrimSpace(run.Worktree)
	if wt == "" || wt == "(cleaned)" {
		return nil, errors.New("no worktree available for omp")
	}
	cmd := exec.Command("bash", "-lc", ompShellLine(run, brief, cfg))
	cmd.Dir = expandHome(wt)
	if brief != "" {
		appendCmdEnv(cmd, "FOREMAN_TRIAGE_BRIEF="+brief)
	}
	return cmd, nil
}

func ompTmuxCommand(run Run, brief string, cfg OmpConfig) (*exec.Cmd, error) {
	wt := strings.TrimSpace(run.Worktree)
	if wt == "" || wt == "(cleaned)" {
		return nil, errors.New("no worktree available for omp")
	}
	inner := ompShellLine(run, brief, cfg)
	if cfg.KeepShell {
		inner += "; exec ${SHELL:-/bin/sh}"
	}
	split := normalizeTmuxSplit(cfg.Tmux.Split)
	if normalizeOmpMode(cfg.Mode) == "window" {
		split = "window"
	}
	worktree := expandHome(wt)
	switch split {
	case "window":
		return exec.Command("tmux", "new-window", "-c", worktree, "-n", "omp:"+run.TaskID, inner), nil
	case "vertical":
		return exec.Command("tmux", "split-window", "-v", "-c", worktree, inner), nil
	default:
		return exec.Command("tmux", "split-window", "-h", "-c", worktree, inner), nil
	}
}

func ompShellLine(run Run, brief string, cfg OmpConfig) string {
	cmd := cfg.Cmd
	if cmd == "" {
		cmd = "omp"
	}
	parts := []string{shellQuote(cmd)}
	parts = append(parts, quoteArgs(cfg.Args)...)
	sessionDir := ompSessionDir(run, cfg)
	if sessionDir != "" {
		parts = append(parts, "--session-dir", shellQuote(sessionDir))
		if hasOmpSession(sessionDir) {
			parts = append(parts, "--continue")
		}
	}
	line := strings.Join(parts, " ")
	execLine := "exec " + line
	if sessionDir != "" {
		execLine = "mkdir -p " + shellQuote(sessionDir) + "; " + execLine
	}
	if brief == "" {
		return execLine
	}
	message := "Foreman triage brief: " + brief + " — read it first, then work in this tree."
	return "printf %s\\n\\n " + shellQuote(message) + "; " + execLine
}

func quoteArgs(args []string) []string {
	out := make([]string, 0, len(args))
	for _, arg := range args {
		out = append(out, shellQuote(arg))
	}
	return out
}

func ompSessionDir(run Run, cfg OmpConfig) string {
	if strings.ToLower(strings.TrimSpace(cfg.Session)) != "per-task" || strings.TrimSpace(run.TaskID) == "" {
		return ""
	}
	return filepath.Join(stateHome(), "foreman-cockpit", "omp", safePathSegment(run.TaskID))
}

func stateHome() string {
	if xdg := os.Getenv("XDG_STATE_HOME"); xdg != "" {
		return xdg
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".local", "state")
	}
	return os.TempDir()
}

func safePathSegment(s string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	if b.Len() == 0 {
		return "task"
	}
	return b.String()
}

func hasOmpSession(dir string) bool {
	found := false
	_ = filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d == nil || d.IsDir() {
			return nil
		}
		found = true
		return filepath.SkipAll
	})
	return found
}

func buildTriageBrief(m model, run Run, briefPath string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Foreman triage brief\n\n")
	fmt.Fprintf(&b, "- Task: %s\n- Run: %s\n- Status: %s\n- Phase: %s\n", run.TaskID, run.RunID, run.Status, run.Phase)
	if run.Attention != "" {
		fmt.Fprintf(&b, "- Attention: %s\n", run.Attention)
	}
	if run.PRURL != "" {
		fmt.Fprintf(&b, "- PR: %s", run.PRURL)
		if run.PRState != "" {
			fmt.Fprintf(&b, " (%s)", run.PRState)
		}
		b.WriteString("\n")
	} else if m.pr.URL != "" {
		fmt.Fprintf(&b, "- PR: %s", m.pr.URL)
		if m.pr.State != "" {
			fmt.Fprintf(&b, " (%s)", m.pr.State)
		}
		b.WriteString("\n")
	}
	b.WriteString("\n## Opening instruction\n\n")
	b.WriteString(ompOpening(run, briefPath, m.config.Integrations.Omp))
	b.WriteString("\n")
	if len(m.events) > 0 || len(m.msgs) > 0 {
		b.WriteString("\n## Recent signals\n\n")
		for i, event := range m.events {
			if i >= 8 {
				break
			}
			line := strings.TrimSpace(event.Detail)
			if line == "" {
				line = event.Type
			}
			if line != "" {
				fmt.Fprintf(&b, "- %s\n", redactBriefLine(line))
			}
		}
		for i, msg := range m.msgs {
			if i >= 5 {
				break
			}
			for _, line := range briefMessageLines(msg) {
				fmt.Fprintf(&b, "- %s\n", redactBriefLine(line))
			}
		}
	}
	appendBriefReports(&b, m.reports)
	appendBriefLogs(&b, m.logs)
	conflicts := conflictedFiles(m.files)
	if len(conflicts) > 0 {
		b.WriteString("\n## Conflicted files\n\n")
		for _, path := range conflicts {
			fmt.Fprintf(&b, "- %s\n", path)
		}
	}
	return b.String()
}

func ompOpening(run Run, brief string, cfg OmpConfig) string {
	attention := strings.ToLower(run.Attention + " " + run.Phase + " " + run.Status)
	switch {
	case strings.Contains(attention, "merge_conflict") || strings.Contains(attention, "conflict"):
		return "Resolve the rebase/merge conflicts in this worktree. Run `git status` first and use " + brief + " for context."
	case strings.Contains(attention, "ci_failed") || strings.Contains(attention, "cicd"):
		return "CI failed. Reproduce the failing build/tests here, fix them, then commit and push. Use " + brief + " for context."
	case strings.Contains(attention, "coderabbit") || strings.Contains(attention, "cli-review"):
		return "Address the CodeRabbit findings for this run. Use " + brief + " for context."
	default:
		return "This Foreman run failed at `" + run.Phase + "`. Investigate using " + brief + " and propose a fix."
	}
}

func conflictedFiles(files []FileChange) []string {
	var out []string
	for _, file := range files {
		if file.Conflict {
			out = append(out, file.Path)
		}
	}
	return out
}

func appendBriefReports(b *strings.Builder, reports []Report) {
	wrote := false
	for _, report := range reports {
		name := strings.TrimSpace(report.Name)
		upper := strings.ToUpper(name)
		if name == "" || (!strings.Contains(upper, "CR_CLI_REPORT") && !strings.Contains(upper, "REVIEW") && !strings.Contains(upper, "FINALIZE_VALIDATION")) {
			continue
		}
		if !wrote {
			b.WriteString("\n## Report excerpts\n\n")
			wrote = true
		}
		fmt.Fprintf(b, "### %s\n\n", name)
		for _, line := range briefExcerptLines(report.Preview, 8) {
			fmt.Fprintf(b, "- %s\n", redactBriefLine(line))
		}
	}
}

func appendBriefLogs(b *strings.Builder, logs []string) {
	var lines []string
	for _, line := range logs {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "fail") || strings.Contains(lower, "error") || strings.Contains(lower, "panic") || strings.Contains(lower, "exception") {
			lines = append(lines, strings.TrimSpace(line))
		}
		if len(lines) >= 8 {
			break
		}
	}
	if len(lines) == 0 {
		return
	}
	b.WriteString("\n## Error log excerpt\n\n")
	for _, line := range lines {
		fmt.Fprintf(b, "- %s\n", redactBriefLine(line))
	}
}

func briefExcerptLines(text string, limit int) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		out = append(out, line)
		if len(out) >= limit {
			break
		}
	}
	return out
}

func redactBriefLine(line string) string {
	lower := strings.ToLower(line)
	if strings.Contains(lower, "token") || strings.Contains(lower, "secret") || strings.Contains(lower, "authorization") {
		return "[redacted sensitive line]"
	}
	return line
}

func triageBriefPath(worktree, runID string) (string, error) {
	wt := expandHome(strings.TrimSpace(worktree))
	if wt == "" || wt == "(cleaned)" {
		return "", errors.New("no worktree available for omp")
	}
	if worktreeIgnoresForeman(wt) {
		dir := filepath.Join(wt, ".foreman")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", err
		}
		return filepath.Join(dir, "triage-"+runID+".md"), nil
	}
	dir, err := os.MkdirTemp("", "foreman-triage-*")
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "triage-"+runID+".md"), nil
}

func writeTriageBrief(worktree, runID, content string) (string, error) {
	path, err := triageBriefPath(worktree, runID)
	if err != nil {
		return "", err
	}
	return path, writeTriageBriefFile(path, content)
}

func writeTriageBriefFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}

func worktreeIgnoresForeman(worktree string) bool {
	data, err := os.ReadFile(filepath.Join(worktree, ".gitignore"))
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == ".foreman" || line == ".foreman/" || line == ".foreman/*" {
			return true
		}
	}
	return false
}

func attachOmp(m model, run Run, plain bool) tea.Cmd {
	cfg := m.config.Integrations.Omp
	mode, err := resolveOmpMode(cfg, run, m.tools, nil)
	if err != nil {
		return func() tea.Msg { return ompDoneMsg{err: err, plain: plain} }
	}
	brief := ""
	if !plain {
		var err error
		brief, err = triageBriefPath(run.Worktree, run.RunID)
		if err != nil {
			return func() tea.Msg { return ompDoneMsg{err: err, mode: mode, plain: plain} }
		}
		if err := writeTriageBriefFile(brief, buildTriageBrief(m, run, brief)); err != nil {
			return func() tea.Msg { return ompDoneMsg{err: err, mode: mode, plain: plain} }
		}
	}
	if mode == "tmux" {
		cmd, err := ompTmuxCommand(run, brief, cfg)
		if err != nil {
			return func() tea.Msg { return ompDoneMsg{err: err, mode: mode, brief: brief, plain: plain} }
		}
		return func() tea.Msg { return ompDoneMsg{err: cmd.Run(), mode: mode, brief: brief, plain: plain} }
	}
	cmd, err := ompInlineCommand(run, brief, cfg)
	if err != nil {
		return func() tea.Msg { return ompDoneMsg{err: err, mode: mode, brief: brief, plain: plain} }
	}
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return ompDoneMsg{err: err, mode: mode, brief: brief, plain: plain} })
}
