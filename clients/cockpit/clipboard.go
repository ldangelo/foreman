package main

import (
	"fmt"
	"os/exec"
	"runtime"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type clipboardCandidate struct {
	command string
	args    []string
}

func clipboardCandidates(goos string) []clipboardCandidate {
	switch goos {
	case "darwin":
		return []clipboardCandidate{{command: "pbcopy"}}
	case "windows":
		return []clipboardCandidate{{command: "clip"}}
	default:
		return []clipboardCandidate{
			{command: "wl-copy"},
			{command: "xclip", args: []string{"-selection", "clipboard"}},
			{command: "xsel", args: []string{"--clipboard", "--input"}},
		}
	}
}

func copyToClipboard(text string) error {
	return copyToClipboardWithRunner(text, clipboardCandidates(runtime.GOOS), runClipboardCommand)
}

func copyToClipboardWithRunner(text string, candidates []clipboardCandidate, run func(clipboardCandidate, string) error) error {
	if len(candidates) == 0 {
		return fmt.Errorf("no clipboard command configured")
	}
	var errors []string
	for _, candidate := range candidates {
		if err := run(candidate, text); err != nil {
			errors = append(errors, candidate.command+": "+err.Error())
			continue
		}
		return nil
	}
	return fmt.Errorf("failed to copy task ID to clipboard (%s)", strings.Join(errors, "; "))
}

func runClipboardCommand(candidate clipboardCandidate, text string) error {
	cmd := exec.Command(candidate.command, candidate.args...)
	cmd.Stdin = strings.NewReader(text)
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	message := strings.TrimSpace(string(output))
	if message == "" {
		message = err.Error()
	}
	return fmt.Errorf("%s", message)
}

func copyTaskID(taskID string) tea.Cmd {
	return func() tea.Msg { return taskCopyDoneMsg{taskID: taskID, err: copyToClipboard(taskID)} }
}
