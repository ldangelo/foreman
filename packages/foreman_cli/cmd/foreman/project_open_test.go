package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// trickyToken holds every character that a naive URL builder mangles: + / = & %.
const trickyToken = "tok+en/with=sp&ce%25end"

type openRequest struct {
	method, path, auth string
}

// openFixture is a fake API server plus a stub browser opener. It guarantees no test in this
// file can launch a real browser.
type openFixture struct {
	t        *testing.T
	srv      *httptest.Server
	mu       sync.Mutex
	requests []openRequest
	opened   []string
}

// newOpenFixture serves GET /api/projects/<id> with the given status and replaces openBrowser
// with a stub that records URLs and returns openErr.
func newOpenFixture(t *testing.T, status int, openErr error) *openFixture {
	t.Helper()

	f := &openFixture{t: t}

	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.requests = append(f.requests, openRequest{r.Method, r.URL.Path, r.Header.Get("Authorization")})
		f.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)

		if status == http.StatusOK {
			_, _ = w.Write([]byte(`{"project":{"project_id":"p"}}`))
		} else {
			_, _ = w.Write([]byte(`{"error":"nope"}`))
		}
	}))
	t.Cleanup(f.srv.Close)

	original := openBrowser
	openBrowser = func(target string) error {
		f.opened = append(f.opened, target)
		return openErr
	}
	t.Cleanup(func() { openBrowser = original })

	return f
}

func (f *openFixture) client(baseURL, token string) *client.Client {
	return &client.Client{BaseURL: baseURL, Token: token, HTTP: f.srv.Client()}
}

func (f *openFixture) requestCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()

	return len(f.requests)
}

func TestProjectOpenOpensWorkspaceWithTokenInURL(t *testing.T) {
	f := newOpenFixture(t, http.StatusOK, nil)
	c := f.client(f.srv.URL, trickyToken)

	var err error

	stdout, stderr := captureOutput(t, func() {
		err = projectOpen(c, []string{"project-1"})
	})
	if err != nil {
		t.Fatalf("projectOpen: %v", err)
	}

	if len(f.opened) != 1 {
		t.Fatalf("opener called %d times, want exactly 1: %v", len(f.opened), f.opened)
	}

	got, perr := url.Parse(f.opened[0])
	if perr != nil {
		t.Fatalf("opened URL %q does not parse: %v", f.opened[0], perr)
	}

	base, _ := url.Parse(f.srv.URL)
	if got.Scheme != base.Scheme || got.Host != base.Host {
		t.Errorf("opened %s://%s, want %s://%s", got.Scheme, got.Host, base.Scheme, base.Host)
	}

	if got.Path != "/dashboard/projects/project-1" {
		t.Errorf("opened path = %q, want /dashboard/projects/project-1", got.Path)
	}

	if tok := got.Query().Get("token"); tok != trickyToken {
		t.Errorf("token query param round-trips to %q, want %q", tok, trickyToken)
	}

	if len(got.Query()) != 1 {
		t.Errorf("opened URL carries extra query params: %q", got.RawQuery)
	}

	// Step 2 must have asked the API about this project with the Bearer header.
	if len(f.requests) != 1 || f.requests[0] != (openRequest{http.MethodGet, "/api/projects/project-1", "Bearer " + trickyToken}) {
		t.Errorf("API requests = %+v, want one authenticated GET /api/projects/project-1", f.requests)
	}

	wantLine := "opened " + f.srv.URL + "/dashboard/projects/project-1 in your browser (token from FOREMAN_API_TOKEN, not printed)\n"
	if stdout != wantLine {
		t.Errorf("stdout = %q, want %q", stdout, wantLine)
	}

	assertNoTokenLeak(t, trickyToken, "stdout", stdout)
	assertNoTokenLeak(t, trickyToken, "stderr", stderr)
}

func TestProjectOpenWithoutTokenFailsBeforeAnyRequest(t *testing.T) {
	f := newOpenFixture(t, http.StatusOK, nil)
	c := f.client(f.srv.URL, "")

	var err error

	stdout := captureStdout(t, func() {
		err = projectOpen(c, []string{"project-1"})
	})

	if err == nil {
		t.Fatal("projectOpen without a token succeeded, want an error")
	}

	if !strings.Contains(err.Error(), "FOREMAN_API_TOKEN") {
		t.Errorf("error %q does not name FOREMAN_API_TOKEN", err)
	}

	if len(f.opened) != 0 {
		t.Errorf("opener called without a token: %v", f.opened)
	}

	if n := f.requestCount(); n != 0 {
		t.Errorf("server received %d requests without a token, want 0", n)
	}

	if stdout != "" {
		t.Errorf("stdout = %q, want empty", stdout)
	}
}

func TestProjectOpenRefusesWhenAPIRejectsTheProject(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
	}{
		{"unknown project", http.StatusNotFound},
		{"wrong token", http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newOpenFixture(t, tc.status, nil)
			c := f.client(f.srv.URL, trickyToken)

			var err error

			stdout, stderr := captureOutput(t, func() {
				err = projectOpen(c, []string{"ghost"})
			})

			var apiErr *client.Error
			if !errors.As(err, &apiErr) || apiErr.Status != tc.status {
				t.Fatalf("err = %v, want the API's HTTP %d returned unchanged", err, tc.status)
			}

			if len(f.opened) != 0 {
				t.Errorf("opener called after HTTP %d: %v", tc.status, f.opened)
			}

			if stdout != "" {
				t.Errorf("stdout = %q, want empty", stdout)
			}

			assertNoTokenLeak(t, trickyToken, "error", err.Error())
			assertNoTokenLeak(t, trickyToken, "stderr", stderr)
		})
	}
}

func TestProjectOpenOpenerFailureLeaksNeitherTokenNorURL(t *testing.T) {
	f := newOpenFixture(t, http.StatusOK, errors.New(`exec: "open": executable file not found in $PATH`))
	c := f.client(f.srv.URL, trickyToken)

	var err error

	stdout, stderr := captureOutput(t, func() {
		err = projectOpen(c, []string{"project-1"})
	})

	if err == nil {
		t.Fatal("projectOpen succeeded although the opener failed")
	}

	if !strings.Contains(err.Error(), "executable file not found") {
		t.Errorf("error %q lost the opener's reason", err)
	}

	if len(f.opened) != 1 {
		t.Fatalf("opener called %d times, want 1", len(f.opened))
	}

	if stdout != "" {
		t.Errorf("stdout = %q after a failed launch, want empty", stdout)
	}

	for name, text := range map[string]string{"error": err.Error(), "stdout": stdout, "stderr": stderr} {
		assertNoTokenLeak(t, trickyToken, name, text)

		if strings.Contains(text, f.opened[0]) {
			t.Errorf("%s leaks the tokenized URL: %q", name, text)
		}
	}
}

func TestProjectOpenEscapesProjectID(t *testing.T) {
	f := newOpenFixture(t, http.StatusOK, nil)
	c := f.client(f.srv.URL, trickyToken)

	var err error

	stdout := captureStdout(t, func() {
		err = projectOpen(c, []string{"café"})
	})
	if err != nil {
		t.Fatalf("projectOpen: %v", err)
	}

	if len(f.opened) != 1 {
		t.Fatalf("opener called %d times, want 1", len(f.opened))
	}

	got, perr := url.Parse(f.opened[0])
	if perr != nil {
		t.Fatalf("opened URL does not parse: %v", perr)
	}

	if got.EscapedPath() != "/dashboard/projects/caf%C3%A9" || got.Path != "/dashboard/projects/café" {
		t.Errorf("path = %q (escaped %q), want the id percent-encoded", got.Path, got.EscapedPath())
	}

	if want := f.srv.URL + "/dashboard/projects/caf%C3%A9 in your browser"; !strings.Contains(stdout, want) {
		t.Errorf("stdout = %q, want it to contain %q", stdout, want)
	}
}

func TestProjectOpenTrimsTrailingSlashOfBaseURL(t *testing.T) {
	f := newOpenFixture(t, http.StatusOK, nil)
	c := f.client(f.srv.URL+"//", trickyToken)

	var err error

	stdout := captureStdout(t, func() {
		err = projectOpen(c, []string{"project-1"})
	})
	if err != nil {
		t.Fatalf("projectOpen: %v", err)
	}

	if len(f.opened) != 1 {
		t.Fatalf("opener called %d times, want 1", len(f.opened))
	}

	want := f.srv.URL + "/dashboard/projects/project-1?token=" + url.QueryEscape(trickyToken)
	if f.opened[0] != want {
		t.Errorf("opened %q, want %q", f.opened[0], want)
	}

	if strings.Contains(stdout, "//dashboard") {
		t.Errorf("stdout has a doubled slash: %q", stdout)
	}
}

func TestProjectOpenRequiresExactlyOneProjectID(t *testing.T) {
	for _, args := range [][]string{nil, {"a", "b"}} {
		f := newOpenFixture(t, http.StatusOK, nil)
		c := f.client(f.srv.URL, trickyToken)

		err := projectOpen(c, args)

		var usageErr *client.UsageError
		if !errors.As(err, &usageErr) {
			t.Fatalf("args %v: err = %v, want a usage error", args, err)
		}

		if !strings.Contains(err.Error(), "foreman project open: expected one argument: <project-id>") {
			t.Errorf("args %v: usage error %q lacks the arity message", args, err)
		}

		if len(f.opened) != 0 || f.requestCount() != 0 {
			t.Errorf("args %v: opened %v with %d requests, want neither", args, f.opened, f.requestCount())
		}
	}
}

// assertNoTokenLeak fails if text carries the token raw or in its URL-encoded form.
func assertNoTokenLeak(t *testing.T, token, where, text string) {
	t.Helper()

	if strings.Contains(text, token) || strings.Contains(text, url.QueryEscape(token)) {
		t.Errorf("%s leaks the token: %q", where, text)
	}
}
