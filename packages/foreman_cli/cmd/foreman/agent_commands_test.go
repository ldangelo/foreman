package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAgentCommandInventoryContainsWorkflowAndStatusCommands(t *testing.T) {
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

	if _, ok := byID["foreman-task-fix"]; !ok {
		t.Fatalf("missing workflow task command")
	}
	trd := byID["foreman-task-implement-trd"]
	if !argRequired(trd, "trd-path") {
		t.Fatalf("implement-trd command must require trd-path: %#v", trd.Args)
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
	if _, ok := byID["foreman-task-get"]; !ok {
		t.Fatalf("missing task get command")
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
		if candidate.ID == "foreman-task-implement-trd" {
			spec = candidate
		}
	}
	body := renderCommandMarkdown("claude", spec)
	for _, want := range []string{
		"missing required project",
		"missing required title",
		"missing required trd-path",
		"foreman task create",
		"--workflow-type \"implement-trd\"",
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
	claude := renderAgentCommands("claude", specs)
	if !claude.NativeInstallSupported || claude.RecommendedProjectDir != ".claude/commands/foreman" {
		t.Fatalf("claude support state wrong: %#v", claude)
	}

	for _, agent := range []string{"pi", "omp", "codex", "opencode"} {
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
	path := filepath.Join(dir, "foreman-run-list.md")
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
