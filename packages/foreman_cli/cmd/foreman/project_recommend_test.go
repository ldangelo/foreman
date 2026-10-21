package main

import (
	"strings"
	"testing"
)

const recBody = `{"project_id":"p1","generated_at":"x","recommendations":[
 {"id":"project.paused","severity":"action","title":"Project is paused","detail":"d","evidence":{},"fix":{"kind":"command","type":"project.resume","payload":{"project_id":"p1"}}},
 {"id":"git.no_remote","severity":"warn","title":"No git remote","detail":"d","evidence":{},"fix":{"kind":"manual","text":"git remote add origin <url>"}},
 {"id":"ci.none_detected","severity":"info","title":"No CI","detail":"d","evidence":{},"fix":null}]}`

const infoOnlyBody = `{"project_id":"p1","generated_at":"x","recommendations":[{"id":"ci.none_detected","severity":"info","title":"No CI","detail":"d","evidence":{},"fix":null}]}`

func TestProjectRecommendTextGroupsBySeverityAndShowsExactFix(t *testing.T) {
	c, rec := recordingServer(t, 200, recBody)
	var err error
	out := captureStdout(t, func() { err = projectRecommend(c, []string{"p1"}) })
	if err != nil {
		t.Fatal(err)
	}
	if rec.method != "GET" || rec.path != "/api/projects/p1/recommendations" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}
	for _, want := range []string{"[action] project.paused", "foreman project resume p1", "[warn] git.no_remote", "git remote add origin <url>", "[info] ci.none_detected"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
	if strings.Index(out, "[action]") > strings.Index(out, "[warn]") || strings.Index(out, "[warn]") > strings.Index(out, "[info]") {
		t.Errorf("not ordered action>warn>info:\n%s", out)
	}
}

func TestProjectRecommendJSONPassesServerBodyThrough(t *testing.T) {
	c, _ := recordingServer(t, 200, recBody)
	out := captureStdout(t, func() { _ = projectRecommend(c, []string{"--format", "json", "p1"}) })
	if !strings.Contains(out, `"project_id": "p1"`) || !strings.Contains(out, `"git.no_remote"`) {
		t.Fatalf("json output = %s", out)
	}
}

func TestProjectRecommendFailOnThreshold(t *testing.T) {
	c, _ := recordingServer(t, 200, recBody)
	captureStdout(t, func() {
		if err := projectRecommend(c, []string{"--fail-on", "warn", "p1"}); err == nil {
			t.Error("--fail-on warn must fail when a warn/action exists")
		}
		if err := projectRecommend(c, []string{"--fail-on", "action", "p1"}); err == nil {
			t.Error("--fail-on action must fail when an action exists")
		}
	})

	info, _ := recordingServer(t, 200, infoOnlyBody)
	captureStdout(t, func() {
		if err := projectRecommend(info, []string{"--fail-on", "warn", "p1"}); err != nil {
			t.Errorf("info-only must not fail --fail-on warn: %v", err)
		}
	})

	warnOnly := strings.Replace(recBody, `"severity":"action"`, `"severity":"info"`, 1)
	c2, _ := recordingServer(t, 200, warnOnly)
	captureStdout(t, func() {
		if err := projectRecommend(c2, []string{"--fail-on", "action", "p1"}); err != nil {
			t.Errorf("warn-only must not fail --fail-on action: %v", err)
		}
	})
}

func TestProjectRecommendRejectsBadFlags(t *testing.T) {
	c, rec := recordingServer(t, 200, recBody)
	for _, args := range [][]string{{}, {"--fail-on", "info", "p1"}, {"--format", "yaml", "p1"}} {
		if err := projectRecommend(c, args); err == nil {
			t.Errorf("args %v accepted", args)
		}
	}
	if rec.calls != 0 {
		t.Errorf("invalid usage reached the server %d times", rec.calls)
	}
}

func TestProjectAdoptBodies(t *testing.T) {
	resp := `{"adoption":{"mode":"move","subject_kind":"run","subject_id":"r1","project_id":"b","from_project_id":"a"}}`
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"--kind", "run", "--id", "r1", "--into", "b"}, []string{`"mode":"move"`, `"target_project_id":"b"`}},
		{[]string{"--kind", "run", "--id", "r1", "--into", "b", "--continue", "--prompt", "go"}, []string{`"mode":"continue"`, `"prompt":"go"`}},
		{[]string{"--kind", "jobsite", "--id", "j1", "--new-project", "--project-id", "x", "--path", "/r"}, []string{`"mode":"mint"`, `"new_project":{"id":"x","path":"/r"}`}},
	}
	for _, tc := range cases {
		c, rec := recordingServer(t, 201, resp)
		captureStdout(t, func() {
			if err := projectAdopt(c, tc.args); err != nil {
				t.Fatalf("%v: %v", tc.args, err)
			}
		})
		if rec.path != "/api/project-adoptions" {
			t.Fatalf("path = %s", rec.path)
		}
		for _, w := range tc.want {
			if !strings.Contains(string(rec.body), w) {
				t.Errorf("%v: body %s missing %s", tc.args, rec.body, w)
			}
		}
	}

	c, rec := recordingServer(t, 201, resp)
	for _, bad := range [][]string{
		{"--kind", "run"},
		{"--kind", "run", "--id", "r1"},
		{"--kind", "run", "--id", "r1", "--into", "b", "--new-project"},
		{"--kind", "run", "--id", "r1", "--into", "b", "--continue"},
	} {
		if err := projectAdopt(c, bad); err == nil {
			t.Errorf("args %v accepted", bad)
		}
	}
	if rec.calls != 0 {
		t.Errorf("invalid usage reached server")
	}
}

func TestDoctorExitsAndRefusesFix(t *testing.T) {
	ok := `{"checks":[{"id":"server","status":"ok","title":"t","detail":""}]}`
	warn := `{"checks":[{"id":"workflows","status":"warn","title":"t","detail":"d"}]}`
	fail := `{"checks":[{"id":"event_store","status":"fail","title":"t","detail":"d"}]}`

	run := func(body string, args ...string) error {
		c, _ := recordingServer(t, 200, body)
		var err error
		captureStdout(t, func() { err = runDoctor(c, args) })
		return err
	}

	if err := run(ok); err != nil {
		t.Errorf("ok: %v", err)
	}
	if err := run(warn); err != nil {
		t.Errorf("warn without --strict must pass: %v", err)
	}
	if err := run(warn, "--strict"); err == nil {
		t.Error("warn with --strict must fail")
	}
	if err := run(fail); err == nil {
		t.Error("fail must fail")
	}

	c, rec := recordingServer(t, 200, ok)
	for _, flag := range []string{"--fix", "--dry-run"} {
		if err := runDoctor(c, []string{flag}); err == nil {
			t.Errorf("%s must be refused", flag)
		}
	}
	if rec.calls != 0 {
		t.Error("refused flags still reached the server")
	}
}
