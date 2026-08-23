package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
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

// TestRunSubmitEnvelopeWithBaseBranch asserts that
// `foreman run submit --base-branch <branch>` posts the flag verbatim in
// the work.submit envelope payload. Per TRD-2026-80ba0665 the flag is
// captured at the protocol level only — server-side consumption is
// forthcoming.
func TestRunSubmitEnvelopeWithBaseBranch(t *testing.T) {
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runSubmit(c, []string{
		"-project-id", "foreman",
		"-workflow", "fix",
		"-prompt", "sample",
		"-base-branch", "slices/jido-migration",
	}); err != nil {
		t.Fatalf("runSubmit: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Type != "work.submit" {
		t.Fatalf("type: got %q, want work.submit", env.Type)
	}
	if env.Payload["base_branch"] != "slices/jido-migration" {
		t.Fatalf("base_branch: got %v, want slices/jido-migration", env.Payload["base_branch"])
	}
}

// TestRunSubmitOmitsBaseBranch asserts that omitting --base-branch
// produces a payload where the base_branch key is ABSENT (not nil) so the
// forthcoming server-side default resolution (operator's current checkout
// HEAD) can apply without being shadowed by an empty value.
func TestRunSubmitOmitsBaseBranch(t *testing.T) {
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runSubmit(c, []string{
		"-project-id", "foreman",
		"-workflow", "fix",
		"-prompt", "sample",
	}); err != nil {
		t.Fatalf("runSubmit: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Type != "work.submit" {
		t.Fatalf("type: got %q, want work.submit", env.Type)
	}
	if _, present := env.Payload["base_branch"]; present {
		t.Fatalf("base_branch should be absent, got %v", env.Payload["base_branch"])
	}
}

// TestRunSubmitRunDispatch confirms `foreman run submit` routes to
// runSubmit.
func TestRunSubmitRunDispatch(t *testing.T) {
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runRun(c, []string{"submit",
		"-project-id", "foreman",
		"-workflow", "fix",
		"-prompt", "sample",
		"-base-branch", "feat/x",
	}); err != nil {
		t.Fatalf("runRun submit: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Type != "work.submit" {
		t.Fatalf("type: got %q, want work.submit", env.Type)
	}
	if env.Payload["base_branch"] != "feat/x" {
		t.Fatalf("base_branch: got %v, want feat/x", env.Payload["base_branch"])
	}
}

func TestRunListFilters(t *testing.T) {
	var seenPath string
	var seenQuery string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenQuery = r.URL.RawQuery
		if r.Method != http.MethodGet {
			http.Error(w, "wrong method", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"runs":[]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := runList(c, []string{"-status", "failed", "-project-id", "foreman", "-limit", "5"}); err != nil {
		t.Fatalf("runList: %v", err)
	}

	if seenPath != "/api/runs" {
		t.Fatalf("path: got %q", seenPath)
	}
	values, err := url.ParseQuery(seenQuery)
	if err != nil {
		t.Fatalf("parse query: %v", err)
	}
	if values.Get("status") != "failed" || values.Get("project_id") != "foreman" || values.Get("limit") != "5" {
		t.Fatalf("query: got %q", seenQuery)
	}
}

func TestRunRemoveEnvelope(t *testing.T) {
	assertRunCommandEnvelope(t, func(c *client.Client) error {
		return runRemove(c, []string{"-id", "run-42"})
	}, "run.remove", "run-42")
}

func TestRunRemoveRequiresID(t *testing.T) {
	assertRunCommandRequiresID(t, func(c *client.Client) error { return runRemove(c, []string{}) })
}

func TestRunResetEnvelope(t *testing.T) {
	assertRunCommandEnvelope(t, func(c *client.Client) error {
		return runReset(c, []string{"-id", "run-42"})
	}, "run.reset", "run-42")
}

func TestRunResetRequiresID(t *testing.T) {
	assertRunCommandRequiresID(t, func(c *client.Client) error { return runReset(c, []string{}) })
}

func assertRunCommandEnvelope(t *testing.T, call func(*client.Client) error, wantType string, wantRunID string) {
	t.Helper()
	var captured []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured, _ = io.ReadAll(r.Body)
		if r.URL.Path != "/api/commands" {
			http.Error(w, "wrong path", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}
	if err := call(c); err != nil {
		t.Fatalf("call: %v", err)
	}

	var env commandEnvelope
	if err := json.Unmarshal(captured, &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Type != wantType {
		t.Fatalf("type: got %q, want %q", env.Type, wantType)
	}
	if env.Payload["run_id"] != wantRunID {
		t.Fatalf("run_id: got %v", env.Payload["run_id"])
	}
}

func assertRunCommandRequiresID(t *testing.T, call func(*client.Client) error) {
	t.Helper()
	var hitServer bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hitServer = true
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}
	if err := call(c); err == nil {
		t.Fatalf("expected missing id error")
	}
	if hitServer {
		t.Fatalf("server should not be hit when --id is missing")
	}
}
