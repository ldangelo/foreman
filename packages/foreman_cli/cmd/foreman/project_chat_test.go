package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

type chatCall struct {
	method, path, query string
	body                []byte
}

// chatServer is a fake coordinator API. handle returns (status, body); it is
// called for every request with calls recorded under a lock.
type chatServer struct {
	mu    sync.Mutex
	calls []chatCall
}

func newChatServer(t *testing.T, handle func(n int, c chatCall) (int, string)) (*client.Client, *chatServer) {
	t.Helper()
	cs := &chatServer{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		cs.mu.Lock()
		call := chatCall{r.Method, r.URL.Path, r.URL.RawQuery, body}
		cs.calls = append(cs.calls, call)
		n := len(cs.calls)
		cs.mu.Unlock()
		status, resp := handle(n, call)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(resp))
	}))
	t.Cleanup(srv.Close)
	return &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}, cs
}

func (cs *chatServer) snapshot() []chatCall {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return append([]chatCall(nil), cs.calls...)
}

const (
	chatReply = `{"seq":8,"message_id":"m8","role":"coordinator","kind":"reply","text":"On it.","source":null,"thread_ref":null,"turn_id":"t1","at":"2026-10-21T10:00:00Z"}`
	chatNote  = `{"seq":9,"message_id":"m9","role":"system","kind":"notice","text":"started thread th-1","source":null,"thread_ref":{"task_id":"x","run_id":"r1"},"turn_id":"t1","at":"2026-10-21T10:00:01Z"}`
	chatEcho  = `{"seq":7,"message_id":"cli-1","role":"operator","kind":"message","text":"fix the login bug","source":"cli","thread_ref":null,"turn_id":null,"at":"2026-10-21T09:59:59Z"}`
)

func chatPageBody(status string, next int, hasMore bool, msgs ...string) string {
	more := "false"
	if hasMore {
		more = "true"
	}
	return `{"messages":[` + strings.Join(msgs, ",") + `],"next_cursor":` + itoa(next) + `,"has_more":` + more + `,"truncated_before_seq":null,"status":"` + status + `"}`
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func runChat(t *testing.T, c *client.Client, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	var err error
	stdout, stderr = captureOutput(t, func() { err = projectChat(c, args) })
	if err != nil {
		stderr += err.Error()
	}
	return stdout, stderr, client.ExitCode(err)
}

func setChatStdin(t *testing.T, input string, tty bool) {
	t.Helper()
	oldIn, oldTTY := chatStdin, chatStdinIsTerminal
	chatStdin = strings.NewReader(input)
	chatStdinIsTerminal = func() bool { return tty }
	t.Cleanup(func() { chatStdin, chatStdinIsTerminal = oldIn, oldTTY })
}

func TestProjectChatOneShotSendsAndStreamsReplies(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
		switch {
		case call.method == http.MethodPost:
			return http.StatusAccepted, `{"message_id":"cli-1","seq":7}`
		case n == 2:
			return 200, chatPageBody("turn_open", 8, false, chatReply)
		default:
			return 200, chatPageBody("idle", 9, false, chatNote)
		}
	})

	stdout, stderr, code := runChat(t, c, "p1", "fix", "the", "login bug")
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %q", code, stderr)
	}
	if stdout != "On it.\n[system notice] started thread th-1\n" {
		t.Fatalf("stdout = %q", stdout)
	}

	calls := cs.snapshot()
	if len(calls) != 3 {
		t.Fatalf("calls = %d, want POST + 2 polls: %+v", len(calls), calls)
	}
	if calls[0].method != http.MethodPost || calls[0].path != "/api/projects/p1/coordinator/messages" {
		t.Fatalf("first call = %+v", calls[0])
	}
	var body map[string]any
	if err := json.Unmarshal(calls[0].body, &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body["text"] != "fix the login bug" || body["source"] != "cli" || !strings.HasPrefix(body["message_id"].(string), "cli-") {
		t.Fatalf("body = %v", body)
	}
	for i, want := range []string{"after=7&limit=200&wait_ms=20000", "after=8&limit=200&wait_ms=20000"} {
		if calls[i+1].method != http.MethodGet || calls[i+1].query != want {
			t.Fatalf("poll %d = %s ?%s, want ?%s", i, calls[i+1].method, calls[i+1].query, want)
		}
	}
}

func TestProjectChatMessageSources(t *testing.T) {
	cases := []struct {
		name  string
		args  []string
		stdin string
		want  string
	}{
		{"dash m after id", []string{"p1", "-m", "hello there"}, "", "hello there"},
		{"flags before id", []string{"-m", "hi", "p1"}, "", "hi"},
		{"piped stdin", []string{"p1"}, "from a pipe\n", "from a pipe"},
		{"words after flags", []string{"p1", "--format", "ndjson", "go"}, "", "go"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setChatStdin(t, tc.stdin, false)
			c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
				if call.method == http.MethodPost {
					return 202, `{"message_id":"cli-1","seq":1}`
				}
				return 200, chatPageBody("idle", 1, false)
			})
			if _, stderr, code := runChat(t, c, tc.args...); code != 0 {
				t.Fatalf("exit = %d: %s", code, stderr)
			}
			var body map[string]any
			_ = json.Unmarshal(cs.snapshot()[0].body, &body)
			if body["text"] != tc.want {
				t.Fatalf("text = %v, want %q", body["text"], tc.want)
			}
		})
	}
}

func TestProjectChatPollsAgainWhenHasMore(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
		switch n {
		case 1:
			return 202, `{"message_id":"cli-1","seq":7}`
		case 2:
			return 200, chatPageBody("idle", 8, true, chatReply)
		default:
			return 200, chatPageBody("idle", 9, false, chatNote)
		}
	})
	stdout, _, code := runChat(t, c, "p1", "go")
	if code != 0 || !strings.Contains(stdout, "On it.") || !strings.Contains(stdout, "started thread") {
		t.Fatalf("code=%d stdout=%q", code, stdout)
	}
	if got := cs.snapshot()[2].query; got != "after=8&limit=200&wait_ms=20000" {
		t.Fatalf("second poll query = %q", got)
	}
}

// chatPendingPageBody is chatPageBody plus the page's pending_messages count.
func chatPendingPageBody(status string, pending, next int, msgs ...string) string {
	return strings.TrimSuffix(chatPageBody(status, next, false, msgs...), "}") + `,"pending_messages":` + itoa(pending) + `}`
}

// Between two turns the coordinator is "idle" while the operator's message is
// still pending: the CLI must keep waiting for the answer to that message.
func TestProjectChatKeepsWaitingWhileMessagesPending(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
		switch n {
		case 1:
			return 202, `{"message_id":"cli-1","seq":7}`
		case 2:
			return 200, chatPendingPageBody("idle", 1, 8, chatReply)
		default:
			return 200, chatPendingPageBody("idle", 0, 9, chatNote)
		}
	})
	stdout, stderr, code := runChat(t, c, "p1", "go")
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %q", code, stderr)
	}
	if stdout != "On it.\n[system notice] started thread th-1\n" {
		t.Fatalf("stdout = %q", stdout)
	}
	calls := cs.snapshot()
	if len(calls) != 3 {
		t.Fatalf("calls = %d, want POST + 2 polls: %+v", len(calls), calls)
	}
	if got := calls[2].query; got != "after=8&limit=200&wait_ms=20000" {
		t.Fatalf("second poll query = %q", got)
	}
}

// A server that does not send pending_messages decodes as 0: idle ends the wait.
func TestProjectChatIdleWithoutPendingFieldReturnsImmediately(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
		if n == 1 {
			return 202, `{"message_id":"cli-1","seq":7}`
		}
		return 200, chatPageBody("idle", 8, false, chatReply)
	})
	stdout, stderr, code := runChat(t, c, "p1", "go")
	if code != 0 || stdout != "On it.\n" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if n := len(cs.snapshot()); n != 2 {
		t.Fatalf("calls = %d, want POST + 1 poll", n)
	}
}

func TestProjectChatPendingForeverEndsWithTimeout(t *testing.T) {
	setChatStdin(t, "", false)
	c, _ := newChatServer(t, func(n int, call chatCall) (int, string) {
		if n == 1 {
			return 202, `{"message_id":"cli-1","seq":7}`
		}
		return 200, chatPendingPageBody("idle", 1, 7)
	})
	_, stderr, code := runChat(t, c, "--timeout", "100ms", "p1", "go")
	if code == 0 || !strings.Contains(stderr, "timed out after 100ms waiting for the coordinator") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestProjectChatNoWait(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(int, chatCall) (int, string) {
		return 202, `{"message_id":"cli-9","seq":42}`
	})
	stdout, _, code := runChat(t, c, "--no-wait", "p1", "later")
	if code != 0 || stdout != "sent message_id=cli-9 seq=42\n" {
		t.Fatalf("code=%d stdout=%q", code, stdout)
	}
	if n := len(cs.snapshot()); n != 1 {
		t.Fatalf("calls = %d, want only the POST", n)
	}
}

func TestProjectChatHistoryAndSince(t *testing.T) {
	setChatStdin(t, "", false)
	page1 := chatPageBody("idle", 8, true, chatEcho, chatReply)
	page2 := chatPageBody("idle", 9, false, chatNote)
	handler := func(n int, call chatCall) (int, string) {
		if strings.HasPrefix(call.query, "after=0") || strings.HasPrefix(call.query, "after=6") {
			return 200, page1
		}
		return 200, page2
	}

	t.Run("history keeps last N across pages", func(t *testing.T) {
		c, cs := newChatServer(t, handler)
		stdout, _, code := runChat(t, c, "--history", "2", "p1")
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
		if stdout != "On it.\n[system notice] started thread th-1\n" {
			t.Fatalf("stdout = %q", stdout)
		}
		calls := cs.snapshot()
		if len(calls) != 2 || calls[0].query != "after=0&limit=200&wait_ms=0" || calls[1].query != "after=8&limit=200&wait_ms=0" {
			t.Fatalf("calls = %+v", calls)
		}
	})

	t.Run("since prints operator messages too and never POSTs", func(t *testing.T) {
		c, cs := newChatServer(t, handler)
		stdout, _, code := runChat(t, c, "--since", "6", "p1")
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
		if !strings.HasPrefix(stdout, "[operator message] fix the login bug\n") {
			t.Fatalf("stdout = %q", stdout)
		}
		for _, call := range cs.snapshot() {
			if call.method != http.MethodGet {
				t.Fatalf("unexpected %s", call.method)
			}
		}
		if cs.snapshot()[0].query != "after=6&limit=200&wait_ms=0" {
			t.Fatalf("query = %q", cs.snapshot()[0].query)
		}
	})
}

func TestProjectChatNDJSONAndJSON(t *testing.T) {
	setChatStdin(t, "", false)
	handler := func(n int, call chatCall) (int, string) {
		if call.method == http.MethodPost {
			return 202, `{"message_id":"cli-1","seq":7}`
		}
		return 200, chatPageBody("idle", 9, false, chatEcho, chatReply, chatNote)
	}

	t.Run("ndjson", func(t *testing.T) {
		c, _ := newChatServer(t, handler)
		stdout, _, code := runChat(t, c, "--format", "ndjson", "p1", "go")
		lines := strings.Split(strings.TrimSpace(stdout), "\n")
		if code != 0 || len(lines) != 2 {
			t.Fatalf("code=%d stdout=%q", code, stdout)
		}
		for i, wantSeq := range []float64{8, 9} {
			var m map[string]any
			if err := json.Unmarshal([]byte(lines[i]), &m); err != nil {
				t.Fatalf("line %d not JSON: %v: %q", i, err, lines[i])
			}
			if m["seq"] != wantSeq || m["thread_ref"] == nil && i == 1 {
				t.Fatalf("line %d = %v", i, m)
			}
		}
	})

	t.Run("json is one array of raw objects", func(t *testing.T) {
		c, _ := newChatServer(t, handler)
		stdout, _, code := runChat(t, c, "--format=json", "p1", "go")
		var arr []map[string]any
		if err := json.Unmarshal([]byte(stdout), &arr); err != nil || code != 0 || len(arr) != 2 {
			t.Fatalf("code=%d err=%v stdout=%q", code, err, stdout)
		}
		if arr[0]["message_id"] != "m8" {
			t.Fatalf("arr = %v", arr)
		}
	})

	t.Run("no-wait ndjson prints the post response", func(t *testing.T) {
		c, _ := newChatServer(t, handler)
		stdout, _, _ := runChat(t, c, "--no-wait", "--format", "ndjson", "p1", "go")
		if stdout != `{"message_id":"cli-1","seq":7}`+"\n" {
			t.Fatalf("stdout = %q", stdout)
		}
	})
}

func TestProjectChatRestart(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(int, chatCall) (int, string) {
		return 200, `{"status":"idle","open_turn":null,"consecutive_failures":0,"last_error":null,"pending_messages":0,"last_activity_at":null}`
	})
	stdout, _, code := runChat(t, c, "--restart", "p1")
	if code != 0 || !strings.Contains(stdout, "restarted") || !strings.Contains(stdout, "idle") {
		t.Fatalf("code=%d stdout=%q", code, stdout)
	}
	calls := cs.snapshot()
	if len(calls) != 1 || calls[0].method != http.MethodPost || calls[0].path != "/api/projects/p1/coordinator/restart" || len(calls[0].body) != 0 {
		t.Fatalf("calls = %+v", calls)
	}

	stdout, _, _ = runChat(t, c, "--restart", "--format", "ndjson", "p1")
	if !strings.Contains(stdout, `"status":"idle"`) || strings.Contains(stdout, "\n  ") {
		t.Fatalf("ndjson restart stdout = %q", stdout)
	}
}

func TestProjectChatUnhealthyExitsThree(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
		switch {
		case call.method == http.MethodPost:
			return 202, `{"message_id":"cli-1","seq":7}`
		case call.path == "/api/projects/p1/coordinator":
			return 200, `{"status":"unhealthy","open_turn":null,"consecutive_failures":3,"last_error":{"code":"provider_unavailable","message":"claude CLI not found"},"pending_messages":1,"last_activity_at":null}`
		default:
			return 200, chatPageBody("unhealthy", 8, false, chatReply)
		}
	})
	stdout, stderr, code := runChat(t, c, "p1", "go")
	if code != 3 {
		t.Fatalf("exit = %d, want 3 (stderr %q)", code, stderr)
	}
	if !strings.Contains(stdout, "On it.") {
		t.Fatalf("messages before the failure should still print: %q", stdout)
	}
	for _, want := range []string{"unhealthy", "3 consecutive failures", "provider_unavailable", "claude CLI not found", "--restart"} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("stderr %q missing %q", stderr, want)
		}
	}
	if last := cs.snapshot()[2]; last.method != http.MethodGet || last.path != "/api/projects/p1/coordinator" {
		t.Fatalf("expected GET /coordinator lookup, got %+v", last)
	}
}

func TestProjectChatHTTPErrorMapping(t *testing.T) {
	cases := []struct {
		status   int
		envelope string
		code     int
	}{
		{404, `{"error":{"code":"project_not_found","message":"no such project"}}`, 2},
		{409, `{"error":{"code":"project_archived","message":"archived"}}`, 3},
		{413, `{"error":{"code":"message_too_large","message":"too big"}}`, 1},
		{422, `{"error":{"code":"invalid","message":"text required"}}`, 1},
		{500, `{"error":{"code":"internal","message":"boom"}}`, 5},
	}
	for _, tc := range cases {
		t.Run(itoa(tc.status), func(t *testing.T) {
			setChatStdin(t, "", false)
			c, _ := newChatServer(t, func(int, chatCall) (int, string) { return tc.status, tc.envelope })
			stdout, stderr, code := runChat(t, c, "p1", "hi")
			if code != tc.code || stdout != "" || !strings.Contains(stderr, tc.envelope) {
				t.Fatalf("code=%d (want %d) stdout=%q stderr=%q", code, tc.code, stdout, stderr)
			}
		})
	}

	t.Run("poll failure after send", func(t *testing.T) {
		setChatStdin(t, "", false)
		c, _ := newChatServer(t, func(n int, call chatCall) (int, string) {
			if call.method == http.MethodPost {
				return 202, `{"message_id":"cli-1","seq":1}`
			}
			return 404, `{"error":{"code":"project_not_found"}}`
		})
		_, stderr, code := runChat(t, c, "p1", "hi")
		if code != 2 || !strings.Contains(stderr, "project_not_found") {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
	})
}

func TestProjectChatUsageErrors(t *testing.T) {
	cases := []struct {
		name  string
		args  []string
		stdin string
		want  string
	}{
		{"no project id", nil, "", "expected <project-id>"},
		{"empty piped message", []string{"p1"}, "  \n", "message is empty"},
		{"bad format", []string{"--format", "xml", "p1", "hi"}, "", "unsupported format"},
		{"both -m and words", []string{"-m", "a", "p1", "b"}, "", "either -m or message words"},
		{"since and history", []string{"--since", "1", "--history", "2", "p1"}, "", "mutually exclusive"},
		{"history zero", []string{"--history", "0", "p1"}, "", "--history must be >= 1"},
		{"negative since", []string{"--since", "-1", "p1"}, "", "--since must be >= 0"},
		{"restart with message", []string{"--restart", "p1", "hi"}, "", "--restart cannot be combined"},
		{"history with message", []string{"--history", "3", "p1", "hi"}, "", "cannot be combined"},
		{"bad timeout", []string{"--timeout", "0s", "p1", "hi"}, "", "--timeout must be positive"},
		{"unknown flag", []string{"--bogus", "p1"}, "", "bogus"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setChatStdin(t, tc.stdin, false)
			c, cs := newChatServer(t, func(int, chatCall) (int, string) { return 200, "{}" })
			stdout, stderr, code := runChat(t, c, tc.args...)
			if code != 2 || stdout != "" || !strings.Contains(stderr, tc.want) {
				t.Fatalf("code=%d stdout=%q stderr=%q, want exit 2 containing %q", code, stdout, stderr, tc.want)
			}
			if n := len(cs.snapshot()); n != 0 {
				t.Fatalf("usage error must not reach the server, got %d calls", n)
			}
		})
	}
}

func TestProjectChatInteractiveLoop(t *testing.T) {
	setChatStdin(t, "first\n\n/restart\nsecond\n/quit\nnever sent\n", true)
	posts := 0
	c, cs := newChatServer(t, func(n int, call chatCall) (int, string) {
		switch {
		case call.path == "/api/projects/p1/coordinator/restart":
			return 200, `{"status":"idle"}`
		case call.method == http.MethodPost:
			posts++
			return 202, `{"message_id":"cli-` + itoa(posts) + `","seq":` + itoa(posts*10) + `}`
		default:
			return 200, chatPageBody("idle", 99, false, chatReply)
		}
	})
	stdout, stderr, code := runChat(t, c)
	if code != 2 {
		t.Fatalf("missing project id should exit 2, got %d (%s)", code, stderr)
	}
	stdout, stderr, code = runChat(t, c, "p1")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if strings.Count(stdout, "On it.") != 2 || !strings.Contains(stdout, "restarted") || posts != 2 {
		t.Fatalf("stdout = %q posts = %d", stdout, posts)
	}
	var texts []string
	for _, call := range cs.snapshot() {
		if call.method == http.MethodPost && strings.HasSuffix(call.path, "/messages") {
			var b map[string]string
			_ = json.Unmarshal(call.body, &b)
			texts = append(texts, b["text"])
		}
	}
	if strings.Join(texts, ",") != "first,second" {
		t.Fatalf("sent = %v", texts)
	}
}

func TestProjectChatRoutedFromRunProject(t *testing.T) {
	setChatStdin(t, "", false)
	c, cs := newChatServer(t, func(int, chatCall) (int, string) {
		return 202, `{"message_id":"cli-1","seq":1}`
	})
	var err error
	captureOutput(t, func() { err = runProject(c, []string{"chat", "--no-wait", "p1", "hi"}) })
	if err != nil || len(cs.snapshot()) != 1 {
		t.Fatalf("err=%v calls=%d", err, len(cs.snapshot()))
	}
	if !strings.Contains(projectUsageText, "foreman project chat") || !strings.Contains(usage, "project chat") {
		t.Fatal("usage texts must list project chat")
	}
}
