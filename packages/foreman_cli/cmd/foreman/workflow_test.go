package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// withStdin feeds `input` to os.Stdin for the duration of the test (the
// `workflow remove` confirmation prompt reads from it).
func withStdin(t *testing.T, input string) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.WriteString(input); err != nil {
		t.Fatal(err)
	}
	w.Close()
	old := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = old; r.Close() })
}

type removeCall struct{ method, path, body string }

func removeServer(t *testing.T) (*client.Client, *[]removeCall) {
	t.Helper()
	var calls []removeCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		calls = append(calls, removeCall{r.Method, r.URL.Path, strings.TrimSpace(string(b))})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"removed","paths":[]}`))
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, &calls
}

func TestWorkflowRemoveConfirmedPostsRemoveAll(t *testing.T) {
	c, calls := removeServer(t)
	withStdin(t, "y\n")

	if err := runWorkflow(c, []string{"remove", "--all"}); err != nil {
		t.Fatalf("remove --all: %v", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("server calls = %d, want 1", len(*calls))
	}
	got := (*calls)[0]
	if got.method != "POST" || got.path != "/api/admin/workflows/remove" || got.body != `{"remove_all":true}` {
		t.Fatalf("request = %+v, want POST /api/admin/workflows/remove {\"remove_all\":true}", got)
	}
}

func TestWorkflowRemoveDeclinedChangesNothing(t *testing.T) {
	for _, answer := range []string{"n\n", "\n", "yes please\n", ""} {
		c, calls := removeServer(t)
		withStdin(t, answer)

		if err := runWorkflow(c, []string{"remove", "--all"}); err != nil {
			t.Fatalf("answer %q: declining must not be an error, got %v", answer, err)
		}
		if len(*calls) != 0 {
			t.Fatalf("answer %q: server called %d times, want 0", answer, len(*calls))
		}
	}
}

func TestWorkflowRemoveRequiresAllFlag(t *testing.T) {
	c, calls := removeServer(t)
	withStdin(t, "y\n")

	if err := runWorkflow(c, []string{"remove"}); err == nil {
		t.Fatal("remove without --all must be a usage error")
	}
	if len(*calls) != 0 {
		t.Fatalf("server called %d times, want 0", len(*calls))
	}
}
