package main

import (
	"os"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestLoadConfigParsesOmpIntegration(t *testing.T) {
	path := t.TempDir() + "/config.yaml"
	data := []byte("integrations:\n  omp:\n    enable: on\n    cmd: omp-dev\n    mode: tmux\n    tmux:\n      split: vertical\n    keepShell: false\n    session: none\n    args: [--model, fast]\n")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	omp := cfg.Integrations.Omp
	if omp.Enable != "on" || omp.Cmd != "omp-dev" || omp.Mode != "tmux" || omp.Tmux.Split != "vertical" || omp.KeepShell || omp.Session != "none" {
		t.Fatalf("unexpected omp config: %+v", omp)
	}
	if got := strings.Join(omp.Args, " "); got != "--model fast" {
		t.Fatalf("unexpected omp args %q", got)
	}
}

func TestResolveOmpModeHonorsAutoTmuxAndValidation(t *testing.T) {
	cfg := defaultConfig().Integrations.Omp
	mode, err := resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}, fakeTools{"omp": true}, []string{"TMUX=/tmp/tmux"})
	if err != nil || mode != "tmux" {
		t.Fatalf("expected auto tmux, mode=%q err=%v", mode, err)
	}
	mode, err = resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}, fakeTools{"omp": true}, []string{"PATH=/bin"})
	if err != nil || mode != "inline" {
		t.Fatalf("expected auto inline, mode=%q err=%v", mode, err)
	}
	_, err = resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "(cleaned)", Status: "failed"}, fakeTools{"omp": true}, nil)
	if err == nil || !strings.Contains(err.Error(), "no worktree") {
		t.Fatalf("expected cleaned worktree error, got %v", err)
	}
	_, err = resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "running", Group: "RUNNING"}, fakeTools{"omp": true}, nil)
	if err == nil || !strings.Contains(err.Error(), "run is active") {
		t.Fatalf("expected active run guard, got %v", err)
	}
}

func TestOmpCommandsUseWorktreeAndBriefing(t *testing.T) {
	cfg := defaultConfig().Integrations.Omp
	cfg.Cmd = "omp-dev"
	cfg.Args = []string{"--model", "fast"}
	cfg.Tmux.Split = "vertical"
	run := Run{TaskID: "task-1", RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}

	inline, err := ompInlineCommand(run, "/tmp/wt/.foreman/triage-run-1.md", cfg)
	if err != nil {
		t.Fatal(err)
	}
	if inline.Dir != "/tmp/wt" || !strings.HasSuffix(inline.Path, "bash") || len(inline.Args) != 3 || !strings.Contains(inline.Args[2], "omp-dev") || !strings.Contains(inline.Args[2], "triage-run-1.md") || !strings.Contains(inline.Args[2], "--model") {
		t.Fatalf("unexpected inline command: dir=%q path=%q args=%v", inline.Dir, inline.Path, inline.Args)
	}

	tmux, err := ompTmuxCommand(run, "/tmp/wt/.foreman/triage-run-1.md", cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(tmux.Path, "tmux") || !strings.Contains(strings.Join(tmux.Args, " "), "split-window -v -c /tmp/wt") || !strings.Contains(strings.Join(tmux.Args, " "), "omp-dev") {
		t.Fatalf("unexpected tmux command: path=%q args=%v", tmux.Path, tmux.Args)
	}
}

func TestBuildTriageBriefIncludesFailureContext(t *testing.T) {
	m := newModel(NewMockClient())
	m.events = []Event{{Type: "ToolCallFinished", Detail: "go test failed", At: "now"}}
	m.files = []FileChange{{Change: "M", Path: "src/conflict.ts", Conflict: true}}
	m.pr = PRStatus{URL: "https://github.com/Fortium/foreman/pull/42", State: "open"}
	run := Run{TaskID: "task-1", RunID: "run-1", Phase: "finalize", Status: "failed", Attention: "failed: merge_conflict", Worktree: "/tmp/wt"}
	brief := buildTriageBrief(m, run)
	for _, want := range []string{"task-1", "run-1", "merge_conflict", "go test failed", "src/conflict.ts", "https://github.com/Fortium/foreman/pull/42"} {
		if !strings.Contains(brief, want) {
			t.Fatalf("expected %q in brief:\n%s", want, brief)
		}
	}
	if strings.Contains(strings.ToLower(brief), "token") || strings.Contains(strings.ToLower(brief), "secret") {
		t.Fatalf("brief should not include secret-like labels:\n%s", brief)
	}
}

func TestPKeyAttachesOmpToSelectedRun(t *testing.T) {
	m := newModelWithConfig(NewMockClient(), defaultConfig(), fakeTools{})
	m.runs = []Run{{Group: "RECENT", TaskID: "task-1", RunID: "run-1", Status: "failed", Worktree: "/tmp/wt"}}
	m.tasks = nil
	m.buildItems()

	_, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	if cmd == nil {
		t.Fatal("expected p to launch omp command")
	}
	msg := cmd()
	updated, _ := m.Update(msg)
	m = updated.(model)
	if !strings.Contains(m.notice, "omp") || !strings.Contains(m.notice, "not found") {
		t.Fatalf("expected omp missing notice from command, got %q", m.notice)
	}
}
