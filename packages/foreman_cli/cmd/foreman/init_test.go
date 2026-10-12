package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
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

// TestInitTemplateScaffoldsWithNoServer proves that `foreman init --template
// basic` (no `--force`) writes the scaffold entirely client-side and makes
// zero HTTP requests.
func TestInitTemplateScaffoldsWithNoServer(t *testing.T) {
	dir := t.TempDir()

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	c := &client.Client{BaseURL: server.URL, HTTP: server.Client()}
	if err := runInit(c, []string{"--template", "basic", "--dir", dir}); err != nil {
		t.Fatalf("runInit(--template basic) error = %v", err)
	}

	if requests != 0 {
		t.Fatalf("requests = %d, want 0 (template scaffold must not touch the server)", requests)
	}

	for _, rel := range []string{"README.md", "Dockerfile", ".gitignore", "basic.exs", "prompts/basic.md"} {
		path := filepath.Join(dir, ".foreman", rel)
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected %s to exist: %v", path, err)
		}
	}
}

// TestEveryScaffoldedScriptFindsTheFilesItLoads guards the contract between a
// template script and the scaffold: a script that does
// `Code.require_file("x.exs", __DIR__)` or reads `prompts/y.md` must find that
// file next to it after `foreman init --template`, for EVERY template. A
// script rewritten to load a new helper without the scaffold shipping it
// fails here instead of at the user's first run.
func TestEveryScaffoldedScriptFindsTheFilesItLoads(t *testing.T) {
	loads := regexp.MustCompile(`(?:Code\.require_file|Path\.join)\((?:__DIR__, )?"([^"]+)"(?:, __DIR__)?\)`)

	for _, name := range []string{"basic", "iterate", "parallel", "review", "triage"} {
		dir := t.TempDir()
		c := &client.Client{BaseURL: "http://unused.invalid"}
		if err := runInit(c, []string{"--template", name, "--dir", dir}); err != nil {
			t.Fatalf("runInit(--template %s) error = %v", name, err)
		}

		root := filepath.Join(dir, ".foreman")
		script, err := os.ReadFile(filepath.Join(root, name+".exs"))
		if err != nil {
			t.Fatalf("%s: script not scaffolded: %v", name, err)
		}

		for _, m := range loads.FindAllStringSubmatch(string(script), -1) {
			if _, err := os.Stat(filepath.Join(root, m[1])); err != nil {
				t.Errorf("%s.exs loads %q but the scaffold did not write it: %v", name, m[1], err)
			}
		}
	}
}

// TestInitTemplateSecondRunSkipsExistingFiles proves a second invocation
// never overwrites an operator's edited scaffold: every file is reported
// skipped and the command still exits 0.
func TestInitTemplateSecondRunSkipsExistingFiles(t *testing.T) {
	dir := t.TempDir()
	c := &client.Client{BaseURL: "http://unused.invalid"}

	if err := runInit(c, []string{"--template", "basic", "--dir", dir}); err != nil {
		t.Fatalf("first runInit error = %v", err)
	}

	customized := filepath.Join(dir, ".foreman", "basic.exs")
	if err := os.WriteFile(customized, []byte("# edited by operator\n"), 0o644); err != nil {
		t.Fatalf("failed to simulate an edited scaffold file: %v", err)
	}

	if err := runInit(c, []string{"--template", "basic", "--dir", dir}); err != nil {
		t.Fatalf("second runInit error = %v", err)
	}

	data, err := os.ReadFile(customized)
	if err != nil {
		t.Fatalf("failed to read scaffold file after second run: %v", err)
	}

	if string(data) != "# edited by operator\n" {
		t.Fatalf("second init overwrote an existing file; got %q", string(data))
	}
}

// TestInitTemplateWithForceAlsoPosts proves `--force --template <name>`
// does both: the local scaffold and the asset-refresh POST.
func TestInitTemplateWithForceAlsoPosts(t *testing.T) {
	dir := t.TempDir()

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"installed","paths":[]}`))
	}))
	defer server.Close()

	c := &client.Client{BaseURL: server.URL, HTTP: server.Client()}
	if err := runInit(c, []string{"--template", "basic", "--dir", dir, "--force"}); err != nil {
		t.Fatalf("runInit(--template basic --force) error = %v", err)
	}

	if requests != 1 {
		t.Fatalf("requests = %d, want 1", requests)
	}

	if _, err := os.Stat(filepath.Join(dir, ".foreman", "basic.exs")); err != nil {
		t.Fatalf("expected scaffold to be written alongside --force: %v", err)
	}
}

// TestInitUnknownTemplateIsUsageError proves an unrecognized --template
// value is rejected before any file is written or any request is made.
func TestInitUnknownTemplateIsUsageError(t *testing.T) {
	dir := t.TempDir()
	c := &client.Client{BaseURL: "http://unused.invalid"}

	err := runInit(c, []string{"--template", "nonexistent", "--dir", dir})
	if err == nil {
		t.Fatalf("runInit(--template nonexistent) error = nil, want non-nil")
	}

	var cliErr *client.Error
	if errors.As(err, &cliErr) {
		t.Fatalf("error type = %T, want a usage error, not *client.Error", err)
	}

	if _, statErr := os.Stat(filepath.Join(dir, ".foreman")); !os.IsNotExist(statErr) {
		t.Fatalf(".foreman must not be created for an unknown template")
	}
}
