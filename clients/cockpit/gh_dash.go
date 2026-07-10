package main

import (
	"os/exec"

	tea "github.com/charmbracelet/bubbletea"
)

type ghDashDoneMsg struct{ err error }

func ghDashCommand(cfg Integrations, tools ToolResolver) (*exec.Cmd, error) {
	if normalizeEnable(cfg.GhDash.Enable) == "off" {
		return nil, errToolDisabled("gh dash")
	}
	if !tools.Available("gh") {
		return nil, errToolMissing("gh", "GitHub CLI")
	}
	args := append([]string{"dash"}, cfg.GhDash.Args...)
	return exec.Command("gh", args...), nil
}

func openGhDash(cfg Integrations, tools ToolResolver) tea.Cmd {
	cmd, err := ghDashCommand(cfg, tools)
	if err != nil {
		return func() tea.Msg { return ghDashDoneMsg{err: err} }
	}
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return ghDashDoneMsg{err: err} })
}
