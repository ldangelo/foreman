package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func TestUserGuideProjectExamplesExecuteAgainstCLI(t *testing.T) {
	doc := readRepoDoc(t, "docs/user-guide.md")

	assertDocCommand(t, doc, "### Create a project", "foreman project create \\\n  --id project-123 \\\n  --path /srv/foreman/project-123 \\\n  --task-provider beads \\\n  --task-provider-database-path /srv/foreman/project-123/.beads", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %q, want POST", r.Method)
		}
		if r.URL.Path != "/api/commands" {
			t.Fatalf("path = %q, want /api/commands", r.URL.Path)
		}
		assertCommandEnvelope(t, body, "project.register", "project-123")
		assertTaskProvider(t, body, "beads")
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful summary and empty stderr", stdout, stderr)
		}
	}, `{"status":"accepted","result":{"events":1}}`)

	assertDocCommand(t, doc, "### Get one project", "foreman project get project-123", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodGet {
			t.Fatalf("method = %q, want GET", r.Method)
		}
		if r.URL.Path != "/api/projects/project-123" {
			t.Fatalf("path = %q, want /api/projects/project-123", r.URL.Path)
		}
		if len(body) != 0 {
			t.Fatalf("body = %q, want empty GET body", string(body))
		}
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful projection output and empty stderr", stdout, stderr)
		}
	}, `{"project":{"project_id":"project-123","path":"/srv/foreman/project-123","status":"active"}}`)

	assertDocCommand(t, doc, "### Update a project", "foreman project update --task-provider beads --task-provider-database-path /srv/foreman/project-123/.beads project-123", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %q, want POST", r.Method)
		}
		if r.URL.Path != "/api/commands" {
			t.Fatalf("path = %q, want /api/commands", r.URL.Path)
		}
		assertCommandEnvelope(t, body, "project.update", "project-123")
		assertTaskProvider(t, body, "beads")
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful summary and empty stderr", stdout, stderr)
		}
	}, `{"status":"accepted","result":{"events":1}}`)

	assertDocCommand(t, doc, "### Delete a project", "foreman project delete project-123", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %q, want POST", r.Method)
		}
		if r.URL.Path != "/api/commands" {
			t.Fatalf("path = %q, want /api/commands", r.URL.Path)
		}
		assertCommandEnvelope(t, body, "project.archive", "project-123")
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful archive summary and empty stderr", stdout, stderr)
		}
	}, `{"status":"accepted","result":{"project_id":"project-123"}}`)

	assertDocCommand(t, doc, "### List projects", "foreman project list", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodGet {
			t.Fatalf("method = %q, want GET", r.Method)
		}
		if r.URL.Path != "/api/projects" {
			t.Fatalf("path = %q, want /api/projects", r.URL.Path)
		}
		if r.URL.RawQuery != "include_archived=false" {
			t.Fatalf("query = %q, want include_archived=false", r.URL.RawQuery)
		}
		if len(body) != 0 {
			t.Fatalf("body = %q, want empty GET body", string(body))
		}
		for _, want := range []string{"ID", "PATH", "ARCHIVED", "REGISTERED", "VERSION", "project-123"} {
			if !strings.Contains(stdout, want) {
				t.Fatalf("stdout = %q, want %q", stdout, want)
			}
		}
		if stderr != "" {
			t.Fatalf("stderr = %q, want empty stderr", stderr)
		}
	}, `{"projects":[{"project_id":"project-123","path":"/srv/foreman/project-123","archived":false,"registered":"2026-08-07T00:00:00Z","version":7}]}`)
}

func TestCLIReferenceProjectExamplesExecuteAgainstCLI(t *testing.T) {
	doc := readRepoDoc(t, "docs/cli-reference.md")

	assertDocCommand(t, doc, "### `foreman project create`", "foreman project create \\\n  --id project-123 \\\n  --path /srv/foreman/project-123 \\\n  --task-provider beads \\\n  --task-provider-database-path /srv/foreman/project-123/.beads", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/commands" {
			t.Fatalf("request = %s %s, want POST /api/commands", r.Method, r.URL.Path)
		}
		assertCommandEnvelope(t, body, "project.register", "project-123")
		assertTaskProvider(t, body, "beads")
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful summary and empty stderr", stdout, stderr)
		}
	}, `{"status":"accepted","result":{"events":1}}`)

	assertDocCommand(t, doc, "### `foreman project get <id>`", "foreman project get project-123", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/projects/project-123" {
			t.Fatalf("request = %s %s, want GET /api/projects/project-123", r.Method, r.URL.Path)
		}
		if len(body) != 0 {
			t.Fatalf("body = %q, want empty GET body", string(body))
		}
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful projection output and empty stderr", stdout, stderr)
		}
	}, `{"project":{"project_id":"project-123","path":"/srv/foreman/project-123","status":"active"}}`)

	assertDocCommand(t, doc, "### `foreman project update <id>`", "foreman project update --task-provider beads --task-provider-database-path /srv/foreman/project-123/.beads project-123", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/commands" {
			t.Fatalf("request = %s %s, want POST /api/commands", r.Method, r.URL.Path)
		}
		assertCommandEnvelope(t, body, "project.update", "project-123")
		assertTaskProvider(t, body, "beads")
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful summary and empty stderr", stdout, stderr)
		}
	}, `{"status":"accepted","result":{"events":1}}`)

	assertDocCommand(t, doc, "### `foreman project delete <id>`", "foreman project delete --force project-123", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/commands" {
			t.Fatalf("request = %s %s, want POST /api/commands", r.Method, r.URL.Path)
		}
		assertCommandEnvelope(t, body, "project.archive", "project-123")
		if !strings.Contains(stdout, "project-123") || stderr != "" {
			t.Fatalf("stdout/stderr = %q / %q, want successful archive summary and empty stderr", stdout, stderr)
		}
	}, `{"status":"accepted","result":{"project_id":"project-123"}}`)

	assertDocCommand(t, doc, "### `foreman project list`", "foreman project list --include-archived", func(t *testing.T, r *http.Request, body []byte, stdout, stderr string) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/projects" {
			t.Fatalf("request = %s %s, want GET /api/projects", r.Method, r.URL.Path)
		}
		if r.URL.RawQuery != "include_archived=true" {
			t.Fatalf("query = %q, want include_archived=true", r.URL.RawQuery)
		}
		if len(body) != 0 {
			t.Fatalf("body = %q, want empty GET body", string(body))
		}
		if !strings.Contains(stdout, "project-archived") || !strings.Contains(stdout, "true") {
			t.Fatalf("stdout = %q, want archived row in table output", stdout)
		}
		if stderr != "" {
			t.Fatalf("stderr = %q, want empty stderr", stderr)
		}
	}, `{"projects":[{"project_id":"project-archived","path":"/srv/foreman/project-archived","archived":true,"registered":"2026-08-07T00:00:00Z","version":9}]}`)
}

func assertDocCommand(t *testing.T, doc, heading, wantCommand string, verify func(t *testing.T, r *http.Request, body []byte, stdout, stderr string), response string) {
	t.Helper()

	gotCommand := markdownCodeBlockAfterHeading(t, doc, heading)
	if gotCommand != wantCommand {
		t.Fatalf("%s example = %q, want %q", heading, gotCommand, wantCommand)
	}

	var seenRequest *http.Request
	var seenBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}
		seenRequest = r.Clone(r.Context())
		seenBody = append([]byte(nil), body...)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(response))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}
	stdout, stderr := captureOutput(t, func() {
		if err := runProject(c, docCommandArgs(t, gotCommand)); err != nil {
			t.Fatalf("runProject(%q): %v", gotCommand, err)
		}
	})

	if seenRequest == nil {
		t.Fatalf("%s example made no HTTP request", heading)
	}

	verify(t, seenRequest, seenBody, stdout, stderr)
}

func assertCommandEnvelope(t *testing.T, body []byte, wantType, wantProjectID string) {
	t.Helper()

	var env commandEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("decode envelope: %v: %s", err, body)
	}

	if env.Type != wantType {
		t.Fatalf("type = %q, want %q", env.Type, wantType)
	}

	if got := env.Payload["project_id"]; got != wantProjectID {
		t.Fatalf("payload.project_id = %#v, want %q", got, wantProjectID)
	}
}

func assertTaskProvider(t *testing.T, body []byte, wantProvider string) {
	t.Helper()

	var env commandEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("decode envelope: %v: %s", err, body)
	}

	taskProvider, ok := env.Payload["task_provider"].(map[string]any)
	if !ok {
		t.Fatalf("payload.task_provider type = %T, want map[string]any", env.Payload["task_provider"])
	}

	if got := taskProvider["provider"]; got != wantProvider {
		t.Fatalf("payload.task_provider.provider = %#v, want %q", got, wantProvider)
	}
}

func readRepoDoc(t *testing.T, rel string) string {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}

	path := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", "..", "..", rel))
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(bytes)
}

func markdownCodeBlockAfterHeading(t *testing.T, doc, heading string) string {
	t.Helper()

	idx := strings.Index(doc, heading)
	if idx < 0 {
		t.Fatalf("heading %q not found", heading)
	}

	rest := doc[idx+len(heading):]
	fenceStart := strings.Index(rest, "```")
	if fenceStart < 0 {
		t.Fatalf("code fence after %q not found", heading)
	}
	block := rest[fenceStart+3:]
	fenceEnd := strings.Index(block, "```")
	if fenceEnd < 0 {
		t.Fatalf("closing code fence after %q not found", heading)
	}

	return strings.Trim(block[:fenceEnd], "\n")
}

func docCommandArgs(t *testing.T, command string) []string {
	t.Helper()

	normalized := strings.ReplaceAll(command, "\\\n", " ")
	normalized = strings.ReplaceAll(normalized, "\\", "")
	normalized = strings.Join(strings.Fields(normalized), " ")
	parts := strings.Fields(normalized)
	if len(parts) < 3 || parts[0] != "foreman" || parts[1] != "project" {
		t.Fatalf("unexpected documented command shape: %q", command)
	}
	return parts[2:]
}
