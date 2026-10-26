package main

import (
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

type libraryRequest struct {
	method string
	path   string
	fields map[string]string
	files  map[string]string // multipart filename -> content
}

func libraryServer(t *testing.T, status int, response string) (*client.Client, *libraryRequest) {
	t.Helper()
	rec := &libraryRequest{fields: map[string]string{}, files: map[string]string{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.method, rec.path = r.Method, r.URL.Path
		if mt, params, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err == nil && strings.HasPrefix(mt, "multipart/") {
			mr := multipart.NewReader(r.Body, params["boundary"])
			for {
				part, err := mr.NextPart()
				if err != nil {
					break
				}
				data, _ := io.ReadAll(part)
				// part.FileName() would strip the directory; the raw header keeps it.
				_, disp, _ := mime.ParseMediaType(part.Header.Get("Content-Disposition"))
				if name := disp["filename"]; name != "" {
					rec.files[name] = string(data)
				} else {
					rec.fields[part.FormName()] = string(data)
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(response))
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, Token: "t", HTTP: srv.Client()}, rec
}

func writeTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for rel, content := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestLibraryAddFolderUploadsEligibleFilesAndReportsSkipped(t *testing.T) {
	root := filepath.Join(t.TempDir(), "kit")
	writeTree(t, root, map[string]string{
		"a.md":                "A",
		"src/b.md":            "B",
		".env":                "SECRET=1",
		"node_modules/x/i.js": "x",
		".git/config":         "[core]",
	})
	if err := os.Symlink(filepath.Join(root, "a.md"), filepath.Join(root, "link.md")); err != nil {
		t.Fatal(err)
	}

	c, rec := libraryServer(t, 201, `{"entry":{"entry_id":"kit-1","name":"kit","file_count":2,"bytes":2},"skipped":[]}`)
	out := captureStdout(t, func() {
		if err := projectLibrary(c, []string{"add", "p1", root}); err != nil {
			t.Fatalf("add: %v", err)
		}
	})

	if rec.method != "POST" || rec.path != "/api/projects/p1/library" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	if got := sortedKeys(rec.files); strings.Join(got, ",") != "a.md,src/b.md" {
		t.Fatalf("uploaded files = %v, want only a.md and src/b.md", got)
	}
	if rec.fields["kind"] != "folder" || rec.fields["name"] != "kit" {
		t.Fatalf("fields = %v, want kind=folder name=kit", rec.fields)
	}
	for _, want := range []string{"added library entry kit-1", "skipped .env (hidden)", "skipped .git (hidden)", "skipped node_modules (node_modules)", "skipped link.md (symlink)"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
}

func TestLibraryAddFolderStopsAtFileCapAndReportsTheRest(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{}
	for i := 0; i < libraryFolderMaxFiles+2; i++ {
		files[filepath.Join("d", strings.Repeat("0", 3-len(libItoa(i)))+libItoa(i)+".txt")] = "x"
	}
	writeTree(t, root, files)

	c, rec := libraryServer(t, 201, `{"entry":{"entry_id":"e","name":"n"},"skipped":[]}`)
	out := captureStdout(t, func() {
		if err := projectLibrary(c, []string{"add", "--name", "n", "p1", root}); err != nil {
			t.Fatalf("add: %v", err)
		}
	})

	if len(rec.files) != libraryFolderMaxFiles {
		t.Fatalf("uploaded %d files, want %d", len(rec.files), libraryFolderMaxFiles)
	}
	if strings.Count(out, "(folder_file_cap)") != 2 {
		t.Fatalf("want 2 folder_file_cap skips:\n%s", out)
	}
}

func libItoa(i int) string {
	b, _ := json.Marshal(i)
	return string(b)
}

func TestLibraryAddFilesRejectsTooManyAndMissingLocally(t *testing.T) {
	c, rec := libraryServer(t, 201, `{}`)
	dir := t.TempDir()
	var paths []string
	for i := 0; i < libraryMaxFilesPerAdd+1; i++ {
		p := filepath.Join(dir, "f"+libItoa(i)+".txt")
		writeTree(t, dir, map[string]string{filepath.Base(p): "x"})
		paths = append(paths, p)
	}

	err := projectLibrary(c, append([]string{"add", "p1"}, paths...))
	if err == nil || !strings.Contains(err.Error(), "at most 100 files per add") {
		t.Fatalf("err = %v, want the 100-file limit", err)
	}
	if rec.method != "" {
		t.Fatalf("a request was sent despite the local failure: %s", rec.method)
	}

	if err := projectLibrary(c, []string{"add", "p1", filepath.Join(dir, "nope.txt")}); err == nil {
		t.Fatal("a missing file must fail locally")
	}
}

// Each file is under the per-file limit and there are fewer than 100 of them, yet the server
// refuses a request over its per-request cap (`upload_max_bytes`, 512 MiB) only AFTER the whole
// body was sent: the CLI refuses such a plan before it uploads a byte.
func TestLibraryAddFilesRejectsAPlanOverThePerRequestTotalLocally(t *testing.T) {
	c, rec := libraryServer(t, 201, `{}`)
	dir := t.TempDir()
	var paths []string
	for i := range 3 {
		// Sparse: 3 x 200 MiB is over the 512 MiB total; nothing here is ever read.
		p := filepath.Join(dir, "big"+libItoa(i)+".bin")
		f, err := os.Create(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := f.Truncate(200 * 1024 * 1024); err != nil {
			t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}

	err := projectLibrary(c, append([]string{"add", "p1"}, paths...))
	if err == nil || !strings.Contains(err.Error(), "per request") {
		t.Fatalf("err = %v, want the per-request total limit", err)
	}
	if rec.method != "" {
		t.Fatalf("a request was sent despite the local failure: %s", rec.method)
	}

	// `replace` shares the plan, so it refuses the same files the same way.
	if err := projectLibrary(c, append([]string{"replace", "p1", "e-1"}, paths...)); err == nil || !strings.Contains(err.Error(), "per request") {
		t.Fatalf("replace shares the plan: err = %v, want the per-request total limit", err)
	}
}

func TestLibraryAddFilesUsesBasenames(t *testing.T) {
	dir := t.TempDir()
	writeTree(t, dir, map[string]string{"one.md": "1", "sub/two.md": "2"})
	c, rec := libraryServer(t, 201, `{"entry":{"entry_id":"e","name":"x"},"skipped":[{"path":"two.md","reason":"hidden"}]}`)

	out := captureStdout(t, func() {
		if err := projectLibrary(c, []string{"add", "--name", "x", "p1", filepath.Join(dir, "one.md"), filepath.Join(dir, "sub/two.md")}); err != nil {
			t.Fatalf("add: %v", err)
		}
	})

	if got := sortedKeys(rec.files); strings.Join(got, ",") != "one.md,two.md" {
		t.Fatalf("files = %v", got)
	}
	if _, folder := rec.fields["kind"]; folder {
		t.Fatalf("a file add must not send kind=folder: %v", rec.fields)
	}
	if !strings.Contains(out, "skipped two.md (hidden)") {
		t.Fatalf("server skipped files must be printed:\n%s", out)
	}
}

func TestLibraryReplaceListRemove(t *testing.T) {
	dir := t.TempDir()
	writeTree(t, dir, map[string]string{"one.md": "1"})

	c, rec := libraryServer(t, 200, `{"entry":{"entry_id":"e-1","name":"x","file_count":1,"bytes":1},"skipped":[]}`)
	captureStdout(t, func() {
		if err := projectLibrary(c, []string{"replace", "p1", "e-1", filepath.Join(dir, "one.md")}); err != nil {
			t.Fatalf("replace: %v", err)
		}
	})
	if rec.method != "PUT" || rec.path != "/api/projects/p1/library/e-1" {
		t.Fatalf("replace request = %s %s", rec.method, rec.path)
	}

	c, rec = libraryServer(t, 200, `{"entries":[{"entry_id":"e-1","name":"x","kind":"file","file_count":1,"bytes":1}],"index":"","limits":{}}`)
	out := captureStdout(t, func() {
		if err := projectLibrary(c, []string{"list", "p1"}); err != nil {
			t.Fatalf("list: %v", err)
		}
	})
	if rec.method != "GET" || !strings.Contains(out, "e-1") {
		t.Fatalf("list request = %s, output %q", rec.method, out)
	}

	c, rec = libraryServer(t, 200, `{"status":"removed"}`)
	captureStdout(t, func() {
		if err := projectLibrary(c, []string{"remove", "p1", "e-1"}); err != nil {
			t.Fatalf("remove: %v", err)
		}
	})
	if rec.method != "DELETE" || rec.path != "/api/projects/p1/library/e-1" {
		t.Fatalf("remove request = %s %s", rec.method, rec.path)
	}
}

func TestLibraryServerErrorsSurface(t *testing.T) {
	root := t.TempDir()
	writeTree(t, root, map[string]string{"a.md": "A"})
	c, _ := libraryServer(t, 422, `{"error":"duplicate_name","message":"already exists"}`)

	err := projectLibrary(c, []string{"add", "--name", "kit", "p1", root})
	if err == nil || !strings.Contains(err.Error(), "duplicate_name") {
		t.Fatalf("err = %v, want the server error verbatim", err)
	}
}
