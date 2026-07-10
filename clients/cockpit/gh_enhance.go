package main

import (
	"errors"
	"os/exec"
	"strings"

	tea "charm.land/bubbletea/v2"
)

type ghEnhanceDoneMsg struct{ err error }

func ghEnhanceCommand(run Run, cfg Integrations, tools ToolResolver) (*exec.Cmd, error) {
	if normalizeEnable(cfg.GhEnhance.Enable) == "off" {
		return nil, errToolDisabled("gh enhance")
	}
	if !tools.Available("gh") {
		return nil, errToolMissing("gh", "GitHub CLI")
	}
	if !tools.ExtensionAvailable("enhance") {
		return nil, errToolMissing("gh enhance", "dlvhdr/gh-enhance")
	}
	worktree := strings.TrimSpace(run.Worktree)
	if worktree == "" || worktree == "(cleaned)" {
		return nil, errors.New("no worktree available for gh enhance")
	}
	args := append([]string{"enhance"}, cfg.GhEnhance.Args...)
	cmd := exec.Command("gh", args...)
	cmd.Dir = expandHome(worktree)
	appendCmdEnv(cmd, "ENHANCE_THEME="+themeTokenGhEnhanceTheme)
	return cmd, nil
}

func openGhEnhance(run Run, cfg Integrations, tools ToolResolver) tea.Cmd {
	cmd, err := ghEnhanceCommand(run, cfg, tools)
	if err != nil {
		return func() tea.Msg { return ghEnhanceDoneMsg{err: err} }
	}
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return ghEnhanceDoneMsg{err: err} })
}
