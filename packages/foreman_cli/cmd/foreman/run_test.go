package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// TestRunCancelEnvelope asserts that `foreman run cancel --id <run-id>
// [--reason <r>]` posts a `run.cancel` operator command to /api/commands
// with `run_id` and `reason` in the payload, and uses the default
// `operator_cancel` reason when --reason is omitted.
func TestRunCancelEnvelope(t *testing.T) {
	var captured []byte
	var seenPath string
	var seenMethod string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenMethod = r.Method
		body, _ := io.ReadAll(r.Body)
		captured = body

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

		if env.Type != "run.cancel" {
			http.Error(w, "wrong type "+env.Type, http.StatusBadRequest)
			return
		}

		if env.Payload["run_id"] != "run-42" {
			http.Error(w, "wrong run_id", http.StatusBadRequest)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runCancel(c, []string{"-id", "run-42", "-reason", "user_abort"}); err != nil {
		t.Fatalf("runCancel: %v", err)
	}

	if seenPath != "/api/commands" {
		t.Fatalf("path: got %q", seenPath)
	}
	if seenMethod != http.MethodPost {
		t.Fatalf("method: got %q", seenMethod)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode captured: %v", err)
	}
	if env.Type != "run.cancel" {
		t.Fatalf("type: got %q", env.Type)
	}
	if env.Payload["run_id"] != "run-42" {
		t.Fatalf("run_id: got %v", env.Payload["run_id"])
	}
	if env.Payload["reason"] != "user_abort" {
		t.Fatalf("reason: got %v", env.Payload["reason"])
	}
}

// TestRunCancelDefaultsReason asserts that omitting --reason defaults
// to "operator_cancel" so the server's Run aggregate has a reason field
// in the RunCancelled event payload.
func TestRunCancelDefaultsReason(t *testing.T) {
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runCancel(c, []string{"-id", "run-x"}); err != nil {
		t.Fatalf("runCancel: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Payload["reason"] != "operator_cancel" {
		t.Fatalf("default reason: got %v, want operator_cancel", env.Payload["reason"])
	}
}

// TestRunCancelRequiresID asserts the CLI rejects calls without --id
// before posting to the server (no http call observed).
func TestRunCancelRequiresID(t *testing.T) {
	var hitServer bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hitServer = true
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := runCancel(c, []string{})
	if err == nil {
		t.Fatalf("expected error for missing --id")
	}
	if hitServer {
		t.Fatalf("server should not be hit when --id is missing")
	}
}

// TestRunRunDispatchesCancel confirms the `foreman run <subcommand>`
// dispatcher routes `cancel` to runCancel.
func TestRunRunDispatchesCancel(t *testing.T) {
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runRun(c, []string{"cancel", "-id", "run-y"}); err != nil {
		t.Fatalf("runRun cancel: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Type != "run.cancel" {
		t.Fatalf("type: got %q, want run.cancel", env.Type)
	}
	if env.Payload["run_id"] != "run-y" {
		t.Fatalf("run_id: got %v", env.Payload["run_id"])
	}
}
