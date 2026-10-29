package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const scheduleUpdatedBody = `{"status":"accepted","result":{"project_id":"p1","schedule_id":"s1","replayed":false}}`

// runScheduleUpdate dispatches through runProject, so the `schedule update` case is exercised.
// It returns the recorded server state, stdout and the command's error.
func runScheduleUpdate(t *testing.T, status int, response string, args ...string) (*recordedRequest, string, error) {
	t.Helper()
	c, rec := recordingServer(t, status, response)
	var err error
	stdout := captureStdout(t, func() {
		err = runProject(c, append([]string{"schedule", "update"}, args...))
	})

	return rec, stdout, err
}

func mustScheduleUpdate(t *testing.T, args ...string) commandEnvelope {
	t.Helper()
	rec, stdout, err := runScheduleUpdate(t, http.StatusCreated, scheduleUpdatedBody, args...)
	if err != nil {
		t.Fatalf("schedule update %v: %v", args, err)
	}
	if !strings.HasPrefix(stdout, "updated schedule s") || !strings.Contains(stdout, " in project p") {
		t.Fatalf("stdout = %q, want the updated line", stdout)
	}

	return decodeEnvelope(t, rec)
}

func TestProjectScheduleUpdateEnvelope(t *testing.T) {
	promptFile := filepath.Join(t.TempDir(), "prompt.txt")
	if err := os.WriteFile(promptFile, []byte("from file\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	base := map[string]any{"project_id": "p1", "schedule_id": "s1"}
	with := func(extra map[string]any) map[string]any {
		out := map[string]any{}
		for k, v := range base {
			out[k] = v
		}
		for k, v := range extra {
			out[k] = v
		}

		return out
	}

	cases := []struct {
		name string
		args []string
		want map[string]any
	}{
		{"name", []string{"--name", "nightly"}, with(map[string]any{"name": "nightly"})},
		{"every", []string{"--every", "30m"}, with(map[string]any{"spec": map[string]any{"every": "30m"}})},
		{"cron with timezone", []string{"--cron", "0 9 * * 1-5", "--timezone", "Etc/UTC"}, with(map[string]any{"spec": map[string]any{"cron": "0 9 * * 1-5", "timezone": "Etc/UTC"}})},
		{"every with timezone sent verbatim", []string{"--every", "1h", "--timezone", "America/Chicago"}, with(map[string]any{"spec": map[string]any{"every": "1h", "timezone": "America/Chicago"}})},
		{"prompt", []string{"--prompt", "do the thing"}, with(map[string]any{"prompt": "do the thing"})},
		{"empty prompt passes through", []string{"--prompt", ""}, with(map[string]any{"prompt": ""})},
		{"empty name passes through", []string{"--name", ""}, with(map[string]any{"name": ""})},
		{"empty workflow passes through", []string{"--workflow", ""}, with(map[string]any{"workflow": ""})},
		{"prompt-file", []string{"--prompt-file", promptFile}, with(map[string]any{"prompt": "from file\n"})},
		{"workflow", []string{"--workflow", "implement"}, with(map[string]any{"workflow": "implement"})},
		{"auto-approve", []string{"--auto-approve"}, with(map[string]any{"auto_approve": true})},
		{"auto-approve=false", []string{"--auto-approve=false"}, with(map[string]any{"auto_approve": false})},
		{"overlap allow", []string{"--overlap", "allow"}, with(map[string]any{"overlap": "allow"})},
		{"overlap skip", []string{"--overlap", "skip"}, with(map[string]any{"overlap": "skip"})},
		{"misfire-grace-seconds", []string{"--misfire-grace-seconds", "120"}, with(map[string]any{"misfire_grace_seconds": float64(120)})},
		{"misfire-grace-seconds zero", []string{"--misfire-grace-seconds", "0"}, with(map[string]any{"misfire_grace_seconds": float64(0)})},
		{"all flags", []string{
			"--name", "n", "--cron", "*/10 * * * *", "--timezone", "UTC", "--prompt", "p", "--workflow", "w",
			"--auto-approve=false", "--overlap", "allow", "--misfire-grace-seconds", "60", "--idempotency-key", "k",
		}, with(map[string]any{
			"name": "n", "spec": map[string]any{"cron": "*/10 * * * *", "timezone": "UTC"}, "prompt": "p", "workflow": "w",
			"auto_approve": false, "overlap": "allow", "misfire_grace_seconds": float64(60),
		})},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := mustScheduleUpdate(t, append([]string{"--project-id", "p1", "--id", "s1"}, tc.args...)...)
			if env.Type != "schedule.update" {
				t.Fatalf("type = %q, want schedule.update", env.Type)
			}
			if env.AggregateID != "" {
				t.Fatalf("aggregate_id = %q, the server derives it", env.AggregateID)
			}
			if !reflect.DeepEqual(env.Payload, tc.want) {
				t.Fatalf("payload = %v, want %v", env.Payload, tc.want)
			}
			if len(env.CommandID) != 64 {
				t.Fatalf("command_id = %q, want a sha256 hex digest", env.CommandID)
			}
		})
	}
}

func TestProjectScheduleUpdateCommandID(t *testing.T) {
	id := func(args ...string) string {
		return mustScheduleUpdate(t, args...).CommandID
	}
	common := []string{"--project-id", "p1", "--id", "s1"}
	args := func(extra ...string) []string { return append(append([]string{}, common...), extra...) }

	// Without a key: the hash of the marshalled payload, exactly.
	payload, err := json.Marshal(map[string]any{"project_id": "p1", "schedule_id": "s1", "name": "n", "auto_approve": true})
	if err != nil {
		t.Fatal(err)
	}
	got := id(args("--name", "n", "--auto-approve")...)
	if want := sha256HexTest("schedule.update." + string(payload)); got != want {
		t.Fatalf("command id = %s, want sha256 of schedule.update.%s", got, payload)
	}
	if again := id(args("--auto-approve", "--name", "n")...); again != got {
		t.Fatal("identical change (flag order differs) produced a different command id")
	}
	if other := id(args("--name", "other", "--auto-approve")...); other == got {
		t.Fatal("a different payload shares a command id")
	}

	// With a key: scoped by project and schedule, independent of the content.
	keyed := id(args("--name", "a", "--idempotency-key", "K")...)
	if want := sha256HexTest("schedule.update.p1\x00s1\x00K"); keyed != want {
		t.Fatalf("keyed command id = %s, want %s", keyed, want)
	}
	if id(args("--prompt", "totally different", "--idempotency-key", "K")...) != keyed {
		t.Fatal("--idempotency-key must override the content hash")
	}
	if id("--project-id", "p2", "--id", "s1", "--name", "a", "--idempotency-key", "K") == keyed {
		t.Fatal("the key is not scoped by project")
	}
	if id("--project-id", "p1", "--id", "s2", "--name", "a", "--idempotency-key", "K") == keyed {
		t.Fatal("the key is not scoped by schedule")
	}
	if id(args("--name", "a", "--idempotency-key", "K2")...) == keyed {
		t.Fatal("different keys share a command id")
	}
}

func TestProjectScheduleUpdateUsageErrorsSendNothing(t *testing.T) {
	emptyFile := filepath.Join(t.TempDir(), "empty.txt")
	if err := os.WriteFile(emptyFile, []byte(" \n\t\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	missingFile := filepath.Join(t.TempDir(), "missing.txt")

	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing project-id", []string{"--id", "s1", "--name", "n"}, "--project-id and --id are required"},
		{"missing id", []string{"--project-id", "p1", "--name", "n"}, "--project-id and --id are required"},
		{"positional argument", []string{"--project-id", "p1", "--id", "s1", "--name", "n", "extra"}, "no positional arguments"},
		{"no change flag", []string{"--project-id", "p1", "--id", "s1"}, "at least one of --name, --every, --cron, --prompt, --prompt-file, --workflow, --auto-approve, --overlap, --misfire-grace-seconds is required"},
		{"idempotency key alone is not a change", []string{"--project-id", "p1", "--id", "s1", "--idempotency-key", "k"}, "at least one of"},
		{"every and cron", []string{"--project-id", "p1", "--id", "s1", "--every", "30m", "--cron", "0 9 * * *"}, "--every and --cron are mutually exclusive"},
		{"prompt and prompt-file", []string{"--project-id", "p1", "--id", "s1", "--prompt", "x", "--prompt-file", "f"}, "--prompt and --prompt-file are mutually exclusive"},
		{"timezone alone", []string{"--project-id", "p1", "--id", "s1", "--name", "n", "--timezone", "UTC"}, "--timezone requires --every or --cron"},
		{"overlap invalid", []string{"--project-id", "p1", "--id", "s1", "--overlap", "queue"}, "--overlap must be skip or allow"},
		{"overlap empty", []string{"--project-id", "p1", "--id", "s1", "--overlap", ""}, "--overlap must be skip or allow"},
		{"empty prompt-file", []string{"--project-id", "p1", "--id", "s1", "--prompt-file", emptyFile}, "is empty"},
		{"non-numeric misfire", []string{"--project-id", "p1", "--id", "s1", "--misfire-grace-seconds", "soon"}, "misfire-grace-seconds"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec, stdout, err := runScheduleUpdate(t, http.StatusCreated, scheduleUpdatedBody, tc.args...)
			if err == nil {
				t.Fatal("want a usage error")
			}
			if rec.calls != 0 {
				t.Fatalf("%d request(s) sent despite the usage error", rec.calls)
			}
			if client.ExitCode(err) != 1 {
				t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
			}
			if !strings.Contains(err.Error(), tc.want) && !strings.Contains(stdout, tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
			if strings.Contains(stdout, "updated schedule") {
				t.Fatalf("stdout %q claims an update", stdout)
			}
		})
	}

	t.Run("unreadable prompt-file", func(t *testing.T) {
		rec, stdout, err := runScheduleUpdate(t, http.StatusCreated, scheduleUpdatedBody, "--project-id", "p1", "--id", "s1", "--prompt-file", missingFile)
		if err == nil || !strings.Contains(err.Error(), "read --prompt-file") {
			t.Fatalf("err = %v, want a read error", err)
		}
		if rec.calls != 0 || client.ExitCode(err) == 0 || strings.Contains(stdout, "updated schedule") {
			t.Fatalf("calls = %d exit = %d stdout = %q, want nothing sent, non-zero exit", rec.calls, client.ExitCode(err), stdout)
		}
	})
}

func TestProjectScheduleUpdateServerRefusalIsAnError(t *testing.T) {
	for _, refusal := range []string{
		`{:invalid_schedule_spec, :every, :below_minimum}`,
		`{:schedule_deleted, "s1"}`,
	} {
		t.Run(refusal, func(t *testing.T) {
			body, err := json.Marshal(map[string]string{"error": refusal})
			if err != nil {
				t.Fatal(err)
			}
			rec, stdout, runErr := runScheduleUpdate(t, http.StatusUnprocessableEntity, string(body), "--project-id", "p1", "--id", "s1", "--every", "1m")
			if rec.calls != 1 {
				t.Fatalf("calls = %d, want the request to reach the server", rec.calls)
			}
			if runErr == nil || !strings.Contains(runErr.Error(), string(body)) {
				t.Fatalf("err = %v, want the server response %s", runErr, body)
			}
			if client.ExitCode(runErr) == 0 {
				t.Fatal("exit code must be non-zero")
			}
			if strings.Contains(stdout, "updated schedule") {
				t.Fatalf("stdout %q claims an update the server refused", stdout)
			}
		})
	}
}

func TestProjectScheduleUsageListsUpdate(t *testing.T) {
	const verbs = "project schedule list|create|update|pause|resume|delete"
	for name, text := range map[string]string{"usage const": usage, "project usage text": projectUsageText} {
		if !strings.Contains(text, verbs) {
			t.Fatalf("%s lacks %q:\n%s", name, verbs, text)
		}
	}
	if !strings.Contains(projectScheduleUsageText, "foreman project schedule update --project-id <id> --id <schedule-id>") {
		t.Fatalf("project schedule usage lacks the update line:\n%s", projectScheduleUsageText)
	}
	if !strings.Contains(projectUsageText, "--repo-allowlist") || !strings.Contains(projectUsageText, "--max-repos-per-run") {
		t.Fatal("project usage lacks the repo policy flags")
	}

	c, _ := recordingServer(t, http.StatusCreated, scheduleUpdatedBody)
	err := runProject(c, []string{"schedule"})
	if err == nil || !strings.Contains(err.Error(), "(list|create|update|pause|resume|delete)") {
		t.Fatalf("err = %v, want the missing-subcommand text to list update", err)
	}
}
