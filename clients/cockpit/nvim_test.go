package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestDescribeRemoteDiffUsesRemoteSend(t *testing.T) {
	target := target{
		ok:      true,
		path:    "/tmp/changed file.go",
		label:   "changed file",
		base:    "origin/dev",
		relPath: "src/changed file.go",
	}
	cmd, mode := describe(EditorConfig{Cmd: "nvim", Mode: "remote", RemoteServer: "/tmp/nvim.sock"}, target, true)
	if !strings.Contains(cmd, "--server /tmp/nvim.sock --remote-send") {
		t.Fatalf("expected remote-send diff command, got %q", cmd)
	}
	if !strings.Contains(cmd, ":edit origin/dev:src/changed\\ file.go | diffthis | vert diffsplit /tmp/changed\\ file.go<CR>") {
		t.Fatalf("expected remote diff edit command, got %q", cmd)
	}
	if !strings.Contains(mode, "remote diff") {
		t.Fatalf("expected remote diff mode, got %q", mode)
	}
}

func TestNvimRemoteArgsOpenPlainFile(t *testing.T) {
	got := nvimRemoteArgs("/tmp/nvim.sock", "/tmp/a.go", false, false, "")
	want := []string{"--server", "/tmp/nvim.sock", "--remote", "/tmp/a.go"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("nvimRemoteArgs plain = %#v, want %#v", got, want)
	}
}

func TestPrepareNvimDiffFilesUsesProjectedBase(t *testing.T) {
	repo := t.TempDir()
	runGit(t, repo, "init")
	runGit(t, repo, "config", "user.name", "Cockpit Test")
	runGit(t, repo, "config", "user.email", "cockpit@example.invalid")
	if err := os.MkdirAll(filepath.Join(repo, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, repo, "src/a.go", "package main\n\nfunc value() string { return \"base\" }\n")
	runGit(t, repo, "add", ".")
	runGit(t, repo, "commit", "-m", "base")
	writeFile(t, repo, "src/a.go", "package main\n\nfunc value() string { return \"worktree\" }\n")

	basePath, workPath, cleanup, err := prepareNvimDiffFiles(target{
		ok:       true,
		path:     filepath.Join(repo, "src/a.go"),
		worktree: repo,
		relPath:  "src/a.go",
		base:     "HEAD",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	base, err := os.ReadFile(basePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(base), `"base"`) || strings.Contains(string(base), `"worktree"`) {
		t.Fatalf("expected base revision content, got %q", string(base))
	}
	if workPath != filepath.Join(repo, "src/a.go") {
		t.Fatalf("expected worktree path, got %q", workPath)
	}
}
