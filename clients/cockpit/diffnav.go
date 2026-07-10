package main

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type diffnavDoneMsg struct{ err error }

func diffnavCommand(run Run, cfg Integrations, tools ToolResolver) (*exec.Cmd, error) {
	if normalizeEnable(cfg.Diffnav.Enable) == "off" {
		return nil, errToolDisabled("diffnav")
	}
	if !tools.Available("diffnav") {
		return nil, errToolMissing("diffnav", "dlvhdr/diffnav")
	}
	wt := strings.TrimSpace(run.Worktree)
	if wt == "" || wt == "(cleaned)" {
		return nil, errors.New("no worktree available for diffnav")
	}
	base := cfg.Diffnav.Base
	if base == "" {
		base = "origin/dev"
	}
	pipeline := fmt.Sprintf("git -C %s diff %s...HEAD | diffnav", shellQuote(expandHome(wt)), shellQuote(base))
	if cfg.Diffnav.Watch {
		pipeline = fmt.Sprintf("git -C %s diff %s...HEAD | diffnav --watch", shellQuote(expandHome(wt)), shellQuote(base))
	}
	cmd := exec.Command("bash", "-lc", pipeline)
	appendCmdEnv(cmd, "DIFFNAV_CONFIG_DIR="+cockpitThemePath("diffnav"))
	return cmd, nil
}

func openInDiffnav(run Run, cfg Integrations, tools ToolResolver) tea.Cmd {
	cmd, err := diffnavCommand(run, cfg, tools)
	if err != nil {
		return func() tea.Msg { return diffnavDoneMsg{err: err} }
	}
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return diffnavDoneMsg{err: err} })
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}
