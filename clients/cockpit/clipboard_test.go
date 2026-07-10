package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestClipboardCandidatesMatchPlatformConventions(t *testing.T) {
	if got := clipboardCandidates("darwin"); len(got) != 1 || got[0].command != "pbcopy" {
		t.Fatalf("expected darwin pbcopy candidate, got %#v", got)
	}
	if got := clipboardCandidates("windows"); len(got) != 1 || got[0].command != "clip" {
		t.Fatalf("expected windows clip candidate, got %#v", got)
	}
	linux := clipboardCandidates("linux")
	if len(linux) != 3 || linux[0].command != "wl-copy" || linux[1].command != "xclip" || linux[2].command != "xsel" {
		t.Fatalf("expected linux wl-copy/xclip/xsel candidates, got %#v", linux)
	}
}

func TestCopyToClipboardUsesFirstSuccessfulCandidate(t *testing.T) {
	var tried []string
	err := copyToClipboardWithRunner("task-1", []clipboardCandidate{
		{command: "missing"},
		{command: "pbcopy"},
		{command: "should-not-run"},
	}, func(candidate clipboardCandidate, text string) error {
		if text != "task-1" {
			t.Fatalf("expected copied task id, got %q", text)
		}
		tried = append(tried, candidate.command)
		if candidate.command == "pbcopy" {
			return nil
		}
		return fmt.Errorf("unavailable")
	})
	if err != nil {
		t.Fatalf("copy failed: %v", err)
	}
	if strings.Join(tried, ",") != "missing,pbcopy" {
		t.Fatalf("expected stop after first success, tried %v", tried)
	}
}

func TestCopyToClipboardSurfacesCandidateFailures(t *testing.T) {
	err := copyToClipboardWithRunner("task-1", []clipboardCandidate{{command: "pbcopy"}}, func(clipboardCandidate, string) error {
		return fmt.Errorf("clipboard unavailable")
	})
	if err == nil || !strings.Contains(err.Error(), "Failed") && !strings.Contains(err.Error(), "failed") || !strings.Contains(err.Error(), "clipboard unavailable") {
		t.Fatalf("expected clipboard failure details, got %v", err)
	}
}
