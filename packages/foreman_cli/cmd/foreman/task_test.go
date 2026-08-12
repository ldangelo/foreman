package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// TestTaskApproveEnvelope asserts that `foreman task approve` posts the
// server-expected envelope: only `task_id` and `approved_by`. Reserved
// fields (approval_id, approved_at, run_id, workflow_snapshot) MUST NOT
// appear — CommandGateway rejects them with
// `{:invalid_envelope, :reserved_approval_field}`.
func TestTaskApproveEnvelope(t *testing.T) {
	var seen []byte
	var seenPath string
	var seenMethod string
	var seenAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		seenAuth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		seen = body

		if r.URL.Path != "/api/commands" {
			http.Error(w, "wrong path", http.StatusNotFound)
			return
		}

		if r.Method != http.MethodPost {
			http.Error(w, "wrong method", http.StatusMethodNotAllowed)
			return
		}

		var env commandEnvelope
		if err := json.Unmarshal(body, &env); err != nil {
			http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
			return
		}

		if env.Type != "task.approve" {
			http.Error(w, "wrong type", http.StatusBadRequest)
			return
		}

		for _, key := range []string{"approval_id", "approved_at", "run_id", "workflow_snapshot"} {
			if v, ok := env.Payload[key]; ok && v != nil {
				http.Error(w, "reserved field present: "+key, http.StatusBadRequest)
				return
			}
		}

		if env.Payload["task_id"] != "task-42" {
			http.Error(w, "wrong task_id", http.StatusBadRequest)
			return
		}

		if env.Payload["approved_by"] != "alice" {
			http.Error(w, "wrong approved_by", http.StatusBadRequest)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{
		BaseURL: srv.URL,
		Token:   "test-token",
		HTTP:    srv.Client(),
	}

	// Invoke taskApprove directly with the postCommand path; bypass the
	// os.Args-driven main() so the test stays hermetic.
	err := taskApprove(c, []string{
		"-id", "task-42",
		"-approved-by", "alice",
	})
	if err != nil {
		t.Fatalf("taskApprove: %v", err)
	}

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

	if env.Type != "task.approve" {
		t.Fatalf("type = %q, want task.approve", env.Type)
	}

	wantPayload := map[string]any{
		"task_id":     "task-42",
		"approved_by": "alice",
	}
	if len(env.Payload) != len(wantPayload) {
		t.Fatalf("payload keys = %v, want %v", keysOf(env.Payload), keysOf(wantPayload))
	}

	for k, v := range wantPayload {
		if got := env.Payload[k]; got != v {
			t.Fatalf("payload[%q] = %v, want %v", k, got, v)
		}
	}

	// Belt-and-braces: explicitly forbid reserved fields by name even
	// if they were inserted with empty strings (which the server treats
	// as "present" via `not in [nil, ""]`).
	for _, key := range []string{"approval_id", "approved_at", "run_id", "workflow_snapshot", "workflow_name"} {
		if v, ok := env.Payload[key]; ok && !isEmptyish(v) {
			t.Fatalf("reserved/operator-supplied field %q leaked into envelope: %v", key, v)
		}
	}
}

// TestTaskApproveSendsOnlyRequiredFields checks that even if extra
// flags are passed, the envelope never picks up operator-supplied
// approval fields (this guards against future flag additions that
// silently bypass the server-side reserved-field guard).
func TestTaskApproveSendsOnlyRequiredFields(t *testing.T) {
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := taskApprove(c, []string{"-id", "task-x", "-approved-by", "bob"}); err != nil {
		t.Fatalf("taskApprove: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}

	keys := keysOf(env.Payload)

	allowed := map[string]bool{"task_id": true, "approved_by": true}
	for _, k := range keys {
		if !allowed[k] {
			t.Fatalf("unexpected key %q in approve envelope (allowed: %v)", k, keys)
		}
	}
}

// TestTaskCreateRejectsUnknownWorkflowType ensures the CLI rejects
// any --workflow-type value outside the supported pair before the
// server sees it, instead of silently falling back to the default.
func TestTaskCreateRejectsUnknownWorkflowType(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("server should not be called for invalid input; body=%s", r.Body)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := taskCreate(c, []string{
		"-id", "task-x",
		"-project", "proj-1",
		"-title", "Implement X",
		"-workflow-type", "implement-bogus",
		"-trd-path", "docs/trd.md",
	})
	if err == nil {
		t.Fatalf("expected error for unsupported --workflow-type, got nil")
	}
	if !strings.Contains(err.Error(), "--workflow-type must be one of") {
		t.Fatalf("error lacks selector guidance: %v", err)
	}
}

// TestTaskCreateRequiresTrdPathForWorkflowType ensures that any
// --workflow-type selector must be paired with a nonblank --trd-path.
func TestTaskCreateRequiresTrdPathForWorkflowType(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("server should not be called when --trd-path missing; body=%s", r.Body)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := taskCreate(c, []string{
		"-id", "task-x",
		"-project", "proj-1",
		"-title", "Implement X",
		"-workflow-type", "implement-trd",
	})
	if err == nil {
		t.Fatalf("expected error when --workflow-type is set without --trd-path")
	}
	if !strings.Contains(err.Error(), "--trd-path is required") {
		t.Fatalf("error lacks trd-path guidance: %v", err)
	}
}

// TestTaskCreateRejectsAbsoluteTrdPath ensures the CLI rejects
// absolute --trd-path values, since the server expects a
// project-relative path.
func TestTaskCreateRejectsAbsoluteTrdPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("server should not be called for absolute path; body=%s", r.Body)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := taskCreate(c, []string{
		"-id", "task-x",
		"-project", "proj-1",
		"-title", "Implement X",
		"-trd-path", "/etc/passwd",
	})
	if err == nil {
		t.Fatalf("expected error for absolute --trd-path")
	}
	if !strings.Contains(err.Error(), "project-relative") {
		t.Fatalf("error lacks relative-path guidance: %v", err)
	}
}

// TestTaskCreateRejectsTraversingTrdPath ensures the CLI rejects
// --trd-path values that traverse outside the project root.
func TestTaskCreateRejectsTraversingTrdPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("server should not be called for traversal; body=%s", r.Body)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := taskCreate(c, []string{
		"-id", "task-x",
		"-project", "proj-1",
		"-title", "Implement X",
		"-trd-path", "../outside.md",
	})
	if err == nil {
		t.Fatalf("expected error for traversing --trd-path")
	}
	if !strings.Contains(err.Error(), "traverse outside the project root") {
		t.Fatalf("error lacks traversal guidance: %v", err)
	}
}

// TestTaskCreateValidEnvelopes asserts that the CLI passes the
// --workflow-type and --trd-path fields through to the server when
// they are present and valid, and trims surrounding whitespace.
func TestTaskCreateValidEnvelopes(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		wantKey string
		want    string
	}{
		{
			name:    "implement-trd",
			args:    []string{"-id", "t1", "-project", "p1", "-title", "T1", "-workflow-type", "implement-trd", "-trd-path", "docs/TRD-1.md"},
			wantKey: "workflow_type",
			want:    "implement-trd",
		},
		{
			name:    "implement-trd-beads",
			args:    []string{"-id", "t2", "-project", "p1", "-title", "T2", "-workflow-type", "implement-trd-beads", "-trd-path", "docs/TRD-2.md"},
			wantKey: "workflow_type",
			want:    "implement-trd-beads",
		},
		{
			name:    "trim whitespace",
			args:    []string{"-id", "t3", "-project", "p1", "-title", "T3", "-workflow-type", "  implement-trd  ", "-trd-path", "  docs/TRD-3.md  "},
			wantKey: "workflow_type",
			want:    "implement-trd",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var captured []byte
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				captured, _ = io.ReadAll(r.Body)
				w.WriteHeader(http.StatusCreated)
			}))
			defer srv.Close()

			c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

			if err := taskCreate(c, tc.args); err != nil {
				t.Fatalf("taskCreate: %v", err)
			}

			var env commandEnvelope
			if err := json.Unmarshal(captured, &env); err != nil {
				t.Fatalf("decode: %v", err)
			}

			got, ok := env.Payload[tc.wantKey]
			if !ok {
				t.Fatalf("payload missing %q: %v", tc.wantKey, env.Payload)
			}
			if got != tc.want {
				t.Fatalf("payload[%q] = %v, want %q", tc.wantKey, got, tc.want)
			}

			trdPath, ok := env.Payload["trd_path"]
			if !ok {
				t.Fatalf("payload missing trd_path: %v", env.Payload)
			}
			if strings.TrimSpace(trdPath.(string)) == "" {
				t.Fatalf("trd_path is empty after trimming")
			}
		})
	}
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func isEmptyish(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(x) == ""
	case map[string]any:
		return len(x) == 0
	}
	return false
}
