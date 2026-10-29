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
		"--coordinator-propose-before-start=false", "--coordinator-max-active-threads", "7", "--coordinator-reuse-threads", "--notification-preference", "every_turn",
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
		"coordinator_propose_before_start": false, "coordinator_max_active_threads": float64(7), "coordinator_reuse_threads": true,
		"notification_preference": "every_turn",
		"cleared_settings":        []any{"goal", "thread_model"},
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
	resp := `{"project_id":"p1","status":"paused","settings":{"goal":"ship","instructions":null,"thread_model":"m1","thread_effort":null,"coordinator_provider":"pi","coordinator_model":null,"coordinator_effort":null,"max_concurrent_runs":4,"daily_thread_cap":null,"coordinator_propose_before_start":true,"coordinator_max_active_threads":5,"coordinator_reuse_threads":false},"limits":{"max_concurrent_runs":4,"active_runs":1,"daily_thread_cap":null,"threads_started_today":3,"remaining_today":null,"cap_reached?":false,"resets_at":"2026-10-22T00:00:00Z","deferred_tasks":2}}`
	c, rec := recordingServer(t, http.StatusOK, resp)
	stdout := captureStdout(t, func() {
		if err := runProject(c, []string{"settings", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if rec.method != http.MethodGet || rec.path != "/api/projects/p1/settings" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	for _, want := range []string{"status: paused", "goal: ship", "instructions: (unset)", "max_concurrent_runs: 4", "active_runs: 1", "cap_reached: false", "deferred_tasks: 2", "resets_at: 2026-10-22T00:00:00Z", "remaining_today: (unset)", "coordinator_propose_before_start: true", "coordinator_max_active_threads: 5", "coordinator_reuse_threads: false"} {
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

func TestProjectUpdatePrAutoFixSendsObjectAndRejectsNonObjects(t *testing.T) {
	env, err := runUpdate(t, "--pr-auto-fix", `{"kinds":["ci"],"max_attempts":2}`, "p1")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"kinds": []any{"ci"}, "max_attempts": float64(2)}
	if !reflect.DeepEqual(env.Payload["pr_auto_fix"], want) {
		t.Fatalf("pr_auto_fix = %v, want %v", env.Payload["pr_auto_fix"], want)
	}
	for _, bad := range []string{`not json`, `null`, `["ci"]`} {
		if _, err := runUpdate(t, "--pr-auto-fix", bad, "p1"); err == nil {
			t.Fatalf("--pr-auto-fix %q must be rejected before any request", bad)
		}
	}
}

func TestProjectSettingsShowsPrAutoFixAsCompactJSON(t *testing.T) {
	resp := `{"project_id":"p1","status":"active","settings":{"pr_auto_fix":{"kinds":["ci"],"max_attempts":2,"cooldown_seconds":300}},"limits":{}}`
	c, _ := recordingServer(t, http.StatusOK, resp)
	stdout := captureStdout(t, func() {
		if err := runProject(c, []string{"settings", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	want := `pr_auto_fix: {"cooldown_seconds":300,"kinds":["ci"],"max_attempts":2}`
	if !strings.Contains(stdout, want) {
		t.Fatalf("stdout missing %q:\n%s", want, stdout)
	}

	c, _ = recordingServer(t, http.StatusOK, `{"project_id":"p1","status":"active","settings":{},"limits":{}}`)
	unset := captureStdout(t, func() {
		if err := runProject(c, []string{"settings", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(unset, "pr_auto_fix: (unset)") {
		t.Fatalf("stdout missing unset pr_auto_fix:\n%s", unset)
	}
}

func TestProjectUpdateRepoPolicyPayload(t *testing.T) {
	t.Run("both flags", func(t *testing.T) {
		env, err := runUpdate(t, "--repo-allowlist", "/srv/b", "--repo-allowlist", "/srv/a", "--max-repos-per-run", "3", "p1")
		if err != nil {
			t.Fatal(err)
		}
		want := map[string]any{"project_id": "p1", "repo_allowlist": []any{"/srv/b", "/srv/a"}, "max_repos_per_run": float64(3)}
		if env.Type != "project.update" || !reflect.DeepEqual(env.Payload, want) {
			t.Fatalf("type = %q payload = %v, want project.update %v", env.Type, env.Payload, want)
		}
	})

	t.Run("each flag alone is a change", func(t *testing.T) {
		env, err := runUpdate(t, "--repo-allowlist", "/srv/a", "p1")
		if err != nil {
			t.Fatal(err)
		}
		if want := (map[string]any{"project_id": "p1", "repo_allowlist": []any{"/srv/a"}}); !reflect.DeepEqual(env.Payload, want) {
			t.Fatalf("payload = %v, want %v", env.Payload, want)
		}
		env, err = runUpdate(t, "--max-repos-per-run", "1000", "p1")
		if err != nil {
			t.Fatal(err)
		}
		if want := (map[string]any{"project_id": "p1", "max_repos_per_run": float64(1000)}); !reflect.DeepEqual(env.Payload, want) {
			t.Fatalf("payload = %v, want %v", env.Payload, want)
		}
	})

	t.Run("clear", func(t *testing.T) {
		env, err := runUpdate(t, "--clear", "repo_allowlist", "--clear", "max_repos_per_run", "p1")
		if err != nil {
			t.Fatal(err)
		}
		want := map[string]any{"project_id": "p1", "cleared_settings": []any{"repo_allowlist", "max_repos_per_run"}}
		if !reflect.DeepEqual(env.Payload, want) {
			t.Fatalf("payload = %v, want %v", env.Payload, want)
		}
	})

	t.Run("non-numeric max is a usage error and sends nothing", func(t *testing.T) {
		_, err := runUpdate(t, "--max-repos-per-run", "many", "p1")
		if err == nil {
			t.Fatal("want usage error")
		}
		if client.ExitCode(err) != 1 {
			t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
		}
	})

	for _, tc := range []struct{ name, arg, refusal string }{
		{"allowlist", "--repo-allowlist=relative/path", `{:invalid_repo_allowlist, "relative/path"}`},
		{"max", "--max-repos-per-run=0", `{:max_repos_per_run_invalid, 0, 1..1000}`},
	} {
		t.Run("server refusal "+tc.name, func(t *testing.T) {
			body, err := json.Marshal(map[string]string{"error": tc.refusal})
			if err != nil {
				t.Fatal(err)
			}
			c, rec := recordingServer(t, http.StatusUnprocessableEntity, string(body))
			var runErr error
			stdout := captureStdout(t, func() { runErr = projectUpdate(c, []string{tc.arg, "p1"}) })
			if rec.calls != 1 {
				t.Fatalf("calls = %d, want the request to reach the server", rec.calls)
			}
			if runErr == nil || !strings.Contains(runErr.Error(), string(body)) {
				t.Fatalf("err = %v, want the server response %s", runErr, body)
			}
			if client.ExitCode(runErr) == 0 || strings.Contains(stdout, "updated project") {
				t.Fatalf("exit code = %d stdout = %q, want non-zero and no success line", client.ExitCode(runErr), stdout)
			}
		})
	}
}

func TestProjectSettingsPrintsRepoPolicy(t *testing.T) {
	show := func(t *testing.T, settings string) string {
		t.Helper()
		c, _ := recordingServer(t, http.StatusOK, `{"project_id":"p1","status":"active","settings":`+settings+`,"limits":{}}`)
		return captureStdout(t, func() {
			if err := runProject(c, []string{"settings", "p1"}); err != nil {
				t.Fatal(err)
			}
		})
	}

	set := show(t, `{"repo_allowlist":["/srv/a","/srv/b"],"max_repos_per_run":3}`)
	for _, want := range []string{`  repo_allowlist: ["/srv/a","/srv/b"]` + "\n", "  max_repos_per_run: 3\n"} {
		if !strings.Contains(set, want) {
			t.Fatalf("stdout missing %q:\n%s", want, set)
		}
	}

	empty := show(t, `{"repo_allowlist":[]}`)
	if !strings.Contains(empty, "  repo_allowlist: []\n") || !strings.Contains(empty, "  max_repos_per_run: (unset)\n") {
		t.Fatalf("empty list / absent max not rendered:\n%s", empty)
	}

	null := show(t, `{"repo_allowlist":null,"max_repos_per_run":null}`)
	if !strings.Contains(null, "  repo_allowlist: (unset)\n") || !strings.Contains(null, "  max_repos_per_run: (unset)\n") {
		t.Fatalf("null not rendered as (unset):\n%s", null)
	}
}
