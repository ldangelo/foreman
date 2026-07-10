package main

import (
	"os"
	"os/exec"
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
		return target{label: "run log", path: "~/.foreman/logs/" + run.RunID + ".log", ok: true}
	case "reports", "files":
		if line, ok := m.viewer.SelectedLine(); ok && line.Target.ok {
			return line.Target
		}
		if tabNames[m.tab] == "reports" {
			if idx := m.selectedReportIndex(); idx >= 0 {
				r := m.reports[idx]
				return target{label: r.Name, path: run.Worktree + "/docs/reports/" + run.TaskID + "/" + r.Name, ok: true}
			}
		}
		if idx := m.selectedFileIndex(); idx >= 0 {
			f := m.files[idx]
			return target{label: f.Path, path: run.Worktree + "/" + f.Path, isFile: true, conflict: f.Conflict, ok: true}
		}
	}
	return target{}
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
		return e.Cmd + " --server $NVIM --remote " + t.path, "remote → your attached nvim session"
	}
	if diff && t.conflict {
		return e.Cmd + " -c 'Gvdiffsplit!' " + t.path, "inline (3-way) → suspends cockpit, resumes on exit"
	}
	if diff {
		return e.Cmd + " -d " + t.path, "inline diff → suspends cockpit, resumes on exit"
	}
	return e.Cmd + " " + t.path, "inline → suspends cockpit, resumes on exit"
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
		args := []string{"--server", e.serverAddr(), "--remote", path}
		c := exec.Command(e.Cmd, args...)
		return func() tea.Msg {
			err := c.Run()
			return nvimDoneMsg{err: err, remote: true, label: t.label}
		}
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
