package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

type seenRequest struct {
	method string
	path   string
	query  string
	body   []byte
}

// threadServer answers every request with the canned status/body and records them.
func threadServer(t *testing.T, handler func(r *http.Request) (int, string)) (*client.Client, *[]seenRequest) {
	t.Helper()

	var seen []seenRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, seenRequest{r.Method, r.URL.Path, r.URL.RawQuery, body})
		status, resp := handler(r)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(resp))
	}))
	t.Cleanup(srv.Close)

	return &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, &seen
}

func TestThreadStopPostsToStopRouteAndExitsZeroOn200(t *testing.T) {
	c, seen := threadServer(t, func(*http.Request) (int, string) {
		return 200, `{"thread_id":"run:r1","requested":"stopping"}`
	})

	var err error
	stdout, _ := captureOutput(t, func() {
		err = runThread(c, []string{"stop", "--reason", "too slow", "run:r1"})
	})
	if err != nil {
		t.Fatalf("thread stop: %v", err)
	}
	if client.ExitCode(err) != 0 {
		t.Fatalf("exit code = %d, want 0", client.ExitCode(err))
	}
	if len(*seen) != 1 || (*seen)[0].method != http.MethodPost || (*seen)[0].path != "/api/threads/run:r1/stop" {
		t.Fatalf("requests = %+v, want one POST /api/threads/run:r1/stop", *seen)
	}

	var body map[string]any
	if err := json.Unmarshal((*seen)[0].body, &body); err != nil || body["reason"] != "too slow" {
		t.Fatalf("body = %s, want reason=too slow", (*seen)[0].body)
	}
	if !strings.Contains(stdout, "stopping") {
		t.Fatalf("stdout = %q, want the server response", stdout)
	}
}

func TestThreadStopOmitsReasonWhenNotGiven(t *testing.T) {
	c, seen := threadServer(t, func(*http.Request) (int, string) { return 200, `{}` })

	captureOutput(t, func() { _ = runThread(c, []string{"stop", "jobsite:j1"}) })

	if len(*seen) != 1 || strings.Contains(string((*seen)[0].body), "reason") {
		t.Fatalf("requests = %+v, want a body without reason (server defaults operator_stop)", *seen)
	}
}

func TestThreadStopConflictExitsNonZeroWithServerText(t *testing.T) {
	c, _ := threadServer(t, func(*http.Request) (int, string) {
		return 409, `{"error":"not_stoppable","thread_id":"run:r1","status":"completed"}`
	})

	err := runThread(c, []string{"stop", "run:r1"})
	if err == nil {
		t.Fatal("thread stop on a 409 returned nil")
	}
	if code := client.ExitCode(err); code != 3 {
		t.Fatalf("exit code = %d, want 3 (conflict)", code)
	}
	if !strings.Contains(err.Error(), "not_stoppable") || !strings.Contains(err.Error(), "completed") {
		t.Fatalf("error = %q, want the server's error text", err.Error())
	}
}

func TestThreadResolvePostsEnvelopeWithThreadAggregate(t *testing.T) {
	c, seen := threadServer(t, func(r *http.Request) (int, string) {
		if r.Method == http.MethodGet {
			return 200, `{"thread":{"id":"run:r1","project_id":"proj-9"}}`
		}
		return 201, `{"status":"accepted"}`
	})

	var err error
	captureOutput(t, func() { err = runThread(c, []string{"resolve", "--reason", "shipped", "run:r1"}) })
	if err != nil {
		t.Fatalf("thread resolve: %v", err)
	}

	if len(*seen) != 2 || (*seen)[0].path != "/api/threads/run:r1" {
		t.Fatalf("requests = %+v, want GET thread then POST command", *seen)
	}
	post := (*seen)[1]
	if post.method != http.MethodPost || post.path != "/api/commands" {
		t.Fatalf("second request = %+v, want POST /api/commands", post)
	}

	var env commandEnvelope
	if err := json.Unmarshal(post.body, &env); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if env.Type != "thread.resolve" || env.AggregateID != "thread:run:r1" {
		t.Fatalf("envelope = %+v, want thread.resolve on thread:run:r1", env)
	}
	if env.Payload["thread_id"] != "run:r1" || env.Payload["project_id"] != "proj-9" ||
		env.Payload["reason"] != "shipped" || env.Payload["source"] != "cli" {
		t.Fatalf("payload = %#v", env.Payload)
	}
}

func TestThreadReopenPostsEnvelope(t *testing.T) {
	c, seen := threadServer(t, func(r *http.Request) (int, string) {
		if r.Method == http.MethodGet {
			return 200, `{"thread":{"id":"jobsite:j1","project_id":"proj-9"}}`
		}
		return 201, `{"status":"accepted"}`
	})

	captureOutput(t, func() { _ = runThread(c, []string{"reopen", "jobsite:j1"}) })

	var env commandEnvelope
	if len(*seen) != 2 || json.Unmarshal((*seen)[1].body, &env) != nil {
		t.Fatalf("requests = %+v", *seen)
	}
	if env.Type != "thread.reopen" || env.AggregateID != "thread:jobsite:j1" ||
		env.Payload["thread_id"] != "jobsite:j1" || env.Payload["project_id"] != "proj-9" {
		t.Fatalf("envelope = %+v", env)
	}
}

func TestThreadResolveUnknownThreadSendsNoCommand(t *testing.T) {
	c, seen := threadServer(t, func(*http.Request) (int, string) {
		return 404, `{"error":"thread_not_found"}`
	})

	err := runThread(c, []string{"resolve", "run:nope"})
	if client.ExitCode(err) != 2 {
		t.Fatalf("exit code = %d (err %v), want 2", client.ExitCode(err), err)
	}
	if len(*seen) != 1 {
		t.Fatalf("requests = %+v, want only the GET", *seen)
	}
}

func TestThreadListRequiresProject(t *testing.T) {
	c, seen := threadServer(t, func(*http.Request) (int, string) { return 200, `{}` })

	err := runThread(c, []string{"list"})
	var usageErr *client.UsageError
	if !errors.As(err, &usageErr) || client.ExitCode(err) == 0 {
		t.Fatalf("err = %v, want a non-zero usage error", err)
	}
	if !strings.Contains(err.Error(), "foreman thread list --project") {
		t.Fatalf("error = %q, want usage text", err.Error())
	}
	if len(*seen) != 0 {
		t.Fatalf("requests = %+v, want none", *seen)
	}
}

func TestThreadListAndGetRequests(t *testing.T) {
	c, seen := threadServer(t, func(*http.Request) (int, string) { return 200, `{"threads":[]}` })

	captureOutput(t, func() {
		_ = runThread(c, []string{"list", "--project", "p1", "--status", "running", "--door", "jobsite", "--limit", "5"})
		_ = runThread(c, []string{"get", "run:r1"})
	})

	if len(*seen) != 2 {
		t.Fatalf("requests = %+v", *seen)
	}
	list := (*seen)[0]
	if list.method != http.MethodGet || list.path != "/api/projects/p1/threads" ||
		list.query != "door=jobsite&limit=5&status=running" {
		t.Fatalf("list request = %+v", list)
	}
	if (*seen)[1].path != "/api/threads/run:r1" {
		t.Fatalf("get request = %+v", (*seen)[1])
	}
}

// Pin: every verb is dispatched and listed in both the thread usage text and
// the top-level usage const, so a new verb cannot ship undocumented.
func TestThreadUsageListsEveryVerb(t *testing.T) {
	c, _ := threadServer(t, func(*http.Request) (int, string) { return 200, `{}` })

	for _, verb := range threadVerbs {
		if !strings.Contains(threadUsage, "foreman thread "+verb) {
			t.Errorf("threadUsage does not list %q", verb)
		}
		if !strings.Contains(usage, "thread "+verb) {
			t.Errorf("main usage does not list %q", verb)
		}

		// Dispatched: a bare verb must fail with its own usage error, not "unknown subcommand".
		var err error
		captureOutput(t, func() { err = runThread(c, []string{verb}) })
		if err != nil && strings.Contains(err.Error(), "unknown subcommand") {
			t.Errorf("verb %q is not dispatched: %v", verb, err)
		}
	}

	if err := runThread(c, []string{"bogus"}); err == nil || !strings.Contains(err.Error(), "unknown subcommand") {
		t.Fatalf("bogus verb err = %v, want unknown subcommand", err)
	}
}
