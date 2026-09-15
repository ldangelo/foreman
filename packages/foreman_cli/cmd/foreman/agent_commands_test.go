package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAgentCommandInventoryContainsRunCommandsOnly(t *testing.T) {
	// TRD-018 (2026-09-13) removed `foreman task create`/`get`/`list`/`update`
	// entirely, with no Foreman CLI replacement. `buildAgentCommandInventory`
	// no longer produces any `foreman-task-*` shortcut — this test asserts
	// their absence, not their presence, and that the surviving run-based
	// shortcuts still validate and pass their expected tags.
	specs := buildAgentCommandInventory([]string{"fix", "implement-trd"})
	if err := validateAgentCommandSpecs(specs); err != nil {
		t.Fatalf("validate specs: %v", err)
	}

	byID := map[string]agentCommandSpec{}
	for _, spec := range specs {
		byID[spec.ID] = spec
		if !containsString(spec.Tags, "foreman") {
			t.Fatalf("%s missing foreman tag", spec.ID)
		}
		if !containsString(spec.Tags, "task") && !containsString(spec.Tags, "run") {
			t.Fatalf("%s missing task/run tag", spec.ID)
		}
	}

	for _, removedID := range []string{
		"foreman-task-fix",
		"foreman-task-implement-trd",
		"foreman-task-get",
		"foreman-task-list",
		"foreman-task-update",
	} {
		if _, ok := byID[removedID]; ok {
			t.Fatalf("%s should not be generated: TRD-018 removed its backing CLI command", removedID)
		}
	}

	if _, ok := byID["foreman-run-submit"]; !ok {
		t.Fatalf("missing run submit command")
	}
	if _, ok := byID["foreman-run-list"]; !ok {
		t.Fatalf("missing run list command")
	}
	if _, ok := byID["foreman-run-get"]; !ok {
		t.Fatalf("missing run get command")
	}
}

func TestAgentCommandSpecValidationRejectsUnknownFlag(t *testing.T) {
	specs := []agentCommandSpec{{
		ID:   "bad",
		CLI:  []string{"foreman", "run", "list", "--bogus"},
		Tags: []string{"foreman", "run"},
	}}
	if err := validateAgentCommandSpecs(specs); err == nil || !strings.Contains(err.Error(), "--bogus") {
		t.Fatalf("expected bogus flag error, got %v", err)
	}
}

func TestAgentCommandValidationRejectsLeakedFlags(t *testing.T) {
	// Test that --status (valid only in runList) is rejected on runSubmit.
	// This proves the function-scoping fix works: if the whole file were scanned,
	// --status would be accepted (it appears in runList).
	specs := []agentCommandSpec{{
		ID:   "bad-run-submit",
		CLI:  []string{"foreman", "run", "submit", "--status", "completed"},
		Tags: []string{"foreman", "run"},
	}}
	if err := validateAgentCommandSpecs(specs); err == nil {
		t.Fatalf("expected rejection of --status on run submit, got nil error")
	} else if !strings.Contains(err.Error(), "--status") {
		t.Fatalf("expected error to mention --status, got: %v", err)
	}
	// Test that --workflow (valid only in runSubmit) is rejected on runList.
	specs = []agentCommandSpec{{
		ID:   "bad-run-list",
		CLI:  []string{"foreman", "run", "list", "--workflow", "implement"},
		Tags: []string{"foreman", "run"},
	}}
	if err := validateAgentCommandSpecs(specs); err == nil {
		t.Fatalf("expected rejection of --workflow on run list, got nil error")
	} else if !strings.Contains(err.Error(), "--workflow") {
		t.Fatalf("expected error to mention --workflow, got: %v", err)
	}
}

func TestRenderCommandMarkdownValidatesInputsAndPreservesExec(t *testing.T) {
	specs := buildAgentCommandInventory([]string{"implement-trd"})
	var spec agentCommandSpec
	for _, candidate := range specs {
		if candidate.ID == "foreman-run-submit" {
			spec = candidate
		}
	}
	if spec.ID == "" {
		t.Fatalf("foreman-run-submit spec not found")
	}
	body := renderCommandMarkdown("claude", spec)
	for _, want := range []string{
		"missing required project-id",
		"missing required workflow",
		"missing required prompt",
		"foreman run submit",
		"--workflow \"$WORKFLOW\"",
		"exec \"${args[@]}\"",
		"FOREMAN_API_TOKEN; no secrets are embedded",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("rendered body missing %q:\n%s", want, body)
		}
	}
}

func TestRenderAgentSupportStates(t *testing.T) {
	specs := buildAgentCommandInventory([]string{"fix"})

	for _, agent := range []string{"claude", "pi", "omp"} {
		result := renderAgentCommands(agent, specs)
		if !result.NativeInstallSupported {
			t.Fatalf("%s should support native install: %#v", agent, result)
		}
		if result.RecommendedProjectDir == "" {
			t.Fatalf("%s missing recommended project dir", agent)
		}
	}

	for _, agent := range []string{"codex", "opencode"} {
		result := renderAgentCommands(agent, specs)
		if result.NativeInstallSupported {
			t.Fatalf("%s should be generate-only until native contract is verified", agent)
		}
		if result.UnsupportedNativeReason == "" {
			t.Fatalf("%s missing unsupported reason", agent)
		}
	}
}

func TestCommandsInstallRefusesExistingWithoutForce(t *testing.T) {
	dir := t.TempDir()
	existingDir := filepath.Join(dir, "foreman-run-list")
	if err := os.MkdirAll(existingDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(existingDir, "SKILL.md")
	if err := os.WriteFile(path, []byte("existing"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := commandsInstall([]string{"--agent", "claude", "--target", dir})
	if err == nil || !strings.Contains(err.Error(), "target exists") {
		t.Fatalf("expected existing-file refusal, got %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("install refusal should be atomic, got %d files", len(entries))
	}

	if err := commandsInstall([]string{"--agent", "claude", "--target", dir, "--force"}); err != nil {
		t.Fatalf("force install: %v", err)
	}
	written, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(written), "existing") {
		t.Fatalf("file was not overwritten")
	}
}

func TestCommandsInstallUnsupportedAgentRefusesNativeWrite(t *testing.T) {
	err := commandsInstall([]string{"--agent", "codex", "--target", t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "native install unsupported for codex") {
		t.Fatalf("expected unsupported native install error, got %v", err)
	}
}

func TestCommandsValidateRendersAllTargets(t *testing.T) {
	if err := commandsValidate(nil); err != nil {
		t.Fatalf("validate: %v", err)
	}
}

func argRequired(spec agentCommandSpec, name string) bool {
	for _, arg := range spec.Args {
		if arg.Name == name && arg.Required {
			return true
		}
	}
	return false
}

func TestExtractCLIFlagsFromSourceDerivesCorrectFlags(t *testing.T) {
	// Verify that extractCLIFlagsFromSource correctly derives flags from the
	// actual run.go source file. This test acts as a regression detector: if
	// run.go adds/removes/renames flags, this test will catch it and prevent
	// validateAgentCommandSpecs from using stale flag maps. `task.go` no
	// longer exists (TRD-018 deleted the entire `task` CLI case) — the
	// extractor's `allowed` map is seeded with only `run submit`/`run list`/
	// `run get`, so this test no longer asserts anything about `task`
	// commands (CodeRabbit review: those assertions could never pass again).

	flags, err := extractCLIFlagsFromSource()
	if err != nil {
		t.Fatalf("extractCLIFlagsFromSource failed: %v", err)
	}

	// Verify the expected commands are present
	expectedCommands := []string{"run submit", "run list", "run get"}
	for _, cmd := range expectedCommands {
		if _, ok := flags[cmd]; !ok {
			t.Errorf("expected command %q not found in extracted flags", cmd)
		}
	}

	// Spot-check known flags for each command
	tests := map[string][]string{
		"run submit": {"--project-id", "--workflow", "--prompt"},
		"run list":   {"--status", "--project-id", "--limit"},
	}

	for cmd, expectedFlags := range tests {
		cmdFlags := flags[cmd]
		for _, flag := range expectedFlags {
			if !cmdFlags[flag] {
				t.Errorf("command %q missing expected flag %q", cmd, flag)
			}
		}
	}

	// Assert run get has no flags (it takes a positional ID only)
	if len(flags["run get"]) != 0 {
		t.Errorf("run get should have no flags, got: %v", flags["run get"])
	}
}
