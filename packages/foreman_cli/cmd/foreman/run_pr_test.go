package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
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

func TestRunPrVerbsRejectSurplusPositionalArguments(t *testing.T) {
	cases := [][]string{
		{"fix-ci", "run-7", "extra"},
		{"fix-ci", "run-7", "--note", "x", "extra"},
		{"address-comments", "run-7", "extra"},
		{"resolve-conflicts", "run-7", "extra"},
		{"create-pr", "run-7", "extra"},
		{"retry-pr", "run-7", "--repo-id", "b", "extra"},
		{"watch-stop", "run-7", "https://github.com/a/b/pull/2"},
		{"watch-start", "run-7", "https://github.com/a/b/pull/2"},
	}

	for _, args := range cases {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			var runErr error
			env := captureCommand(t, func(c *client.Client) error {
				runErr = runRun(c, args)
				return runErr
			})
			if env != nil {
				t.Fatalf("server was hit with %+v; surplus arguments must be rejected", env)
			}
			if runErr == nil || !strings.Contains(runErr.Error(), "unexpected argument") {
				t.Fatalf("err = %v, want unexpected argument usage error", runErr)
			}
		})
	}
}

// TRD-030: `foreman run publish-report` posts the operator command for the run's stream with a
// random command id of its own; it names no head, digest or level.
func TestRunPublishReportPostsItsCommand(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want map[string]any
	}{
		{"positional id", []string{"publish-report", "run-7"},
			map[string]any{"run_id": "run-7"}},
		{"--id", []string{"publish-report", "--id", "run-7"},
			map[string]any{"run_id": "run-7"}},
		{"--pr and --repo-id after a positional id",
			[]string{"publish-report", "run-7", "--pr", "https://github.com/a/b/pull/1", "--repo-id", "repo-b"},
			map[string]any{"run_id": "run-7", "pr_url": "https://github.com/a/b/pull/1", "repo_id": "repo-b"}},
		{"--id with --pr", []string{"publish-report", "--id", "run-9", "--pr", "https://github.com/a/b/pull/2"},
			map[string]any{"run_id": "run-9", "pr_url": "https://github.com/a/b/pull/2"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := captureCommand(t, func(c *client.Client) error { return runRun(c, tc.args) })
			if env == nil {
				t.Fatal("server was never hit")
			}
			if env.Type != "run.pr.publish_report" {
				t.Errorf("type = %q, want run.pr.publish_report", env.Type)
			}
			if !reflect.DeepEqual(env.Payload, tc.want) {
				t.Errorf("payload = %v, want %v", env.Payload, tc.want)
			}
			runID, _ := tc.want["run_id"].(string)
			if env.AggregateID != "run:"+runID {
				t.Errorf("aggregate_id = %q, want run:%s", env.AggregateID, runID)
			}
			if !strings.HasPrefix(env.CommandID, "publish-report-") || len(env.CommandID) <= len("publish-report-") {
				t.Errorf("command_id = %q, want a generated publish-report-<random> id", env.CommandID)
			}
		})
	}
}

func TestRunPublishReportSendsAFreshCommandIDEachCall(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 5; i++ {
		env := captureCommand(t, func(c *client.Client) error {
			return runRun(c, []string{"publish-report", "run-7"})
		})
		if env == nil || env.CommandID == "" {
			t.Fatalf("call %d: no command id sent: %+v", i, env)
		}
		if seen[env.CommandID] {
			t.Fatalf("command id %q was sent twice: two requests would collapse into one", env.CommandID)
		}
		seen[env.CommandID] = true
	}
}

func TestRunPublishReportWithoutARunIDFailsWithUsageAndNoRequest(t *testing.T) {
	for _, args := range [][]string{
		{"publish-report"},
		{"publish-report", "--pr", "https://github.com/a/b/pull/1"},
		{"publish-report", "--repo-id", "repo-b"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			var runErr error
			env := captureCommand(t, func(c *client.Client) error {
				runErr = runRun(c, args)
				return runErr
			})
			if env != nil {
				t.Fatalf("server was hit with %+v; the run id must be validated client-side", env)
			}
			if runErr == nil || !strings.Contains(runErr.Error(), "<run-id> is required") ||
				!strings.Contains(runErr.Error(), "Usage") {
				t.Fatalf("err = %v, want a usage error naming <run-id>", runErr)
			}
		})
	}
}

func TestRunPublishReportRejectsSurplusArguments(t *testing.T) {
	var runErr error
	env := captureCommand(t, func(c *client.Client) error {
		runErr = runRun(c, []string{"publish-report", "run-7", "https://github.com/a/b/pull/2"})
		return runErr
	})
	if env != nil {
		t.Fatalf("server was hit with %+v; surplus arguments must be rejected", env)
	}
	if runErr == nil || !strings.Contains(runErr.Error(), "unexpected argument") {
		t.Fatalf("err = %v, want unexpected argument usage error", runErr)
	}
}

// An accepted request is not a posted report: the CLI says so on stderr after the answer, and
// not at all when the request failed. The test swaps os.Stderr for a pipe and restores it with a
// defer; no test in this package calls t.Parallel(), so the swap cannot be seen by another test.
func TestRunPublishReportSaysWhatAcceptedMeans(t *testing.T) {
	readStderr := func(fn func()) string {
		old := os.Stderr
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		os.Stderr = w
		defer func() { os.Stderr = old }()

		fn()
		w.Close()
		out, _ := io.ReadAll(r)
		return string(out)
	}

	got := readStderr(func() {
		captureCommand(t, func(c *client.Client) error {
			return runRun(c, []string{"publish-report", "run-7"})
		})
	})
	for _, want := range []string{"request is recorded", "required_checks gate is on", "current risk record"} {
		if !strings.Contains(got, want) {
			t.Errorf("stderr %q lacks %q", got, want)
		}
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"no_risk_record"}`, http.StatusUnprocessableEntity)
	}))
	defer srv.Close()

	var runErr error
	got = readStderr(func() {
		runErr = runRun(&client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, []string{"publish-report", "run-7"})
	})
	if runErr == nil {
		t.Fatal("a refused request must be an error")
	}
	if strings.Contains(got, "request is recorded") {
		t.Errorf("a refused request printed the accepted note: %q", got)
	}
}

// The request names nothing the server decides: a head, a digest or a level is an unknown flag,
// a usage error, and nothing is posted.
func TestRunPublishReportRefusesFlagsThatNameWhatTheServerDecides(t *testing.T) {
	for _, flagArgs := range [][]string{
		{"--head-sha", "abc"},
		{"--digest", "d1"},
		{"--level", "LOW"},
	} {
		args := append([]string{"publish-report", "run-7"}, flagArgs...)
		t.Run(strings.Join(flagArgs, " "), func(t *testing.T) {
			var runErr error
			env := captureCommand(t, func(c *client.Client) error {
				runErr = runRun(c, args)
				return runErr
			})
			if env != nil {
				t.Fatalf("server was hit with %+v; the flag must be refused client-side", env)
			}
			if runErr == nil || !strings.Contains(runErr.Error(), "flag provided but not defined") {
				t.Fatalf("err = %v, want an unknown-flag usage error", runErr)
			}
		})
	}
}

func TestRunPublishReportSendsPrAndRepoIDTogether(t *testing.T) {
	env := captureCommand(t, func(c *client.Client) error {
		return runRun(c, []string{"publish-report", "--id", "run-7", "--repo-id", "repo-b", "--pr", "https://github.com/a/b/pull/3"})
	})
	if env == nil {
		t.Fatal("server was never hit")
	}
	want := map[string]any{"run_id": "run-7", "pr_url": "https://github.com/a/b/pull/3", "repo_id": "repo-b"}
	if !reflect.DeepEqual(env.Payload, want) {
		t.Errorf("payload = %v, want %v", env.Payload, want)
	}
}

// A first argument that starts with `-` is a flag, never a run id: nothing is posted.
func TestRunPublishReportFirstArgumentStartingWithADashIsNotARunID(t *testing.T) {
	for _, args := range [][]string{
		{"publish-report", "-run-7"},
		{"publish-report", "-x", "run-7"},
		{"publish-report", "--", "-run-7"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			var runErr error
			env := captureCommand(t, func(c *client.Client) error {
				runErr = runRun(c, args)
				return runErr
			})
			if env != nil {
				t.Fatalf("server was hit with %+v", env)
			}
			if runErr == nil {
				t.Fatal("want a usage error")
			}
		})
	}
}

// The server's refusal (a 422 with its reason) is the CLI's error, verbatim, and exits non-zero.
func TestRunPublishReportPrintsTheServersRefusal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"error":"command_rejected","detail":"no_risk_record: https://github.com/a/b/pull/1"}`))
	}))
	defer srv.Close()

	err := runRun(&client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, []string{"publish-report", "run-7"})
	if err == nil {
		t.Fatal("a refused request must be an error (non-zero exit)")
	}
	for _, want := range []string{"422", "no_risk_record"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("err = %q, want it to carry %q", err.Error(), want)
		}
	}
}
