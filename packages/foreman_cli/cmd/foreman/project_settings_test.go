package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// recordingServer answers every request with status/body and records the
// last request body, method and path.
type recordedRequest struct {
	method, path string
	body         []byte
	calls        int
}

func recordingServer(t *testing.T, status int, response string) (*client.Client, *recordedRequest) {
	t.Helper()
	rec := &recordedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read body: %v", err)
		}
		rec.method, rec.path, rec.body = r.Method, r.URL.Path, body
		rec.calls++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(response))
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, rec
}

const acceptedBody = `{"status":"accepted","result":{"events":1}}`

func decodeEnvelope(t *testing.T, rec *recordedRequest) commandEnvelope {
	t.Helper()
	if rec.calls == 0 {
		t.Fatal("no request reached the server")
	}
	if rec.method != http.MethodPost || rec.path != "/api/commands" {
		t.Fatalf("request = %s %s, want POST /api/commands", rec.method, rec.path)
	}
	var env commandEnvelope
	if err := json.Unmarshal(rec.body, &env); err != nil {
		t.Fatalf("decode envelope: %v: %s", err, rec.body)
	}
	return env
}

func TestProjectLifecycleVerbEnvelopes(t *testing.T) {
	cases := []struct {
		verb, wantType, wantOut string
		args                    []string
		wantPayload             map[string]any
	}{
		{"pause", "project.pause", "paused project p1", []string{"--reason", "release freeze", "p1"}, map[string]any{"project_id": "p1", "reason": "release freeze"}},
		{"pause", "project.pause", "paused project p1", []string{"p1"}, map[string]any{"project_id": "p1"}},
		{"resume", "project.resume", "resumed project p1", []string{"p1"}, map[string]any{"project_id": "p1"}},
		{"reactivate", "project.reactivate", "reactivated project p1", []string{"p1"}, map[string]any{"project_id": "p1"}},
	}
	for _, tc := range cases {
		t.Run(tc.verb+"/"+strings.Join(tc.args, " "), func(t *testing.T) {
			c, rec := recordingServer(t, http.StatusCreated, acceptedBody)
			stdout := captureStdout(t, func() {
				if err := runProject(c, append([]string{tc.verb}, tc.args...)); err != nil {
					t.Fatalf("runProject: %v", err)
				}
			})
			env := decodeEnvelope(t, rec)
			if env.Type != tc.wantType {
				t.Fatalf("type = %q, want %q", env.Type, tc.wantType)
			}
			if !reflect.DeepEqual(env.Payload, tc.wantPayload) {
				t.Fatalf("payload = %v, want %v", env.Payload, tc.wantPayload)
			}
			if env.CommandID == "" || !strings.Contains(stdout, tc.wantOut) {
				t.Fatalf("command_id=%q stdout=%q, want %q", env.CommandID, stdout, tc.wantOut)
			}
		})
	}
}

func TestProjectLifecycleCommandIDsAreStableAndDistinct(t *testing.T) {
	id := func(args ...string) string {
		c, rec := recordingServer(t, http.StatusCreated, acceptedBody)
		captureStdout(t, func() {
			if err := runProject(c, args); err != nil {
				t.Fatalf("runProject %v: %v", args, err)
			}
		})
		return decodeEnvelope(t, rec).CommandID
	}
	if id("pause", "p1") != id("pause", "p1") {
		t.Fatal("same pause produced different command ids")
	}
	if id("pause", "p1") == id("resume", "p1") || id("resume", "p1") == id("reactivate", "p1") {
		t.Fatal("different verbs share a command id")
	}
	if id("pause", "p1") == id("pause", "p2") {
		t.Fatal("different projects share a command id")
	}
	if id("pause", "--idempotency-key", "k", "p1") != sha256HexTest("project.pause.k") {
		t.Fatal("idempotency key not honoured")
	}
}

func runUpdate(t *testing.T, args ...string) (commandEnvelope, error) {
	t.Helper()
	c, rec := recordingServer(t, http.StatusCreated, acceptedBody)
	var err error
	captureStdout(t, func() { err = projectUpdate(c, args) })
	if err != nil {
		if rec.calls != 0 {
			t.Fatalf("request sent despite error %v", err)
		}
		return commandEnvelope{}, err
	}
	return decodeEnvelope(t, rec), nil
}

func TestProjectUpdateSettingsPayload(t *testing.T) {
	env, err := runUpdate(t,
		"--goal", "ship it", "--instructions", "be careful",
		"--thread-model", "m1", "--thread-effort", "high",
		"--coordinator-provider", "claude", "--coordinator-model", "m2", "--coordinator-effort", "low",
		"--max-concurrent-runs", "4", "--daily-thread-cap", "20",
		"--clear", "goal", "--clear", "thread_model",
		"p1")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"project_id": "p1", "goal": "ship it", "instructions": "be careful",
		"thread_model": "m1", "thread_effort": "high",
		"coordinator_provider": "claude", "coordinator_model": "m2", "coordinator_effort": "low",
		"max_concurrent_runs": float64(4), "daily_thread_cap": float64(20),
		"cleared_settings": []any{"goal", "thread_model"},
	}
	if !reflect.DeepEqual(env.Payload, want) {
		t.Fatalf("payload = %v\nwant     %v", env.Payload, want)
	}
	if _, ok := env.Payload["task_provider"]; ok {
		t.Fatal("task_provider must be omitted when --task-provider is not given")
	}
	if _, ok := env.Payload["status"]; ok {
		t.Fatal("status must never be sent")
	}
}

func TestProjectUpdateClearOnly(t *testing.T) {
	env, err := runUpdate(t, "--clear", "daily_thread_cap", "p1")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"project_id": "p1", "cleared_settings": []any{"daily_thread_cap"}}
	if !reflect.DeepEqual(env.Payload, want) {
		t.Fatalf("payload = %v, want %v", env.Payload, want)
	}
}

func TestProjectUpdateInstructionsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "instr.md")
	content := "line one\nline two\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	env, err := runUpdate(t, "--instructions-file", path, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if got := env.Payload["instructions"]; got != content {
		t.Fatalf("instructions = %q, want file content %q", got, content)
	}

	if _, err := runUpdate(t, "--instructions", "x", "--instructions-file", path, "p1"); err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("err = %v, want mutual-exclusion usage error", err)
	}
	if _, err := runUpdate(t, "--instructions-file", filepath.Join(t.TempDir(), "missing"), "p1"); err == nil {
		t.Fatal("missing instructions file must fail before POST")
	}
}

func TestProjectUpdateFlagShapeErrors(t *testing.T) {
	for name, args := range map[string][]string{
		"no change flags":          {"p1"},
		"bad integer":              {"--max-concurrent-runs", "lots", "p1"},
		"db path without provider": {"--task-provider-database-path", "/abs/x", "p1"},
		"no project id":            {"--goal", "x"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := runUpdate(t, args...); err == nil {
				t.Fatal("want usage error, got nil")
			} else if client.ExitCode(err) == 0 {
				t.Fatalf("exit code 0 for %v", err)
			}
		})
	}
}

func TestProjectUpdateCommandIDHashesFullPayload(t *testing.T) {
	a, _ := runUpdate(t, "--goal", "one", "p1")
	b, _ := runUpdate(t, "--goal", "two", "p1")
	a2, _ := runUpdate(t, "--goal", "one", "p1")
	cleared, _ := runUpdate(t, "--clear", "goal", "p1")
	if a.CommandID == b.CommandID {
		t.Fatal("different updates for the same project share a command id")
	}
	if a.CommandID == cleared.CommandID {
		t.Fatal("set and clear share a command id")
	}
	if a.CommandID != a2.CommandID {
		t.Fatal("identical update produced different command ids")
	}
	keyed, _ := runUpdate(t, "--goal", "x", "--idempotency-key", "k", "p1")
	keyed2, _ := runUpdate(t, "--goal", "y", "--idempotency-key", "k", "p1")
	if keyed.CommandID != sha256HexTest("project.update.k") || keyed.CommandID != keyed2.CommandID {
		t.Fatal("--idempotency-key must override the content hash")
	}
}

func TestProjectUpdateSurfacesServerValidationError(t *testing.T) {
	c, _ := recordingServer(t, http.StatusUnprocessableEntity, `{"error":"{:instructions_too_long, 16001, 16000}"}`)
	err := projectUpdate(c, []string{"--instructions", "x", "p1"})
	if err == nil {
		t.Fatal("want server error")
	}
	if !strings.Contains(err.Error(), "{:instructions_too_long, 16001, 16000}") {
		t.Fatalf("error %q hides the server validation text", err)
	}
	if client.ExitCode(err) == 0 {
		t.Fatal("exit code must be non-zero")
	}
}

func TestProjectUpdateErrorTextReachesStderrAndExitCode(t *testing.T) {
	// exitWithError prints err.Error() to stderr; assert that contract holds
	// for the server error text.
	c, _ := recordingServer(t, http.StatusUnprocessableEntity, `{"error":"{:setting_not_editable, :status}"}`)
	err := projectUpdate(c, []string{"--goal", "g", "p1"})
	if err == nil || !strings.Contains(err.Error(), "{:setting_not_editable, :status}") {
		t.Fatalf("err = %v", err)
	}
}

func TestProjectSettingsPrintsSettingsAndLimits(t *testing.T) {
	resp := `{"project_id":"p1","status":"paused","settings":{"goal":"ship","instructions":null,"thread_model":"m1","thread_effort":null,"coordinator_provider":"pi","coordinator_model":null,"coordinator_effort":null,"max_concurrent_runs":4,"daily_thread_cap":null},"limits":{"max_concurrent_runs":4,"active_runs":1,"daily_thread_cap":null,"threads_started_today":3,"remaining_today":null,"cap_reached?":false,"resets_at":"2026-10-22T00:00:00Z","deferred_tasks":2}}`
	c, rec := recordingServer(t, http.StatusOK, resp)
	stdout := captureStdout(t, func() {
		if err := runProject(c, []string{"settings", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if rec.method != http.MethodGet || rec.path != "/api/projects/p1/settings" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	for _, want := range []string{"status: paused", "goal: ship", "instructions: (unset)", "max_concurrent_runs: 4", "active_runs: 1", "cap_reached: false", "deferred_tasks: 2", "resets_at: 2026-10-22T00:00:00Z", "remaining_today: (unset)"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}

	c, _ = recordingServer(t, http.StatusOK, resp)
	jsonOut := captureStdout(t, func() {
		if err := projectSettings(c, []string{"--format=json", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	var decoded map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &decoded); err != nil || decoded["status"] != "paused" {
		t.Fatalf("json output %q: %v", jsonOut, err)
	}
}

func TestProjectDeleteWordingSaysArchiveAndReactivate(t *testing.T) {
	c, rec := recordingServer(t, http.StatusCreated, acceptedBody)
	stdout := captureStdout(t, func() {
		if err := projectDelete(c, []string{"p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if env := decodeEnvelope(t, rec); env.Type != "project.archive" {
		t.Fatalf("type = %q, want project.archive", env.Type)
	}
	for _, want := range []string{"archived project p1", "foreman project reactivate p1"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout %q missing %q", stdout, want)
		}
	}

	err := projectDelete(c, []string{"-h"})
	var helpErr *client.HelpError
	if !errors.As(err, &helpErr) {
		t.Fatalf("err = %v, want help error", err)
	}
	for _, want := range []string{"archives the project", "not purge", "event history are kept", "foreman project reactivate <id>"} {
		if !strings.Contains(strings.ToLower(helpErr.Text), strings.ToLower(want)) {
			t.Fatalf("delete help missing %q:\n%s", want, helpErr.Text)
		}
	}
}

func TestProjectContextPrintsTextOrJSON(t *testing.T) {
	resp := `{"project_id":"p1","system_text":"## Project instructions\nNever touch vendor/","bytes":43,"sha256":"abc","sections":[{"id":"instructions","bytes":18}],"truncated":[],"redactions":0}`
	c, rec := recordingServer(t, http.StatusOK, resp)
	stdout := captureStdout(t, func() {
		if err := runProject(c, []string{"context", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if rec.method != http.MethodGet || rec.path != "/api/projects/p1/context" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	if !strings.Contains(stdout, "Never touch vendor/") {
		t.Fatalf("stdout missing context text:\n%s", stdout)
	}

	c, _ = recordingServer(t, http.StatusOK, resp)
	jsonOut := captureStdout(t, func() {
		if err := projectContext(c, []string{"--format=json", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	var decoded map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &decoded); err != nil || decoded["sha256"] != "abc" {
		t.Fatalf("json output %q: %v", jsonOut, err)
	}

	empty, _ := recordingServer(t, http.StatusOK, `{"project_id":"p2","system_text":null,"bytes":0,"sha256":null,"sections":[],"truncated":[],"redactions":0}`)
	out := captureStdout(t, func() {
		if err := projectContext(empty, []string{"p2"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, "no standing context") {
		t.Fatalf("empty context output = %q", out)
	}
}

func TestProjectContextUnknownProjectIsAnError(t *testing.T) {
	c, _ := recordingServer(t, http.StatusNotFound, `{"error":"not_found","reason":":project_not_found"}`)
	if err := projectContext(c, []string{"ghost"}); err == nil {
		t.Fatal("expected an error for an unknown project")
	}
}
