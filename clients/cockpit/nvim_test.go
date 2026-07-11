package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestDescribeRemoteDiffUsesRemoteSend(t *testing.T) {
	target := target{ok: true, path: "/tmp/changed file.go", label: "changed file"}
	cmd, mode := describe(EditorConfig{Cmd: "nvim", Mode: "remote", RemoteServer: "/tmp/nvim.sock"}, target, true)
	if !strings.Contains(cmd, "--server /tmp/nvim.sock --remote-send") {
		t.Fatalf("expected remote-send diff command, got %q", cmd)
	}
	if !strings.Contains(cmd, ":edit /tmp/changed\\ file.go | diffthis<CR>") {
		t.Fatalf("expected remote diff edit command, got %q", cmd)
	}
	if !strings.Contains(mode, "remote diff") {
		t.Fatalf("expected remote diff mode, got %q", mode)
	}
}

func TestNvimRemoteArgsOpenPlainFile(t *testing.T) {
	got := nvimRemoteArgs("/tmp/nvim.sock", "/tmp/a.go", false, false)
	want := []string{"--server", "/tmp/nvim.sock", "--remote", "/tmp/a.go"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("nvimRemoteArgs plain = %#v, want %#v", got, want)
	}
}
