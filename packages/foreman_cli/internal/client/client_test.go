package client

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNewReadsEnvironmentWithDefaults(t *testing.T) {
	t.Setenv("FOREMAN_API_URL", "")
	t.Setenv("FOREMAN_API_TOKEN", "")

	c := New()
	if c.BaseURL != "http://127.0.0.1:4766" {
		t.Fatalf("expected default base URL, got %q", c.BaseURL)
	}
	if c.Token != "" {
		t.Fatalf("expected empty token, got %q", c.Token)
	}
	if c.HTTP == nil {
		t.Fatal("expected a configured http.Client")
	}
}

func TestNewReadsConfiguredEnvironment(t *testing.T) {
	t.Setenv("FOREMAN_API_URL", "https://foreman.example:9999")
	t.Setenv("FOREMAN_API_TOKEN", "secret-token")

	c := New()
	if c.BaseURL != "https://foreman.example:9999" {
		t.Fatalf("expected configured base URL, got %q", c.BaseURL)
	}
	if c.Token != "secret-token" {
		t.Fatalf("expected configured token, got %q", c.Token)
	}
}

func TestPostJSONSendsBodyAndDecodesResponse(t *testing.T) {
	var gotMethod, gotPath, gotAuth, gotContentType string
	var gotBody []byte

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotContentType = r.Header.Get("Content-Type")
		buf := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(buf)
		gotBody = buf

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, Token: "tok-123", HTTP: srv.Client()}

	var out struct {
		Status string `json:"status"`
	}
	if err := c.PostJSON("/api/commands", map[string]string{"type": "run.cancel"}, &out); err != nil {
		t.Fatalf("PostJSON returned error: %v", err)
	}

	if gotMethod != http.MethodPost {
		t.Fatalf("expected POST, got %s", gotMethod)
	}
	if gotPath != "/api/commands" {
		t.Fatalf("expected /api/commands, got %s", gotPath)
	}
	if gotAuth != "Bearer tok-123" {
		t.Fatalf("expected bearer auth header, got %q", gotAuth)
	}
	if gotContentType != "application/json" {
		t.Fatalf("expected JSON content type, got %q", gotContentType)
	}
	if len(gotBody) == 0 {
		t.Fatal("expected a non-empty request body")
	}
	if out.Status != "accepted" {
		t.Fatalf("expected decoded response, got %#v", out)
	}
}

func TestGetJSONOmitsAuthHeaderWhenTokenEmpty(t *testing.T) {
	var authHeaderSet bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeaderSet = r.Header.Get("Authorization") != ""
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"proj-1"}`))
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}

	var out struct {
		ID string `json:"id"`
	}
	if err := c.GetJSON("/api/projects/proj-1", &out); err != nil {
		t.Fatalf("GetJSON returned error: %v", err)
	}
	if authHeaderSet {
		t.Fatal("expected no Authorization header")
	}
	if out.ID != "proj-1" {
		t.Fatalf("expected decoded response, got %#v", out)
	}
}

func TestDoReturnsStructuredErrorOnNon2xx(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not found"}`))
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}

	err := c.GetJSON("/api/projects/missing", nil)
	if err == nil {
		t.Fatal("expected an error for a 404 response")
	}

	var httpErr *Error
	if !errors.As(err, &httpErr) {
		t.Fatalf("expected *Error, got %T: %v", err, err)
	}
	if httpErr.Status != http.StatusNotFound {
		t.Fatalf("expected status 404, got %d", httpErr.Status)
	}
	if httpErr.Body != `{"error":"not found"}` {
		t.Fatalf("expected body preserved, got %q", httpErr.Body)
	}
}

func TestDoReturnsDecodeErrorOnMalformedJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}

	var out struct{ ID string }
	if err := c.GetJSON("/api/projects/proj-1", &out); err == nil {
		t.Fatal("expected a decode error for malformed JSON")
	}
}

func TestDoSkipsDecodeWhenOutIsNil(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}

	if err := c.GetJSON("/api/projects/proj-1", nil); err != nil {
		t.Fatalf("expected no error when out is nil, got %v", err)
	}
}

func TestDoSkipsDecodeWhenBodyEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}

	var out struct{ ID string }
	if err := c.GetJSON("/api/projects/proj-1", &out); err != nil {
		t.Fatalf("expected no error for empty body, got %v", err)
	}
}

func TestExitCodeMapsErrorClasses(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"nil", nil, 0},
		{"help", NewHelpError("help text"), 0},
		{"usage", NewUsageError("bad flag"), 1},
		{"not found", &Error{Status: http.StatusNotFound}, 2},
		{"conflict", &Error{Status: http.StatusConflict}, 3},
		{"unauthorized", &Error{Status: http.StatusUnauthorized}, 4},
		{"server error", &Error{Status: http.StatusInternalServerError}, 5},
		{"server error 502", &Error{Status: http.StatusBadGateway}, 5},
		{"other http error", &Error{Status: http.StatusBadRequest}, 1},
		{"unwrapped error", errors.New("boom"), 1},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ExitCode(tc.err); got != tc.want {
				t.Fatalf("ExitCode(%v) = %d, want %d", tc.err, got, tc.want)
			}
		})
	}
}

func TestErrorMessagesIncludeContext(t *testing.T) {
	if got := (&Error{Status: 404, Body: "missing"}).Error(); got != "foreman: HTTP 404: missing" {
		t.Fatalf("unexpected Error message: %q", got)
	}
	if got := (&UsageError{Text: "bad flag"}).Error(); got != "bad flag" {
		t.Fatalf("unexpected UsageError message: %q", got)
	}
	if got := (&HelpError{Text: "usage text"}).Error(); got != "usage text" {
		t.Fatalf("unexpected HelpError message: %q", got)
	}
}

func TestJoinPathConcatenatesSegments(t *testing.T) {
	cases := []struct {
		name  string
		parts []string
		want  string
	}{
		{"simple", []string{"/api/tasks", "task-1"}, "/api/tasks/task-1"},
		{"empty segments skipped", []string{"/api/tasks", "", "task-1"}, "/api/tasks/task-1"},
		{"trailing slash on first", []string{"/api/tasks/", "task-1"}, "/api/tasks/task-1"},
		{"leading slash on second", []string{"/api/tasks", "/task-1"}, "/api/tasks/task-1"},
		{"both slashes", []string{"/api/tasks/", "/task-1"}, "/api/tasks/task-1"},
		{"single part", []string{"/api/tasks"}, "/api/tasks"},
		{"no parts", nil, ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := JoinPath(tc.parts...); got != tc.want {
				t.Fatalf("JoinPath(%v) = %q, want %q", tc.parts, got, tc.want)
			}
		})
	}
}

func TestURLValuesEncodesNonEmptyParams(t *testing.T) {
	if got := URLValues(map[string]string{}); got != "" {
		t.Fatalf("expected empty query string, got %q", got)
	}
	if got := URLValues(map[string]string{"status": ""}); got != "" {
		t.Fatalf("expected blank values to be omitted, got %q", got)
	}
	if got := URLValues(map[string]string{"status": "open"}); got != "?status=open" {
		t.Fatalf("expected single param encoded, got %q", got)
	}
}
