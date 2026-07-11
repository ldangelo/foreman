package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestHTTPClientParsesLiveProjectionShapes(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"task-live","title":"Live task","priority":"P1","status":"in_progress","project_id":"proj-live"},{"task_id":"task-ready","title":"Ready task","priority":"P2","status":"ready","workflow":"default","project_id":"proj-live","dependencies":["task-parent","task-blocker"]}]}`))
		case "/api/v1/runs":
			w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-live","task_id":"task-live","status":"running","current_phase":"developer","priority":"P1","created_at":"2026-07-09T00:00:00Z","updated_at":"2026-07-10T00:00:00Z","status_text":"working","messages_count":2,"events_count":4,"pr_state":"open","pr_checks":{"passed":3,"failed":1},"additions":12,"deletions":5}]}`))
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
			w.Write([]byte(`{"ok":true,"logs":{"run_id":"run-live","mode":"compact","entries":[{"message":"developer started","type":"PhaseStarted"}]}}`))
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
	if runs[0].Messages != 2 || runs[0].Events != 4 || runs[0].PRState != "open" || runs[0].Checks.Passed != 3 || runs[0].Checks.Failed != 1 || runs[0].DiffAdded != 12 || runs[0].DiffRemoved != 5 || runs[0].Created == "" || runs[0].Last == "" {
		t.Fatalf("expected run metadata columns to map from projection, got %#v", runs[0])
	}

	tasks := client.Dispatchable()
	if len(tasks) != 1 || tasks[0].TaskID != "task-ready" || tasks[0].Summary != "Ready task" {
		t.Fatalf("unexpected tasks: %#v", tasks)
	}
	if tasks[0].Depends != "task-parent, task-blocker" {
		t.Fatalf("expected dependencies from live projection, got %#v", tasks[0])
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
	if len(logs) != 1 || logs[0] != "developer started" {
		t.Fatalf("unexpected logs: %#v", logs)
	}

	reports := client.Reports("run-live")
	if len(reports) != 2 || reports[0].Name != "DEVELOPER_REPORT.md" || !strings.Contains(reports[0].Preview, "docs/reports/task-live/DEVELOPER_REPORT.md") {
		t.Fatalf("unexpected reports: %#v", reports)
	}

	if errors := client.DrainErrors(); len(errors) != 0 {
		t.Fatalf("unexpected client errors: %#v", errors)
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
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"active-task","title":"Active task","task_type":"feature","status":"in-progress","project_id":"proj-live"},{"task_id":"ready-task","title":"Ready task","status":"backlog","project_id":"proj-live"}]}`))
		case "/api/v1/runs":
			w.Write([]byte(`{"ok":true,"runs":[{"run_id":"active-run","task_id":"active-task","status":"in_progress","current_phase":"developer","updated_at":"2026-07-10T00:00:00Z"}]}`))
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
	if runs[0].Title != "Active task" || runs[0].TaskType != "feature" {
		t.Fatalf("expected run title/type from task projection, got title=%q type=%q", runs[0].Title, runs[0].TaskType)
	}
	tasks := client.Dispatchable()
	if len(tasks) != 1 || tasks[0].TaskID != "ready-task" {
		t.Fatalf("expected active task excluded from READY, got %#v", tasks)
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
	if len(commands) != 7 {
		t.Fatalf("expected seven commands, got %#v", commands)
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
	if updatePayload["title"] != "Edited task" || updatePayload["description"] != "new" || updatePayload["status"] != "ready" {
		t.Fatalf("unexpected update payload: %#v", updatePayload)
	}
	if commands[2]["command_type"] != "task.create" {
		t.Fatalf("expected task.create command, got %#v", commands[2])
	}
	createPayload := commands[2]["payload"].(map[string]any)
	if createPayload["task_id"] != "task-new" || createPayload["title"] != "New task" || createPayload["task_type"] != "feature" || createPayload["source"] != "cockpit" {
		t.Fatalf("unexpected create payload: %#v", createPayload)
	}
	if commands[3]["command_type"] != "run.update" || commands[4]["command_type"] != "task.update" {
		t.Fatalf("expected retry to reset run then ready task, got %#v %#v", commands[3], commands[4])
	}
	retryRunPayload := commands[3]["payload"].(map[string]any)
	if retryRunPayload["run_id"] != "run-live" || retryRunPayload["status"] != "reset" {
		t.Fatalf("unexpected retry run payload: %#v", retryRunPayload)
	}
	retryTaskPayload := commands[4]["payload"].(map[string]any)
	if retryTaskPayload["task_id"] != "task-ready" || retryTaskPayload["status"] != "ready" {
		t.Fatalf("unexpected retry task payload: %#v", retryTaskPayload)
	}
	if commands[5]["command_type"] != "run.update" || commands[6]["command_type"] != "task.update" {
		t.Fatalf("expected reset to reset run then ready task, got %#v %#v", commands[5], commands[6])
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
					"run_id":      "run-live",
					"worktree":    repo,
					"base_branch": "main",
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

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v failed: %v\n%s", args, err, string(out))
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
