package main

import (
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func TestProjectRepoAddPostsCommand(t *testing.T) {
	c, rec := recordingServer(t, http.StatusCreated, acceptedBody)

	err := runProject(c, []string{"repo", "add", "--id", "api", "--path", "/srv/api", "--default-branch", "develop", "p1"})
	if err != nil {
		t.Fatalf("repo add: %v", err)
	}

	env := decodeEnvelope(t, rec)
	if env.Type != "project.repo.add" {
		t.Fatalf("type = %q", env.Type)
	}
	want := map[string]any{
		"project_id": "p1", "repo_id": "api", "path": "/srv/api",
		"default_branch": "develop", "added_by": "cli",
	}
	if !reflect.DeepEqual(env.Payload, want) {
		t.Fatalf("payload = %v, want %v", env.Payload, want)
	}
	if env.CommandID == "" {
		t.Fatal("command_id must be deterministic and non-empty")
	}
}

func TestProjectRepoAddRequiresIDAndPath(t *testing.T) {
	c, rec := recordingServer(t, http.StatusCreated, acceptedBody)

	for _, args := range [][]string{
		{"repo", "add", "--path", "/srv/api", "p1"},
		{"repo", "add", "--id", "api", "p1"},
		{"repo", "add", "--id", "api", "--path", "/srv/api"},
	} {
		if err := runProject(c, args); err == nil {
			t.Fatalf("args %v: expected usage error", args)
		}
	}
	if rec.calls != 0 {
		t.Fatalf("server was called %d times for invalid usage", rec.calls)
	}
}

func TestProjectRepoRemovePostsCommand(t *testing.T) {
	c, rec := recordingServer(t, http.StatusCreated, acceptedBody)

	if err := runProject(c, []string{"repo", "remove", "--id", "api", "p1"}); err != nil {
		t.Fatalf("repo remove: %v", err)
	}

	env := decodeEnvelope(t, rec)
	want := map[string]any{"project_id": "p1", "repo_id": "api", "removed_by": "cli"}
	if env.Type != "project.repo.remove" || !reflect.DeepEqual(env.Payload, want) {
		t.Fatalf("envelope = %+v", env)
	}
}

func TestProjectRepoAddSurfacesServerRejection(t *testing.T) {
	c, _ := recordingServer(t, http.StatusUnprocessableEntity, `{"error":"{:repo_not_git_work_tree, \"/x\"}"}`)

	err := runProject(c, []string{"repo", "add", "--id", "api", "--path", "/x", "p1"})
	if err == nil || !strings.Contains(err.Error(), "repo_not_git_work_tree") {
		t.Fatalf("err = %v, want the server rejection", err)
	}
}

func TestProjectRepoListGetsRepositories(t *testing.T) {
	c, rec := recordingServer(t, http.StatusOK,
		`{"project_id":"p1","repositories":[{"id":"main","path":"/srv/main","primary":true,"default_branch":null}]}`)

	if err := runProject(c, []string{"repo", "list", "--format=json", "p1"}); err != nil {
		t.Fatalf("repo list: %v", err)
	}
	if rec.method != http.MethodGet || rec.path != "/api/projects/p1/repositories" {
		t.Fatalf("request = %s %s", rec.method, rec.path)
	}

	if err := runProject(c, []string{"repo", "list", "p1"}); err != nil {
		t.Fatalf("repo list table: %v", err)
	}
}

func TestProjectRepoUnknownSubcommand(t *testing.T) {
	c, _ := recordingServer(t, http.StatusOK, `{}`)
	if err := runProject(c, []string{"repo", "bogus"}); err == nil {
		t.Fatal("expected usage error")
	}
}
