package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// timezoneRefusal is the body `POST /api/commands` answers (422) when a schedule names a
// timezone other than UTC: the same literal the server's
// command_controller_schedule_test.exs asserts byte for byte.
const timezoneRefusal = `{"error":"{:invalid_schedule_spec, :timezone, :unsupported_timezone}"}`

// assertTimezoneSentVerbatim: what the CLI sends for the create below is a schedule.create whose
// spec carries --timezone as typed. The ids the CLI derives for idempotency (command_id,
// schedule_id) are not what this pins, so they are only required to be present.
func assertTimezoneSentVerbatim(t *testing.T, req scheduleRequest) {
	t.Helper()

	if req.method != http.MethodPost || req.path != "/api/commands" {
		t.Fatalf("request = %s %s, want POST /api/commands", req.method, req.path)
	}
	var body struct {
		Type    string         `json:"type"`
		Payload map[string]any `json:"payload"`
	}
	if err := json.Unmarshal(req.body, &body); err != nil {
		t.Fatalf("decode request body %q: %v", req.body, err)
	}
	if body.Type != "schedule.create" {
		t.Fatalf("type = %q, want schedule.create", body.Type)
	}
	wantSpec := map[string]any{"cron": "0 9 * * 1-5", "timezone": "America/Chicago"}
	if !reflect.DeepEqual(body.Payload["spec"], wantSpec) {
		t.Fatalf("spec = %v, want %v (the timezone rides inside the spec, verbatim)", body.Payload["spec"], wantSpec)
	}
	if body.Payload["project_id"] != "p" || body.Payload["name"] != "n" || body.Payload["workflow"] != "implement" {
		t.Fatalf("payload = %v, want project p, name n, workflow implement", body.Payload)
	}
}

func timezoneCreateArgs() []string {
	return []string{"schedule", "create", "--project-id", "p", "--name", "n", "--cron", "0 9 * * 1-5", "--timezone", "America/Chicago", "--prompt", "x", "--workflow", "implement"}
}

// The CLI accepts any --timezone (the server takes UTC only), so the server's refusal is the only
// thing between the operator and a schedule in the wrong zone: the flag must reach the server as
// typed, and the refusal must come back as a failure, not as "created schedule".
func TestProjectScheduleCreateTimezoneRefusedByServerIsAnError(t *testing.T) {
	c, seen := scheduleTestServer(t, http.StatusUnprocessableEntity, timezoneRefusal)

	var err error
	stdout := captureStdout(t, func() {
		err = runProject(c, timezoneCreateArgs())
	})

	if len(*seen) != 1 {
		t.Fatalf("requests = %d, want exactly 1 (the timezone is the server's call)", len(*seen))
	}
	assertTimezoneSentVerbatim(t, (*seen)[0])

	var httpErr *client.Error
	if !errors.As(err, &httpErr) {
		t.Fatalf("err = %v, want the server's *client.Error", err)
	}
	if httpErr.Status != http.StatusUnprocessableEntity || httpErr.Body != timezoneRefusal {
		t.Fatalf("err = %+v, want 422 with the server's body verbatim", httpErr)
	}
	if want := "foreman: HTTP 422: " + timezoneRefusal; err.Error() != want {
		t.Fatalf("err.Error() = %q, want %q", err.Error(), want)
	}
	if client.ExitCode(err) != 1 {
		t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
	}
	if stdout != "" {
		t.Fatalf("stdout = %q, want nothing: no schedule was created", stdout)
	}
}

// The same, through main(): the process prints the server's error verbatim on stderr and exits
// non-zero, and says nothing on stdout.
func TestProjectScheduleCreateTimezoneRefusalExitsNonZeroWithServerError(t *testing.T) {
	c, seen := scheduleTestServer(t, http.StatusUnprocessableEntity, timezoneRefusal)
	t.Setenv("FOREMAN_API_URL", c.BaseURL)
	t.Setenv("FOREMAN_API_TOKEN", "test-token")

	result := runExitHelper(t, "main-project-schedule-create-timezone")

	if result.exitCode != 1 {
		t.Fatalf("exit code = %d, want 1; stderr=%q", result.exitCode, result.stderr)
	}
	if want := "foreman: HTTP 422: " + timezoneRefusal; !strings.Contains(result.stderr, want) {
		t.Fatalf("stderr = %q, want it to hold %q", result.stderr, want)
	}
	if strings.Contains(result.stdout, "created schedule") {
		t.Fatalf("stdout = %q, want no success line", result.stdout)
	}
	if len(*seen) != 1 {
		t.Fatalf("requests = %d, want exactly 1", len(*seen))
	}
	assertTimezoneSentVerbatim(t, (*seen)[0])
}
