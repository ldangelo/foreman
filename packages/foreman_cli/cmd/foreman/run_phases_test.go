package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func TestRunPhasesReadsTheRunPhasesEndpoint(t *testing.T) {
	var gotPath, gotMethod string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotMethod = r.URL.Path, r.Method
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"run_id":"run-7","phases":[]}`))
	}))
	defer srv.Close()

	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}
	if err := runRun(c, []string{"phases", "run-7"}); err != nil {
		t.Fatalf("run phases: %v", err)
	}
	if gotMethod != http.MethodGet || gotPath != "/api/runs/run-7/phases" {
		t.Fatalf("request = %s %s, want GET /api/runs/run-7/phases", gotMethod, gotPath)
	}

	if err := runRun(c, []string{"phases"}); err == nil {
		t.Fatal("run phases without an id must fail")
	}
	if err := runRun(c, []string{"phases", "run-7", "extra"}); err == nil {
		t.Fatal("run phases with a surplus argument must fail")
	}
}
