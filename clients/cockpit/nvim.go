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

// EditorConfig mirrors the `.foreman/config.yaml` editor block from the spec.
type EditorConfig struct {
	Cmd          string // editor binary, default "nvim"
	Mode         string // auto | remote | inline
	RemoteServer string // explicit --server address; empty = autodetect $NVIM
}

func defaultEditorConfig() EditorConfig {
	cmd := os.Getenv("EDITOR")
	if cmd == "" || !strings.Contains(cmd, "vim") {
		cmd = "nvim"
	}
	return EditorConfig{Cmd: cmd, Mode: "auto"}
}

// target describes what "open in nvim" would act on for the current selection.
type target struct {
	label    string
	path     string
	worktree string
	relPath  string
	base     string
	isFile   bool
	conflict bool
	ok       bool
}

// resolveTarget computes the open target for the selected run + viewer line.
func resolveTarget(m model) target {
	run, ok := m.selectedRun()
	if !ok || !m.openableTab() {
		return target{}
	}
	switch tabNames[m.tab] {
	case "logs":
		return logTarget(run, m.logPath)
	case "reports", "files":
		if line, ok := m.viewer.SelectedLine(); ok && line.Target.ok {
			return line.Target
		}
		if tabNames[m.tab] == "reports" {
			if idx := m.selectedReportIndex(); idx >= 0 {
				r := m.reports[idx]
				return reportTarget(run, r)
			}
		}
		if idx := m.selectedFileIndex(); idx >= 0 && idx < len(m.files) {
			f := m.files[idx]
			base := selectedDiffBase(run, m.config.Integrations)
			return fileTarget(run, f.Path, base, f.Conflict)
		}
	}
	return target{}
}

func logTarget(run Run, logPath string) target {
	if strings.TrimSpace(logPath) == "" {
		logPath = "~/.foreman/logs/" + run.RunID + ".log"
	}
	return target{label: "run log", path: logPath, ok: true}
}

func reportTarget(run Run, r Report) target {
	reportPath := strings.TrimSpace(r.Path)
	if reportPath == "" {
		reportPath = filepath.Join(run.Worktree, "docs", "reports", run.TaskID, r.Name)
	} else if !filepath.IsAbs(reportPath) && run.Worktree != "" && run.Worktree != "(cleaned)" {
		reportPath = filepath.Join(run.Worktree, reportPath)
	}
	return target{label: r.Name, path: reportPath, ok: true}
}

func fileTarget(run Run, relPath, base string, conflict bool) target {
	return target{
		label:    relPath,
		path:     run.Worktree + "/" + relPath,
		worktree: run.Worktree,
		relPath:  relPath,
		base:     base,
		isFile:   true,
		conflict: conflict,
		ok:       true,
	}
}

// serverAddr returns the remote nvim socket to use, if any.
func (e EditorConfig) serverAddr() string {
	if e.RemoteServer != "" {
		return e.RemoteServer
	}
	return os.Getenv("NVIM")
}

// useRemote decides whether to open in a running nvim session.
func (e EditorConfig) useRemote() bool {
	switch e.Mode {
	case "remote":
		return true
	case "inline":
		return false
	default: // auto
		return e.serverAddr() != ""
	}
}

// describe returns a human-readable command + mode string for the action bar.
func describe(e EditorConfig, t target, diff bool) (string, string) {
	if e.useRemote() {
		cmd := e.Cmd + " " + strings.Join(nvimRemoteArgs(e.serverAddr(), t.path, diff, t.conflict, t.describeBasePath()), " ")
		if diff && t.conflict {
			return cmd, "remote 3-way → your attached nvim session"
		}
		if diff {
			return cmd, "remote diff → your attached nvim session"
		}
		return cmd, "remote → your attached nvim session"
	}
	if diff && t.conflict {
		return e.Cmd + " -c 'Gvdiffsplit!' " + t.path, "inline (3-way) → suspends cockpit, resumes on exit"
	}
	if diff {
		return e.Cmd + " -d " + t.describeBasePath() + " " + t.path, "inline diff → suspends cockpit, resumes on exit"
	}
	return e.Cmd + " " + t.path, "inline → suspends cockpit, resumes on exit"
}

func nvimRemoteArgs(server, path string, diff, conflict bool, basePath string) []string {
	if !diff {
		return []string{"--server", server, "--remote", path}
	}
	if conflict {
		cmd := "<Esc>:edit " + nvimExPath(path) + " | Gvdiffsplit!<CR>"
		return []string{"--server", server, "--remote-send", cmd}
	}
	cmd := "<Esc>:edit " + nvimExPath(basePath) + " | diffthis | vert diffsplit " + nvimExPath(path) + "<CR>"
	return []string{"--server", server, "--remote-send", cmd}
}

func (t target) describeBasePath() string {
	if t.base != "" && t.relPath != "" {
		return t.base + ":" + t.relPath
	}
	return "[base]"
}

func nvimExPath(path string) string {
	replacer := strings.NewReplacer(
		"\\", "\\\\",
		" ", "\\ ",
		"\t", "\\\t",
		"|", "\\|",
		"%", "\\%",
		"#", "\\#",
	)
	return replacer.Replace(path)
}

func prepareNvimDiffFiles(t target) (string, string, func(), error) {
	workPath := expandHome(t.path)
	basePath, cleanupBase, err := writeBaseFile(t)
	if err != nil {
		return "", "", cleanupBase, err
	}
	cleanupWork := func() {}
	if _, err := os.Stat(workPath); err != nil {
		file, createErr := os.CreateTemp("", "foreman-cockpit-work-*"+filepath.Ext(t.relPath))
		if createErr != nil {
			cleanupBase()
			return "", "", func() {}, createErr
		}
		_ = file.Close()
		workPath = file.Name()
		cleanupWork = func() { _ = os.Remove(workPath) }
	}
	cleanup := func() {
		cleanupBase()
		cleanupWork()
	}
	return basePath, workPath, cleanup, nil
}

func writeBaseFile(t target) (string, func(), error) {
	cleanup := func() {}
	if strings.TrimSpace(t.worktree) == "" || strings.TrimSpace(t.relPath) == "" || strings.TrimSpace(t.base) == "" {
		return "", cleanup, errors.New("no base revision available for selected diff")
	}
	output, err := exec.Command("git", "-C", expandHome(t.worktree), "show", t.base+":"+t.relPath).Output()
	if err != nil {
		if _, statErr := os.Stat(expandHome(t.path)); statErr == nil {
			output = nil
		} else {
			return "", cleanup, fmt.Errorf("read base file: %w", err)
		}
	}
	file, err := os.CreateTemp("", "foreman-cockpit-base-*"+filepath.Ext(t.relPath))
	if err != nil {
		return "", cleanup, err
	}
	if _, err := file.Write(output); err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		return "", cleanup, err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(file.Name())
		return "", cleanup, err
	}
	cleanup = func() { _ = os.Remove(file.Name()) }
	return file.Name(), cleanup, nil
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~") {
		if home, err := os.UserHomeDir(); err == nil {
			return home + p[1:]
		}
	}
	return p
}

// openInNvim returns a command that opens the target in nvim, preferring a
// running session and falling back to an inline (suspending) launch.
func openInNvim(e EditorConfig, t target, diff bool) tea.Cmd {
	if !t.ok {
		return nil
	}
	path := expandHome(t.path)

	if e.useRemote() {
		return func() tea.Msg {
			basePath := t.describeBasePath()
			if diff && !t.conflict {
				var err error
				basePath, path, _, err = prepareNvimDiffFiles(t)
				if err != nil {
					return nvimDoneMsg{err: err, remote: true, label: t.label}
				}
			}
			c := exec.Command(e.Cmd, nvimRemoteArgs(e.serverAddr(), path, diff, t.conflict, basePath)...)
			err := c.Run()
			return nvimDoneMsg{err: err, remote: true, label: t.label}
		}
	}

	if diff && !t.conflict {
		basePath, workPath, cleanup, err := prepareNvimDiffFiles(t)
		if err != nil {
			return func() tea.Msg { return nvimDoneMsg{err: err, remote: false, label: t.label} }
		}
		c := exec.Command(e.Cmd, "-d", basePath, workPath)
		return tea.ExecProcess(c, func(err error) tea.Msg {
			cleanup()
			return nvimDoneMsg{err: err, remote: false, label: t.label}
		})
	}
	var c *exec.Cmd
	switch {
	case diff && t.conflict:
		c = exec.Command(e.Cmd, "-c", "Gvdiffsplit!", path)
	case diff:
		c = exec.Command(e.Cmd, "-d", path)
	default:
		c = exec.Command(e.Cmd, path)
	}
	return tea.ExecProcess(c, func(err error) tea.Msg {
		return nvimDoneMsg{err: err, remote: false, label: t.label}
	})
}
