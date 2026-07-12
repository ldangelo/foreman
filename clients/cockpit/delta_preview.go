package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

type DiffPreview struct {
	RunID string
	Path  string
	Base  string
	Lines []string
	Err   string
	Plain bool
}

type diffPreviewMsg struct {
	key     string
	preview DiffPreview
}

func diffPreviewKey(run Run, filePath, base string) string {
	return run.RunID + "\x00" + base + "\x00" + filePath
}

func selectedDiffBase(run Run, cfg Integrations) string {
	if run.BaseBranch != "" {
		return run.BaseBranch
	}
	if cfg.Diffnav.Base != "" {
		return cfg.Diffnav.Base
	}
	return "origin/dev"
}

func deltaPreviewCommand(run Run, filePath string, width int, cfg Integrations, tools ToolResolver) (*exec.Cmd, bool, error) {
	wt := strings.TrimSpace(run.Worktree)
	if wt == "" || wt == "(cleaned)" {
		return nil, false, errors.New("no worktree available for diff preview")
	}
	if strings.TrimSpace(filePath) == "" {
		return nil, false, errors.New("no file selected for diff preview")
	}
	base := selectedDiffBase(run, cfg)
	gitDiff := fmt.Sprintf("git -C %s diff %s...HEAD -- %s", shellQuote(expandHome(wt)), shellQuote(base), shellQuote(filePath))
	useDelta := normalizeEnable(cfg.Delta.Enable) != "off" && os.Getenv("NO_COLOR") == "" && tools.Available("delta")
	if useDelta {
		cmd := exec.Command("bash", "-lc", gitDiff+" | delta --config "+shellQuote(cockpitThemePath("delta.gitconfig"))+" --color-only")
		applyColumns(cmd, width)
		return cmd, true, nil
	}
	cmd := exec.Command("bash", "-lc", gitDiff)
	applyColumns(cmd, width)
	return cmd, false, nil
}

func loadDiffPreview(run Run, filePath string, width int, cfg Integrations, tools ToolResolver) tea.Cmd {
	base := selectedDiffBase(run, cfg)
	key := diffPreviewKey(run, filePath, base)
	return func() tea.Msg {
		cmd, usingDelta, err := deltaPreviewCommand(run, filePath, width, cfg, tools)
		preview := DiffPreview{RunID: run.RunID, Path: filePath, Base: base, Plain: !usingDelta}
		if err != nil {
			preview.Err = err.Error()
			return diffPreviewMsg{key: key, preview: preview}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		cmd = exec.CommandContext(ctx, cmd.Path, cmd.Args[1:]...)
		out, err := cmd.CombinedOutput()
		if ctx.Err() == context.DeadlineExceeded {
			preview.Err = "diff preview timed out"
			return diffPreviewMsg{key: key, preview: preview}
		}
		if err != nil {
			preview.Err = err.Error()
		}
		text := strings.TrimRight(string(out), "\n")
		if text != "" {
			preview.Lines = strings.Split(text, "\n")
		}
		return diffPreviewMsg{key: key, preview: preview}
	}
}

func applyColumns(cmd *exec.Cmd, width int) {
	if width <= 0 {
		return
	}
	cmd.Env = append(os.Environ(), fmt.Sprintf("COLUMNS=%d", width))
}
