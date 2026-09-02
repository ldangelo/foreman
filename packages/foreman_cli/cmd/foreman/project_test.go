package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func TestProjectCreateEnvelope(t *testing.T) {
	var seen []byte
	var seenPath string
	var seenMethod string
	var seenAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		seenAuth = r.Header.Get("Authorization")

		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, Token: "test-token", HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectCreate(c, []string{
			"--id", "project-123",
			"--path", "/tmp/demo-project",
			"--task-provider", "beads",
			"--task-provider-database-path", "/tmp/demo-project/.beads",
		}); err != nil {
			t.Fatalf("projectCreate: %v", err)
		}
	})

	if seenMethod != http.MethodPost {
		t.Fatalf("method = %q, want POST", seenMethod)
	}

	if seenPath != "/api/commands" {
		t.Fatalf("path = %q, want /api/commands", seenPath)
	}

	if seenAuth != "Bearer test-token" {
		t.Fatalf("auth = %q, want Bearer test-token", seenAuth)
	}

	var env commandEnvelope
	if err := json.Unmarshal(seen, &env); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	if env.Type != "project.register" {
		t.Fatalf("type = %q, want project.register", env.Type)
	}

	wantCommandID := sha256HexTest("project.create./tmp/demo-project.beads./tmp/demo-project/.beads")
	if env.CommandID != wantCommandID {
		t.Fatalf("command_id = %q, want %q", env.CommandID, wantCommandID)
	}

	if got := env.Payload["project_id"]; got != "project-123" {
		t.Fatalf("payload.project_id = %#v, want project-123", got)
	}

	if got := env.Payload["path"]; got != "/tmp/demo-project" {
		t.Fatalf("payload.path = %#v, want /tmp/demo-project", got)
	}

	taskProvider, ok := env.Payload["task_provider"].(map[string]any)
	if !ok {
		t.Fatalf("payload.task_provider type = %T, want map[string]any", env.Payload["task_provider"])
	}

	if got := taskProvider["provider"]; got != "beads" {
		t.Fatalf("payload.task_provider.provider = %#v, want beads", got)
	}

	config, ok := taskProvider["config"].(map[string]any)
	if !ok {
		t.Fatalf("payload.task_provider.config type = %T, want map[string]any", taskProvider["config"])
	}
	if got := config["database_path"]; got != "/tmp/demo-project/.beads" {
		t.Fatalf("payload.task_provider.config.database_path = %#v, want /tmp/demo-project/.beads", got)
	}

	if !strings.Contains(stdout, "project-123") || !strings.Contains(stdout, "/tmp/demo-project") || !strings.Contains(stdout, "beads") {
		t.Fatalf("stdout = %q, want human-readable summary with id, path, and provider", stdout)
	}
}

func TestProjectCreateIdempotencyKeyDerivation(t *testing.T) {
	var seen []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectCreate(c, []string{
			"--id", "project-456",
			"--path", "/tmp/ignored-for-idempotency",
			"--task-provider", "beads",
			"--task-provider-database-path", "/tmp/ignored.db",
			"--idempotency-key", "operator-key",
		}); err != nil {
			t.Fatalf("projectCreate: %v", err)
		}
	})

	var env commandEnvelope
	if err := json.Unmarshal(seen, &env); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	wantCommandID := sha256HexTest("project.create.operator-key")
	if env.CommandID != wantCommandID {
		t.Fatalf("command_id = %q, want %q", env.CommandID, wantCommandID)
	}

	if !strings.Contains(stdout, "project-456") {
		t.Fatalf("stdout = %q, want project id in human-readable output", stdout)
	}
}

func TestProjectUpdateEnvelope(t *testing.T) {
	var seen []byte
	var seenPath string
	var seenMethod string
	var seenAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		seenAuth = r.Header.Get("Authorization")

		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, Token: "test-token", HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectUpdate(c, []string{
			"--task-provider", "beads",
			"--task-provider-database-path", "/tmp/project-123.beads",
			"project-123",
		}); err != nil {
			t.Fatalf("projectUpdate: %v", err)
		}
	})

	if seenMethod != http.MethodPost {
		t.Fatalf("method = %q, want POST", seenMethod)
	}

	if seenPath != "/api/commands" {
		t.Fatalf("path = %q, want /api/commands", seenPath)
	}

	if seenAuth != "Bearer test-token" {
		t.Fatalf("auth = %q, want Bearer test-token", seenAuth)
	}

	var env commandEnvelope
	if err := json.Unmarshal(seen, &env); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	if env.Type != "project.update" {
		t.Fatalf("type = %q, want project.update", env.Type)
	}

	wantCommandID := sha256HexTest("project.update.project-123.beads./tmp/project-123.beads")
	if env.CommandID != wantCommandID {
		t.Fatalf("command_id = %q, want %q", env.CommandID, wantCommandID)
	}

	if got := env.Payload["project_id"]; got != "project-123" {
		t.Fatalf("payload.project_id = %#v, want project-123", got)
	}

	taskProvider, ok := env.Payload["task_provider"].(map[string]any)
	if !ok {
		t.Fatalf("payload.task_provider type = %T, want map[string]any", env.Payload["task_provider"])
	}

	if got := taskProvider["provider"]; got != "beads" {
		t.Fatalf("payload.task_provider.provider = %#v, want beads", got)
	}

	config, ok := taskProvider["config"].(map[string]any)
	if !ok {
		t.Fatalf("payload.task_provider.config type = %T, want map[string]any", taskProvider["config"])
	}
	if got := config["database_path"]; got != "/tmp/project-123.beads" {
		t.Fatalf("payload.task_provider.config.database_path = %#v, want /tmp/project-123.beads", got)
	}

	if !strings.Contains(stdout, "project-123") || !strings.Contains(stdout, "beads") {
		t.Fatalf("stdout = %q, want human-readable summary with id and provider", stdout)
	}
}

func TestProjectUpdatePayloadFixture(t *testing.T) {
	var seen []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, Token: "test-token", HTTP: srv.Client()}

	if err := projectUpdate(c, []string{"--task-provider", "beads", "--task-provider-database-path", "/tmp/project-123.beads", "project-123"}); err != nil {
		t.Fatalf("projectUpdate: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(seen, &got); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	wantPath := filepath.Join("testdata", "project_update_payload.json")
	wantBytes, err := os.ReadFile(wantPath)
	if err != nil {
		t.Fatalf("read fixture %s: %v", wantPath, err)
	}

	var want map[string]any
	if err := json.Unmarshal(wantBytes, &want); err != nil {
		t.Fatalf("decode fixture %s: %v", wantPath, err)
	}

	if !equalJSON(want, got) {
		t.Fatalf("captured payload mismatch\nwant: %s\ngot:  %s", wantBytes, seen)
	}
}

func TestProjectUpdateJSONOutput(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1,"project_id":"project-123"}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectUpdate(c, []string{
			"--task-provider", "beads",
			"--task-provider-database-path", "/tmp/project-123.beads",
			"--format=json",
			"project-123",
		}); err != nil {
			t.Fatalf("projectUpdate: %v", err)
		}
	})

	var out map[string]any
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("stdout is not JSON: %v: %q", err, stdout)
	}

	if got := out["status"]; got != "accepted" {
		t.Fatalf("status = %#v, want accepted", got)
	}

	result, ok := out["result"].(map[string]any)
	if !ok {
		t.Fatalf("result envelope type = %T, want map[string]any", out["result"])
	}

	if got := result["project_id"]; got != "project-123" {
		t.Fatalf("result.project_id = %#v, want project-123", got)
	}
}

func TestProjectUpdateIdempotencyKeyDerivation(t *testing.T) {
	var seen []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := projectUpdate(c, []string{
		"--task-provider", "beads",
		"--task-provider-database-path", "/tmp/ignored.db",
		"--idempotency-key", "operator-key",
		"project-456",
	}); err != nil {
		t.Fatalf("projectUpdate: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(seen, &env); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	wantCommandID := sha256HexTest("project.update.operator-key")
	if env.CommandID != wantCommandID {
		t.Fatalf("command_id = %q, want %q", env.CommandID, wantCommandID)
	}
}

func TestProjectCreateRequiresDatabasePathForBeadsBeforePost(t *testing.T) {
	var seenMethod string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := projectCreate(c, []string{
		"--id", "project-missing-db",
		"--path", "/tmp/project-missing-db",
		"--task-provider", "beads",
	})
	if err == nil {
		t.Fatal("projectCreate error = nil, want usage error")
	}
	if client.ExitCode(err) != 1 {
		t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
	}
	if !strings.Contains(err.Error(), "--task-provider-database-path is required when --task-provider=beads") {
		t.Fatalf("error = %q, want missing database path message", err.Error())
	}
	if seenMethod != "" {
		t.Fatalf("request method = %q, want no HTTP mutation call", seenMethod)
	}
}

func TestProjectUpdateRequiresDatabasePathForBeadsBeforePost(t *testing.T) {
	var seenMethod string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := projectUpdate(c, []string{
		"--task-provider", "beads",
		"project-missing-db",
	})
	if err == nil {
		t.Fatal("projectUpdate error = nil, want usage error")
	}
	if client.ExitCode(err) != 1 {
		t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
	}
	if !strings.Contains(err.Error(), "--task-provider-database-path is required when --task-provider=beads") {
		t.Fatalf("error = %q, want missing database path message", err.Error())
	}
	if seenMethod != "" {
		t.Fatalf("request method = %q, want no HTTP mutation call", seenMethod)
	}
}

func TestProjectUpdateRejectsUnsupportedFormatBeforePost(t *testing.T) {
	var seenMethod string
	var seenPath string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		seenPath = r.URL.Path
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := projectUpdate(c, []string{
		"--task-provider", "beads",
		"--format", "yaml",
		"project-unsupported",
	})
	if err == nil {
		t.Fatal("projectUpdate error = nil, want usage error")
	}

	if client.ExitCode(err) != 1 {
		t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
	}

	if !strings.Contains(err.Error(), "foreman project update: unsupported format \"yaml\"") {
		t.Fatalf("error = %q, want unsupported-format usage message", err.Error())
	}

	if seenMethod != "" || seenPath != "" {
		t.Fatalf("request = %s %s, want no HTTP mutation call", seenMethod, seenPath)
	}
}
func TestProjectCreateRejectsUnsupportedFormatBeforePost(t *testing.T) {
	var seenMethod string
	var seenPath string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		seenPath = r.URL.Path
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := projectCreate(c, []string{
		"--id", "project-unsupported",
		"--path", "/tmp/unsupported",
		"--task-provider", "beads",
		"--format", "yaml",
	})
	if err == nil {
		t.Fatal("projectCreate error = nil, want usage error")
	}

	if client.ExitCode(err) != 1 {
		t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
	}

	if !strings.Contains(err.Error(), "foreman project create: unsupported format \"yaml\"") {
		t.Fatalf("error = %q, want unsupported-format usage message", err.Error())
	}

	if seenMethod != "" || seenPath != "" {
		t.Fatalf("request = %s %s, want no HTTP mutation call", seenMethod, seenPath)
	}
}

func TestMainProjectCreateUsesEnvClientAndJSONOutput(t *testing.T) {
	var seenAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"events":1}}`))
	}))
	defer srv.Close()

	t.Setenv("FOREMAN_API_URL", srv.URL)
	t.Setenv("FOREMAN_API_TOKEN", "env-token")

	oldArgs := os.Args
	os.Args = []string{
		"foreman",
		"project",
		"create",
		"--id", "project-789",
		"--path", "/tmp/from-env",
		"--task-provider", "beads",
		"--task-provider-database-path", "/tmp/from-env/.beads",
		"--format=json",
	}
	defer func() { os.Args = oldArgs }()

	stdout := captureStdout(t, func() {
		main()
	})

	if seenAuth != "Bearer env-token" {
		t.Fatalf("auth = %q, want Bearer env-token", seenAuth)
	}

	var out map[string]any
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("stdout is not JSON: %v: %q", err, stdout)
	}

	if got := out["status"]; got != "accepted" {
		t.Fatalf("status = %#v, want accepted", got)
	}
}

func TestProjectGetJSONEnvelope(t *testing.T) {
	var seenPath string
	var seenMethod string
	var seenAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		seenAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"project":{"project_id":"project-123","path":"/tmp/demo","status":"active"}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, Token: "test-token", HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectGet(c, []string{"--format=json", "project-123"}); err != nil {
			t.Fatalf("projectGet: %v", err)
		}
	})

	if seenMethod != http.MethodGet {
		t.Fatalf("method = %q, want GET", seenMethod)
	}

	if seenPath != "/api/projects/project-123" {
		t.Fatalf("path = %q, want /api/projects/project-123", seenPath)
	}

	if seenAuth != "Bearer test-token" {
		t.Fatalf("auth = %q, want Bearer test-token", seenAuth)
	}

	var out map[string]any
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("stdout is not JSON: %v: %q", err, stdout)
	}

	project, ok := out["project"].(map[string]any)
	if !ok {
		t.Fatalf("project envelope type = %T, want map[string]any", out["project"])
	}

	if got := project["project_id"]; got != "project-123" {
		t.Fatalf("project.project_id = %#v, want project-123", got)
	}
}

func TestProjectGetHumanReadableOutput(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"project":{"project_id":"project-456","path":"/tmp/human","status":"archived"}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectGet(c, []string{"project-456"}); err != nil {
			t.Fatalf("projectGet: %v", err)
		}
	})

	if !strings.Contains(stdout, "project-456") || !strings.Contains(stdout, "/tmp/human") || !strings.Contains(stdout, "archived") {
		t.Fatalf("stdout = %q, want human-readable summary with id, path, and status", stdout)
	}
}

func TestProjectGetRejectsUnsupportedFormatBeforeRequest(t *testing.T) {
	var seenMethod string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := projectGet(c, []string{"--format=yaml", "project-unsupported"})
	if err == nil {
		t.Fatal("projectGet error = nil, want usage error")
	}

	if client.ExitCode(err) != 1 {
		t.Fatalf("exit code = %d, want 1", client.ExitCode(err))
	}

	if !strings.Contains(err.Error(), "foreman project get: unsupported format \"yaml\"") {
		t.Fatalf("error = %q, want unsupported-format usage message", err.Error())
	}

	if seenMethod != "" {
		t.Fatalf("method = %q, want no HTTP request", seenMethod)
	}
}

func TestProjectDeleteEnvelope(t *testing.T) {
	var seen []byte
	var seenPath string
	var seenMethod string
	var seenAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		seenAuth = r.Header.Get("Authorization")

		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"project_id":"project-123"}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, Token: "test-token", HTTP: srv.Client()}

	stdout := captureStdout(t, func() {
		if err := projectDelete(c, []string{"project-123"}); err != nil {
			t.Fatalf("projectDelete: %v", err)
		}
	})

	if seenMethod != http.MethodPost {
		t.Fatalf("method = %q, want POST", seenMethod)
	}

	if seenPath != "/api/commands" {
		t.Fatalf("path = %q, want /api/commands", seenPath)
	}

	if seenAuth != "Bearer test-token" {
		t.Fatalf("auth = %q, want Bearer test-token", seenAuth)
	}

	var env commandEnvelope
	if err := json.Unmarshal(seen, &env); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	if env.Type != "project.archive" {
		t.Fatalf("type = %q, want project.archive", env.Type)
	}

	wantCommandID := sha256HexTest("project.delete.project-123")
	if env.CommandID != wantCommandID {
		t.Fatalf("command_id = %q, want %q", env.CommandID, wantCommandID)
	}

	if got := env.Payload["project_id"]; got != "project-123" {
		t.Fatalf("payload.project_id = %#v, want project-123", got)
	}

	if !strings.Contains(stdout, "project-123") {
		t.Fatalf("stdout = %q, want archived project summary", stdout)
	}
}

func TestProjectDeleteIdempotencyKeyDerivation(t *testing.T) {
	var seen []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seen = append([]byte(nil), body...)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted","result":{"project_id":"project-456"}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := projectDelete(c, []string{"--idempotency-key", "operator-key", "project-456"}); err != nil {
		t.Fatalf("projectDelete: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(seen, &env); err != nil {
		t.Fatalf("decode captured body: %v: %s", err, seen)
	}

	wantCommandID := sha256HexTest("project.delete.operator-key")
	if env.CommandID != wantCommandID {
		t.Fatalf("command_id = %q, want %q", env.CommandID, wantCommandID)
	}
}

func TestProjectDeleteForcePrintsActiveRunIDsOnConflict(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"code":"project_has_active_runs","run_ids":["run-1","run-2"]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	var err error
	stdout, stderr := captureOutput(t, func() {
		err = projectDelete(c, []string{"--force", "project-789"})
	})

	if err == nil {
		t.Fatal("projectDelete error = nil, want HTTP conflict")
	}

	if got := client.ExitCode(err); got != 3 {
		t.Fatalf("exit code = %d, want 3", got)
	}

	if strings.TrimSpace(stdout) != "" {
		t.Fatalf("stdout = %q, want empty stdout", stdout)
	}

	if !strings.Contains(stderr, "run-1") || !strings.Contains(stderr, "run-2") {
		t.Fatalf("stderr = %q, want active run ids", stderr)
	}
}

func TestProjectDeleteHTTPExitCodes(t *testing.T) {
	cases := []struct {
		name       string
		statusCode int
		wantExit   int
	}{
		{name: "not found exits two", statusCode: http.StatusNotFound, wantExit: 2},
		{name: "conflict exits three", statusCode: http.StatusConflict, wantExit: 3},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.statusCode)
				_, _ = w.Write([]byte(`{"error":"boom"}`))
			}))
			defer srv.Close()

			c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

			err := projectDelete(c, []string{"project-delete-exit"})
			if err == nil {
				t.Fatal("projectDelete error = nil, want HTTP error")
			}

			if got := client.ExitCode(err); got != tc.wantExit {
				t.Fatalf("exit code = %d, want %d", got, tc.wantExit)
			}
		})
	}
}

func TestProjectListDefaultTableAndQuery(t *testing.T) {
	var seenPath string
	var seenMethod string
	var seenQuery string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		seenQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"projects":[{"project_id":"project-123","path":"/tmp/demo","archived":false,"registered":"2026-08-07T00:00:00Z","version":7}]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout, stderr := captureOutput(t, func() {
		if err := projectList(c, nil); err != nil {
			t.Fatalf("projectList: %v", err)
		}
	})

	if seenMethod != http.MethodGet {
		t.Fatalf("method = %q, want GET", seenMethod)
	}

	if seenPath != "/api/projects" {
		t.Fatalf("path = %q, want /api/projects", seenPath)
	}

	if seenQuery != "include_archived=false" {
		t.Fatalf("query = %q, want include_archived=false", seenQuery)
	}

	if stderr != "" {
		t.Fatalf("stderr = %q, want empty stderr", stderr)
	}

	for _, want := range []string{
		"ID",
		"PATH",
		"ARCHIVED",
		"REGISTERED",
		"VERSION",
		"project-123",
		"/tmp/demo",
		"false",
		"2026-08-07T00:00:00Z",
		"7",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout = %q, want %q", stdout, want)
		}
	}
}

func TestProjectListIncludeArchivedUsesQueryAndIncludesArchivedRows(t *testing.T) {
	var seenQuery string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"projects":[{"project_id":"project-archived","path":"/tmp/archived","archived":true,"registered":"2026-08-07T01:00:00Z","version":9}]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout, stderr := captureOutput(t, func() {
		if err := projectList(c, []string{"--include-archived"}); err != nil {
			t.Fatalf("projectList: %v", err)
		}
	})

	if seenQuery != "include_archived=true" {
		t.Fatalf("query = %q, want include_archived=true", seenQuery)
	}

	if stderr != "" {
		t.Fatalf("stderr = %q, want empty stderr", stderr)
	}

	if !strings.Contains(stdout, "project-archived") || !strings.Contains(stdout, "true") {
		t.Fatalf("stdout = %q, want archived project row", stdout)
	}
}

func TestProjectListJSONOutputArray(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"projects":[{"project_id":"project-1","path":"/tmp/one"},{"project_id":"project-2","path":"/tmp/two"}]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout, stderr := captureOutput(t, func() {
		if err := projectList(c, []string{"--format=json"}); err != nil {
			t.Fatalf("projectList: %v", err)
		}
	})

	if stderr != "" {
		t.Fatalf("stderr = %q, want empty stderr", stderr)
	}

	var projects []map[string]any
	if err := json.Unmarshal([]byte(stdout), &projects); err != nil {
		t.Fatalf("stdout is not JSON array: %v: %q", err, stdout)
	}

	if len(projects) != 2 {
		t.Fatalf("len(projects) = %d, want 2", len(projects))
	}

	if got := projects[0]["project_id"]; got != "project-1" {
		t.Fatalf("projects[0].project_id = %#v, want project-1", got)
	}
}

func TestProjectListNDJSONOutput(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"projects":[{"project_id":"project-1","path":"/tmp/one"},{"project_id":"project-2","path":"/tmp/two"}]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout, stderr := captureOutput(t, func() {
		if err := projectList(c, []string{"--format=ndjson"}); err != nil {
			t.Fatalf("projectList: %v", err)
		}
	})

	if stderr != "" {
		t.Fatalf("stderr = %q, want empty stderr", stderr)
	}

	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	if len(lines) != 2 {
		t.Fatalf("ndjson lines = %d, want 2: %q", len(lines), stdout)
	}

	for i, line := range lines {
		var project map[string]any
		if err := json.Unmarshal([]byte(line), &project); err != nil {
			t.Fatalf("line %d is not JSON: %v: %q", i, err, line)
		}
	}

	if !strings.Contains(lines[0], `"project-1"`) || !strings.Contains(lines[1], `"project-2"`) {
		t.Fatalf("stdout = %q, want one JSON object per project line", stdout)
	}
}

func TestProjectListEmptyResponseExitsZero(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"projects":[]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout, stderr := captureOutput(t, func() {
		if err := projectList(c, []string{"--format=json"}); err != nil {
			t.Fatalf("projectList: %v", err)
		}
	})

	if stderr != "" {
		t.Fatalf("stderr = %q, want empty stderr", stderr)
	}

	if strings.TrimSpace(stdout) != "[]" {
		t.Fatalf("stdout = %q, want empty JSON array", stdout)
	}
}

func TestProjectListWarnsOnTruncatedResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"projects":[{"project_id":"project-1","path":"/tmp/one"}],"meta":{"truncated":true}}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	stdout, stderr := captureOutput(t, func() {
		if err := projectList(c, nil); err != nil {
			t.Fatalf("projectList: %v", err)
		}
	})

	if !strings.Contains(stdout, "project-1") {
		t.Fatalf("stdout = %q, want project row", stdout)
	}

	if !strings.Contains(stderr, "warning: project list truncated") {
		t.Fatalf("stderr = %q, want truncation warning", stderr)
	}
}

func TestProjectListHTTPExitCodes(t *testing.T) {
	cases := []struct {
		name       string
		statusCode int
		wantExit   int
	}{
		{name: "unauthorized exits four", statusCode: http.StatusUnauthorized, wantExit: 4},
		{name: "server error exits five", statusCode: http.StatusInternalServerError, wantExit: 5},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.statusCode)
				_, _ = w.Write([]byte(`{"error":"boom"}`))
			}))
			defer srv.Close()

			c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

			err := projectList(c, nil)
			if err == nil {
				t.Fatal("projectList error = nil, want HTTP error")
			}

			if got := client.ExitCode(err); got != tc.wantExit {
				t.Fatalf("exit code = %d, want %d", got, tc.wantExit)
			}
		})
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	stdout, _ := captureOutput(t, fn)
	return stdout
}

func captureOutput(t *testing.T, fn func()) (string, string) {
	t.Helper()

	stdoutReader, stdoutWriter, err := os.Pipe()
	if err != nil {
		t.Fatalf("stdout os.Pipe: %v", err)
	}

	stderrReader, stderrWriter, err := os.Pipe()
	if err != nil {
		t.Fatalf("stderr os.Pipe: %v", err)
	}

	oldStdout := os.Stdout
	oldStderr := os.Stderr
	os.Stdout = stdoutWriter
	os.Stderr = stderrWriter

	defer func() {
		os.Stdout = oldStdout
		os.Stderr = oldStderr
	}()

	fn()

	if err := stdoutWriter.Close(); err != nil {
		t.Fatalf("close stdout writer: %v", err)
	}

	if err := stderrWriter.Close(); err != nil {
		t.Fatalf("close stderr writer: %v", err)
	}

	stdout, err := io.ReadAll(stdoutReader)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}

	stderr, err := io.ReadAll(stderrReader)
	if err != nil {
		t.Fatalf("read stderr: %v", err)
	}

	return string(stdout), string(stderr)
}

func equalJSON(a, b map[string]any) bool {
	left, err := json.Marshal(a)
	if err != nil {
		return false
	}

	right, err := json.Marshal(b)
	if err != nil {
		return false
	}

	return string(left) == string(right)
}

func sha256HexTest(input string) string {
	sum := sha256.Sum256([]byte(input))
	return hex.EncodeToString(sum[:])
}
