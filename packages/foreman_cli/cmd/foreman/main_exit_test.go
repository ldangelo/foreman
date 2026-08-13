package main

import (
	"bytes"
	"net/http"
	"os"
	"os/exec"
	"testing"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func TestInitRefusesWithoutForce(t *testing.T) {
	result := runExitHelper(t, "main-init-missing-force")

	if result.exitCode != 1 {
		t.Fatalf("exit code = %d, want 1; stderr=%q", result.exitCode, result.stderr)
	}

	if !bytes.Contains([]byte(result.stderr), []byte("foreman init: --force is required")) {
		t.Fatalf("stderr = %q, want --force required message", result.stderr)
	}

	if !bytes.Contains([]byte(result.stderr), []byte("Usage of init:")) {
		t.Fatalf("stderr = %q, want usage text", result.stderr)
	}
}
func TestUsageErrorsExitOneWithUsageOnStderr(t *testing.T) {
	result := runExitHelper(t, "main-project-create-missing-flags")

	if result.exitCode != 1 {
		t.Fatalf("exit code = %d, want 1; stderr=%q", result.exitCode, result.stderr)
	}

	if !bytes.Contains([]byte(result.stderr), []byte("foreman project create: --id, --path, and --task-provider are required")) {
		t.Fatalf("stderr = %q, want missing-flags message", result.stderr)
	}

	if !bytes.Contains([]byte(result.stderr), []byte("Usage of project create:")) {
		t.Fatalf("stderr = %q, want usage text", result.stderr)
	}
}
func TestHelpOutputIncludesWorkflowInstall(t *testing.T) {
	result := runExitHelper(t, "help")

	if result.exitCode != 0 {
		t.Fatalf("exit code = %d, want 0; stderr=%q", result.exitCode, result.stderr)
	}

	if !bytes.Contains([]byte(result.stdout), []byte("workflow install    Install workflow assets")) {
		t.Fatalf("stdout = %q, want workflow install help entry", result.stdout)
	}
}

func TestProjectDeleteHelpMentionsSoftDeleteAndActiveRunBlock(t *testing.T) {
	result := runExitHelper(t, "main-project-delete-help")

	if result.exitCode != 0 {
		t.Fatalf("exit code = %d, want 0; stderr=%q", result.exitCode, result.stderr)
	}

	if !bytes.Contains([]byte(result.stdout), []byte("Soft-delete (archive) a project")) {
		t.Fatalf("stdout = %q, want soft-delete help text", result.stdout)
	}

	if !bytes.Contains([]byte(result.stdout), []byte("active runs remain")) {
		t.Fatalf("stdout = %q, want active-run blocker help text", result.stdout)
	}
}

func TestProjectListHelpMentionsDefaultColumnsAndFlags(t *testing.T) {
	result := runExitHelper(t, "main-project-list-help")

	if result.exitCode != 0 {
		t.Fatalf("exit code = %d, want 0; stderr=%q", result.exitCode, result.stderr)
	}

	for _, want := range []string{
		"Default table columns: ID, PATH, ARCHIVED, REGISTERED, VERSION.",
		"-include-archived",
		"-format",
	} {
		if !bytes.Contains([]byte(result.stdout), []byte(want)) {
			t.Fatalf("stdout = %q, want %q", result.stdout, want)
		}
	}
}



func TestExitWithErrorMapsDocumentedCodes(t *testing.T) {
	cases := []struct {
		name     string
		scenario string
		wantCode int
	}{
		{name: "success exits zero", scenario: "success", wantCode: 0},
		{name: "not found exits two", scenario: "not-found", wantCode: 2},
		{name: "conflict exits three", scenario: "conflict", wantCode: 3},
		{name: "unauthorized exits four", scenario: "unauthorized", wantCode: 4},
		{name: "server error exits five", scenario: "server-error", wantCode: 5},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result := runExitHelper(t, tc.scenario)
			if result.exitCode != tc.wantCode {
				t.Fatalf("exit code = %d, want %d; stderr=%q", result.exitCode, tc.wantCode, result.stderr)
			}
		})
	}
}

type exitHelperResult struct {
	exitCode int
	stdout   string
	stderr   string
}

func runExitHelper(t *testing.T, scenario string) exitHelperResult {
	t.Helper()

	cmd := exec.Command(os.Args[0], "-test.run=TestExitHelperProcess", "--", scenario)
	cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	exitCode := 0
	if err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("run helper: %v", err)
		}
		exitCode = exitErr.ExitCode()
	}

	return exitHelperResult{exitCode: exitCode, stdout: stdout.String(), stderr: stderr.String()}
}

func TestExitHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	scenario := os.Args[len(os.Args)-1]

	switch scenario {
	case "main-init-missing-force":
		os.Args = []string{"foreman", "init"}
		main()
		return
	case "main-project-create-missing-flags":
		os.Args = []string{"foreman", "project", "create"}
		main()
		return
	case "help":
		os.Args = []string{"foreman", "help"}
		main()
		return
	case "main-project-delete-help":
		os.Args = []string{"foreman", "project", "delete", "-h"}
		main()
		return
	case "main-project-list-help":
		os.Args = []string{"foreman", "project", "list", "-h"}
		main()
		return
	case "success":
		exitWithError(nil)
		os.Exit(0)
	case "not-found":
		exitWithError(&client.Error{Status: http.StatusNotFound, Body: `{"error":"not_found"}`})
	case "conflict":
		exitWithError(&client.Error{Status: http.StatusConflict, Body: `{"error":"version_conflict"}`})
	case "unauthorized":
		exitWithError(&client.Error{Status: http.StatusUnauthorized, Body: `{"error":"unauthorized"}`})
	case "server-error":
		exitWithError(&client.Error{Status: http.StatusInternalServerError, Body: `{"error":"boom"}`})
	default:
		os.Exit(99)
	}
}
