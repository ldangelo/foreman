package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

func TestDumpRequested(t *testing.T) {
	cases := []struct {
		name string
		args []string
		env  string
		want bool
	}{
		{name: "flag", args: []string{"--dump"}, want: true},
		{name: "env one", env: "1", want: true},
		{name: "env true", env: "true", want: true},
		{name: "env true case insensitive", env: "TRUE", want: true},
		{name: "unset", want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dumpRequested(tc.args, tc.env); got != tc.want {
				t.Fatalf("dumpRequested(%#v, %q) = %v, want %v", tc.args, tc.env, got, tc.want)
			}
		})
	}
}

func TestDumpClientSmokesMockBackend(t *testing.T) {
	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	err = dumpClient(NewMockClient())
	if closeErr := w.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	os.Stdout = oldStdout
	out, readErr := io.ReadAll(r)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if err != nil {
		t.Fatalf("dumpClient returned error: %v", err)
	}
	text := string(out)
	for _, want := range []string{"runs=", "running=", "recent=", "ready=", "first_run=", "messages=", "events=", "logs=", "reports="} {
		if !strings.Contains(text, want) {
			t.Fatalf("expected dump output to include %q, got:\n%s", want, text)
		}
	}
}

func TestInstallThemesRequested(t *testing.T) {
	if !installThemesRequested([]string{"--install-themes"}) {
		t.Fatal("expected --install-themes to request theme installation")
	}
	if installThemesRequested([]string{"--dump"}) {
		t.Fatal("did not expect --dump to request theme installation")
	}
}

func TestProgramOptionsFromEnvEnablesDeterministicDemoMode(t *testing.T) {
	if opts := programOptionsFromEnv(""); len(opts) != 0 {
		t.Fatalf("expected no default program options, got %d", len(opts))
	}
	if opts := programOptionsFromEnv("true"); len(opts) != 2 {
		t.Fatalf("expected deterministic demo window/color options, got %d", len(opts))
	}
}

func TestClientForConfigDefaultsToLocalLiveServer(t *testing.T) {
	client := clientForConfig("", "", "")
	httpClient, ok := client.(*httpClient)
	if !ok {
		t.Fatalf("expected default client to use live HTTP backend, got %T", client)
	}
	if httpClient.base != defaultServerURL {
		t.Fatalf("expected default server URL %q, got %q", defaultServerURL, httpClient.base)
	}
}

func TestClientForConfigCanForceMockBackend(t *testing.T) {
	client := clientForConfig("", "", "mock")
	if _, ok := client.(*mockClient); !ok {
		t.Fatalf("expected mock backend, got %T", client)
	}
}
