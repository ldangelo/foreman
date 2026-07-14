package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestHTTPClientParsesLiveProjectionShapes(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"task-live","title":"Live task","priority":"P1","status":"in_progress","project_id":"proj-live"},{"task_id":"task-ready","title":"Ready task","description":"Detailed task body","task_type":"feature","priority":"P2","status":"ready","workflow":"default","project_id":"proj-live","depends_on":"task-parent","created_at":"2026-07-09T00:00:00Z","updated_at":"2026-07-10T00:00:00Z"},{"task_id":"task-array","title":"Array dependency task","priority":"P3","status":"ready","project_id":"proj-live","dependencies":["task-parent","task-blocker"]}]}`))
		case "/api/v1/runs":
			w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-live","task_id":"task-live","status":"running","current_phase":"developer","priority":"P1","created_at":"2026-07-09T00:00:00Z","updated_at":"2026-07-10T00:00:00Z","status_text":"working","attention":"needs-review","worktree_path":"/tmp/foreman/run-live","branch":"foreman/run-live","base_ref":"main","messages_count":2,"events_count":4,"pr_state":"open","pr_checks":{"passed":3,"failed":1},"additions":12,"deletions":5}]}`))
		case "/api/v1/inbox":
			if r.URL.Query().Get("run_id") != "run-live" {
				t.Fatalf("expected inbox run_id filter, got %q", r.URL.RawQuery)
			}
			w.Write([]byte(`{"ok":true,"inbox":[{"run_id":"run-live","created_at":"2026-07-10T00:01:00Z","sender_agent_type":"developer","recipient_agent_type":"qa","subject":"handoff","body":"ready"}]}`))
		case "/api/v1/events":
			if r.URL.Query().Get("run_id") != "run-live" {
				t.Fatalf("expected events run_id filter, got %q", r.URL.RawQuery)
			}
			w.Write([]byte(`{"ok":true,"events":[{"run_id":"run-live","occurred_at":"2026-07-10T00:02:00Z","event_type":"PhaseStarted","payload":{"phase_id":"developer"}}]}`))
		case "/api/v1/runs/run-live/logs":
			w.Write([]byte(`{"ok":true,"logs":{"run_id":"run-live","path":"/tmp/foreman/run-live/custom.log","mode":"compact","entries":[{"message":"developer started","type":"PhaseStarted"}]}}`))
		case "/api/v1/runs/run-live/report":
			w.Write([]byte(`{"ok":true,"report":{"run_id":"run-live","status":"running","current_phase":"developer","report_paths":["docs/reports/task-live/DEVELOPER_REPORT.md"],"artifact_paths":["artifacts/task-live/build.log"],"summary":{"event_count":3}}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")

	runs := client.Runs()
	if len(runs) != 1 || runs[0].RunID != "run-live" || runs[0].Phase != "developer" {
		t.Fatalf("unexpected runs: %#v", runs)
	}
	if runs[0].Messages != 2 || runs[0].Events != 4 || runs[0].PRState != "open" || runs[0].Checks.Passed != 3 || runs[0].Checks.Failed != 1 || runs[0].DiffAdded != 12 || runs[0].DiffRemoved != 5 || runs[0].Created == "" || runs[0].Last == "" || runs[0].Attention != "needs-review" || runs[0].Worktree != "/tmp/foreman/run-live" || runs[0].BranchName != "foreman/run-live" || runs[0].BaseBranch != "main" {
		t.Fatalf("expected run metadata columns to map from projection, got %#v", runs[0])
	}

	tasks := client.Dispatchable()
	if len(tasks) != 3 || tasks[0].TaskID != "task-live" || tasks[1].TaskID != "task-ready" || tasks[1].Summary != "Ready task" {
		t.Fatalf("unexpected tasks: %#v", tasks)
	}
	if tasks[1].Description != "Detailed task body" || tasks[1].TaskType != "feature" || tasks[1].Priority != "P2" || tasks[1].Depends != "task-parent" || tasks[1].Workflow != "default" || tasks[1].ProjectID != "proj-live" || tasks[1].Created == "" || tasks[1].Updated == "" {
		t.Fatalf("expected rich task fields from live projection, got %#v", tasks[1])
	}
	if tasks[2].Depends != "task-parent, task-blocker" {
		t.Fatalf("expected dependency array from live projection, got %#v", tasks[2])
	}

	messages := client.Messages("run-live")
	if len(messages) != 1 || messages[0].Subject != "handoff" || messages[0].Body != "ready" {
		t.Fatalf("unexpected messages: %#v", messages)
	}

	events := client.Events("run-live")
	if len(events) != 1 || events[0].Type != "PhaseStarted" || !strings.Contains(events[0].Detail, "developer") {
		t.Fatalf("unexpected events: %#v", events)
	}

	logs := client.Logs("run-live")
	if len(logs) != 1 || logs[0] != "developer started" || client.LogPath("run-live") != "/tmp/foreman/run-live/custom.log" {
		t.Fatalf("unexpected logs/path: logs=%#v path=%q", logs, client.LogPath("run-live"))
	}

	reports := client.Reports("run-live")
	if len(reports) != 2 || reports[0].Name != "DEVELOPER_REPORT.md" || reports[0].Path != "docs/reports/task-live/DEVELOPER_REPORT.md" || reports[1].Path != "artifacts/task-live/build.log" || !strings.Contains(reports[0].Preview, "docs/reports/task-live/DEVELOPER_REPORT.md") {
		t.Fatalf("unexpected reports: %#v", reports)
	}

	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("unexpected client errors: %#v", errors)
	}
}

func TestHTTPClientSortsMessagesNewestFirst(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/inbox" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		w.Write([]byte(`{"ok":true,"inbox":[{"run_id":"run-live","created_at":"2026-07-10T00:01:00Z","sender_agent_type":"developer","recipient_agent_type":"qa","subject":"old","body":"old"},{"run_id":"run-live","created_at":"2026-07-10T00:03:00Z","sender_agent_type":"qa","recipient_agent_type":"developer","subject":"new","body":"new"}]}`))
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	messages := client.Messages("run-live")
	if len(messages) != 2 || messages[0].Subject != "new" || messages[1].Subject != "old" {
		t.Fatalf("expected newest-first messages, got %#v", messages)
	}
}

func TestPipelineUsesRunPhaseOrderAndRetryCounts(t *testing.T) {
	pipeline := pipelineForRun(map[string]any{
		"phase_order": []any{"fix", "qa", "merge"},
		"phase_status": map[string]any{
			"fix": "completed",
			"qa":  "retrying",
		},
		"retry_history": []any{
			map[string]any{"phase_id": "qa", "attempt": 1},
			map[string]any{"phase_id": "qa", "attempt": 2},
		},
	}, Task{}, "running", "qa")

	if got, want := len(pipeline), 3; got != want {
		t.Fatalf("expected %d workflow phases, got %#v", want, pipeline)
	}
	if pipeline[0].Name != "fix" || pipeline[0].State != "done" || pipeline[0].Retries != 0 {
		t.Fatalf("expected completed fix phase with zero retries, got %#v", pipeline[0])
	}
	if pipeline[1].Name != "qa" || pipeline[1].State != "retry" || pipeline[1].Retries != 2 {
		t.Fatalf("expected retrying qa phase with two retries, got %#v", pipeline[1])
	}
	if pipeline[2].Name != "merge" || pipeline[2].State != "pending" || pipeline[2].Retries != 0 {
		t.Fatalf("expected pending merge phase with zero retries, got %#v", pipeline[2])
	}
}

func TestPipelineFallsBackToWorkflowDefinition(t *testing.T) {
	home := t.TempDir()
	workflowDir := filepath.Join(home, ".foreman", "workflows")
	if err := os.MkdirAll(workflowDir, 0o755); err != nil {
		t.Fatalf("mkdir workflow dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(workflowDir, "custom-cockpit-test.yaml"), []byte("phases:\n  - name: alpha\n  - name: beta\n"), 0o644); err != nil {
		t.Fatalf("write workflow: %v", err)
	}
	t.Setenv("HOME", home)
	workflowPhaseCache.Delete("custom-cockpit-test")

	pipeline := pipelineForRun(map[string]any{}, Task{Workflow: "custom-cockpit-test (2 phases)"}, "running", "beta")

	if len(pipeline) != 2 || pipeline[0].Name != "alpha" || pipeline[0].State != "done" || pipeline[1].Name != "beta" || pipeline[1].State != "active" {
		t.Fatalf("expected workflow definition phases with beta active, got %#v", pipeline)
	}
}

func TestHTTPClientSurfacesDecodeErrors(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[]}`))
		case "/api/v1/runs":
			w.Write([]byte(`not-json`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	if runs := client.Runs(); len(runs) != 0 {
		t.Fatalf("expected no runs from invalid JSON, got %#v", runs)
	}

	errors := client.DrainErrors()
	if len(errors) != 1 || !strings.Contains(errors[0], "decode GET /api/v1/runs") || !strings.Contains(errors[0], "not-json") {
		t.Fatalf("expected decode error with body snippet, got %#v", errors)
	}
}

func TestHTTPClientParsesMetricsEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/metrics" {
			t.Fatalf("unexpected path %s", r.URL.String())
		}
		w.Write([]byte(`{"ok":true,"metrics":{"counters":{"phases_started":3,"failures":"1"},"gauges":{"projection_lag":2},"timers":{"phase_duration_ms":[{"run_id":"run-1","phase_id":"qa","status":"failed","duration_ms":1500}]},"emitted_at":"2026-07-10T00:00:00Z"}}`))
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	metrics := client.Metrics()
	if metrics.Counters["phases_started"] != 3 || metrics.Counters["failures"] != 1 {
		t.Fatalf("unexpected counters: %#v", metrics.Counters)
	}
	if metrics.Gauges["projection_lag"] != 2 {
		t.Fatalf("unexpected gauges: %#v", metrics.Gauges)
	}
	if len(metrics.PhaseDuration) != 1 || metrics.PhaseDuration[0].RunID != "run-1" || metrics.PhaseDuration[0].DurationMS != 1500 {
		t.Fatalf("unexpected phase durations: %#v", metrics.PhaseDuration)
	}
	if metrics.EmittedAt != "2026-07-10T00:00:00Z" {
		t.Fatalf("unexpected emitted_at: %q", metrics.EmittedAt)
	}
}

func TestHTTPClientMetricsErrorsAreSurfaced(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":{"code":"METRICS_DOWN"}}`, http.StatusBadGateway)
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	metrics := client.Metrics()
	if len(metrics.Counters) != 0 || len(metrics.Gauges) != 0 || len(metrics.PhaseDuration) != 0 {
		t.Fatalf("expected empty metrics on HTTP failure, got %#v", metrics)
	}
	errors := client.DrainErrors()
	if len(errors) != 1 || !strings.Contains(errors[0], "GET /api/v1/metrics: 502 Bad Gateway") || !strings.Contains(errors[0], "METRICS_DOWN") {
		t.Fatalf("expected metrics error with body snippet, got %#v", errors)
	}
}

func TestHTTPClientDoesNotTreatStaleRunsAsRunningTasks(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"closed-task","title":"Closed task","status":"closed","project_id":"proj-live"},{"task_id":"other-task","title":"Other task","status":"in_progress","project_id":"other-project"}]}`))
		case "/api/v1/runs":
			w.Write([]byte(`{"ok":true,"runs":[{"run_id":"stale-run","task_id":"closed-task","status":"in_progress","current_phase":"developer","updated_at":"2026-07-10T00:00:00Z"},{"run_id":"other-run","task_id":"other-task","status":"in_progress","current_phase":"developer","updated_at":"2026-07-10T00:01:00Z"}]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	runs := NewHTTPClient(server.URL, "").Runs()
	if len(runs) != 1 {
		t.Fatalf("expected only the current project's linked run, got %#v", runs)
	}
	if runs[0].RunID != "stale-run" || runs[0].Group != "RECENT" {
		t.Fatalf("expected stale in-progress run for closed task to be recent, got %#v", runs[0])
	}
}

func TestHTTPClientTreatsHyphenatedInProgressTaskAsRunning(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"active-task","title":"Active task","task_type":"feature","priority":"P0","status":"in-progress","project_id":"proj-live"},{"task_id":"ready-task","title":"Ready task","priority":"P2","status":"backlog","project_id":"proj-live"}]}`))
		case "/api/v1/runs":
			w.Write([]byte(`{"ok":true,"runs":[{"run_id":"active-run","task_id":"active-task","status":"in_progress","current_phase":"developer","priority":"","updated_at":"2026-07-10T00:00:00Z"}]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	runs := client.Runs()
	if len(runs) != 1 || runs[0].RunID != "active-run" || runs[0].Group != "RUNNING" {
		t.Fatalf("expected hyphenated in-progress task with active run to be RUNNING, got %#v", runs)
	}
	if runs[0].Title != "Active task" || runs[0].TaskType != "feature" || runs[0].Priority != "P0" {
		t.Fatalf("expected run title/type/priority from task projection, got title=%q type=%q priority=%q", runs[0].Title, runs[0].TaskType, runs[0].Priority)
	}
	tasks := client.Dispatchable()
	if len(tasks) != 2 || tasks[0].TaskID != "active-task" || tasks[1].TaskID != "ready-task" {
		t.Fatalf("expected active and ready task projections for task-list classification, got %#v", tasks)
	}
}

func TestHTTPClientKeepsActiveTaskWithoutRunVisible(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"pending-task","title":"Pending task","status":"pending","project_id":"proj-live"},{"task_id":"ready-task","title":"Ready task","status":"backlog","project_id":"proj-live"}]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	tasks := NewHTTPClient(server.URL, "").Dispatchable()
	if len(tasks) != 2 || tasks[0].TaskID != "pending-task" || tasks[1].TaskID != "ready-task" {
		t.Fatalf("expected active task without run to stay visible to the cockpit, got %#v", tasks)
	}
}

func TestHTTPClientReadyTasksComeFromCurrentProjectTaskState(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"backlog-task","status":"backlog","project_id":"proj-live"},{"task_id":"failed-task","status":"failed","project_id":"proj-live"},{"task_id":"closed-task","status":"closed","project_id":"proj-live"},{"task_id":"other-task","status":"backlog","project_id":"other-project"}]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	tasks := NewHTTPClient(server.URL, "").Dispatchable()
	if len(tasks) != 2 || tasks[0].TaskID != "backlog-task" || tasks[1].TaskID != "failed-task" {
		t.Fatalf("expected current project backlog and failed tasks only, got %#v", tasks)
	}
}

func TestHTTPClientPostsReadyTaskActions(t *testing.T) {
	var commands []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/api/v1/commands" {
			t.Fatalf("unexpected path %s", r.URL.String())
		}
		var command map[string]any
		if err := json.NewDecoder(r.Body).Decode(&command); err != nil {
			t.Fatalf("decode command: %v", err)
		}
		commands = append(commands, command)
		w.WriteHeader(http.StatusAccepted)
		w.Write([]byte(`{"ok":true,"events":["evt-1"],"projection_version":1}`))
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	task := Task{
		TaskID: "task-ready", ProjectID: "proj-live", Title: "Ready task",
		Description: "old", TaskType: "bug", Priority: "P2", Status: "backlog",
	}
	if err := client.ApproveTask(task); err != nil {
		t.Fatalf("approve: %v", err)
	}
	task.Title = "Edited task"
	task.Description = "new"
	task.Status = "ready"
	if err := client.UpdateTask(task); err != nil {
		t.Fatalf("update: %v", err)
	}
	created := Task{
		TaskID: "task-new", ProjectID: "proj-live", Title: "New task",
		Description: "fresh", TaskType: "feature", Priority: "1", Status: "backlog",
	}
	if err := client.CreateTask(created); err != nil {
		t.Fatalf("create: %v", err)
	}
	run := Run{RunID: "run-live", TaskID: "task-ready", ProjectID: "proj-live"}
	if err := client.RetryRun(run); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if err := client.ResetRun(run); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if len(commands) != 5 {
		t.Fatalf("expected five commands, got %#v", commands)
	}
	if commands[0]["command_type"] != "task.approve" {
		t.Fatalf("expected task.approve command, got %#v", commands[0])
	}
	approvePayload := commands[0]["payload"].(map[string]any)
	if approvePayload["project_id"] != "proj-live" || approvePayload["task_id"] != "task-ready" {
		t.Fatalf("unexpected approve payload: %#v", approvePayload)
	}
	if commands[1]["command_type"] != "task.update" {
		t.Fatalf("expected task.update command, got %#v", commands[1])
	}
	updatePayload := commands[1]["payload"].(map[string]any)
	if updatePayload["project_id"] != "proj-live" || updatePayload["title"] != "Edited task" || updatePayload["description"] != "new" || updatePayload["type"] != "bug" || updatePayload["task_type"] != "bug" || updatePayload["priority"] != "P2" || updatePayload["status"] != "ready" {
		t.Fatalf("unexpected update payload: %#v", updatePayload)
	}
	if commands[2]["command_type"] != "task.create" {
		t.Fatalf("expected task.create command, got %#v", commands[2])
	}
	createPayload := commands[2]["payload"].(map[string]any)
	if createPayload["project_id"] != "proj-live" || createPayload["task_id"] != "task-new" || createPayload["title"] != "New task" || createPayload["description"] != "fresh" || createPayload["type"] != "feature" || createPayload["task_type"] != "feature" || createPayload["priority"] != "1" || createPayload["source"] != "cockpit" {
		t.Fatalf("unexpected create payload: %#v", createPayload)
	}
	if commands[3]["command_type"] != "run.retry" {
		t.Fatalf("expected retry command, got %#v", commands[3])
	}
	retryPayload := commands[3]["payload"].(map[string]any)
	if retryPayload["run_id"] != "run-live" || retryPayload["task_id"] != "task-ready" {
		t.Fatalf("unexpected retry payload: %#v", retryPayload)
	}
	if commands[4]["command_type"] != "run.reset" {
		t.Fatalf("expected reset command, got %#v", commands[4])
	}
	resetPayload := commands[4]["payload"].(map[string]any)
	if resetPayload["run_id"] != "run-live" || resetPayload["task_id"] != "task-ready" {
		t.Fatalf("unexpected reset payload: %#v", resetPayload)
	}
}

func TestHTTPClientRequestsAttachEndpoint(t *testing.T) {
	var gotPath, gotAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		gotPath = r.URL.EscapedPath()
		gotAuth = r.Header.Get("Authorization")
		w.Write([]byte(`{"ok":true,"attach":{"status":"ready"}}`))
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "secret")
	if err := client.AttachRun(Run{RunID: "run/with space"}); err != nil {
		t.Fatalf("attach: %v", err)
	}
	if gotPath != "/api/v1/runs/run%2Fwith%20space/attach" {
		t.Fatalf("unexpected attach path %q", gotPath)
	}
	if gotAuth != "Bearer secret" {
		t.Fatalf("expected auth header, got %q", gotAuth)
	}
}
func TestHTTPClientFallsBackToDebugTimelineWhenEventsEndpointFails(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/events":
			http.Error(w, "", http.StatusInternalServerError)
		case "/api/v1/runs/run-live/debug":
			w.Write([]byte(`{"ok":true,"debug":{"timeline":[{"type":"PhaseStarted","occurred_at":"2026-07-10T00:02:00Z","phase_id":"developer"}]}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	events := client.Events("run-live")
	if len(events) != 1 || events[0].Type != "PhaseStarted" || !strings.Contains(events[0].Detail, "developer") {
		t.Fatalf("unexpected fallback events: %#v", events)
	}
	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("fallback should not surface the failed events endpoint, got %#v", errors)
	}
}

func TestHTTPClientPrefersWorktreeDiffForFiles(t *testing.T) {
	repo := t.TempDir()
	runGit(t, repo, "init")
	runGit(t, repo, "config", "user.email", "cockpit@example.invalid")
	runGit(t, repo, "config", "user.name", "Cockpit Test")
	writeFile(t, repo, "keep.txt", "keep\n")
	writeFile(t, repo, "remove.txt", "remove\n")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "base")
	runGit(t, repo, "branch", "-M", "main")
	runGit(t, repo, "checkout", "-b", "foreman-run")
	writeFile(t, repo, "keep.txt", "keep\nchanged\n")
	writeFile(t, repo, "new.txt", "new\n")
	runGit(t, repo, "rm", "remove.txt")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "changes")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/runs":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok": true,
				"runs": []map[string]any{{
					"run_id":   "run-live",
					"worktree": repo,
					"base_ref": "main",
				}},
			})
		case "/api/v1/runs/run-live/debug":
			t.Fatalf("worktree diff should avoid debug fallback")
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	files := client.Files("run-live")
	byPath := map[string]FileChange{}
	for _, file := range files {
		byPath[file.Path] = file
	}
	if byPath["keep.txt"].Change != "M" || byPath["keep.txt"].Stat != "+1 -0" {
		t.Fatalf("expected modified keep.txt with numstat, got %#v", files)
	}
	if byPath["new.txt"].Change != "A" || byPath["new.txt"].Stat != "+1 -0" {
		t.Fatalf("expected added new.txt with numstat, got %#v", files)
	}
	if byPath["remove.txt"].Change != "D" || byPath["remove.txt"].Stat != "+0 -1" {
		t.Fatalf("expected deleted remove.txt with numstat, got %#v", files)
	}
	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("worktree diff should not surface errors, got %#v", errors)
	}
}
func TestHTTPClientUsesForemanWorktreeFallbackForProjectedFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	repo := filepath.Join(home, ".foreman", "worktrees", "proj-live", "task-ready")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatalf("mkdir fallback worktree: %v", err)
	}
	runGit(t, repo, "init")
	runGit(t, repo, "config", "user.email", "cockpit@example.invalid")
	runGit(t, repo, "config", "user.name", "Cockpit Test")
	writeFile(t, repo, "keep.txt", "keep\n")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "base")
	runGit(t, repo, "branch", "-M", "main")
	runGit(t, repo, "checkout", "-b", "foreman-run")
	writeFile(t, repo, "keep.txt", "keep\nchanged\n")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "changes")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/runs":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok": true,
				"runs": []map[string]any{{
					"run_id":     "run-live",
					"task_id":    "task-ready",
					"project_id": "proj-live",
					"base_ref":   "main",
				}},
			})
		case "/api/v1/runs/run-live/debug":
			t.Fatalf("foreman worktree fallback should avoid debug fallback")
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	files := client.Files("run-live")
	if len(files) != 1 || files[0].Path != "keep.txt" || files[0].Change != "M" {
		t.Fatalf("expected fallback foreman worktree diff, got %#v", files)
	}
}

func TestHTTPClientDerivesFilesFromProjectBranchWhenWorktreeMissing(t *testing.T) {
	repo := t.TempDir()
	runGit(t, repo, "init")
	runGit(t, repo, "config", "user.email", "cockpit@example.invalid")
	runGit(t, repo, "config", "user.name", "Cockpit Test")
	writeFile(t, repo, "keep.txt", "keep\n")
	writeFile(t, repo, "remove.txt", "remove\n")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "base")
	runGit(t, repo, "branch", "-M", "main")
	runGit(t, repo, "checkout", "-b", "foreman/foreman-37350")
	writeFile(t, repo, "keep.txt", "keep\nchanged\n")
	writeFile(t, repo, "new.txt", "new\n")
	runGit(t, repo, "rm", "remove.txt")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "changes")
	runGit(t, repo, "checkout", "main")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/runs":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok": true,
				"runs": []map[string]any{{
					"run_id":      "run-live",
					"project_id":  "project-live",
					"base_branch": "main",
					"branch_name": "foreman/foreman-37350",
				}},
			})
		case "/api/v1/projects":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok": true,
				"projects": []map[string]any{{
					"project_id": "project-live",
					"path":       repo,
				}},
			})
		case "/api/v1/runs/run-live/debug":
			t.Fatalf("project branch diff should avoid debug fallback")
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	files := client.Files("run-live")
	byPath := map[string]FileChange{}
	for _, file := range files {
		byPath[file.Path] = file
	}
	if byPath["keep.txt"].Change != "M" || byPath["keep.txt"].Stat != "+1 -0" {
		t.Fatalf("expected modified keep.txt from branch diff, got %#v", files)
	}
	if byPath["new.txt"].Change != "A" || byPath["new.txt"].Stat != "+1 -0" {
		t.Fatalf("expected added new.txt from branch diff, got %#v", files)
	}
	if byPath["remove.txt"].Change != "D" || byPath["remove.txt"].Stat != "+0 -1" {
		t.Fatalf("expected deleted remove.txt from branch diff, got %#v", files)
	}
	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("project branch diff should not surface errors, got %#v", errors)
	}
}

func TestHTTPClientMarksWorktreeMergeConflicts(t *testing.T) {
	repo := t.TempDir()
	runGit(t, repo, "init")
	runGit(t, repo, "config", "user.email", "cockpit@example.invalid")
	runGit(t, repo, "config", "user.name", "Cockpit Test")
	writeFile(t, repo, "conflict.txt", "base\n")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "base")
	runGit(t, repo, "branch", "-M", "main")
	runGit(t, repo, "checkout", "-b", "foreman-run")
	writeFile(t, repo, "conflict.txt", "branch\n")
	runGit(t, repo, "commit", "-am", "branch")
	runGit(t, repo, "checkout", "main")
	writeFile(t, repo, "conflict.txt", "main\n")
	runGit(t, repo, "commit", "-am", "main")
	runGit(t, repo, "checkout", "foreman-run")
	runGitWantFailure(t, repo, "merge", "main")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/runs":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok": true,
				"runs": []map[string]any{{
					"run_id":   "run-live",
					"worktree": repo,
					"base_ref": "main",
				}},
			})
		case "/api/v1/runs/run-live/debug":
			t.Fatalf("worktree conflict detection should avoid debug fallback")
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	files := NewHTTPClient(server.URL, "").Files("run-live")
	if len(files) == 0 {
		t.Fatal("expected conflicted worktree files")
	}
	byPath := map[string]FileChange{}
	for _, file := range files {
		byPath[file.Path] = file
	}
	if file := byPath["conflict.txt"]; file.Change != "U" || file.Stat != "conflict" || !file.Conflict {
		t.Fatalf("expected conflict metadata from preferred worktree diff, got %#v from %#v", file, files)
	}
}

func TestHTTPClientDerivesFilesFromDebugTimeline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/runs":
			http.NotFound(w, r)
		case "/api/v1/runs/run-live/debug":
			w.Write([]byte(`{"ok":true,"debug":{"timeline":[{"type":"ToolCallFinished","payload":{"output":{"changed":["M src/main.go","A docs/guide.md"],"filesChanged":"- src/cli/board.ts\n- D old.txt"}}}]}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	files := client.Files("run-live")
	if len(files) != 4 || files[0].Path != "src/main.go" || files[0].Change != "M" || files[1].Path != "docs/guide.md" || files[1].Change != "A" || files[3].Path != "old.txt" || files[3].Change != "D" {
		t.Fatalf("unexpected files: %#v", files)
	}
	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("debug fallback should not surface missing run projection, got %#v", errors)
	}
}

func TestHTTPClientDerivesStructuredFilesFromDebugTimeline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/runs":
			http.NotFound(w, r)
		case "/api/v1/runs/run-live/debug":
			w.Write([]byte(`{"ok":true,"debug":{"timeline":[{"type":"ToolCallFinished","file_changes":[{"path":"lib/debug.ex","change":"M","additions":2,"deletions":13,"conflict":true}],"payload":{"details":{"file_changes":[{"file":"docs/guide.md","status":"A","additions":5,"deletions":0}]},"output":{"changed":[{"path":"src/main.go","status":"D","additions":0,"deletions":7}]}}}]}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client := NewHTTPClient(server.URL, "")
	files := client.Files("run-live")
	if len(files) != 3 {
		t.Fatalf("expected three structured files, got %#v", files)
	}
	byPath := map[string]FileChange{}
	for _, file := range files {
		byPath[file.Path] = file
	}
	if file := byPath["lib/debug.ex"]; file.Change != "M" || file.Stat != "+2 -13" || !file.Conflict {
		t.Fatalf("unexpected top-level file_changes entry: %#v", file)
	}
	if file := byPath["docs/guide.md"]; file.Change != "A" || file.Stat != "+5 -0" {
		t.Fatalf("unexpected details file_changes entry: %#v", file)
	}
	if file := byPath["src/main.go"]; file.Change != "D" || file.Stat != "+0 -7" {
		t.Fatalf("unexpected output changed entry: %#v", file)
	}
}

func TestMockClientPRDataCoversCurrentDemoRuns(t *testing.T) {
	client := NewMockClient()
	want := map[string]string{
		"a1b2c3d4": "draft",
		"77aa11bb": "merged",
		"33cc44dd": "open",
	}
	for runID, state := range want {
		pr := client.PR(runID)
		if pr.URL == "" || pr.State != state {
			t.Fatalf("expected mock PR for %s with state %s, got %#v", runID, state, pr)
		}
	}
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v failed: %v\n%s", args, err, string(out))
	}
}

func runGitWantFailure(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err == nil {
		t.Fatalf("git %v unexpectedly succeeded:\n%s", args, string(out))
	}
}

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(dir+"/"+name, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestHTTPClientLiveServerSmoke(t *testing.T) {
	base := os.Getenv("FOREMAN_LIVE_SMOKE_URL")
	if base == "" {
		t.Skip("FOREMAN_LIVE_SMOKE_URL is not set")
	}

	client := NewHTTPClient(base, os.Getenv("FOREMAN_SERVER_AUTH_TOKEN"))
	runs := client.Runs()
	tasks := client.Dispatchable()
	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("live projection reads failed: %#v", errors)
	}

	if len(runs) > 0 {
		runID := runs[0].RunID
		_ = client.Messages(runID)
		_ = client.Events(runID)
		_ = client.Logs(runID)
		_ = client.Reports(runID)
		if errors := client.DrainErrors(); len(errors) != 0 {
			t.Fatalf("live run detail reads failed for %s: %#v", runID, errors)
		}
	}

	t.Logf("live cockpit smoke read %d runs and %d dispatchable tasks", len(runs), len(tasks))
}
