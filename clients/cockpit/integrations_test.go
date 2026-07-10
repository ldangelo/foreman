package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

type fakeTools map[string]bool

func (f fakeTools) Available(name string) bool { return f[name] }

func (f fakeTools) ExtensionAvailable(name string) bool { return f["ext:"+name] }

func TestIntegrationEnabledModes(t *testing.T) {
	tools := fakeTools{"present": true, "missing": false}
	if !integrationEnabled("auto", "present", tools) {
		t.Fatal("auto should enable a tool that is available")
	}
	if integrationEnabled("auto", "missing", tools) {
		t.Fatal("auto should disable a tool that is unavailable")
	}
	if !integrationEnabled("on", "missing", tools) {
		t.Fatal("on should request the integration even when the tool is absent")
	}
	if integrationEnabled("off", "present", tools) {
		t.Fatal("off should disable the integration even when the tool is present")
	}
	if !integrationEnabled("bad-value", "present", tools) {
		t.Fatal("invalid values normalize to auto and should use availability")
	}
}

func TestParseGhExtensions(t *testing.T) {
	available := parseGhExtensions("dlvhdr/gh-dash\tv4.7.0\nsome/gh-enhance\tv1.2.3\n")
	if !available["dash"] {
		t.Fatal("expected gh-dash extension to register as dash")
	}
	if !available["enhance"] {
		t.Fatal("expected gh-enhance extension to register as enhance")
	}
}

func TestLoadConfigDefaultsAndEnvOverrides(t *testing.T) {
	t.Setenv("EDITOR", "nvim")
	t.Setenv("COCKPIT_DIFFNAV", "off")
	t.Setenv("COCKPIT_GHENHANCE", "off")
	cfg, err := loadConfig(t.TempDir() + "/missing.yaml")
	if err != nil {
		t.Fatalf("missing config should use defaults: %v", err)
	}
	if cfg.Integrations.Diffnav.Base != "origin/dev" {
		t.Fatalf("expected default base origin/dev, got %q", cfg.Integrations.Diffnav.Base)
	}
	if cfg.Integrations.Diffnav.Enable != "off" {
		t.Fatalf("expected env override to disable diffnav, got %q", cfg.Integrations.Diffnav.Enable)
	}
	if cfg.Integrations.GhEnhance.Enable != "off" {
		t.Fatalf("expected env override to disable gh enhance, got %q", cfg.Integrations.GhEnhance.Enable)
	}
	if cfg.PR.Provider != "github" {
		t.Fatalf("expected default PR provider github, got %q", cfg.PR.Provider)
	}
}

func TestLoadConfigParsesIntegrations(t *testing.T) {
	path := t.TempDir() + "/config.yaml"
	if err := os.WriteFile(path, []byte("integrations:\n  diffnav:\n    enable: on\n    base: main\n    watch: true\n  ghDash:\n    args: [--repo, Fortium/foreman]\n  ghEnhance:\n    enable: on\n    args: [--branch, foreman/task]\npr:\n  provider: foreman\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Integrations.Diffnav.Enable != "on" || cfg.Integrations.Diffnav.Base != "main" || !cfg.Integrations.Diffnav.Watch {
		t.Fatalf("unexpected diffnav config: %+v", cfg.Integrations.Diffnav)
	}
	if got := strings.Join(cfg.Integrations.GhDash.Args, " "); got != "--repo Fortium/foreman" {
		t.Fatalf("unexpected gh dash args %q", got)
	}
	if cfg.Integrations.GhEnhance.Enable != "on" {
		t.Fatalf("unexpected gh enhance enable %q", cfg.Integrations.GhEnhance.Enable)
	}
	if got := strings.Join(cfg.Integrations.GhEnhance.Args, " "); got != "--branch foreman/task" {
		t.Fatalf("unexpected gh enhance args %q", got)
	}
	if cfg.PR.Provider != "foreman" {
		t.Fatalf("unexpected PR provider %q", cfg.PR.Provider)
	}
}

func TestDiffnavCommandValidationAndShape(t *testing.T) {
	cfg := defaultConfig().Integrations
	cmd, err := diffnavCommand(Run{RunID: "run-1", Worktree: "~/wt with space"}, cfg, fakeTools{"diffnav": true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(cmd.Path, "bash") || len(cmd.Args) != 3 || cmd.Args[1] != "-lc" {
		t.Fatalf("unexpected diffnav command: path=%q args=%v", cmd.Path, cmd.Args)
	}
	if !strings.Contains(cmd.Args[2], "git -C '") || !strings.Contains(cmd.Args[2], "origin/dev") || !strings.Contains(cmd.Args[2], "| diffnav") {
		t.Fatalf("unexpected diffnav pipeline %q", cmd.Args[2])
	}
	if _, err := diffnavCommand(Run{RunID: "run-1"}, cfg, fakeTools{"diffnav": true}); err == nil || !strings.Contains(err.Error(), "no worktree") {
		t.Fatalf("expected empty worktree error, got %v", err)
	}
	if _, err := diffnavCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{}); err == nil || !strings.Contains(err.Error(), "diffnav not found") {
		t.Fatalf("expected missing diffnav error, got %v", err)
	}
}

func TestGhDashCommandUsesConfiguredArgs(t *testing.T) {
	cfg := defaultConfig().Integrations
	cfg.GhDash.Args = []string{"--repo", "Fortium/foreman"}
	cmd, err := ghDashCommand(cfg, fakeTools{"gh": true, "ext:dash": true})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cmd.Args, " ") != "gh dash --repo Fortium/foreman" {
		t.Fatalf("unexpected gh dash args: %v", cmd.Args)
	}
	if _, err := ghDashCommand(cfg, fakeTools{"gh": true}); err == nil || !strings.Contains(err.Error(), "gh dash not found") {
		t.Fatalf("expected missing gh dash extension error, got %v", err)
	}
}

func TestGhEnhanceCommandUsesSelectedRunWorktree(t *testing.T) {
	cfg := defaultConfig().Integrations
	cfg.GhEnhance.Args = []string{"--repo", "Fortium/foreman"}
	cmd, err := ghEnhanceCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{"gh": true, "ext:enhance": true})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cmd.Args, " ") != "gh enhance --repo Fortium/foreman" {
		t.Fatalf("unexpected gh enhance args: %v", cmd.Args)
	}
	if cmd.Dir != "/tmp/wt" {
		t.Fatalf("expected command dir to be selected worktree, got %q", cmd.Dir)
	}
	if _, err := ghEnhanceCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{"gh": true}); err == nil || !strings.Contains(err.Error(), "gh enhance not found") {
		t.Fatalf("expected missing gh enhance extension error, got %v", err)
	}
	if _, err := ghEnhanceCommand(Run{RunID: "run-1"}, cfg, fakeTools{"gh": true, "ext:enhance": true}); err == nil || !strings.Contains(err.Error(), "no worktree") {
		t.Fatalf("expected empty worktree error, got %v", err)
	}
}

func TestDeltaPreviewCommandFallsBackToPlainGitDiff(t *testing.T) {
	cfg := defaultConfig().Integrations
	cmd, usingDelta, err := deltaPreviewCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, "src/a file.go", cfg, fakeTools{})
	if err != nil {
		t.Fatal(err)
	}
	if usingDelta {
		t.Fatal("expected plain git diff when delta is absent")
	}
	if !strings.Contains(cmd.Args[2], "git -C '/tmp/wt' diff 'origin/dev'...HEAD -- 'src/a file.go'") {
		t.Fatalf("unexpected git diff command %q", cmd.Args[2])
	}
}

func TestPRStatusMapsFromRunProjection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/projects", "/api/v1/tasks":
			_, _ = w.Write([]byte(`{"ok":true,"projects":[],"tasks":[]}`))
		case "/api/v1/runs":
			_, _ = w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-pr","task_id":"task-1","status":"running","pr_url":"https://github.com/acme/repo/pull/42","pr_state":"open","pr_head_sha":"abc123","base_branch":"main","branch_name":"foreman/task-1"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	pr := client.PR("run-pr")
	if pr.URL != "https://github.com/acme/repo/pull/42" || pr.Number != "42" || pr.State != "open" || pr.HeadSHA != "abc123" {
		t.Fatalf("unexpected PR status: %+v", pr)
	}
}

func TestPRTabIsViewerButNotOpenable(t *testing.T) {
	m := newModel(NewMockClient())
	m.tab = 6
	if !m.viewerTab() {
		t.Fatal("expected pr tab to be a viewer tab")
	}
	if m.openableTab() {
		t.Fatal("expected pr tab not to be nvim-openable")
	}
}
