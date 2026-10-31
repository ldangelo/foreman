package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// jobsiteRecorder is a fake POST /api/jobsites/template server that records every
// request it receives and replies with a canned status and body.
type jobsiteRecorder struct {
	mu      sync.Mutex
	methods []string
	paths   []string
	bodies  [][]byte
}

func (r *jobsiteRecorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.bodies)
}

func (r *jobsiteRecorder) lastBody(t *testing.T) map[string]any {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.bodies) == 0 {
		t.Fatal("server received no request")
	}
	var got map[string]any
	if err := json.Unmarshal(r.bodies[len(r.bodies)-1], &got); err != nil {
		t.Fatalf("request body is not a JSON object: %v", err)
	}
	return got
}

func newJobsiteServer(t *testing.T, status int, response string) (*client.Client, *jobsiteRecorder) {
	t.Helper()
	rec := &jobsiteRecorder{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read request body: %v", err)
		}
		rec.mu.Lock()
		rec.methods = append(rec.methods, r.Method)
		rec.paths = append(rec.paths, r.URL.Path)
		rec.bodies = append(rec.bodies, body)
		rec.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, response)
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, Token: "test-token", HTTP: srv.Client()}, rec
}

const jobsiteOKResponse = `{
  "name": "fix-tests",
  "files": [
    {"path": "fix-tests.exs", "content": "# script\nIO.puts(\"hi\")\n"},
    {"path": "prompts/fix-tests.md", "content": "Fix the tests.\n"}
  ],
  "spec": {"name": "fix-tests", "agent": {"provider": "claude"}},
  "features": ["loop", "push-to-origin"],
  "notes": ["note one", "note two"]
}`

func TestJobsiteTemplateSendsExactRequestForFullFlagSet(t *testing.T) {
	c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()

	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template",
			"--project-id", "proj-1", "--prompt", "fix the failing tests",
			"--name", "fix-tests", "--provider", "claude", "--model", "opus",
			"--iterations", "7", "--signal", "DONE", "--branch", "feat/x",
			"--sandbox", "docker", "--push", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}

	if rec.methods[0] != "POST" || rec.paths[0] != "/api/jobsites/template" {
		t.Fatalf("request = %s %s, want POST /api/jobsites/template", rec.methods[0], rec.paths[0])
	}
	want := map[string]any{
		"project_id":        "proj-1",
		"prompt":            "fix the failing tests",
		"name":              "fix-tests",
		"agent":             map[string]any{"provider": "claude", "model": "opus"},
		"max_iterations":    float64(7),
		"completion_signal": "DONE",
		"strategy":          map[string]any{"branch": "feat/x"},
		"sandbox":           "docker",
		"push":              true,
	}
	if got := rec.lastBody(t); !reflect.DeepEqual(got, want) {
		t.Fatalf("request body = %#v, want %#v", got, want)
	}
}

func TestJobsiteTemplateOmitsUnsetFlags(t *testing.T) {
	c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()

	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "do it", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}

	want := map[string]any{"project_id": "p", "prompt": "do it"}
	if got := rec.lastBody(t); !reflect.DeepEqual(got, want) {
		t.Fatalf("request body = %#v, want exactly %#v", got, want)
	}
}

func TestJobsiteTemplateAgentObjectContainsOnlySetKeys(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want map[string]any
	}{
		{"provider only", []string{"--provider", "pi"}, map[string]any{"provider": "pi"}},
		{"model only", []string{"--model", "m"}, map[string]any{"model": "m"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
			args := append([]string{"template", "--project-id", "p", "--prompt", "x", "--dir", t.TempDir()}, tc.args...)
			var err error
			captureOutput(t, func() { err = runJobsite(c, args) })
			if err != nil {
				t.Fatalf("runJobsite: %v", err)
			}
			got := rec.lastBody(t)
			if !reflect.DeepEqual(got["agent"], tc.want) {
				t.Fatalf("agent = %#v, want %#v", got["agent"], tc.want)
			}
			if len(got) != 3 {
				t.Fatalf("body keys = %v, want project_id, prompt, agent only", got)
			}
		})
	}
}

func TestJobsiteTemplatePushTriState(t *testing.T) {
	cases := []struct {
		name    string
		extra   []string
		wantKey bool
		want    bool
	}{
		{"--push is true", []string{"--push"}, true, true},
		{"--push=false is false", []string{"--push=false"}, true, false},
		{"absent has no push key", nil, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
			args := append([]string{"template", "--project-id", "p", "--prompt", "x", "--dir", t.TempDir()}, tc.extra...)
			var err error
			captureOutput(t, func() { err = runJobsite(c, args) })
			if err != nil {
				t.Fatalf("runJobsite: %v", err)
			}
			got := rec.lastBody(t)
			v, present := got["push"]
			if present != tc.wantKey {
				t.Fatalf("push present = %v, want %v (body %v)", present, tc.wantKey, got)
			}
			if present && v != tc.want {
				t.Fatalf("push = %v, want %v", v, tc.want)
			}
		})
	}
}

func TestJobsiteTemplateSendsExplicitZeroIterations(t *testing.T) {
	c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--iterations", "0", "--dir", t.TempDir()})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}
	got := rec.lastBody(t)
	v, present := got["max_iterations"]
	if !present || v != float64(0) {
		t.Fatalf("max_iterations = %v (present=%v), want explicit 0", v, present)
	}
}

func TestJobsiteTemplateSendsPromptVerbatim(t *testing.T) {
	c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
	prompt := "  line one\n\tline \"two\" <&>  "
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", prompt, "--dir", t.TempDir()})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}
	if got := rec.lastBody(t)["prompt"]; got != prompt {
		t.Fatalf("prompt = %q, want %q", got, prompt)
	}
}

func TestJobsiteTemplateUsageErrorsSendNoRequest(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"missing project-id", []string{"template", "--prompt", "x"}},
		{"empty project-id", []string{"template", "--project-id", "", "--prompt", "x"}},
		{"missing prompt", []string{"template", "--project-id", "p"}},
		{"empty prompt", []string{"template", "--project-id", "p", "--prompt", ""}},
		{"positional argument", []string{"template", "--project-id", "p", "--prompt", "x", "stray"}},
		{"unknown format", []string{"template", "--project-id", "p", "--prompt", "x", "--format", "yaml"}},
		{"unknown flag", []string{"template", "--project-id", "p", "--prompt", "x", "--bogus"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
			var err error
			captureOutput(t, func() { err = runJobsite(c, tc.args) })
			var usageErr *client.UsageError
			if !errors.As(err, &usageErr) {
				t.Fatalf("error = %v (%T), want *client.UsageError", err, err)
			}
			if n := rec.count(); n != 0 {
				t.Fatalf("server received %d requests, want 0", n)
			}
		})
	}
}

func TestJobsiteTemplatePositiveControlSameArgsWithoutDefectSendRequest(t *testing.T) {
	// Control for the table above: the valid form of those invocations must reach
	// the server, so a zero request count there is caused by the usage error.
	c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--format", "json", "--dir", t.TempDir()})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}
	if n := rec.count(); n != 1 {
		t.Fatalf("server received %d requests, want 1", n)
	}
}

func TestRunJobsiteSubcommandErrors(t *testing.T) {
	for _, args := range [][]string{nil, {}, {"bogus"}} {
		c, rec := newJobsiteServer(t, 200, jobsiteOKResponse)
		err := runJobsite(c, args)
		var usageErr *client.UsageError
		if !errors.As(err, &usageErr) {
			t.Fatalf("runJobsite(%v) error = %v (%T), want *client.UsageError", args, err, err)
		}
		if n := rec.count(); n != 0 {
			t.Fatalf("runJobsite(%v) sent %d requests, want 0", args, n)
		}
	}
}

func TestJobsiteTemplateWritesFilesUnderDotForeman(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}

	want := map[string]string{
		filepath.Join(dir, ".foreman", "fix-tests.exs"):           "# script\nIO.puts(\"hi\")\n",
		filepath.Join(dir, ".foreman", "prompts", "fix-tests.md"): "Fix the tests.\n",
	}
	for path, content := range want {
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		if string(got) != content {
			t.Fatalf("%s = %q, want %q", path, got, content)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0o022 != 0 {
			t.Fatalf("%s mode %v is group/world writable", path, info.Mode().Perm())
		}
	}
}

func TestJobsiteTemplateNeverOverwritesExistingFiles(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()
	args := []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir}

	var err error
	captureOutput(t, func() { err = runJobsite(c, args) })
	if err != nil {
		t.Fatalf("first run: %v", err)
	}

	script := filepath.Join(dir, ".foreman", "fix-tests.exs")
	if err := os.WriteFile(script, []byte("operator edit\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout string
	stdout = captureStdout(t, func() { err = runJobsite(c, args) })
	if err != nil {
		t.Fatalf("second run must exit 0 when everything is skipped: %v", err)
	}

	got, readErr := os.ReadFile(script)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(got) != "operator edit\n" {
		t.Fatalf("second run overwrote the file: %q", got)
	}
	for _, rel := range []string{"fix-tests.exs", "prompts/fix-tests.md"} {
		line := "kept " + filepath.Join(dir, ".foreman", rel) + " (already exists; not overwritten)"
		if !strings.Contains(stdout, line+"\n") {
			t.Fatalf("stdout missing %q:\n%s", line, stdout)
		}
		if strings.Contains(stdout, "wrote "+filepath.Join(dir, ".foreman", rel)) {
			t.Fatalf("stdout claims to have written %s:\n%s", rel, stdout)
		}
	}
}

func TestJobsiteTemplateSkipsDanglingSymlinkWithoutWritingThrough(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()
	foreman := filepath.Join(dir, ".foreman")
	if err := os.MkdirAll(foreman, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "escaped-target")
	link := filepath.Join(foreman, "fix-tests.exs")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	var err error
	stdout := captureStdout(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}

	if _, statErr := os.Lstat(target); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("symlink target was created (write-through); Lstat err = %v", statErr)
	}
	if !strings.Contains(stdout, "kept "+link+" (already exists; not overwritten)\n") {
		t.Fatalf("dangling symlink not reported as kept:\n%s", stdout)
	}
	// The other file is independent and must still be written.
	if _, statErr := os.Stat(filepath.Join(foreman, "prompts", "fix-tests.md")); statErr != nil {
		t.Fatalf("sibling file not written: %v", statErr)
	}
}

func TestJobsiteTemplateRejectsUnsafePathsAndWritesNothing(t *testing.T) {
	cases := []struct {
		name  string
		paths []string
	}{
		{"parent traversal", []string{"ok.exs", "../x"}},
		{"nested traversal", []string{"ok.exs", "a/../../x"}},
		{"absolute path", []string{"ok.exs", "/abs"}},
		{"empty path", []string{"ok.exs", ""}},
		{"NUL in path", []string{"ok.exs", "a\x00b"}},
		{"duplicate paths", []string{"ok.exs", "dup.md", "dup.md"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			files := make([]map[string]string, 0, len(tc.paths))
			for _, p := range tc.paths {
				files = append(files, map[string]string{"path": p, "content": "x"})
			}
			resp, err := json.Marshal(map[string]any{"name": "n", "files": files, "spec": map[string]any{}, "features": []string{}, "notes": []string{}})
			if err != nil {
				t.Fatal(err)
			}
			c, rec := newJobsiteServer(t, 200, string(resp))
			dir := t.TempDir()

			captureOutput(t, func() {
				err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
			})
			if err == nil {
				t.Fatal("expected an error for an unsafe path set, got nil")
			}
			if rec.count() != 1 {
				t.Fatalf("server received %d requests, want 1 (the error must come from validating the response)", rec.count())
			}
			entries, readErr := os.ReadDir(dir)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if len(entries) != 0 {
				t.Fatalf("directory not untouched; found %d entries (first: %s)", len(entries), entries[0].Name())
			}
		})
	}
}

func TestJobsiteTemplateUnsafePathErrorNamesThePath(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, `{"name":"n","files":[{"path":"../evil.exs","content":"x"}],"spec":{},"features":[],"notes":[]}`)
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", t.TempDir()})
	})
	if err == nil || !strings.Contains(err.Error(), "../evil.exs") {
		t.Fatalf("error = %v, want it to name ../evil.exs", err)
	}
}

func TestJobsiteTemplateRejectsEmptyFilesList(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, `{"name":"n","files":[],"spec":{},"features":[],"notes":[]}`)
	dir := t.TempDir()
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
	})
	if err == nil {
		t.Fatal("expected an error for an empty files list")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("directory not untouched: %d entries", len(entries))
	}
}

func TestJobsiteTemplateReturnsClientErrorOn422(t *testing.T) {
	c, _ := newJobsiteServer(t, 422, `{"error":"spec_provider_invalid"}`)
	dir := t.TempDir()
	var err error
	captureOutput(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
	})
	var httpErr *client.Error
	if !errors.As(err, &httpErr) {
		t.Fatalf("error = %v (%T), want *client.Error", err, err)
	}
	if httpErr.Status != 422 {
		t.Fatalf("status = %d, want 422", httpErr.Status)
	}
	if !strings.Contains(err.Error(), "spec_provider_invalid") {
		t.Fatalf("error text %q lost the server body", err.Error())
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("files written on a failed request: %d entries", len(entries))
	}
}

func TestJobsiteTemplateTextOutputExactLines(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()
	var err error
	stdout := captureStdout(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "proj-9", "--prompt", "x", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}

	script := filepath.Join(dir, ".foreman", "fix-tests.exs")
	want := "wrote " + script + "\n" +
		"wrote " + filepath.Join(dir, ".foreman", "prompts", "fix-tests.md") + "\n" +
		"features read from the prompt: loop, push-to-origin\n" +
		"notes:\n" +
		"  * note one\n" +
		"  * note two\n" +
		"next: FOREMAN_API_TOKEN=... FOREMAN_PROJECT_ID=proj-9 elixir " + script + "\n"
	if stdout != want {
		t.Fatalf("stdout =\n%s\nwant\n%s", stdout, want)
	}
}

func TestJobsiteTemplateTextOutputWithoutFeaturesNotesOrScript(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, `{"name":"n","files":[{"path":"only.md","content":"m"}],"spec":{},"features":[],"notes":[]}`)
	dir := t.TempDir()
	var err error
	stdout := captureStdout(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}
	want := "wrote " + filepath.Join(dir, ".foreman", "only.md") + "\n" +
		"features read from the prompt: none\n"
	if stdout != want {
		t.Fatalf("stdout =\n%q\nwant\n%q", stdout, want)
	}
}

func TestJobsiteTemplateNextLineUsesFirstExsFile(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, `{"name":"n","files":[{"path":"prompts/n.md","content":"m"},{"path":"a.exs","content":"1"},{"path":"b.exs","content":"2"}],"spec":{},"features":[],"notes":[]}`)
	dir := t.TempDir()
	var err error
	stdout := captureStdout(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--dir", dir})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}
	want := "next: FOREMAN_API_TOKEN=... FOREMAN_PROJECT_ID=p elixir " + filepath.Join(dir, ".foreman", "a.exs") + "\n"
	if !strings.HasSuffix(stdout, want) {
		t.Fatalf("stdout = %q, want suffix %q", stdout, want)
	}
}

func TestJobsiteTemplateJSONOutputShape(t *testing.T) {
	c, _ := newJobsiteServer(t, 200, jobsiteOKResponse)
	dir := t.TempDir()
	args := []string{"template", "--project-id", "p", "--prompt", "x", "--format", "json", "--dir", dir}

	var err error
	stdout := captureStdout(t, func() { err = runJobsite(c, args) })
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}

	var got map[string]any
	if jerr := json.Unmarshal([]byte(stdout), &got); jerr != nil {
		t.Fatalf("stdout is not a JSON object: %v\n%s", jerr, stdout)
	}
	script := filepath.Join(dir, ".foreman", "fix-tests.exs")
	prompt := filepath.Join(dir, ".foreman", "prompts", "fix-tests.md")
	want := map[string]any{
		"name":     "fix-tests",
		"written":  []any{script, prompt},
		"skipped":  []any{},
		"features": []any{"loop", "push-to-origin"},
		"notes":    []any{"note one", "note two"},
		"spec":     map[string]any{"name": "fix-tests", "agent": map[string]any{"provider": "claude"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("json output = %#v, want %#v", got, want)
	}
	if _, serr := os.Stat(script); serr != nil {
		t.Fatalf("--format json must still write files: %v", serr)
	}

	// Second run: everything skipped, arrays stay arrays (never null).
	stdout = captureStdout(t, func() { err = runJobsite(c, args) })
	if err != nil {
		t.Fatalf("second runJobsite: %v", err)
	}
	got = nil
	if jerr := json.Unmarshal([]byte(stdout), &got); jerr != nil {
		t.Fatalf("second stdout is not JSON: %v", jerr)
	}
	if !reflect.DeepEqual(got["written"], []any{}) || !reflect.DeepEqual(got["skipped"], []any{script, prompt}) {
		t.Fatalf("second run written/skipped = %#v / %#v", got["written"], got["skipped"])
	}
}

func TestJobsiteTemplateJSONOutputArraysNeverNull(t *testing.T) {
	// Server omits features/notes entirely: the CLI must still emit [] not null.
	c, _ := newJobsiteServer(t, 200, `{"name":"n","files":[{"path":"a.exs","content":"1"}],"spec":{}}`)
	var err error
	stdout := captureStdout(t, func() {
		err = runJobsite(c, []string{"template", "--project-id", "p", "--prompt", "x", "--format", "json", "--dir", t.TempDir()})
	})
	if err != nil {
		t.Fatalf("runJobsite: %v", err)
	}
	var got map[string]json.RawMessage
	if jerr := json.Unmarshal([]byte(stdout), &got); jerr != nil {
		t.Fatal(jerr)
	}
	for _, key := range []string{"written", "skipped", "features", "notes"} {
		if string(got[key]) == "null" || len(got[key]) == 0 {
			t.Fatalf("%s = %s, want a JSON array", key, got[key])
		}
		if !strings.HasPrefix(string(got[key]), "[") {
			t.Fatalf("%s = %s, want a JSON array", key, got[key])
		}
	}
}

// testdata/jobsite_template_response.json is the response shape the server's controller test
// (JobsiteTemplateControllerTest, "the response has the shape the CLI's fixture pins") holds
// POST /api/jobsites/template to, so a change to either side's JSON breaks a test on that side.
func TestJobsiteTemplateConsumesTheServersResponseFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "jobsite_template_response.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Name  string `json:"name"`
		Files []struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		} `json:"files"`
		Spec     map[string]any `json:"spec"`
		Features []string       `json:"features"`
		Notes    []string       `json:"notes"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Files) != 2 || len(fixture.Features) == 0 || len(fixture.Notes) == 0 || len(fixture.Spec) == 0 {
		t.Fatalf("the fixture must carry two files, features, notes and a spec: %+v", fixture)
	}

	c, _ := newJobsiteServer(t, 200, string(raw))
	dir := t.TempDir()
	var runErr error
	stdout := captureStdout(t, func() {
		runErr = runJobsite(c, []string{"template", "--project-id", "proj-1", "--prompt", "x", "--format", "json", "--dir", dir})
	})
	if runErr != nil {
		t.Fatalf("runJobsite: %v", runErr)
	}

	for _, file := range fixture.Files {
		got, readErr := os.ReadFile(filepath.Join(dir, ".foreman", file.Path))
		if readErr != nil {
			t.Fatalf("%s was not written: %v", file.Path, readErr)
		}
		if string(got) != file.Content {
			t.Fatalf("%s = %q, want %q", file.Path, got, file.Content)
		}
	}

	var out struct {
		Name     string         `json:"name"`
		Written  []string       `json:"written"`
		Features []string       `json:"features"`
		Notes    []string       `json:"notes"`
		Spec     map[string]any `json:"spec"`
	}
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("output is not JSON: %v: %s", err, stdout)
	}
	if out.Name != fixture.Name || len(out.Written) != 2 ||
		!reflect.DeepEqual(out.Features, fixture.Features) ||
		!reflect.DeepEqual(out.Notes, fixture.Notes) ||
		!reflect.DeepEqual(out.Spec, fixture.Spec) {
		t.Fatalf("the CLI did not carry the fixture through: %+v", out)
	}
}
