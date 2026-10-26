package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func usageServer(t *testing.T, status int, body string) (*client.Client, *http.Request) {
	t.Helper()
	var last http.Request
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		last = *r.Clone(r.Context())
		calls++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}
	return c, &last
}

const usageBody = `{
 "project_id":"p1","totals":{"input_tokens":110,"output_tokens":25,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":135,"cost_usd":0.01,"events":3,"cost_unknown_events":2},
 "by_model":[
  {"model":"m1","input_tokens":10,"output_tokens":5,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":15,"cost_usd":0.01,"events":1,"cost_unknown_events":0},
  {"model":"unknown","input_tokens":100,"output_tokens":20,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":120,"cost_usd":null,"events":2,"cost_unknown_events":2}],
 "by_day":[{"date":"2026-01-01","input_tokens":1,"output_tokens":1,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":2,"cost_usd":0.5,"events":2,"cost_unknown_events":1}],
 "limits":{"daily_thread_cap":10,"threads_started_today":3,"resets_at":"2026-10-22T00:00:00Z","deferred_today":4}
}`

func TestUsageRendersUnknownCostAsDashAndShowsCapLine(t *testing.T) {
	c, req := usageServer(t, 200, usageBody)

	out := captureStdout(t, func() {
		if err := runUsage(c, []string{"--project", "p1", "--from", "2026-01-01"}); err != nil {
			t.Fatalf("runUsage: %v", err)
		}
	})

	if req.URL.Path != "/api/projects/p1/usage" {
		t.Fatalf("path = %q", req.URL.Path)
	}
	if q := req.URL.Query(); q.Get("group_by") != "model" || q.Get("from") != "2026-01-01" {
		t.Fatalf("query = %v, want group_by=model&from=2026-01-01", q)
	}
	var unknownRow string
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "unknown") {
			unknownRow = line
		}
	}
	if !strings.HasSuffix(strings.TrimSpace(unknownRow), "-") || strings.Contains(unknownRow, "0.00") {
		t.Fatalf("unknown-cost row = %q, want cost %q", unknownRow, "-")
	}
	if !strings.Contains(out, "0.0100*") {
		t.Fatalf("partial total cost not marked with *: %s", out)
	}
	if !strings.Contains(out, "2 events with unknown cost") {
		t.Fatalf("missing unknown-cost footnote: %s", out)
	}
	want := "daily thread cap: threads today: 3/10, resets 00:00 UTC, 4 deferred today"
	if !strings.Contains(out, want) {
		t.Fatalf("missing cap line %q in %s", want, out)
	}
}

func TestUsageNoCapNoCapLine(t *testing.T) {
	c, _ := usageServer(t, 200, `{"totals":{"cost_unknown_events":0},"by_model":[],"limits":{"daily_thread_cap":null}}`)
	out := captureStdout(t, func() {
		if err := runUsage(c, []string{"--project", "p1"}); err != nil {
			t.Fatal(err)
		}
	})
	if strings.Contains(out, "daily thread cap") || strings.Contains(out, "unknown cost") {
		t.Fatalf("unexpected cap/footnote lines: %s", out)
	}
}

func TestUsageByDayAndLimitAreSentToServer(t *testing.T) {
	c, req := usageServer(t, 200, usageBody)
	_ = captureStdout(t, func() {
		if err := runUsage(c, []string{"--project", "p1", "--by", "day", "--limit", "7"}); err != nil {
			t.Fatal(err)
		}
	})
	if q := req.URL.Query(); q.Get("group_by") != "day" || q.Get("limit") != "7" {
		t.Fatalf("query = %v", q)
	}
}

func TestUsageJSONFormatPrintsBodyUnchanged(t *testing.T) {
	c, _ := usageServer(t, 200, usageBody)
	out := captureStdout(t, func() {
		if err := runUsage(c, []string{"--project", "p1", "--format", "json"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, `"cost_unknown_events": 2`) || !strings.Contains(out, `"cost_usd": null`) {
		t.Fatalf("json not passed through: %s", out)
	}
}

func TestUsageRejectsBadInputWithoutCallingServer(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++ }))
	defer srv.Close()
	c := &client.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	for name, args := range map[string][]string{
		"missing project": {},
		"bad date":        {"--project", "p", "--from", "01/02/2026"},
		"bad by":          {"--project", "p", "--by", "planet"},
		"bad format":      {"--project", "p", "--format", "xml"},
	} {
		if err := runUsage(c, args); err == nil {
			t.Errorf("%s: expected a usage error", name)
		}
	}
	if calls != 0 {
		t.Fatalf("server called %d times, want 0", calls)
	}
}

func TestUsageSurfacesServerErrors(t *testing.T) {
	c, _ := usageServer(t, 422, `{"error":"invalid_range","reason":"to must not be before from"}`)
	err := runUsage(c, []string{"--project", "p1"})
	if err == nil || !strings.Contains(err.Error(), "invalid_range") {
		t.Fatalf("err = %v, want it to carry invalid_range", err)
	}
}

func TestUserGuideUsageExampleExecutesAgainstCLI(t *testing.T) {
	doc := readRepoDoc(t, "docs/user-guide.md")
	want := "foreman usage --project project-123 --from 2026-10-01 --by day"
	if got := markdownCodeBlockAfterHeading(t, doc, "### Usage and cost"); got != want {
		t.Fatalf("usage example = %q, want %q", got, want)
	}

	c, req := usageServer(t, 200, usageBody)
	out := captureStdout(t, func() {
		if err := runUsage(c, strings.Fields(want)[2:]); err != nil {
			t.Fatalf("documented command failed: %v", err)
		}
	})
	if req.URL.Path != "/api/projects/project-123/usage" || req.URL.Query().Get("group_by") != "day" ||
		req.URL.Query().Get("from") != "2026-10-01" {
		t.Fatalf("request = %s ?%s", req.URL.Path, req.URL.RawQuery)
	}
	if !strings.Contains(out, "2026-01-01") {
		t.Fatalf("no day row rendered: %s", out)
	}
}

// usageThreadBody is what `UsageDTO` answers for `group_by=thread`: the totals and ONLY
// the by_thread breakdown (highest cost first, unknown cost last). A thread row carries no
// title, so its id is the whole group label.
const usageThreadBody = `{
 "project_id":"p1","from":"2026-10-01","to":"2026-10-21","group_by":"thread","thread_count":3,
 "totals":{"input_tokens":1700,"output_tokens":340,"cache_read_tokens":900,"cache_write_tokens":null,"total_tokens":2040,"cost_usd":0.0412,"events":6,"cost_unknown_events":2},
 "by_thread":[
  {"thread_id":"thread-7a1f","thread_kind":"run","role":"worker","provider":"pi","last_at":"2026-10-20T10:00:00Z","input_tokens":1000,"output_tokens":200,"cache_read_tokens":900,"cache_write_tokens":null,"total_tokens":1200,"cost_usd":0.0412,"events":3,"cost_unknown_events":0},
  {"thread_id":"js-3c9d","thread_kind":"jobsite","role":"worker","provider":"claude","last_at":"2026-10-20T11:00:00Z","input_tokens":500,"output_tokens":120,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":620,"cost_usd":null,"events":2,"cost_unknown_events":2},
  {"thread_id":"coordinator-p1","thread_kind":"coordinator","role":"coordinator","provider":"claude","last_at":"2026-10-20T12:00:00Z","input_tokens":200,"output_tokens":20,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":220,"cost_usd":0.0,"events":1,"cost_unknown_events":0}],
 "cache_hints":[],
 "limits":{"daily_thread_cap":null}
}`

func TestUsageByThreadSendsGroupByThreadAndRendersOneRowPerThread(t *testing.T) {
	c, req := usageServer(t, 200, usageThreadBody)
	out := captureStdout(t, func() {
		args := []string{"--project", "p1", "--by", "thread", "--limit", "5", "--from", "2026-10-01", "--to", "2026-10-21"}
		if err := runUsage(c, args); err != nil {
			t.Fatal(err)
		}
	})

	if req.Method != http.MethodGet || req.URL.Path != "/api/projects/p1/usage" {
		t.Fatalf("request = %s %s, want GET /api/projects/p1/usage", req.Method, req.URL.Path)
	}
	if want := "from=2026-10-01&group_by=thread&limit=5&to=2026-10-21"; req.URL.RawQuery != want {
		t.Fatalf("query = %q, want %q", req.URL.RawQuery, want)
	}

	// One row per thread in the server's order, then the TOTAL row. An unknown cost is "-"
	// (not 0.0000), a cost of exactly zero is 0.0000, and a partial total carries "*".
	want := "THREAD          INPUT  OUTPUT  CACHE-READ  CACHE-WRITE  TOTAL  COST\n" +
		"thread-7a1f     1000   200     900         -            1200   0.0412\n" +
		"js-3c9d         500    120     -           -            620    -\n" +
		"coordinator-p1  200    20      -           -            220    0.0000\n" +
		"TOTAL           1700   340     900         -            2040   0.0412*\n" +
		"\n" +
		"2 events with unknown cost (\"-\" = no cost reported, \"*\" = partial sum)\n"
	if out != want {
		t.Fatalf("table =\n%s\nwant\n%s", out, want)
	}
}

func TestUsageByThreadWithNoThreadsRendersHeaderAndTotalRowOnly(t *testing.T) {
	c, req := usageServer(t, 200, `{
 "project_id":"p1","from":null,"to":null,"group_by":"thread","thread_count":0,
 "totals":{"input_tokens":null,"output_tokens":null,"cache_read_tokens":null,"cache_write_tokens":null,"total_tokens":null,"cost_usd":null,"events":0,"cost_unknown_events":0},
 "by_thread":[],"cache_hints":[],"limits":{"daily_thread_cap":null}
}`)
	out := captureStdout(t, func() {
		if err := runUsage(c, []string{"--project", "p1", "--by", "thread"}); err != nil {
			t.Fatal(err)
		}
	})

	// Nothing optional is sent unless asked for.
	if req.URL.Path != "/api/projects/p1/usage" || req.URL.RawQuery != "group_by=thread" {
		t.Fatalf("request = %s ?%s, want /api/projects/p1/usage ?group_by=thread", req.URL.Path, req.URL.RawQuery)
	}

	want := "THREAD  INPUT  OUTPUT  CACHE-READ  CACHE-WRITE  TOTAL  COST\n" +
		"TOTAL   -      -       -           -            -      -\n"
	if out != want {
		t.Fatalf("table =\n%q\nwant\n%q", out, want)
	}
}
