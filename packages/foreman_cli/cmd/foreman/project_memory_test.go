package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

type memoryRecordedRequest struct {
	method string
	path   string
	body   []byte
}

func memoryServer(t *testing.T, status int, response string) (*client.Client, *memoryRecordedRequest) {
	t.Helper()
	rec := &memoryRecordedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.method = r.Method
		rec.path = r.URL.Path
		rec.body, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(response))
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, Token: "t", HTTP: srv.Client()}, rec
}

func TestProjectMemoryWriteFromFilePutsDescriptionAndContent(t *testing.T) {
	c, rec := memoryServer(t, 200, `{"entry":{"name":"conv"}}`)
	file := filepath.Join(t.TempDir(), "c.md")
	if err := os.WriteFile(file, []byte("Use mix format."), 0o600); err != nil {
		t.Fatal(err)
	}

	out := captureStdout(t, func() {
		if err := projectMemory(c, []string{"write", "--name", "conv", "--description", "How we work", "--file", file, "proj-1"}); err != nil {
			t.Fatalf("write: %v", err)
		}
	})

	if rec.method != "PUT" || rec.path != "/api/projects/proj-1/memory/conv" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.body, &body); err != nil {
		t.Fatal(err)
	}
	if body["content"] != "Use mix format." || body["description"] != "How we work" {
		t.Fatalf("body = %v", body)
	}
	if !strings.Contains(out, "conv") {
		t.Fatalf("stdout = %q", out)
	}
}

func TestProjectMemoryWriteReadsStdin(t *testing.T) {
	c, rec := memoryServer(t, 200, `{"entry":{}}`)
	old := memoryStdin
	memoryStdin = strings.NewReader("from stdin")
	defer func() { memoryStdin = old }()

	captureStdout(t, func() {
		if err := projectMemory(c, []string{"write", "--name", "n", "--file", "-", "proj-1"}); err != nil {
			t.Fatalf("write: %v", err)
		}
	})
	if !strings.Contains(string(rec.body), `"from stdin"`) {
		t.Fatalf("body = %s", rec.body)
	}
}

func TestProjectMemoryWriteValidatesBeforeAnyRequest(t *testing.T) {
	c, rec := memoryServer(t, 200, `{}`)
	for _, args := range [][]string{
		{"write", "--file", "-", "proj-1"},
		{"write", "--name", "n", "proj-1"},
		{"forget", "proj-1"},
		{"read", "proj-1"},
	} {
		if err := projectMemory(c, args); err == nil {
			t.Fatalf("args %v: expected usage error", args)
		}
	}
	if rec.method != "" {
		t.Fatalf("a request was sent: %s %s", rec.method, rec.path)
	}
}

func TestProjectMemoryForgetDeletes(t *testing.T) {
	c, rec := memoryServer(t, 200, `{"status":"forgotten"}`)
	out := captureStdout(t, func() {
		if err := projectMemory(c, []string{"forget", "--name", "old", "proj-1"}); err != nil {
			t.Fatal(err)
		}
	})
	if rec.method != "DELETE" || rec.path != "/api/projects/proj-1/memory/old" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	if !strings.Contains(out, "old") {
		t.Fatalf("stdout = %q", out)
	}
}

func TestProjectMemoryListJSONIsNDJSONOfEntries(t *testing.T) {
	c, rec := memoryServer(t, 200, `{"index":"","entries":[{"name":"a","bytes":3},{"name":"b","bytes":4}]}`)
	out := captureStdout(t, func() {
		if err := projectMemory(c, []string{"list", "--format", "json", "proj-1"}); err != nil {
			t.Fatal(err)
		}
	})
	if rec.method != "GET" || rec.path != "/api/projects/proj-1/memory" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"a"`) || !strings.Contains(lines[1], `"b"`) {
		t.Fatalf("stdout = %q", out)
	}
}

func TestProjectMemoryListTable(t *testing.T) {
	c, _ := memoryServer(t, 200, `{"index":"","entries":[{"name":"a","bytes":3,"author_kind":"agent","description":"hook"}]}`)
	out := captureStdout(t, func() {
		if err := projectMemory(c, []string{"list", "proj-1"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, "NAME") || !strings.Contains(out, "hook") {
		t.Fatalf("stdout = %q", out)
	}
}

func TestProjectMemoryReadPrintsContentAndSyncPosts(t *testing.T) {
	c, rec := memoryServer(t, 200, `{"entry":{"name":"a"},"content":"body text"}`)
	out := captureStdout(t, func() {
		if err := projectMemory(c, []string{"read", "--name", "a", "proj-1"}); err != nil {
			t.Fatal(err)
		}
	})
	if out != "body text" {
		t.Fatalf("stdout = %q", out)
	}
	if rec.method != "GET" || rec.path != "/api/projects/proj-1/memory/a" {
		t.Fatalf("read request = %s %s", rec.method, rec.path)
	}

	c, rec = memoryServer(t, 200, `{"recorded":["a"],"forgotten":[],"failed":[]}`)
	out = captureStdout(t, func() {
		if err := projectMemory(c, []string{"sync", "proj-1"}); err != nil {
			t.Fatal(err)
		}
	})
	if rec.method != "POST" || rec.path != "/api/projects/proj-1/memory/sync" || !strings.Contains(out, "recorded 1") {
		t.Fatalf("request = %s %s stdout = %q", rec.method, rec.path, out)
	}
}

func TestProjectMemorySyncFailureIsNonZero(t *testing.T) {
	c, _ := memoryServer(t, 200, `{"recorded":[],"forgotten":[],"failed":[{"name":"dump","error":"content_not_durable","message":"x"}]}`)
	var err error
	captureStdout(t, func() { err = projectMemory(c, []string{"sync", "proj-1"}) })
	if err == nil {
		t.Fatal("expected error when a topic failed to sync")
	}
}

func TestProjectMemoryServerErrorSurfaces(t *testing.T) {
	c, _ := memoryServer(t, 422, `{"error":"content_too_large"}`)
	old := memoryStdin
	memoryStdin = strings.NewReader("x")
	defer func() { memoryStdin = old }()
	err := projectMemory(c, []string{"write", "--name", "n", "--file", "-", "proj-1"})
	if err == nil || !strings.Contains(err.Error(), "422") && !strings.Contains(err.Error(), "content_too_large") {
		t.Fatalf("err = %v", err)
	}
}
