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

func TestDiffnavRequiresDeltaForPipeline(t *testing.T) {
	run := Run{RunID: "run-1", Worktree: "/tmp/wt"}
	cfg := defaultConfig().Integrations
	_, err := diffnavCommand(run, cfg, fakeTools{"diffnav": true})
	if err == nil || !strings.Contains(err.Error(), "delta") {
		t.Fatalf("expected missing delta notice before diffnav pipeline, got %v", err)
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
}

func TestLoadConfigParsesCockpitFocus(t *testing.T) {
	path := t.TempDir() + "/config.yaml"
	if err := os.WriteFile(path, []byte("cockpit:\n  focus:\n    style: border\n    dimInactive: false\n  reducedMotion: true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Cockpit.Focus.Style != focusStyleBorder || cfg.Cockpit.Focus.DimInactive || !cfg.Cockpit.ReducedMotion {
		t.Fatalf("unexpected cockpit config: %+v", cfg.Cockpit)
	}

	t.Setenv("COCKPIT_FOCUS_STYLE", "dim")
	t.Setenv("COCKPIT_FOCUS_DIM_INACTIVE", "true")
	t.Setenv("COCKPIT_REDUCED_MOTION", "false")
	cfg, err = loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Cockpit.Focus.Style != focusStyleDim || !cfg.Cockpit.Focus.DimInactive || cfg.Cockpit.ReducedMotion {
		t.Fatalf("expected env cockpit override, got %+v", cfg.Cockpit)
	}
}

func TestLoadConfigParsesTaskListSections(t *testing.T) {
	path := t.TempDir() + "/config.yaml"
	if err := os.WriteFile(path, []byte("cockpit:\n  taskList:\n    width: 58%\n    sections:\n      - name: Hot\n        filter: priority:p0 state:running\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Cockpit.TaskList.Width != "58%" {
		t.Fatalf("expected configured task-list width, got %q", cfg.Cockpit.TaskList.Width)
	}
	if len(cfg.Cockpit.TaskList.Sections) != 1 || cfg.Cockpit.TaskList.Sections[0].Name != "Hot" || cfg.Cockpit.TaskList.Sections[0].Filter != "priority:p0 state:running" {
		t.Fatalf("unexpected task-list sections: %#v", cfg.Cockpit.TaskList.Sections)
	}
}

func TestLoadConfigParsesIntegrations(t *testing.T) {
	path := t.TempDir() + "/config.yaml"
	if err := os.WriteFile(path, []byte("integrations:\n  diffnav:\n    enable: on\n    base: main\n    watch: true\n  ghDash:\n    args: [--repo, Fortium/foreman]\n  ghEnhance:\n    enable: on\n    args: [--branch, foreman/task]\n"), 0o600); err != nil {
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
}

func TestDiffnavCommandValidationAndShape(t *testing.T) {
	cfg := defaultConfig().Integrations
	cmd, err := diffnavCommand(Run{RunID: "run-1", Worktree: "~/wt with space"}, cfg, fakeTools{"diffnav": true, "delta": true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(cmd.Path, "bash") || len(cmd.Args) != 3 || cmd.Args[1] != "-lc" {
		t.Fatalf("unexpected diffnav command: path=%q args=%v", cmd.Path, cmd.Args)
	}
	if !strings.Contains(cmd.Args[2], "git -C '") || !strings.Contains(cmd.Args[2], "origin/dev") || !strings.Contains(cmd.Args[2], "| diffnav") {
		t.Fatalf("unexpected diffnav pipeline %q", cmd.Args[2])
	}
	if !hasEnv(cmd.Env, "DIFFNAV_CONFIG_DIR=") {
		t.Fatalf("expected diffnav command to inherit theme config dir, env=%v", cmd.Env)
	}
	runBase, err := diffnavCommand(Run{RunID: "run-1", Worktree: "/tmp/wt", BaseBranch: "main"}, cfg, fakeTools{"diffnav": true, "delta": true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(runBase.Args[2], "'main'...HEAD") {
		t.Fatalf("expected projected run base branch in diffnav pipeline %q", runBase.Args[2])
	}
	if _, err := diffnavCommand(Run{RunID: "run-1"}, cfg, fakeTools{"diffnav": true, "delta": true}); err == nil || !strings.Contains(err.Error(), "no worktree") {
		t.Fatalf("expected empty worktree error, got %v", err)
	}
	if _, err := diffnavCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{}); err == nil || !strings.Contains(err.Error(), "diffnav not found") {
		t.Fatalf("expected missing diffnav error, got %v", err)
	}
}

func TestDiffnavCommandDisabledAndWatchShape(t *testing.T) {
	cfg := defaultConfig().Integrations
	cfg.Diffnav.Enable = "off"
	if _, err := diffnavCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{"diffnav": true, "delta": true}); err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("expected disabled diffnav error, got %v", err)
	}

	cfg.Diffnav.Enable = "on"
	cfg.Diffnav.Watch = true
	cmd, err := diffnavCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{"diffnav": true, "delta": true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(cmd.Args[2], "diffnav --watch") {
		t.Fatalf("expected diffnav watch flag in command, got %q", cmd.Args[2])
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

func TestGhDashCommandDisabled(t *testing.T) {
	cfg := defaultConfig().Integrations
	cfg.GhDash.Enable = "off"
	if _, err := ghDashCommand(cfg, fakeTools{"gh": true, "ext:dash": true}); err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("expected disabled gh dash error, got %v", err)
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
	if !hasEnv(cmd.Env, "ENHANCE_THEME=tokyonight") {
		t.Fatalf("expected gh enhance theme env, got %v", cmd.Env)
	}
	if _, err := ghEnhanceCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{"gh": true}); err == nil || !strings.Contains(err.Error(), "gh enhance not found") {
		t.Fatalf("expected missing gh enhance extension error, got %v", err)
	}
	if _, err := ghEnhanceCommand(Run{RunID: "run-1"}, cfg, fakeTools{"gh": true, "ext:enhance": true}); err == nil || !strings.Contains(err.Error(), "no worktree") {
		t.Fatalf("expected empty worktree error, got %v", err)
	}
}

func TestGhEnhanceCommandDisabled(t *testing.T) {
	cfg := defaultConfig().Integrations
	cfg.GhEnhance.Enable = "off"
	if _, err := ghEnhanceCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{"gh": true, "ext:enhance": true}); err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("expected disabled gh enhance error, got %v", err)
	}
}

func TestGhCommandsReportMissingGitHubCLI(t *testing.T) {
	cfg := defaultConfig().Integrations
	if _, err := ghDashCommand(cfg, fakeTools{}); err == nil || !strings.Contains(err.Error(), "gh not found") {
		t.Fatalf("expected missing gh error for gh dash, got %v", err)
	}
	if _, err := ghEnhanceCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, cfg, fakeTools{}); err == nil || !strings.Contains(err.Error(), "gh not found") {
		t.Fatalf("expected missing gh error for gh enhance, got %v", err)
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

func TestDeltaPreviewCommandHonorsDisabledAndNoColor(t *testing.T) {
	cfg := defaultConfig().Integrations
	cfg.Delta.Enable = "off"
	_, usingDelta, err := deltaPreviewCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, "src/a.go", cfg, fakeTools{"delta": true})
	if err != nil {
		t.Fatal(err)
	}
	if usingDelta {
		t.Fatal("expected disabled delta preview to fall back to plain git diff")
	}

	cfg.Delta.Enable = "on"
	t.Setenv("NO_COLOR", "1")
	_, usingDelta, err = deltaPreviewCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, "src/a.go", cfg, fakeTools{"delta": true})
	if err != nil {
		t.Fatal(err)
	}
	if usingDelta {
		t.Fatal("expected NO_COLOR delta preview to fall back to plain git diff")
	}
}

func TestDeltaPreviewCommandUsesProjectedRunBaseBranch(t *testing.T) {
	cfg := defaultConfig().Integrations
	cmd, usingDelta, err := deltaPreviewCommand(Run{RunID: "run-1", Worktree: "/tmp/wt", BaseBranch: "main"}, "src/a.go", cfg, fakeTools{})
	if err != nil {
		t.Fatal(err)
	}
	if usingDelta {
		t.Fatal("expected plain git diff when delta is absent")
	}
	if !strings.Contains(cmd.Args[2], "git -C '/tmp/wt' diff 'main'...HEAD -- 'src/a.go'") {
		t.Fatalf("expected projected run base branch in git diff command %q", cmd.Args[2])
	}
}

func TestDeltaPreviewCommandUsesPackagedThemeConfig(t *testing.T) {
	t.Setenv("NO_COLOR", "")
	cfg := defaultConfig().Integrations
	cmd, usingDelta, err := deltaPreviewCommand(Run{RunID: "run-1", Worktree: "/tmp/wt"}, "src/a.go", cfg, fakeTools{"delta": true})
	if err != nil {
		t.Fatal(err)
	}
	if !usingDelta {
		t.Fatal("expected delta preview when delta is available")
	}
	if !strings.Contains(cmd.Args[2], " | delta --config ") || !strings.Contains(cmd.Args[2], "theme/delta.gitconfig") {
		t.Fatalf("expected packaged delta config in command %q", cmd.Args[2])
	}
}

func TestMaybeLoadSelectedDiffPreviewUsesLoadingAndCacheGuards(t *testing.T) {
	m := newModel(NewMockClient())
	run := Run{Group: taskGroupRunning, RunID: "run-1", TaskID: "task-1", Status: "running", Worktree: "/tmp/wt"}
	m.runs = []Run{run}
	m.files = []FileChange{{Change: "M", Path: "src/a.go"}}
	m.tab = 5
	m.tools = fakeTools{}
	m.buildItems()

	cmd := m.maybeLoadSelectedDiffPreview()
	if cmd == nil {
		t.Fatal("expected first selected-file preview request to start loading")
	}
	key := diffPreviewKey(run, "src/a.go", selectedDiffBase(run, m.config.Integrations))
	if !m.diffLoading[key] {
		t.Fatalf("expected diff preview key to be marked loading, got %#v", m.diffLoading)
	}
	if cmd := m.maybeLoadSelectedDiffPreview(); cmd != nil {
		t.Fatal("expected in-flight diff preview to suppress recomputation")
	}
	m.diffLoading = map[string]bool{}
	m.diffPreviews[key] = DiffPreview{RunID: "run-1", Path: "src/a.go", Lines: []string{"cached"}}
	if cmd := m.maybeLoadSelectedDiffPreview(); cmd != nil {
		t.Fatal("expected cached diff preview to suppress recomputation")
	}
}

func hasEnv(env []string, prefix string) bool {
	for _, item := range env {
		if strings.HasPrefix(item, prefix) {
			return true
		}
	}
	return false
}

func TestPRStatusMapsFromRunProjection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/projects", "/api/v1/tasks":
			_, _ = w.Write([]byte(`{"ok":true,"projects":[],"tasks":[]}`))
		case "/api/v1/runs":
			_, _ = w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-pr","task_id":"task-1","status":"running","pr_url":"https://github.com/acme/repo/pull/42","pr_state":"open","pr_head_sha":"abc123","base_ref":"main","branch_name":"foreman/task-1","pr_mergeable":"mergeable","pr_review_decision":"approved","pr_checks":{"passed":3,"failed":1,"pending":2}}]}`))
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
	if pr.BaseBranch != "main" || pr.BranchName != "foreman/task-1" {
		t.Fatalf("expected PR branch fields from base_ref projection: %+v", pr)
	}
	if pr.Mergeable != "mergeable" || pr.ReviewDecision != "approved" || pr.Checks.Passed != 3 || pr.Checks.Failed != 1 || pr.Checks.Pending != 2 {
		t.Fatalf("expected rich PR projection fields: %+v", pr)
	}
}

func TestPRStatusFallsBackToEvents(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/projects", "/api/v1/tasks":
			_, _ = w.Write([]byte(`{"ok":true,"projects":[],"tasks":[]}`))
		case "/api/v1/runs":
			_, _ = w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-pr","task_id":"task-1","status":"running"}]}`))
		case "/api/v1/events":
			if r.URL.Query().Get("run_id") != "run-pr" {
				t.Fatalf("expected PR fallback to query selected run, got %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`{"ok":true,"events":[{"event_type":"PrGateObserved","run_id":"run-pr","checks":{"passed":4,"failed":0,"pending":1},"review":"approved","mergeable":"mergeable"},{"event_type":"PrReady","run_id":"run-pr","pr_url":"https://github.com/acme/repo/pull/43","head_sha":"def456","base_branch":"main","branch_name":"foreman/task-2"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	pr := client.PR("run-pr")
	if pr.URL != "https://github.com/acme/repo/pull/43" || pr.Number != "43" || pr.State != "open" || pr.HeadSHA != "def456" {
		t.Fatalf("unexpected PR event fallback status: %+v", pr)
	}
	if pr.Mergeable != "mergeable" || pr.ReviewDecision != "approved" || pr.Checks.Passed != 4 || pr.Checks.Pending != 1 {
		t.Fatalf("expected PR gate fields from events: %+v", pr)
	}
}

func TestPRStatusFallsBackToDebugTimeline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/projects", "/api/v1/tasks":
			_, _ = w.Write([]byte(`{"ok":true,"projects":[],"tasks":[]}`))
		case "/api/v1/runs":
			_, _ = w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-pr","task_id":"task-1","status":"running"}]}`))
		case "/api/v1/events":
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"ok":false}`))
		case "/api/v1/runs/run-pr/debug":
			_, _ = w.Write([]byte(`{"ok":true,"debug":{"timeline":[{"type":"PrRetargeted","payload":{"run_id":"run-pr","pr_url":"https://github.com/acme/repo/pull/44","head_sha":"abc999","new_base_branch":"release","branch_name":"foreman/task-3"}}]}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	pr := client.PR("run-pr")
	if pr.URL != "https://github.com/acme/repo/pull/44" || pr.Number != "44" || pr.State != "open" || pr.HeadSHA != "abc999" || pr.BaseBranch != "release" {
		t.Fatalf("unexpected PR debug fallback status: %+v", pr)
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
