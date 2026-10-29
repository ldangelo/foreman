package main

import (
	"net/http"
	"strings"
	"testing"
)

const (
	freshBody    = `{"status":"accepted","result":{"project_id":"p1","replayed":false}}`
	replayedBody = `{"status":"accepted","result":{"project_id":"p1","replayed":true}}`
)

// replayCases is every `project` command whose command id is derived from its payload and that
// printed a success line before the server could say the id was already recorded.
var replayCases = []struct {
	name    string
	args    []string
	applied string
}{
	{"create", []string{"create", "--path", "/srv/p", "--id", "p1", "--task-provider", "native"}, "registered project p1"},
	{"update", []string{"update", "--thread-model", "X", "p1"}, "updated project p1"},
	{"pause", []string{"pause", "p1"}, "paused project p1"},
	{"resume", []string{"resume", "p1"}, "resumed project p1"},
	{"reactivate", []string{"reactivate", "p1"}, "reactivated project p1"},
	{"delete", []string{"delete", "p1"}, "archived project p1"},
	{"repo add", []string{"repo", "add", "--id", "api", "--path", "/srv/api", "p1"}, "added repository api to project p1"},
	{"repo remove", []string{"repo", "remove", "--id", "api", "p1"}, "removed repository api from project p1"},
	{"schedule create", timezoneCreateArgs(), "created schedule"},
	{"schedule update", []string{"schedule", "update", "--project-id", "p1", "--id", "s1", "--name", "n"}, "updated schedule s1"},
}

func TestProjectCommandsPrintHonestMessageOnReplay(t *testing.T) {
	for _, tc := range replayCases {
		t.Run(tc.name+"/applied", func(t *testing.T) {
			c, _ := recordingServer(t, http.StatusCreated, freshBody)

			var err error
			out := captureStdout(t, func() { err = runProject(c, tc.args) })
			if err != nil {
				t.Fatalf("fresh command: %v", err)
			}
			if !strings.Contains(out, tc.applied) || strings.Contains(out, "no change") {
				t.Fatalf("fresh output = %q, want %q and no replay notice", out, tc.applied)
			}
		})

		t.Run(tc.name+"/replayed", func(t *testing.T) {
			c, _ := recordingServer(t, http.StatusCreated, replayedBody)

			var err error
			out := captureStdout(t, func() { err = runProject(c, tc.args) })
			if err != nil {
				t.Fatalf("a replay is not an error (exit 0): %v", err)
			}
			if strings.Contains(out, tc.applied) {
				t.Fatalf("replayed output = %q must not claim %q", out, tc.applied)
			}
			for _, want := range []string{"no change", "already recorded", "same command id", "--idempotency-key <new-key>"} {
				if !strings.Contains(out, want) {
					t.Fatalf("replayed output = %q, missing %q", out, want)
				}
			}
		})
	}
}

func TestProjectUpdateJSONFormatCarriesReplayedFlag(t *testing.T) {
	c, _ := recordingServer(t, http.StatusCreated, replayedBody)

	var err error
	out := captureStdout(t, func() { err = runProject(c, []string{"update", "--thread-model", "X", "--format", "json", "p1"}) })
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if !strings.Contains(out, `"replayed": true`) {
		t.Fatalf("json output = %q, want the server's replayed flag passed through", out)
	}
}
