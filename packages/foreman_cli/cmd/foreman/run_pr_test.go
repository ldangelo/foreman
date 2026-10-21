package main

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func TestRunPrVerbsPostTheirCommand(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		wantType string
		want     map[string]any
	}{
		{"fix-ci positional id with flags after it", []string{"fix-ci", "run-7", "--pr", "https://github.com/a/b/pull/1", "--note", "focus on unit"},
			"run.pr.fix_ci", map[string]any{"run_id": "run-7", "pr_url": "https://github.com/a/b/pull/1", "note": "focus on unit"}},
		{"fix-ci --id with no optional fields", []string{"fix-ci", "--id", "run-7"},
			"run.pr.fix_ci", map[string]any{"run_id": "run-7"}},
		{"address-comments", []string{"address-comments", "run-7", "--note", "n"},
			"run.pr.address_comments", map[string]any{"run_id": "run-7", "note": "n"}},
		{"resolve-conflicts", []string{"resolve-conflicts", "run-7", "--pr", "https://github.com/a/b/pull/2"},
			"run.pr.resolve_conflicts", map[string]any{"run_id": "run-7", "pr_url": "https://github.com/a/b/pull/2"}},
		{"create-pr sends only the run id", []string{"create-pr", "run-7"},
			"run.pr.create", map[string]any{"run_id": "run-7"}},
		{"watch-stop", []string{"watch-stop", "run-7", "--pr", "https://github.com/a/b/pull/1"},
			"run.pr.watch_stop", map[string]any{"run_id": "run-7", "pr_url": "https://github.com/a/b/pull/1"}},
		{"watch-start", []string{"watch-start", "run-7"},
			"run.pr.watch_start", map[string]any{"run_id": "run-7"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := captureCommand(t, func(c *client.Client) error { return runRun(c, tc.args) })
			if env == nil {
				t.Fatal("server was never hit")
			}
			if env.Type != tc.wantType {
				t.Errorf("type = %q, want %q", env.Type, tc.wantType)
			}
			if !reflect.DeepEqual(env.Payload, tc.want) {
				t.Errorf("payload = %v, want %v", env.Payload, tc.want)
			}
		})
	}
}

func TestRunPrVerbsRejectMissingRunIDWithoutCallingTheServer(t *testing.T) {
	for _, verb := range []string{"fix-ci", "address-comments", "resolve-conflicts", "create-pr", "watch-stop", "watch-start"} {
		t.Run(verb, func(t *testing.T) {
			if env := captureCommand(t, func(c *client.Client) error {
				return runRun(c, []string{verb, "--pr", "https://github.com/a/b/pull/1"})
			}); env != nil {
				t.Fatalf("server was hit with %+v; the run id must be validated client-side", env)
			}
		})
	}
}

func TestRunPrsReadsTheRunPrsEndpoint(t *testing.T) {
	var gotPath, gotMethod string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotMethod = r.URL.Path, r.Method
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"run_id":"run-7","prs":[]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}
	if err := runRun(c, []string{"prs", "run-7"}); err != nil {
		t.Fatalf("run prs: %v", err)
	}
	if gotMethod != http.MethodGet || gotPath != "/api/runs/run-7/prs" {
		t.Fatalf("request = %s %s, want GET /api/runs/run-7/prs", gotMethod, gotPath)
	}

	if err := runRun(c, []string{"prs"}); err == nil {
		t.Fatal("run prs without an id must fail")
	}
}
