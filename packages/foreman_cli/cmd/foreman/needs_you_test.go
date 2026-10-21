package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func needsYouServer(t *testing.T, body string) (*client.Client, *http.Request, *string) {
	t.Helper()
	var last http.Request
	var sent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		last = *r.Clone(r.Context())
		b, _ := io.ReadAll(r.Body)
		sent = string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, &last, &sent
}

func TestApprovalsListHitsProjectAndRunEndpoints(t *testing.T) {
	c, req, _ := needsYouServer(t, `{"approvals":[{"tool_call_id":"c1","run_id":"r1","tool_name":"Write","status":"requested","approval_delivery":"resume_with_override","input_summary":"x"}]}`)
	out := captureStdout(t, func() {
		if err := runApprovals(c, []string{"list", "--project", "p1", "--all"}); err != nil {
			t.Fatal(err)
		}
	})
	if req.URL.Path != "/api/projects/p1/approvals" || req.URL.Query().Get("status") != "all" {
		t.Fatalf("request = %v", req.URL)
	}
	if !strings.Contains(out, "c1") || !strings.Contains(out, "resume_with_override") {
		t.Fatalf("out = %q", out)
	}
	if err := runApprovals(c, []string{"list", "--run", "r9"}); err != nil || req.URL.Path != "/api/runs/r9/approvals" {
		t.Fatalf("run path = %v err=%v", req.URL.Path, err)
	}
	if err := runApprovals(c, []string{"list"}); err == nil {
		t.Fatal("list without --project/--run must fail")
	}
}

func TestApproveAndDenyPostOnlyToolCommands(t *testing.T) {
	c, req, sent := needsYouServer(t, `{"status":"accepted"}`)
	for sub, want := range map[string]string{"approve": "tool.approve", "deny": "tool.deny"} {
		captureStdout(t, func() {
			if err := runApprovals(c, []string{sub, "--run", "r1", "--call", "c1", "--reason", "ok"}); err != nil {
				t.Fatal(err)
			}
		})
		var body map[string]any
		if err := json.Unmarshal([]byte(*sent), &body); err != nil {
			t.Fatal(err)
		}
		if req.URL.Path != "/api/commands" || body["type"] != want {
			t.Fatalf("%s: path=%s body=%v", sub, req.URL.Path, body)
		}
		p := body["payload"].(map[string]any)
		if p["run_id"] != "r1" || p["tool_call_id"] != "c1" {
			t.Fatalf("payload = %v", p)
		}
	}
	if err := runApprovals(c, []string{"approve", "--run", "r1"}); err == nil {
		t.Fatal("approve without --call must fail")
	}
}

func TestQuestionsListAndAnswer(t *testing.T) {
	c, req, sent := needsYouServer(t, `{"questions":[{"question_id":"q1","run_id":"global","agent_id":"a","status":"open","text":"why?"}]}`)
	out := captureStdout(t, func() {
		if err := runQuestions(c, []string{"list", "--project", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if req.URL.Path != "/api/projects/p1/questions" || !strings.Contains(out, "why?") {
		t.Fatalf("path=%s out=%q", req.URL.Path, out)
	}
	captureStdout(t, func() {
		if err := runQuestions(c, []string{"answer", "--run", "global", "--question", "q1", "--text", "because"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(*sent, `"type":"question.answer"`) || !strings.Contains(*sent, `"text":"because"`) {
		t.Fatalf("sent = %s", *sent)
	}
	if err := runQuestions(c, []string{"answer", "--run", "global"}); err == nil {
		t.Fatal("answer without question/text must fail")
	}
}
