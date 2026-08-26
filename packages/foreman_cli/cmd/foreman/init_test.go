package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// TestInitPostsInstallWithEmptyBody proves that `foreman init --force`
// posts to `/api/admin/workflows/install` with an *empty* JSON object
// so the server resolves both the source (bundled app dir) and the
// target (`System.user_home!()/.foreman/workflows`) from its own
// configuration.
//
// A CLI that pinned a `target_dir` here would install into the
// *client* machine's user home on the *server*, which is exactly what
// the server-authoritative-root contract is meant to prevent.
func TestInitPostsInstallWithEmptyBody(t *testing.T) {
	var (
		gotMethod string
		gotPath   string
		gotBody   []byte
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"installed","paths":["/tmp/.foreman/workflows/plan.yaml"]}`))
	}))
	defer server.Close()

	c := &client.Client{BaseURL: server.URL, HTTP: server.Client()}
	if err := runInit(c, []string{"--force"}); err != nil {
		t.Fatalf("runInit(--force) error = %v", err)
	}

	if gotMethod != http.MethodPost {
		t.Fatalf("method = %q, want POST", gotMethod)
	}

	if gotPath != "/api/admin/workflows/install" {
		t.Fatalf("path = %q, want /api/admin/workflows/install", gotPath)
	}

	var fields map[string]any
	if err := json.Unmarshal(gotBody, &fields); err != nil {
		t.Fatalf("body is not JSON: %v (raw=%q)", err, string(gotBody))
	}

	if len(fields) != 0 {
		t.Fatalf("body must be {} (server-resolves path contract); got %d keys: %v", len(fields), fields)
	}
}

// TestInitPropagatesServerError proves that runInit surfaces non-2xx
// responses as a structured client.Error instead of swallowing them —
// the operator must see the server's failure reason when a refresh
// fails (e.g. permission denied on the target root).
func TestInitPropagatesServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"error":"permission_denied"}`))
	}))
	defer server.Close()

	c := &client.Client{BaseURL: server.URL, HTTP: server.Client()}
	err := runInit(c, []string{"--force"})
	if err == nil {
		t.Fatalf("runInit(--force) error = nil, want non-nil")
	}

	var cliErr *client.Error
	if !errors.As(err, &cliErr) {
		t.Fatalf("error type = %T, want *client.Error (err=%v)", err, err)
	}

	if cliErr.Status != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want %d", cliErr.Status, http.StatusUnprocessableEntity)
	}
}
