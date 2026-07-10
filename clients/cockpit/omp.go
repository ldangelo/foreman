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
	if run.Group != "RUNNING" {
		return false
	}
	switch normalizeStatus(run.Status) {
	case "running", "in_progress", "pending":
		return true
	default:
		return false
	}
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
	if cfg.Session == "per-task" && run.TaskID != "" {
		// OMP's session flag may change; keep the launcher configurable by not
		// assuming one here. The stable seed is the briefing file path.
	}
	line := strings.Join(parts, " ")
	if brief == "" {
		return "exec " + line
	}
	message := "Foreman triage brief: " + brief + " — read it first, then work in this tree."
	return "printf %s\\n\\n " + shellQuote(message) + "; exec " + line
}

func quoteArgs(args []string) []string {
	out := make([]string, 0, len(args))
	for _, arg := range args {
		out = append(out, shellQuote(arg))
	}
	return out
}

func buildTriageBrief(m model, run Run) string {
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
	b.WriteString(ompOpening(run, "./.foreman/triage-"+run.RunID+".md", m.config.Integrations.Omp))
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
			line := strings.TrimSpace(msg.Subject)
			if line == "" {
				line = strings.TrimSpace(msg.Body)
			}
			if line != "" {
				fmt.Fprintf(&b, "- %s\n", redactBriefLine(line))
			}
		}
	}
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

func redactBriefLine(line string) string {
	lower := strings.ToLower(line)
	if strings.Contains(lower, "token") || strings.Contains(lower, "secret") || strings.Contains(lower, "authorization") {
		return "[redacted sensitive line]"
	}
	return line
}

func writeTriageBrief(worktree, runID, content string) (string, error) {
	wt := expandHome(strings.TrimSpace(worktree))
	if wt == "" || wt == "(cleaned)" {
		return "", errors.New("no worktree available for omp")
	}
	if worktreeIgnoresForeman(wt) {
		dir := filepath.Join(wt, ".foreman")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", err
		}
		path := filepath.Join(dir, "triage-"+runID+".md")
		return path, os.WriteFile(path, []byte(content), 0o600)
	}
	dir, err := os.MkdirTemp("", "foreman-triage-*")
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "triage-"+runID+".md")
	return path, os.WriteFile(path, []byte(content), 0o600)
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
		brief, err = writeTriageBrief(run.Worktree, run.RunID, buildTriageBrief(m, run))
		if err != nil {
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
