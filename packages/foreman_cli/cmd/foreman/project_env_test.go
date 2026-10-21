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

// envServer answers GET .../environment with `getBody` and records every
// PUT/DELETE (method, path, body) in order.
type envCall struct{ method, path, body string }

func envServer(t *testing.T, getBody string) (*client.Client, *[]envCall) {
	t.Helper()
	calls := &[]envCall{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		*calls = append(*calls, envCall{r.Method, r.URL.Path, string(raw)})
		w.Header().Set("Content-Type", "application/json")
		switch r.Method {
		case http.MethodGet:
			_, _ = w.Write([]byte(getBody))
		default:
			_, _ = w.Write([]byte(`{"name":"API_TOKEN","version":3,"vars":{}}`))
		}
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, calls
}

func decodeBody(t *testing.T, call envCall) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(call.body), &out); err != nil {
		t.Fatalf("decode %q: %v", call.body, err)
	}
	return out
}

const recordEnv = `{"vars":{"A":"1"},"legacy_env":false,"secrets":[]}`

func TestEnvSetMergesIntoTheCurrentVars(t *testing.T) {
	c, calls := envServer(t, recordEnv)
	if err := projectEnv(c, []string{"set", "p1", "B=two", "C=a=b"}); err != nil {
		t.Fatal(err)
	}
	put := (*calls)[len(*calls)-1]
	if put.method != http.MethodPut || put.path != "/api/projects/p1/environment" {
		t.Fatalf("last call = %+v", put)
	}
	vars := decodeBody(t, put)["vars"].(map[string]any)
	if vars["A"] != "1" || vars["B"] != "two" || vars["C"] != "a=b" {
		t.Fatalf("vars = %v", vars)
	}
}

func TestEnvUnsetRemovesNames(t *testing.T) {
	c, calls := envServer(t, `{"vars":{"A":"1","B":"2"},"legacy_env":false}`)
	if err := projectEnv(c, []string{"unset", "p1", "A"}); err != nil {
		t.Fatal(err)
	}
	vars := decodeBody(t, (*calls)[len(*calls)-1])["vars"].(map[string]any)
	if _, ok := vars["A"]; ok || vars["B"] != "2" {
		t.Fatalf("vars = %v", vars)
	}
}

func TestEnvSetRefusesToMergeIntoHiddenLegacyValues(t *testing.T) {
	c, calls := envServer(t, `{"vars":{"OLD":"[redacted]"},"legacy_env":true}`)
	err := projectEnv(c, []string{"set", "p1", "B=2"})
	if err == nil || !strings.Contains(err.Error(), "--replace") {
		t.Fatalf("err = %v, want --replace guidance", err)
	}
	for _, call := range *calls {
		if call.method == http.MethodPut {
			t.Fatalf("a PUT was sent despite the refusal: %+v", call)
		}
	}

	if err := projectEnv(c, []string{"set", "--replace", "p1", "B=2"}); err != nil {
		t.Fatal(err)
	}
	vars := decodeBody(t, (*calls)[len(*calls)-1])["vars"].(map[string]any)
	if len(vars) != 1 || vars["B"] != "2" {
		t.Fatalf("vars = %v", vars)
	}
}

func TestSecretSetReadsStdinAndNeverTakesAValueArgument(t *testing.T) {
	c, calls := envServer(t, recordEnv)
	if err := projectSecretSet(c, strings.NewReader("s3cret-from-stdin\n"), []string{"p1", "API_TOKEN"}); err != nil {
		t.Fatal(err)
	}
	put := (*calls)[0]
	if put.method != http.MethodPut || put.path != "/api/projects/p1/secrets/API_TOKEN" {
		t.Fatalf("call = %+v", put)
	}
	if decodeBody(t, put)["value"] != "s3cret-from-stdin" {
		t.Fatalf("body = %s (trailing newline must be trimmed)", put.body)
	}

	// A third positional (a value on the command line) is a usage error and sends nothing.
	c2, calls2 := envServer(t, recordEnv)
	if err := projectSecretSet(c2, strings.NewReader("x"), []string{"p1", "API_TOKEN", "leaky"}); err == nil {
		t.Fatal("a value argument must be rejected")
	}
	if len(*calls2) != 0 {
		t.Fatalf("requests sent: %+v", *calls2)
	}
}

func TestSecretSetFromEnvAndEmptyValues(t *testing.T) {
	c, calls := envServer(t, recordEnv)
	t.Setenv("MY_SECRET_SRC", "from-env-value")
	if err := projectSecretSet(c, strings.NewReader(""), []string{"--from-env", "MY_SECRET_SRC", "p1", "API_TOKEN"}); err != nil {
		t.Fatal(err)
	}
	if decodeBody(t, (*calls)[0])["value"] != "from-env-value" {
		t.Fatalf("body = %s", (*calls)[0].body)
	}

	if err := projectSecretSet(c, strings.NewReader("\n"), []string{"p1", "API_TOKEN"}); err == nil {
		t.Fatal("an empty stdin value must be rejected")
	}
}

func TestSecretOutputNeverContainsTheValue(t *testing.T) {
	c, _ := envServer(t, recordEnv)
	r, w, _ := os.Pipe()
	old := os.Stdout
	os.Stdout = w
	err := projectSecretSet(c, strings.NewReader("do-not-print-me"), []string{"p1", "API_TOKEN"})
	_ = w.Close()
	os.Stdout = old
	out, _ := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), "do-not-print-me") || !strings.Contains(string(out), "API_TOKEN") {
		t.Fatalf("stdout = %q", out)
	}
}

func TestSecretUnsetSendsDelete(t *testing.T) {
	c, calls := envServer(t, recordEnv)
	if err := projectSecret(c, []string{"unset", "p1", "API_TOKEN"}); err != nil {
		t.Fatal(err)
	}
	call := (*calls)[0]
	if call.method != http.MethodDelete || call.path != "/api/projects/p1/secrets/API_TOKEN" {
		t.Fatalf("call = %+v", call)
	}
}

func TestSetupScriptSetAndClear(t *testing.T) {
	c, calls := envServer(t, recordEnv)
	file := filepath.Join(t.TempDir(), "setup.sh")
	if err := os.WriteFile(file, []byte("npm ci\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := projectSetupScript(c, []string{"set", "--file", file, "p1"}); err != nil {
		t.Fatal(err)
	}
	if got := decodeBody(t, (*calls)[0])["setup_script"]; got != "npm ci\n" {
		t.Fatalf("setup_script = %v", got)
	}

	if err := projectSetupScript(c, []string{"clear", "p1"}); err != nil {
		t.Fatal(err)
	}
	body := decodeBody(t, (*calls)[1])
	if v, present := body["setup_script"]; !present || v != nil {
		t.Fatalf("clear body = %s, want an explicit null", (*calls)[1].body)
	}

	if err := projectSetupScript(c, []string{"set", "p1"}); err == nil {
		t.Fatal("set without --file must fail")
	}
}

func TestNetworkSet(t *testing.T) {
	c, calls := envServer(t, recordEnv)
	if err := projectNetwork(c, []string{"set", "--mode", "allowlist", "--allow", "pypi.org", "--allow", "*.example.com", "p1"}); err != nil {
		t.Fatal(err)
	}
	network := decodeBody(t, (*calls)[0])["network"].(map[string]any)
	hosts := network["hosts"].([]any)
	if network["mode"] != "allowlist" || len(hosts) != 2 || hosts[0] != "pypi.org" {
		t.Fatalf("network = %v", network)
	}

	if err := projectNetwork(c, []string{"set", "--mode", "none", "p1"}); err != nil {
		t.Fatal(err)
	}
	none := decodeBody(t, (*calls)[1])["network"].(map[string]any)
	if none["mode"] != "none" || len(none["hosts"].([]any)) != 0 {
		t.Fatalf("network = %v", none)
	}
}
