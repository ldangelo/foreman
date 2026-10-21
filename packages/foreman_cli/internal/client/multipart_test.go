package client

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A slow upload must not be killed by the client's whole-exchange timeout, which
// bounds ordinary JSON calls (30s in production; shortened here).
func TestSendMultipartIsNotBoundByTheClientTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(srv.Close)

	c := &Client{BaseURL: srv.URL, HTTP: &http.Client{Timeout: 100 * time.Millisecond}}

	var out map[string]any
	if err := c.GetJSON("/x", &out); err == nil {
		t.Fatal("control: a plain JSON call must hit the 100ms client timeout")
	}

	file := filepath.Join(t.TempDir(), "a.txt")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := c.SendMultipart("POST", "/up", nil, []UploadFile{{Name: "a.txt", Path: file}}, &out)
	if err != nil {
		t.Fatalf("multipart upload was cut off by the client timeout: %v", err)
	}
}
