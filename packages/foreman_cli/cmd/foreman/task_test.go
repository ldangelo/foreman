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