package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestHTTPClientParsesLiveProjectionShapes(t *testing.T) {
	t.Setenv("COCKPIT_PROJECT_ID", "proj-live")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/tasks":
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"task-live","title":"Live task","priority":"P1","status":"in_progress","project_id":"proj-live"},{"task_id":"task-ready","title":"Ready task","priority":"P2","status":"ready","workflow":"default","project_id":"proj-live"}]}`))
		case "/api/v1/runs":
			w.Write([]byte(`{"ok":true,"runs":[{"run_id":"run-live","task_id":"task-live","status":"running","current_phase":"developer","priority":"P1","updated_at":"2026-07-10T00:00:00Z","status_text":"working"}]}`))
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

	tasks := client.Dispatchable()
	if len(tasks) != 1 || tasks[0].TaskID != "task-ready" || tasks[0].Summary != "Ready task" {
		t.Fatalf("unexpected tasks: %#v", tasks)
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
			w.Write([]byte(`{"ok":true,"tasks":[{"task_id":"active-task","title":"Active task","status":"in-progress","project_id":"proj-live"},{"task_id":"ready-task","title":"Ready task","status":"backlog","project_id":"proj-live"}]}`))
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
	if len(commands) != 2 {
		t.Fatalf("expected two commands, got %#v", commands)
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
