package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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

func TestLoadConfigAppliesOmpEnvOverrides(t *testing.T) {
	t.Setenv("COCKPIT_OMP", "off")
	t.Setenv("COCKPIT_OMP_MODE", "window")
	cfg, err := loadConfig(t.TempDir() + "/missing.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Integrations.Omp.Enable != "off" || cfg.Integrations.Omp.Mode != "window" {
		t.Fatalf("expected OMP env overrides, got %+v", cfg.Integrations.Omp)
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
	_, err = resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "failed", Group: "RUNNING"}, fakeTools{"omp": true}, nil)
	if err == nil || !strings.Contains(err.Error(), "run is active") {
		t.Fatalf("expected running group guard even with stale status, got %v", err)
	}
	cfg.Enable = "off"
	_, err = resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}, fakeTools{"omp": true}, nil)
	if err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("expected disabled omp error, got %v", err)
	}
	cfg.Enable = "on"
	_, err = resolveOmpMode(cfg, Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}, fakeTools{}, nil)
	if err == nil || !strings.Contains(err.Error(), "omp not found") {
		t.Fatalf("expected missing omp error, got %v", err)
	}
}

func TestResolveOmpModeHonorsExplicitModes(t *testing.T) {
	run := Run{RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}
	for _, tc := range []struct {
		configured string
		want       string
	}{
		{configured: "inline", want: "inline"},
		{configured: "tmux", want: "tmux"},
		{configured: "window", want: "tmux"},
	} {
		cfg := defaultConfig().Integrations.Omp
		cfg.Mode = tc.configured
		mode, err := resolveOmpMode(cfg, run, fakeTools{"omp": true}, nil)
		if err != nil || mode != tc.want {
			t.Fatalf("mode %q: expected %q, got mode=%q err=%v", tc.configured, tc.want, mode, err)
		}
	}
}

func TestResolveOmpModeRefusesActiveStatusEvenWhenGroupStale(t *testing.T) {
	cfg := defaultConfig().Integrations.Omp
	for _, status := range []string{"pending", "running", "in_progress", "cooldown"} {
		_, err := resolveOmpMode(cfg, Run{RunID: "run-stale", Worktree: "/tmp/wt", Status: status, Group: "RECENT"}, fakeTools{"omp": true}, nil)
		if err == nil || !strings.Contains(err.Error(), "run is active") {
			t.Fatalf("expected active status guard for %s independent of group, got %v", status, err)
		}
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
	if strings.Contains(inline.Args[2], "exec exec") {
		t.Fatalf("expected inline command to exec omp exactly once, got %q", inline.Args[2])
	}
	if strings.Contains(inline.Args[2], "'-p'") || strings.Contains(inline.Args[2], "\"-p\"") || strings.Contains(inline.Args[2], "--prompt") {
		t.Fatalf("expected attach flow to avoid prompt injection flags, got %q", inline.Args[2])
	}

	cfg.KeepShell = true
	tmux, err := ompTmuxCommand(run, "/tmp/wt/.foreman/triage-run-1.md", cfg)
	if err != nil {
		t.Fatal(err)
	}
	joinedTmux := strings.Join(tmux.Args, " ")
	if !strings.HasSuffix(tmux.Path, "tmux") || !strings.Contains(joinedTmux, "split-window -v -c /tmp/wt") || !strings.Contains(joinedTmux, "omp-dev") || !strings.Contains(joinedTmux, "exec ${SHELL:-/bin/sh}") {
		t.Fatalf("unexpected tmux command: path=%q args=%v", tmux.Path, tmux.Args)
	}
	if strings.Contains(joinedTmux, "exec 'omp-dev'") {
		t.Fatalf("expected keep-shell tmux command to run omp before shell handoff without exec, got %q", joinedTmux)
	}
	cfg.KeepShell = false
	tmux, err = ompTmuxCommand(run, "/tmp/wt/.foreman/triage-run-1.md", cfg)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(tmux.Args, " "), "exec ${SHELL:-/bin/sh}") {
		t.Fatalf("expected keep-shell disabled to omit shell handoff, got %v", tmux.Args)
	}
	if strings.Contains(strings.Join(tmux.Args, " "), "'-p'") || strings.Contains(strings.Join(tmux.Args, " "), "\"-p\"") || strings.Contains(strings.Join(tmux.Args, " "), "--prompt") {
		t.Fatalf("expected tmux attach flow to avoid prompt injection flags, got %v", tmux.Args)
	}
}

func TestOmpTmuxCommandShapesDefaultHorizontalAndWindowModes(t *testing.T) {
	cfg := defaultConfig().Integrations.Omp
	run := Run{TaskID: "task-1", RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}

	horizontal, err := ompTmuxCommand(run, "/tmp/wt/.foreman/triage-run-1.md", cfg)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(horizontal.Args, " ")
	if !strings.Contains(joined, "split-window -h -c /tmp/wt") {
		t.Fatalf("expected default horizontal split, got path=%q args=%v", horizontal.Path, horizontal.Args)
	}

	cfg.Mode = "window"
	window, err := ompTmuxCommand(run, "/tmp/wt/.foreman/triage-run-1.md", cfg)
	if err != nil {
		t.Fatal(err)
	}
	joined = strings.Join(window.Args, " ")
	if !strings.Contains(joined, "new-window -c /tmp/wt -n omp:task-1") {
		t.Fatalf("expected window mode to use tmux new-window, got path=%q args=%v", window.Path, window.Args)
	}
}

func TestOmpPerTaskSessionUsesStableStateDirAndContinuesExistingSession(t *testing.T) {
	stateDir := t.TempDir()
	t.Setenv("XDG_STATE_HOME", stateDir)
	cfg := defaultConfig().Integrations.Omp
	cfg.Cmd = "omp-dev"
	cfg.Session = "per-task"
	run := Run{TaskID: "task/one", RunID: "run-1", Worktree: "/tmp/wt", Status: "failed"}

	first := ompShellLine(run, "", cfg, true)
	sessionDir := filepath.Join(stateDir, "foreman-cockpit", "omp", "task-one")
	if !strings.Contains(first, "--session-dir "+shellQuote(sessionDir)) {
		t.Fatalf("expected stable per-task session dir in command, got %q", first)
	}
	if strings.Contains(first, "--continue") {
		t.Fatalf("did not expect continue before a prior session exists, got %q", first)
	}

	if err := os.MkdirAll(sessionDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessionDir, "session.jsonl"), []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	next := ompShellLine(run, "/tmp/wt/.foreman/triage-run-1.md", cfg, true)
	if !strings.Contains(next, "--continue") {
		t.Fatalf("expected existing per-task session to continue with briefing, got %q", next)
	}
	if strings.Contains(next, "exec exec") || strings.Contains(next, "exec mkdir") {
		t.Fatalf("expected briefing command to create session then exec omp, got %q", next)
	}
}

func TestBuildTriageBriefIncludesFailureContext(t *testing.T) {
	m := newModel(NewMockClient())
	m.events = []Event{{Type: "ToolCallFinished", Detail: "go test failed", At: "now"}}
	m.files = []FileChange{{Change: "M", Path: "src/conflict.ts", Conflict: true}}
	m.pr = PRStatus{URL: "https://github.com/Fortium/foreman/pull/42", State: "open"}
	run := Run{TaskID: "task-1", RunID: "run-1", Phase: "finalize", Status: "failed", Attention: "failed: merge_conflict", Worktree: "/tmp/wt"}
	brief := buildTriageBrief(m, run, "/tmp/wt/.foreman/triage-run-1.md")
	for _, want := range []string{"task-1", "run-1", "merge_conflict", "go test failed", "src/conflict.ts", "https://github.com/Fortium/foreman/pull/42"} {
		if !strings.Contains(brief, want) {
			t.Fatalf("expected %q in brief:\n%s", want, brief)
		}
	}
	if strings.Contains(strings.ToLower(brief), "token") || strings.Contains(strings.ToLower(brief), "secret") {
		t.Fatalf("brief should not include secret-like labels:\n%s", brief)
	}
}

func TestBuildTriageBriefIncludesMessageBodyFailureSignal(t *testing.T) {
	m := newModel(NewMockClient())
	m.msgs = []Message{{Subject: "handoff", Body: "ERROR: integration failed\nSECRET_TOKEN=abc"}}
	run := Run{TaskID: "task-1", RunID: "run-1", Phase: "qa", Status: "failed", Attention: "ci_failed", Worktree: "/tmp/wt"}

	brief := buildTriageBrief(m, run, "/tmp/wt/.foreman/triage-run-1.md")
	if !strings.Contains(brief, "handoff") || !strings.Contains(brief, "ERROR: integration failed") {
		t.Fatalf("expected subject and body failure signal in brief:\n%s", brief)
	}
	if strings.Contains(brief, "SECRET_TOKEN") {
		t.Fatalf("expected secret-like body line to be omitted/redacted:\n%s", brief)
	}
}

func TestBuildTriageBriefRedactsCommonSecretAndBearerLines(t *testing.T) {
	m := newModel(NewMockClient())
	m.msgs = []Message{{
		Subject: "handoff",
		Body: strings.Join([]string{
			"ERROR: integration failed",
			"api_key=abc",
			"Authorization: Bearer secret",
			"github_pat_abc",
			"private_key: secret",
			"password=hunter2",
		}, "\n"),
	}}
	run := Run{TaskID: "task-1", RunID: "run-1", Phase: "qa", Status: "failed", Attention: "ci_failed", Worktree: "/tmp/wt"}

	brief := buildTriageBrief(m, run, "/tmp/wt/.foreman/triage-run-1.md")
	for _, leak := range []string{"api_key", "Authorization", "github_pat", "private_key", "hunter2"} {
		if strings.Contains(brief, leak) {
			t.Fatalf("expected %q to be redacted from brief:\n%s", leak, brief)
		}
	}
	if !strings.Contains(brief, "ERROR: integration failed") {
		t.Fatalf("expected non-secret failure signal to remain:\n%s", brief)
	}
}

func TestBuildTriageBriefIncludesReportsLogsAndRedactsSecrets(t *testing.T) {
	m := newModel(NewMockClient())
	m.reports = []Report{
		{Name: "CR_CLI_REPORT.md", Preview: "token=abc123\nReview finding: fix retry handling"},
		{Name: "FINALIZE_VALIDATION.md", Preview: "Rebase conflict in src/app.ts"},
	}
	m.logs = []string{"ok", "ERROR: test failed", "authorization bearer secret"}
	run := Run{TaskID: "task-1", RunID: "run-1", Phase: "qa", Status: "failed", Attention: "ci_failed", Worktree: "/tmp/wt"}

	brief := buildTriageBrief(m, run, "/tmp/wt/.foreman/triage-run-1.md")
	for _, want := range []string{"Report excerpts", "CR_CLI_REPORT.md", "Review finding", "FINALIZE_VALIDATION.md", "Error log excerpt", "ERROR: test failed"} {
		if !strings.Contains(brief, want) {
			t.Fatalf("expected %q in brief:\n%s", want, brief)
		}
	}
	if strings.Contains(brief, "token=abc123") || strings.Contains(brief, "authorization bearer secret") {
		t.Fatalf("expected secret-like lines redacted:\n%s", brief)
	}
}

func TestWriteTriageBriefUsesWorktreeOnlyWhenForemanIgnored(t *testing.T) {
	worktree := t.TempDir()
	path, err := writeTriageBrief(worktree, "run-1", "brief")
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasPrefix(path, worktree) {
		t.Fatalf("expected temp path when .foreman is not ignored, got %q", path)
	}

	if err := os.WriteFile(filepath.Join(worktree, ".gitignore"), []byte(".foreman/\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	path, err = writeTriageBrief(worktree, "run-2", "brief")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(path, filepath.Join(worktree, ".foreman")) {
		t.Fatalf("expected ignored .foreman path, got %q", path)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("expected triage brief mode 0600, got %v", info.Mode().Perm())
	}
}

func TestTriageBriefOpeningUsesActualWrittenPath(t *testing.T) {
	worktree := t.TempDir()
	run := Run{TaskID: "task-1", RunID: "run-actual", Phase: "qa", Status: "failed", Attention: "ci_failed", Worktree: worktree}
	path, err := triageBriefPath(worktree, run.RunID)
	if err != nil {
		t.Fatal(err)
	}
	brief := buildTriageBrief(newModel(NewMockClient()), run, path)
	if err := writeTriageBriefFile(path, brief); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), path) {
		t.Fatalf("expected brief to point at actual written path %q, got:\n%s", path, body)
	}
	if strings.Contains(string(body), "./.foreman/triage-run-actual.md") {
		t.Fatalf("brief still points at worktree-local path despite temp fallback:\n%s", body)
	}
}

func TestPKeyAttachesOmpToSelectedRun(t *testing.T) {
	m := newModelWithConfig(NewMockClient(), defaultConfig(), fakeTools{})
	m.taskList.MoveSection(3)
	m.runs = []Run{{Group: "RECENT", TaskID: "task-1", RunID: "run-1", Status: "failed", Worktree: "/tmp/wt"}}
	m.tasks = nil
	m.buildItems()

	_, cmd := m.handleKey(keyPress("p"))
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

func TestUppercasePKeyOpensPlainOmpWithoutTriageBrief(t *testing.T) {
	worktree := t.TempDir()
	if err := os.WriteFile(filepath.Join(worktree, ".gitignore"), []byte(".foreman/\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	binDir := t.TempDir()
	marker := filepath.Join(worktree, "tmux-ran")
	tmux := filepath.Join(binDir, "tmux")
	scriptBody := "#!/bin/sh\nprintf '%s\\n' \"$*\" > " + shellQuote(marker) + "\n"
	if err := os.WriteFile(tmux, []byte(scriptBody), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	cfg := defaultConfig()
	cfg.Integrations.Omp.Cmd = "omp-dev"
	cfg.Integrations.Omp.Mode = "tmux"
	cfg.Integrations.Omp.Session = "none"
	cfg.Integrations.Omp.Args = []string{"--probe"}
	m := newModelWithConfig(NewMockClient(), cfg, fakeTools{"omp-dev": true})
	m.taskList.MoveSection(3) // Recent
	m.runs = []Run{{Group: taskGroupRecent, TaskID: "task-1", RunID: "run-1", Status: "failed", Worktree: worktree}}
	m.tasks = nil
	m.buildItems()

	_, cmd := m.handleKey(keyPress("P"))
	if cmd == nil {
		t.Fatal("expected P to launch plain omp command")
	}
	msg := cmd()
	updated, _ := m.Update(msg)
	m = updated.(model)
	if !strings.Contains(m.notice, "opened omp in tmux pane") {
		t.Fatalf("expected plain omp tmux command to close cleanly, got %q", m.notice)
	}
	data, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	output := string(data)
	if !strings.Contains(output, "omp-dev") || !strings.Contains(output, "--probe") || strings.Contains(output, "triage-run-1.md") || strings.Contains(output, "FOREMAN_TRIAGE_BRIEF") {
		t.Fatalf("expected plain omp invocation without triage brief, got:\n%s", output)
	}
	if _, err := os.Stat(filepath.Join(worktree, ".foreman", "triage-run-1.md")); !os.IsNotExist(err) {
		t.Fatalf("expected P not to write a triage brief, stat err=%v", err)
	}
}
