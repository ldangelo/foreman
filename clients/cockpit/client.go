package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// defaultPhases is the visible slice of the default workflow pipeline.
var defaultPhases = []string{
	"explorer", "developer", "documentation", "qa", "reviewer",
	"cli-review", "finalize", "create-pr", "pr-wait", "merge",
}

// Phase is one step of a run's pipeline.
type Phase struct {
	Name  string
	State string // done | active | pending | fail | retry
}

// Run is a projection of an orchestration run (GET /api/v1/runs).
type Run struct {
	Group       string // RUNNING | RECENT
	TaskID      string
	RunID       string
	Status      string
	Phase       string
	Priority    string
	Title       string
	TaskType    string
	Verdict     string
	Worktree    string
	Branch      string
	ProjectID   string
	Elapsed     string
	Last        string
	Created     string
	Messages    int
	Events      int
	Checks      CheckSummary
	DiffAdded   int
	DiffRemoved int
	Attention   string
	Summary     string
	Pipeline    []Phase
	PRURL       string
	PRState     string
	PRHeadSHA   string
	BaseBranch  string
	BranchName  string
}

// Task is a current-project task shown in the READY bucket.
type Task struct {
	TaskID      string
	Title       string
	Description string
	TaskType    string
	Priority    string
	Status      string
	Depends     string
	Workflow    string
	Summary     string
	ProjectID   string
	Created     string
	Updated     string
}

// Message is an Agent Mail message.
type Message struct {
	At      string
	From    string
	To      string
	Subject string
	Body    string
}

// Event is a pipeline/domain event.
type Event struct {
	At     string
	Type   string
	Detail string
}

// Report is a produced artifact.
type Report struct {
	Name    string
	Size    string
	Status  string
	Preview string // markdown, rendered with Glamour in the drill-down
	Path    string
}

// FileChange is a changed file in a run's worktree.
type FileChange struct {
	Change   string // A | M | D
	Path     string
	Stat     string
	Conflict bool
}

type PhaseDuration struct {
	RunID      string
	PhaseID    string
	Status     string
	DurationMS int
}

type Metrics struct {
	Counters      map[string]int
	Gauges        map[string]int
	PhaseDuration []PhaseDuration
	EmittedAt     string
}

// Client is the read-model contract the cockpit consumes. Every method maps to
// an existing Elixir endpoint; the cockpit holds no authoritative state.
type Client interface {
	ProjectID() string
	Runs() []Run
	Dispatchable() []Task
	Metrics() Metrics
	Messages(runID string) []Message
	Events(runID string) []Event
	Logs(runID string) []string
	LogPath(runID string) string
	Reports(runID string) []Report
	Files(runID string) []FileChange
	DrainErrors() []string
	PR(runID string) PRStatus
	ApproveTask(task Task) error
	UpdateTask(task Task) error
	CreateTask(task Task) error
	RetryRun(run Run) error
	ResetRun(run Run) error
	AttachRun(run Run) error
}

func pipe(activeIdx, failIdx int) []Phase {
	out := make([]Phase, len(defaultPhases))
	for i, name := range defaultPhases {
		state := "pending"
		switch {
		case i == failIdx:
			state = "fail"
		case i < activeIdx:
			state = "done"
		case i == activeIdx:
			state = "active"
		}
		out[i] = Phase{Name: name, State: state}
	}
	return out
}

// ---------------------------------------------------------------------------
// Mock client — realistic canned data so the POC runs with no server.
// ---------------------------------------------------------------------------

type mockClient struct {
	mu    sync.Mutex
	tasks []Task
}

// NewMockClient returns an in-memory client for standalone demos.
func NewMockClient() Client { return &mockClient{tasks: defaultMockTasks()} }

func (*mockClient) ProjectID() string       { return "proj-mock" }
func (c *mockClient) DrainErrors() []string { return nil }
func (*mockClient) Metrics() Metrics {
	return Metrics{
		Counters: map[string]int{
			"phases_started":   18,
			"phases_completed": 14,
			"retries":          2,
			"failures":         1,
			"recoveries":       1,
			"worker_restarts":  0,
		},
		Gauges: map[string]int{"projection_lag": 0},
		PhaseDuration: []PhaseDuration{
			{RunID: "a1b2c3d4", PhaseID: "explorer", Status: "completed", DurationMS: 42000},
			{RunID: "a1b2c3d4", PhaseID: "developer", Status: "completed", DurationMS: 155000},
			{RunID: "a1b2c3d4", PhaseID: "qa", Status: "failed", DurationMS: 39000},
			{RunID: "33cc44dd", PhaseID: "finalize", Status: "failed", DurationMS: 61000},
		},
		EmittedAt: time.Now().Format(time.RFC3339),
	}
}
func (c *mockClient) ApproveTask(task Task) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := range c.tasks {
		if c.tasks[i].TaskID == task.TaskID {
			c.tasks[i].Status = "approved"
			return nil
		}
	}
	return nil
}
func (c *mockClient) UpdateTask(task Task) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := range c.tasks {
		if c.tasks[i].TaskID == task.TaskID {
			c.tasks[i] = task
			return nil
		}
	}
	c.tasks = append(c.tasks, task)
	return nil
}
func (c *mockClient) CreateTask(task Task) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tasks = append(c.tasks, task)
	return nil
}
func (c *mockClient) RetryRun(run Run) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tasks = append(c.tasks, Task{TaskID: run.TaskID, Title: run.Title, TaskType: run.TaskType, Priority: run.Priority, Status: "ready", Summary: run.Summary})
	return nil
}
func (c *mockClient) ResetRun(run Run) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tasks = append(c.tasks, Task{TaskID: run.TaskID, Title: run.Title, TaskType: run.TaskType, Priority: run.Priority, Status: "ready", Summary: run.Summary})
	return nil
}
func (*mockClient) AttachRun(run Run) error {
	if strings.TrimSpace(run.RunID) == "" {
		return fmt.Errorf("run id is required")
	}
	return nil
}
func (*mockClient) PR(runID string) PRStatus {
	switch runID {
	case "a1b2c3d4":
		return PRStatus{
			RunID:          runID,
			Number:         "42",
			URL:            "https://github.com/Fortium/foreman/pull/42",
			State:          "draft",
			Mergeable:      "unknown",
			ReviewDecision: "review_required",
			Checks:         CheckSummary{Passed: 4, Failed: 1, Pending: 2},
			HeadSHA:        "sha-a1b2c3d4",
			BaseBranch:     "origin/dev",
			BranchName:     "foreman-a1b2c",
		}
	case "77aa11bb":
		return PRStatus{
			RunID:          runID,
			Number:         "482",
			URL:            "https://github.com/Fortium/foreman/pull/482",
			State:          "merged",
			Mergeable:      "mergeable",
			ReviewDecision: "approved",
			Checks:         CheckSummary{Passed: 7},
			HeadSHA:        "sha-77aa11bb",
			BaseBranch:     "origin/dev",
			BranchName:     "foreman-77aa1",
		}
	case "33cc44dd":
		return PRStatus{
			RunID:          runID,
			Number:         "483",
			URL:            "https://github.com/Fortium/foreman/pull/483",
			State:          "open",
			Mergeable:      "conflicting",
			ReviewDecision: "changes_requested",
			Checks:         CheckSummary{Passed: 3, Failed: 2},
			HeadSHA:        "sha-33cc44dd",
			BaseBranch:     "origin/dev",
			BranchName:     "foreman-33cc4",
		}
	default:
		return PRStatus{RunID: runID}
	}
}

func (*mockClient) Runs() []Run {
	return []Run{
		{
			Group: "RUNNING", TaskID: "foreman-a1b2c", RunID: "a1b2c3d4", Status: "running",
			Title: "Implement auth middleware", TaskType: "feature",
			Phase: "developer", Priority: "P1", Verdict: "unknown", Elapsed: "4m 12s",
			Worktree: "~/.foreman/worktrees/foreman-a1b2c", Branch: "foreman-a1b2c",
			Last:     "12s ago · progress_update",
			Summary:  "Implementing auth middleware + token refresh. 3 files changed, tests not yet run.",
			Pipeline: pipe(1, -1),
		},
		{
			Group: "RUNNING", TaskID: "foreman-9f8e7", RunID: "9f8e7d6c", Status: "running",
			Title: "Verify VCS backend", TaskType: "test",
			Phase: "qa", Priority: "P0", Verdict: "retrying", Elapsed: "9m 47s",
			Worktree: "~/.foreman/worktrees/foreman-9f8e7", Branch: "foreman-9f8e7",
			Last:     "31s ago · phase.start",
			Summary:  "QA verifying VcsBackend abstraction. Running targeted jujutsu-backend suite.",
			Pipeline: pipe(3, -1),
		},
		{
			Group: "RUNNING", TaskID: "foreman-5a4b3", RunID: "5a4b3c2d", Status: "cooldown",
			Title: "Address CodeRabbit findings", TaskType: "bug",
			Phase: "cr-developer", Priority: "P2", Verdict: "retrying", Elapsed: "1m 06s",
			Worktree: "~/.foreman/worktrees/foreman-5a4b3", Branch: "foreman-5a4b3",
			Last: "6s ago · retry.scheduled", Attention: "retrying: coderabbit_findings (2)",
			Summary:  "Retrying after CodeRabbit findings (2 blocking). Rate-limit cooldown 45s.",
			Pipeline: func() []Phase { p := pipe(5, -1); p[5] = Phase{"cli-review", "retry"}; return p }(),
		},
		{
			Group: "RECENT", TaskID: "foreman-77aa1", RunID: "77aa11bb", Status: "merged",
			Title: "Merge refinery PR", TaskType: "task",
			Phase: "merge", Priority: "P1", Verdict: "pass", Elapsed: "—",
			Worktree: "(cleaned)", Branch: "foreman-77aa1 (deleted)",
			Last:     "38m ago · run.pr.merge",
			Summary:  "Merged to dev. PR #482 fast-forwarded by refinery.",
			Pipeline: pipe(10, -1),
		},
		{
			Group: "RECENT", TaskID: "foreman-33cc4", RunID: "33cc44dd", Status: "failed",
			Title: "Resolve finalize conflict", TaskType: "bug",
			Phase: "finalize", Priority: "P2", Verdict: "fail", Elapsed: "—",
			Worktree: "~/.foreman/worktrees/foreman-33cc4", Branch: "foreman-33cc4",
			Last: "1h 12m ago · run.failed", Attention: "failed: merge_conflict at finalize",
			Summary:  "Failed at finalize: rebase conflict could not auto-resolve. Reset available.",
			Pipeline: pipe(6, 6),
		},
	}
}

func (c *mockClient) Dispatchable() []Task {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := append([]Task(nil), c.tasks...)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Priority != out[j].Priority {
			return out[i].Priority < out[j].Priority
		}
		return out[i].TaskID < out[j].TaskID
	})
	return out
}

func defaultMockTasks() []Task {
	return []Task{
		{TaskID: "foreman-c3845", Title: "Wire PR status into cockpit", TaskType: "feature", Priority: "P0", Status: "ready", Depends: "blocked-by foreman-77aa1 ✓ merged",
			Workflow: "default (10 phases)", Summary: "Unblocked — all dependencies merged. Dispatches next tick (opus, P0)."},
		{TaskID: "foreman-0207c", Title: "Harden task reset confirmation", TaskType: "task", Priority: "P1", Status: "ready", Depends: "no blockers",
			Workflow: "default", Summary: "Ready. Awaiting a free worker slot (2/2 in use)."},
		{TaskID: "foreman-03f40", Title: "Refresh CLI reference", TaskType: "docs", Priority: "P2", Status: "ready", Depends: "no blockers",
			Workflow: "docs (repair-enabled)", Summary: "Ready. Low priority — runs after P0/P1 drain."},
		{TaskID: "foreman-071f9", Title: "Polish file preview states", TaskType: "task", Priority: "P1", Status: "ready", Depends: "no blockers",
			Workflow: "default", Summary: "Ready. Queued behind higher-priority work."},
		{TaskID: "foreman-0ade6", Title: "Refine parent epic leftovers", TaskType: "chore", Priority: "P2", Status: "ready", Depends: "no blockers",
			Workflow: "default", Summary: "Ready. Newly refined from a parent epic."},
	}
}

func (*mockClient) Messages(runID string) []Message {
	switch runID {
	case "a1b2c3d4":
		return []Message{
			{"11:02:14", "explorer", "developer", "handoff", "EXPLORER_REPORT ready: 6 files in scope, no schema changes."},
			{"11:04:41", "developer", "overwatch", "progress", "Added src/auth/middleware.ts; wiring refresh flow."},
			{"11:06:02", "overwatch", "developer", "nudge", "No commit in 90s — checkpoint your work."},
		}
	case "33cc44dd":
		return []Message{
			{"09:40:22", "finalize", "merge-resolver", "conflict", "Conflict in 2 files during rebase onto origin/dev."},
		}
	}
	return nil
}

func (*mockClient) Events(runID string) []Event {
	switch runID {
	case "a1b2c3d4":
		return []Event{
			{"11:00:03", "phase.start", "explorer · haiku"},
			{"11:02:14", "phase.complete", "explorer · verdict=pass"},
			{"11:02:15", "phase.start", "developer · sonnet"},
			{"11:06:20", "progress.update", "3 files changed, +214/-38"},
		}
	case "33cc44dd":
		return []Event{
			{"09:40:22", "verdict.fail", "finalize · merge_conflict"},
			{"09:41:00", "run.failed", "exhausted retries (2/2)"},
		}
	}
	return nil
}

func (*mockClient) Logs(runID string) []string {
	switch runID {
	case "a1b2c3d4":
		return []string{
			"[11:06:19] tool git_status → 3 modified",
			"[11:06:20] tool artifact_write DEVELOPER_REPORT.md",
			"[11:06:31] assistant: running type-check…",
			"[11:06:44] tsc: no errors",
		}
	case "33cc44dd":
		return []string{
			"[09:40:05] git rebase origin/dev",
			"[09:40:22] CONFLICT (content): src/orchestrator/dispatcher.ts",
		}
	}
	return []string{"(no log lines)"}
}

func (*mockClient) LogPath(string) string { return "" }

func (*mockClient) Reports(runID string) []Report {
	switch runID {
	case "a1b2c3d4":
		return []Report{
			{Name: "EXPLORER_REPORT.md", Size: "2.1 KB", Status: "done",
				Preview: "# Explorer report\n\n- 6 files in scope\n- **No** schema changes\n- Entry point: `src/auth/middleware.ts`"},
			{Name: "DEVELOPER_REPORT.md", Size: "draft", Status: "writing",
				Preview: "# Developer report (draft)\n\nImplemented token refresh. Remaining:\n\n1. Wire error path\n2. Add tests"},
		}
	case "33cc44dd":
		return []Report{
			{Name: "FINALIZE_VALIDATION.md", Size: "1.6 KB", Status: "done",
				Preview: "# Finalize validation\n\n> Rebase onto `origin/dev` produced conflicts.\n\nSee `src/orchestrator/dispatcher.ts`."},
		}
	}
	return nil
}

func (*mockClient) Files(runID string) []FileChange {
	switch runID {
	case "a1b2c3d4":
		return []FileChange{
			{"M", "src/auth/middleware.ts", "+118 -12", false},
			{"M", "src/auth/tokens.ts", "+64 -9", false},
			{"A", "src/auth/__tests__/refresh.test.ts", "+32 -0", false},
		}
	case "33cc44dd":
		return []FileChange{
			{"M", "src/orchestrator/dispatcher.ts", "conflict", true},
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// HTTP client — talks to the live Elixir core. Field mapping is best-effort and
// should be verified against a published /api/v1 schema (see ADR 0001, phase 2).
// ---------------------------------------------------------------------------

type httpClient struct {
	base  string
	token string
	hc    *http.Client

	mu       sync.Mutex
	errors   []string
	logPaths map[string]string
}

// NewHTTPClient returns a client bound to a running Elixir server.
func NewHTTPClient(base, token string) Client {
	return &httpClient{base: strings.TrimRight(base, "/"), token: token, hc: &http.Client{Timeout: 5 * time.Second}, logPaths: map[string]string{}}
}

func (c *httpClient) get(p string) (map[string]any, error) {
	return c.getMaybe(p, true)
}

func (c *httpClient) getMaybe(p string, record bool) (map[string]any, error) {
	errf := func(msg string) error {
		if record {
			return c.recordError(msg)
		}
		return fmt.Errorf("%s", msg)
	}
	req, err := http.NewRequest(http.MethodGet, c.base+p, nil)
	if err != nil {
		return nil, errf("build GET " + p + ": " + err.Error())
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, errf("GET " + p + ": " + err.Error())
	}
	defer resp.Body.Close()
	body, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		return nil, errf("read GET " + p + ": " + readErr.Error())
	}
	if resp.StatusCode >= 300 {
		return nil, errf(fmt.Sprintf("GET %s: %s%s", p, resp.Status, bodySnippet(body)))
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, errf(fmt.Sprintf("decode GET %s: %v%s", p, err, bodySnippet(body)))
	}
	return out, nil
}

func (c *httpClient) postCommand(commandType string, payload map[string]any) error {
	commandID := fmt.Sprintf("cockpit-%s-%d", strings.ReplaceAll(commandType, ".", "-"), time.Now().UnixNano())
	body, err := json.Marshal(map[string]any{
		"command_id":   commandID,
		"command_type": commandType,
		"payload":      payload,
		"metadata": map[string]any{
			"correlation_id": commandID,
		},
	})
	if err != nil {
		return c.recordError("encode " + commandType + ": " + err.Error())
	}
	req, err := http.NewRequest(http.MethodPost, c.base+"/api/v1/commands", bytes.NewReader(body))
	if err != nil {
		return c.recordError("build POST /api/v1/commands: " + err.Error())
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return c.recordError("POST /api/v1/commands: " + err.Error())
	}
	defer resp.Body.Close()
	respBody, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		return c.recordError("read POST /api/v1/commands: " + readErr.Error())
	}
	if resp.StatusCode >= 300 {
		return c.recordError(fmt.Sprintf("POST /api/v1/commands %s: %s%s", commandType, resp.Status, bodySnippet(respBody)))
	}
	return nil
}

func (c *httpClient) recordError(msg string) error {
	c.mu.Lock()
	c.errors = append(c.errors, msg)
	c.mu.Unlock()
	return fmt.Errorf("%s", msg)
}

func (c *httpClient) DrainErrors() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.errors) == 0 {
		return nil
	}
	out := append([]string(nil), c.errors...)
	c.errors = nil
	return out
}

func bodySnippet(body []byte) string {
	s := strings.TrimSpace(string(body))
	if s == "" {
		return ""
	}
	if len(s) > 180 {
		s = s[:180] + "…"
	}
	return ": " + s
}

func arr(m map[string]any, key string) []map[string]any {
	return arrValue(m[key])
}

func arrValue(raw any) []map[string]any {
	items, ok := raw.([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(items))
	for _, r := range items {
		if mm, ok := r.(map[string]any); ok {
			out = append(out, mm)
		}
	}
	return out
}

func intValue(raw any) int {
	switch v := raw.(type) {
	case int:
		return v
	case int64:
		return int(v)
	case float64:
		return int(v)
	case json.Number:
		n, _ := v.Int64()
		return int(n)
	case string:
		n := 0
		ok := false
		for _, r := range strings.TrimSpace(v) {
			if r < '0' || r > '9' {
				return 0
			}
			ok = true
			n = n*10 + int(r-'0')
		}
		if ok {
			return n
		}
	}
	return 0
}

func obj(m map[string]any, key string) map[string]any {
	if mm, ok := m[key].(map[string]any); ok {
		return mm
	}
	return nil
}

func stringList(raw any) []string {
	items, ok := raw.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if item != nil {
			out = append(out, fmt.Sprintf("%v", item))
		}
	}
	return out
}

func str(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			return fmt.Sprintf("%v", v)
		}
	}
	return ""
}
func (c *httpClient) projectID() string {
	if projectID := os.Getenv("COCKPIT_PROJECT_ID"); projectID != "" {
		return projectID
	}
	if projectID := os.Getenv("FOREMAN_PROJECT_ID"); projectID != "" {
		return projectID
	}
	m, err := c.get("/api/v1/projects")
	if err != nil {
		return ""
	}
	wd, err := os.Getwd()
	if err != nil {
		return ""
	}
	wd, _ = filepath.Abs(wd)
	bestID, bestLen := "", -1
	for _, p := range arr(m, "projects") {
		projectPath := str(p, "path", "root")
		if projectPath == "" {
			continue
		}
		projectPath, _ = filepath.Abs(projectPath)
		if !pathContains(projectPath, wd) {
			continue
		}
		if len(projectPath) > bestLen {
			bestID, bestLen = str(p, "project_id", "id"), len(projectPath)
		}
	}
	return bestID
}

func (c *httpClient) ProjectID() string { return c.projectID() }

func pathContains(root, child string) bool {
	rel, err := filepath.Rel(root, child)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

func (c *httpClient) taskIndex(projectID string) map[string]Task {
	m, err := c.get("/api/v1/tasks")
	if err != nil {
		return nil
	}
	out := map[string]Task{}
	for _, t := range arr(m, "tasks") {
		task := taskFromMap(t)
		if task.TaskID == "" {
			continue
		}
		if projectID != "" && task.ProjectID != projectID {
			continue
		}
		out[task.TaskID] = task
	}
	return out
}

func taskFromMap(t map[string]any) Task {
	return Task{
		TaskID:      str(t, "task_id", "id"),
		Title:       str(t, "title"),
		Description: str(t, "description"),
		TaskType:    str(t, "task_type", "type"),
		Priority:    str(t, "priority"),
		Status:      str(t, "status"),
		Depends:     taskDepends(t),
		Workflow:    str(t, "workflow"),
		Summary:     str(t, "title"),
		ProjectID:   str(t, "project_id"),
		Created:     str(t, "created_at"),
		Updated:     str(t, "updated_at"),
	}
}

func taskDepends(t map[string]any) string {
	if depends := str(t, "depends_on"); depends != "" {
		return depends
	}
	return strings.Join(stringList(t["dependencies"]), ", ")
}

func activeTaskStatus(status string) bool {
	switch normalizeStatus(status) {
	case "running", "in_progress", "pending", "cooldown":
		return true
	default:
		return false
	}
}

func readyTaskStatus(status string) bool {
	switch normalizeStatus(status) {
	case "completed", "closed", "merged", "running", "in_progress", "pending", "cooldown":
		return false
	default:
		return true
	}
}

func normalizeStatus(status string) string {
	return strings.ReplaceAll(status, "-", "_")
}

func activeRunStatus(status string) bool {
	switch normalizeStatus(status) {
	case "running", "in_progress", "pending", "cooldown":
		return true
	default:
		return false
	}
}

func newerRun(a, b Run) Run {
	if b.Last > a.Last {
		return b
	}
	return a
}

func (c *httpClient) Runs() []Run {
	projectID := c.projectID()
	tasks := c.taskIndex(projectID)
	m, err := c.get("/api/v1/runs")
	if err != nil {
		return nil
	}
	byTask := map[string]Run{}
	for _, r := range arr(m, "runs") {
		taskID := str(r, "task_id")
		if taskID == "" {
			continue
		}
		task, hasTask := tasks[taskID]
		if projectID != "" && !hasTask {
			continue
		}
		status := str(r, "status")
		group := "RECENT"
		if hasTask && activeTaskStatus(task.Status) && activeRunStatus(status) {
			group = "RUNNING"
		}
		phase := str(r, "current_phase", "phase")
		active := indexOf(defaultPhases, phase)
		failIdx := -1
		if status == "failed" || status == "conflict" || task.Status == "failed" {
			failIdx = active
		}
		run := Run{
			Group: group, TaskID: taskID, RunID: str(r, "run_id", "id"),
			Status: status, Phase: phase, Priority: str(r, "priority"),
			Title: str(r, "title", "task_title"), TaskType: str(r, "type", "task_type"),
			Verdict: str(r, "verdict"), Worktree: str(r, "worktree", "worktree_path"), Branch: str(r, "branch", "branch_name"),
			ProjectID: str(r, "project_id"), Created: str(r, "created_at"), Last: str(r, "updated_at", "last"),
			Summary: str(r, "status_text", "summary"), Attention: str(r, "attention", "failure_reason", "reason", "status_reason"),
			Pipeline: pipe(active, failIdx),
			PRURL:    str(r, "pr_url", "pull_request_url"), PRState: str(r, "pr_state"),
			PRHeadSHA: str(r, "pr_head_sha", "head_sha"), BaseBranch: str(r, "base_branch", "base_ref", "target_branch"),
			BranchName:  str(r, "branch_name", "branch"),
			Messages:    firstPositiveInt(intValue(r["messages_count"]), intValue(r["message_count"]), intValue(r["messages"])),
			Events:      firstPositiveInt(intValue(r["events_count"]), intValue(r["event_count"]), intValue(r["events"])),
			Checks:      prStatusFromProjection(str(r, "run_id", "id"), r).Checks,
			DiffAdded:   firstPositiveInt(intValue(r["diff_added"]), intValue(r["additions"]), intValue(r["added"])),
			DiffRemoved: firstPositiveInt(intValue(r["diff_removed"]), intValue(r["deletions"]), intValue(r["removed"])),
		}
		if hasTask {
			run.Priority = task.Priority
			run.Title = task.Title
			run.TaskType = task.TaskType
			if run.Summary == "" {
				run.Summary = task.Title
			}
		}
		if existing, ok := byTask[taskID]; ok {
			run = newerRun(existing, run)
		}
		byTask[taskID] = run
	}
	out := make([]Run, 0, len(byTask))
	for _, run := range byTask {
		out = append(out, run)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Group != out[j].Group {
			return out[i].Group == "RUNNING"
		}
		return out[i].Last > out[j].Last
	})
	return out
}

func (c *httpClient) PR(runID string) PRStatus {
	m, err := c.getMaybe("/api/v1/runs", false)
	if err == nil {
		for _, r := range arr(m, "runs") {
			if str(r, "run_id", "id") != runID {
				continue
			}
			if pr := prStatusFromProjection(runID, r); hasPRStatus(pr) {
				return pr
			}
			break
		}
	}

	if pr := c.prStatusFromEvents(runID); hasPRStatus(pr) {
		return pr
	}
	if pr := c.prStatusFromDebug(runID); hasPRStatus(pr) {
		return pr
	}
	if err != nil {
		return PRStatus{RunID: runID, Err: err.Error()}
	}
	return PRStatus{RunID: runID}
}

func (c *httpClient) prStatusFromEvents(runID string) PRStatus {
	m, err := c.getMaybe("/api/v1/events?run_id="+url.QueryEscape(runID), false)
	if err != nil {
		return PRStatus{RunID: runID}
	}
	return prStatusFromEventRows(runID, arr(m, "events"))
}

func (c *httpClient) prStatusFromDebug(runID string) PRStatus {
	m, err := c.getMaybe("/api/v1/runs/"+url.PathEscape(runID)+"/debug", false)
	if err != nil {
		return PRStatus{RunID: runID}
	}
	return prStatusFromEventRows(runID, arrValue(obj(m, "debug")["timeline"]))
}

func (c *httpClient) Metrics() Metrics {
	m, err := c.get("/api/v1/metrics")
	if err != nil {
		return Metrics{}
	}
	metrics := obj(m, "metrics")
	counters := map[string]int{}
	for key, value := range obj(metrics, "counters") {
		counters[key] = intValue(value)
	}
	gauges := map[string]int{}
	for key, value := range obj(metrics, "gauges") {
		gauges[key] = intValue(value)
	}
	var durations []PhaseDuration
	timers := obj(metrics, "timers")
	for _, raw := range arrValue(timers["phase_duration_ms"]) {
		durations = append(durations, PhaseDuration{
			RunID:      str(raw, "run_id"),
			PhaseID:    str(raw, "phase_id"),
			Status:     str(raw, "status"),
			DurationMS: intValue(raw["duration_ms"]),
		})
	}
	return Metrics{
		Counters:      counters,
		Gauges:        gauges,
		PhaseDuration: durations,
		EmittedAt:     str(metrics, "emitted_at"),
	}
}

func (c *httpClient) Dispatchable() []Task {
	projectID := c.projectID()
	tasks := c.taskIndex(projectID)
	out := make([]Task, 0, len(tasks))
	for _, task := range tasks {
		if readyTaskStatus(task.Status) || activeTaskStatus(task.Status) {
			out = append(out, task)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Priority != out[j].Priority {
			return out[i].Priority < out[j].Priority
		}
		return out[i].TaskID < out[j].TaskID
	})
	return out
}

func (c *httpClient) ApproveTask(task Task) error {
	projectID := task.ProjectID
	if projectID == "" {
		projectID = c.projectID()
	}
	return c.postCommand("task.approve", map[string]any{
		"project_id": projectID,
		"task_id":    task.TaskID,
	})
}

func (c *httpClient) UpdateTask(task Task) error {
	projectID := task.ProjectID
	if projectID == "" {
		projectID = c.projectID()
	}
	payload := map[string]any{
		"project_id":  projectID,
		"task_id":     task.TaskID,
		"title":       task.Title,
		"description": task.Description,
		"type":        task.TaskType,
		"task_type":   task.TaskType,
		"priority":    task.Priority,
		"status":      task.Status,
	}
	return c.postCommand("task.update", payload)
}

func (c *httpClient) CreateTask(task Task) error {
	projectID := task.ProjectID
	if projectID == "" {
		projectID = c.projectID()
	}
	if task.TaskID == "" {
		return fmt.Errorf("task id is required")
	}
	return c.postCommand("task.create", map[string]any{
		"project_id":  projectID,
		"task_id":     task.TaskID,
		"title":       task.Title,
		"description": task.Description,
		"type":        task.TaskType,
		"task_type":   task.TaskType,
		"priority":    task.Priority,
		"status":      task.Status,
		"source":      "cockpit",
	})
}

func (c *httpClient) RetryRun(run Run) error {
	return c.requeueRunTask(run, "run.retry", "retry requested from cockpit")
}

func (c *httpClient) ResetRun(run Run) error {
	return c.requeueRunTask(run, "run.reset", "reset requested from cockpit")
}

func (c *httpClient) requeueRunTask(run Run, commandType string, reason string) error {
	projectID := run.ProjectID
	if projectID == "" {
		projectID = c.projectID()
	}
	if strings.TrimSpace(run.RunID) == "" {
		return fmt.Errorf("run id is required")
	}
	if strings.TrimSpace(run.TaskID) == "" {
		return fmt.Errorf("task id is required")
	}
	return c.postCommand(commandType, map[string]any{
		"project_id": projectID,
		"run_id":     run.RunID,
		"task_id":    run.TaskID,
		"reason":     reason,
		"source":     "cockpit",
	})
}

func (c *httpClient) AttachRun(run Run) error {
	if strings.TrimSpace(run.RunID) == "" {
		return fmt.Errorf("run id is required")
	}
	_, err := c.getMaybe("/api/v1/runs/"+url.PathEscape(run.RunID)+"/attach", true)
	return err
}

func (c *httpClient) Messages(runID string) []Message {
	p := "/api/v1/inbox"
	if runID != "" {
		p += "?run_id=" + url.QueryEscape(runID)
	}
	m, err := c.get(p)
	if err != nil {
		return nil
	}
	messages := arr(m, "inbox")
	if len(messages) == 0 {
		messages = arr(m, "messages")
	}
	var out []Message
	for _, x := range messages {
		if runID != "" && str(x, "run_id") != runID {
			continue
		}
		out = append(out, Message{
			At: str(x, "created_at"), From: str(x, "sender_agent_type"),
			To: str(x, "recipient_agent_type"), Subject: str(x, "subject"), Body: str(x, "body"),
		})
	}
	return out
}

func (c *httpClient) Events(runID string) []Event {
	p := "/api/v1/events"
	if runID != "" {
		p += "?run_id=" + url.QueryEscape(runID)
	}
	m, err := c.getMaybe(p, false)
	if err != nil {
		if runID != "" {
			return c.debugTimelineEvents(runID)
		}
		_ = c.recordError(err.Error())
		return nil
	}
	var out []Event
	for _, x := range arr(m, "events") {
		if runID != "" && str(x, "run_id") != runID {
			continue
		}
		out = append(out, Event{At: str(x, "created_at", "occurred_at"), Type: str(x, "event_type", "type"), Detail: eventDetail(x)})
	}
	return out
}

func (c *httpClient) debugTimelineEvents(runID string) []Event {
	m, err := c.get("/api/v1/runs/" + url.PathEscape(runID) + "/debug")
	if err != nil {
		return nil
	}
	debug := obj(m, "debug")
	var out []Event
	for _, x := range arrValue(debug["timeline"]) {
		out = append(out, Event{At: str(x, "occurred_at", "created_at"), Type: str(x, "type", "event_type"), Detail: eventDetail(x)})
	}
	return out
}

func (c *httpClient) Logs(runID string) []string {
	m, err := c.get("/api/v1/runs/" + url.PathEscape(runID) + "/logs")
	if err != nil {
		return []string{"(logs unavailable: " + err.Error() + ")"}
	}
	logs := obj(m, "logs")
	c.setLogPath(runID, firstNonEmpty(str(logs, "path", "log_path"), str(m, "path", "log_path")))
	entries := arrValue(logs["entries"])
	if len(entries) == 0 {
		entries = arr(m, "logs")
	}
	var out []string
	for _, x := range entries {
		line := str(x, "line", "message")
		if line == "" {
			line = eventDetail(x)
		}
		out = append(out, line)
	}
	return out
}

func (c *httpClient) setLogPath(runID, logPath string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if logPath == "" {
		delete(c.logPaths, runID)
		return
	}
	c.logPaths[runID] = logPath
}

func (c *httpClient) LogPath(runID string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.logPaths[runID]
}

func (c *httpClient) Reports(runID string) []Report {
	m, err := c.get("/api/v1/runs/" + url.PathEscape(runID) + "/report")
	if err != nil {
		return nil
	}
	report := obj(m, "report")
	if len(report) == 0 {
		return reportsFromArray(arr(m, "reports"))
	}
	preview := reportPreview(report)
	var out []Report
	for _, p := range append(stringList(report["report_paths"]), stringList(report["artifact_paths"])...) {
		out = append(out, Report{Name: path.Base(p), Path: p, Status: "recorded", Preview: "`" + p + "`\n\n" + preview})
	}
	if len(out) == 0 {
		out = append(out, Report{Name: "run report", Status: str(report, "status"), Preview: preview})
	}
	return out
}

func eventDetail(x map[string]any) string {
	if detail := str(x, "detail", "message", "reason"); detail != "" {
		return detail
	}
	if phase := str(x, "phase_id"); phase != "" {
		if status := str(x, "status"); status != "" {
			return phase + " · " + status
		}
		return phase
	}
	if payload, ok := x["payload"]; ok && payload != nil {
		if data, err := json.Marshal(payload); err == nil {
			return string(data)
		}
	}
	return ""
}

func reportsFromArray(items []map[string]any) []Report {
	var out []Report
	for _, x := range items {
		out = append(out, Report{Name: str(x, "name"), Path: str(x, "path", "artifact_path", "report_path"), Size: str(x, "size"), Status: str(x, "status"), Preview: str(x, "content")})
	}
	return out
}

func reportPreview(report map[string]any) string {
	var b strings.Builder
	if status := str(report, "status"); status != "" {
		fmt.Fprintf(&b, "Status: %s\n", status)
	}
	if phase := str(report, "current_phase"); phase != "" {
		fmt.Fprintf(&b, "Current phase: %s\n", phase)
	}
	if summary := obj(report, "summary"); len(summary) > 0 {
		if count := str(summary, "event_count"); count != "" {
			fmt.Fprintf(&b, "Events: %s\n", count)
		}
	}
	if b.Len() == 0 {
		data, _ := json.MarshalIndent(report, "", "  ")
		return "```json\n" + string(data) + "\n```"
	}
	return strings.TrimSpace(b.String())
}

func (c *httpClient) Files(runID string) []FileChange {
	if run, ok := c.runProjection(runID); ok {
		if files := fileChangesFromGitWorktree(run); len(files) > 0 {
			return files
		}
	}

	m, err := c.get("/api/v1/runs/" + url.PathEscape(runID) + "/debug")
	if err != nil {
		return nil
	}
	return fileChangesFromTimeline(arrValue(obj(m, "debug")["timeline"]))
}

func (c *httpClient) runProjection(runID string) (Run, bool) {
	m, err := c.getMaybe("/api/v1/runs", false)
	if err != nil {
		return Run{}, false
	}
	for _, r := range arr(m, "runs") {
		if str(r, "run_id", "id") != runID {
			continue
		}
		return Run{
			RunID:      runID,
			Worktree:   str(r, "worktree", "worktree_path"),
			BaseBranch: str(r, "base_branch", "base_ref", "target_branch"),
			BranchName: str(r, "branch_name", "branch"),
		}, true
	}
	return Run{}, false
}

func fileChangesFromGitWorktree(run Run) []FileChange {
	worktree := strings.TrimSpace(run.Worktree)
	if worktree == "" || worktree == "(cleaned)" {
		return nil
	}
	worktree = expandHome(worktree)
	conflicts := gitConflictStatuses(worktree)

	for _, spec := range diffSpecs(run) {
		files := fileChangesFromGitDiff(worktree, spec, conflicts)
		if len(files) > 0 {
			return files
		}
	}
	return conflictFileChanges(conflicts)
}

func diffSpecs(run Run) []string {
	var specs []string
	add := func(spec string) {
		spec = strings.TrimSpace(spec)
		if spec == "" {
			return
		}
		for _, existing := range specs {
			if existing == spec {
				return
			}
		}
		specs = append(specs, spec)
	}
	if run.BaseBranch != "" {
		add(run.BaseBranch + "...HEAD")
		if !strings.HasPrefix(run.BaseBranch, "origin/") {
			add("origin/" + run.BaseBranch + "...HEAD")
		}
	}
	add("origin/dev...HEAD")
	add("origin/main...HEAD")
	add("HEAD")
	add("")
	return specs
}

func fileChangesFromGitDiff(worktree, spec string, conflicts map[string]bool) []FileChange {
	args := []string{"-C", worktree, "diff", "--numstat"}
	if spec != "" {
		args = append(args, spec)
	}
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return nil
	}
	statuses := gitDiffStatuses(worktree, spec)
	var files []FileChange
	seen := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 3 {
			continue
		}
		pathText := strings.TrimSpace(parts[len(parts)-1])
		if pathText == "" || seen[pathText] {
			continue
		}
		seen[pathText] = true
		change := statuses[pathText]
		if change == "" {
			change = "M"
		}
		file := FileChange{
			Change: change,
			Path:   pathText,
			Stat:   "+" + parts[0] + " -" + parts[1],
		}
		if conflicts[pathText] || isUnmergedGitStatus(change) {
			file.Change = "U"
			file.Conflict = true
			file.Stat = "conflict"
		}
		files = append(files, file)
	}
	return files
}

func gitDiffStatuses(worktree, spec string) map[string]string {
	args := []string{"-C", worktree, "diff", "--name-status"}
	if spec != "" {
		args = append(args, spec)
	}
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return nil
	}
	statuses := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pathText := fields[len(fields)-1]
		statuses[pathText] = strings.ToUpper(string([]rune(fields[0])[0]))
	}
	return statuses
}

func gitConflictStatuses(worktree string) map[string]bool {
	out, err := exec.Command("git", "-C", worktree, "status", "--porcelain").Output()
	if err != nil {
		return nil
	}
	conflicts := map[string]bool{}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if len(line) < 4 || !isUnmergedGitStatus(line[:2]) {
			continue
		}
		pathText := strings.TrimSpace(line[3:])
		if i := strings.LastIndex(pathText, " -> "); i >= 0 {
			pathText = strings.TrimSpace(pathText[i+4:])
		}
		if pathText != "" {
			conflicts[pathText] = true
		}
	}
	return conflicts
}

func isUnmergedGitStatus(status string) bool {
	status = strings.ToUpper(strings.TrimSpace(status))
	if status == "AA" || status == "DD" {
		return true
	}
	return strings.Contains(status, "U")
}

func conflictFileChanges(conflicts map[string]bool) []FileChange {
	if len(conflicts) == 0 {
		return nil
	}
	paths := make([]string, 0, len(conflicts))
	for path := range conflicts {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	files := make([]FileChange, 0, len(paths))
	for _, path := range paths {
		files = append(files, FileChange{Change: "U", Path: path, Stat: "conflict", Conflict: true})
	}
	return files
}

func fileChangesFromTimeline(timeline []map[string]any) []FileChange {
	var out []FileChange
	seen := map[string]bool{}
	add := func(file FileChange) {
		file.Path = strings.TrimSpace(file.Path)
		if file.Path == "" || seen[file.Path] {
			return
		}
		file.Change = normalizeFileChangeKind(file.Change)
		seen[file.Path] = true
		out = append(out, file)
	}
	addParsed := func(raw string) {
		change, pathText := parseFileChange(raw)
		add(FileChange{Change: change, Path: pathText})
	}
	var addValue func(any)
	addValue = func(raw any) {
		switch v := raw.(type) {
		case string:
			for _, pathText := range splitFileChangeLines(v) {
				addParsed(pathText)
			}
		case []any:
			for _, item := range v {
				addValue(item)
			}
		case []map[string]any:
			for _, item := range v {
				addValue(item)
			}
		case map[string]any:
			if file, ok := fileChangeFromMap(v); ok {
				add(file)
			}
		}
	}
	keys := []string{"file_changes", "fileChanges", "changed", "files_changed", "filesChanged", "files"}
	for _, entry := range timeline {
		for _, key := range keys {
			addValue(entry[key])
		}
		payload := obj(entry, "payload")
		output := obj(payload, "output")
		details := obj(payload, "details")
		for _, source := range []map[string]any{output, payload, details} {
			for _, key := range keys {
				addValue(source[key])
			}
		}
	}
	return out
}

func fileChangeFromMap(raw map[string]any) (FileChange, bool) {
	pathText := strings.TrimSpace(str(raw, "path", "file", "name"))
	if pathText == "" {
		return FileChange{}, false
	}
	stat := str(raw, "stat")
	_, hasAdditions := raw["additions"]
	_, hasDeletions := raw["deletions"]
	if stat == "" && (hasAdditions || hasDeletions) {
		stat = fmt.Sprintf("+%d -%d", intValue(raw["additions"]), intValue(raw["deletions"]))
	}
	return FileChange{
		Change:   str(raw, "change", "status"),
		Path:     pathText,
		Stat:     stat,
		Conflict: normalizeBool(str(raw, "conflict"), false),
	}, true
}

func normalizeFileChangeKind(change string) string {
	s := strings.ToUpper(strings.TrimSpace(change))
	if s == "" {
		return "M"
	}
	switch {
	case strings.HasPrefix(s, "A"):
		return "A"
	case strings.HasPrefix(s, "D"):
		return "D"
	case strings.HasPrefix(s, "M"):
		return "M"
	default:
		return s
	}
}

func parseFileChange(raw string) (change, pathText string) {
	s := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "-"))
	s = strings.TrimSpace(s)
	if s == "" {
		return "", ""
	}
	fields := strings.Fields(s)
	if len(fields) >= 2 {
		switch strings.ToUpper(fields[0]) {
		case "A", "M", "D":
			return strings.ToUpper(fields[0]), strings.Join(fields[1:], " ")
		}
	}
	return "M", s
}

func stringScalar(raw any) string {
	if s, ok := raw.(string); ok {
		return s
	}
	return ""
}

func splitFileChangeLines(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	return strings.Split(raw, "\n")
}

func indexOf(list []string, v string) int {
	for i, s := range list {
		if s == v {
			return i
		}
	}
	return 0
}
