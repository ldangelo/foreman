package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// captureCommand runs fn against a server that accepts one command and returns
// the decoded envelope it received (or nil if the server was never hit).
func captureCommand(t *testing.T, fn func(c *client.Client) error) *commandEnvelope {
	t.Helper()

	var captured *commandEnvelope

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)

		var env commandEnvelope
		if err := json.Unmarshal(body, &env); err != nil {
			http.Error(w, "decode: "+err.Error(), http.StatusBadRequest)
			return
		}

		captured = &env
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	if err := fn(&client.Client{BaseURL: srv.URL, HTTP: srv.Client()}); err != nil {
		// Validation failures are asserted by the callers via `captured == nil`.
		t.Logf("command returned: %v", err)
	}

	return captured
}

func TestRunApproveMergePostsMergeApprove(t *testing.T) {
	env := captureCommand(t, func(c *client.Client) error {
		return runApproveMerge(c, []string{
			"-id", "run-7", "-approver", "leo", "-identity", "github:ldangelo",
		})
	})

	if env == nil {
		t.Fatal("server was never hit")
	}
	if env.Type != "merge_approve" {
		t.Fatalf("type = %q, want merge_approve", env.Type)
	}
	want := map[string]any{
		"run_id":            "run-7",
		"approver":          "leo",
		"approver_identity": "github:ldangelo",
	}
	if len(env.Payload) != len(want) {
		t.Fatalf("payload = %v, want exactly %v", env.Payload, want)
	}
	for k, v := range want {
		if env.Payload[k] != v {
			t.Errorf("payload[%q] = %v, want %v", k, env.Payload[k], v)
		}
	}
}

// The server builds the merge payload from the approved PrReady event. The CLI
// must therefore send nothing but the run id: any other field would be a way for a
// caller to try to steer which PR or commit gets merged.
func TestRunMergeSendsOnlyTheRunID(t *testing.T) {
	env := captureCommand(t, func(c *client.Client) error {
		return runMerge(c, []string{"-id", "run-7"})
	})

	if env == nil {
		t.Fatal("server was never hit")
	}
	if env.Type != "run.pr.merge" {
		t.Fatalf("type = %q, want run.pr.merge", env.Type)
	}
	if len(env.Payload) != 1 || env.Payload["run_id"] != "run-7" {
		t.Fatalf("payload = %v, want only run_id=run-7", env.Payload)
	}
}

func TestRunMergeVerbsRejectMissingFlagsWithoutCallingTheServer(t *testing.T) {
	cases := []struct {
		name string
		call func(c *client.Client) error
	}{
		{"merge without --id", func(c *client.Client) error { return runMerge(c, nil) }},
		{"approve-merge without --id", func(c *client.Client) error {
			return runApproveMerge(c, []string{"-approver", "leo", "-identity", "github:ldangelo"})
		}},
		{"approve-merge without --approver", func(c *client.Client) error {
			return runApproveMerge(c, []string{"-id", "run-7", "-identity", "github:ldangelo"})
		}},
		{"approve-merge without --identity", func(c *client.Client) error {
			return runApproveMerge(c, []string{"-id", "run-7", "-approver", "leo"})
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if env := captureCommand(t, tc.call); env != nil {
				t.Fatalf("server was hit with %+v; flags must be validated client-side", env)
			}
		})
	}
}

func TestRunRunDispatchesMergeVerbs(t *testing.T) {
	for verb, wantType := range map[string]string{
		"merge":         "run.pr.merge",
		"approve-merge": "merge_approve",
	} {
		args := []string{verb, "-id", "run-7"}
		if verb == "approve-merge" {
			args = append(args, "-approver", "leo", "-identity", "github:ldangelo")
		}

		env := captureCommand(t, func(c *client.Client) error { return runRun(c, args) })
		if env == nil || env.Type != wantType {
			t.Errorf("run %s: got %+v, want type %s", verb, env, wantType)
		}
	}
}

// A repository's PR is addressed by --repo-id; without it nothing but the run id
// is sent (the primary's PR), so the single-repo wire shape is unchanged.
func TestRunApproveMergeAndMergeCarryRepoID(t *testing.T) {
	approve := captureCommand(t, func(c *client.Client) error {
		return runApproveMerge(c, []string{
			"-id", "run-7", "-approver", "leo", "-identity", "github:ldangelo", "-repo-id", "b",
		})
	})
	if approve == nil || approve.Type != "merge_approve" || approve.Payload["repo_id"] != "b" {
		t.Fatalf("approve envelope = %+v, want merge_approve with repo_id b", approve)
	}

	merge := captureCommand(t, func(c *client.Client) error {
		return runMerge(c, []string{"-id", "run-7", "-repo-id", "b"})
	})
	if merge == nil || merge.Type != "run.pr.merge" || merge.Payload["repo_id"] != "b" || len(merge.Payload) != 2 {
		t.Fatalf("merge envelope = %+v, want run.pr.merge with exactly run_id and repo_id", merge)
	}
}

func TestRunRetryPrPostsRunPrRetry(t *testing.T) {
	env := captureCommand(t, func(c *client.Client) error {
		return runRetryPr(c, []string{"run-7", "-repo-id", "b"})
	})
	if env == nil || env.Type != "run.pr.retry" {
		t.Fatalf("envelope = %+v, want run.pr.retry", env)
	}
	if env.Payload["run_id"] != "run-7" || env.Payload["repo_id"] != "b" || len(env.Payload) != 2 {
		t.Fatalf("payload = %v, want exactly run_id and repo_id", env.Payload)
	}
}

func TestRunRetryPrRequiresRepoID(t *testing.T) {
	if env := captureCommand(t, func(c *client.Client) error {
		return runRetryPr(c, []string{"run-7"})
	}); env != nil {
		t.Fatalf("server was hit without --repo-id: %+v", env)
	}
}
