package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// generateID returns a unique ID string using crypto/rand.
func generateID(prefix string) string {
	b := make([]byte, 8)
	rand.Read(b)
	return fmt.Sprintf("%s-%s", prefix, hex.EncodeToString(b))
}

var validBackends = map[string]bool{"pi": true, "claude": true, "codex": true, "opencode": true}

func runRun(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman run: missing subcommand (get, cancel, submit)",
			"Usage:\n  foreman run get <id>\n  foreman run cancel --id <run-id> [--reason <reason>]\n  foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>]",
		)
	}

	switch args[0] {
	case "get":
		return runGet(c, args[1:])
	case "cancel":
		return runCancel(c, args[1:])
	case "submit":
		return runSubmit(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman run: unknown subcommand %q", args[0]),
			"Usage:\n  foreman run get <id>\n  foreman run cancel --id <run-id> [--reason <reason>]\n  foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>]",
		)
	}
}

func runGet(c *client.Client, args []string) error {
	fs := newFlagSet("run get")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman run get: expected one argument: <run-id>")
	}

	var out map[string]any
	err := c.GetJSON(client.JoinPath("/api/runs", fs.Arg(0)), &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}

func runCancel(c *client.Client, args []string) error {
	fs := newFlagSet("run cancel")
	runID := fs.String("id", "", "Run ID (required)")
	reason := fs.String("reason", "operator_cancel", "Cancellation reason (default: operator_cancel)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run cancel: --id is required")
	}

	payload := map[string]any{
		"run_id": *runID,
		"reason": *reason,
	}

	return postCommand(c, commandEnvelope{Type: "run.cancel", Payload: payload})
}

// runSubmit dispatches `foreman run submit --workflow <name> --prompt <text>
// --project-id <id> [--work-id <id>] [--backend <backend>] [--base-branch <branch>]`.
// Posts a work.submit command envelope to /api/commands. Backend is omitted when
// the default "pi" is used (per TRD-002 AC). Valid workflow names are: prd, trd, fix.
//
// --base-branch is captured at the protocol level only — server-side consumption
// (PlanContext derivation, plan_base_branch nil fallback, AutoPR skip-when-nil)
// is forthcoming per TRD-2026-80ba0665. When the flag is omitted the key is
// absent from the payload; when supplied, it is forwarded verbatim.
func runSubmit(c *client.Client, args []string) error {
	fs := newFlagSet("run submit")
	workID := fs.String("work-id", "", "Work ID (auto-generated if omitted)")
	projectID := fs.String("project-id", "", "Project ID (required)")
	workflow := fs.String("workflow", "", "Workflow name (required)")
	prompt := fs.String("prompt", "", "Input prompt (required)")
	backend := fs.String("backend", "pi", "Backend to use (pi, claude, codex, opencode; default: pi)")
	baseBranch := fs.String("base-branch", "",
		"Parent branch for the new task's worktree and PR. Protocol-level capture only; server-side consumption forthcoming per TRD-2026-80ba0665.")

	if err := fs.parse(args); err != nil {
		return err
	}

	if *projectID == "" {
		return usageError(fs, "foreman run submit: --project-id is required")
	}
	if *workflow == "" {
		return usageError(fs, "foreman run submit: --workflow is required")
	}
	if !isValidWorkflow(*workflow) {
		return usageError(fs,
			"foreman run submit: --workflow must be one of: prd, trd, fix (got %s)",
			*workflow)
	}
	if *prompt == "" {
		return usageError(fs, "foreman run submit: --prompt is required")
	}
	if !validBackends[*backend] {
		return usageError(fs,
			"foreman run submit: --backend must be one of: pi, claude, codex, opencode (got %s)",
			*backend)
	}

	wid := *workID
	if wid == "" {
		wid = generateID("work")
	}

	// Build payload; omit backend when it's the default "pi" per TRD-002.
	// Omit base_branch when empty so the server can apply its forthcoming
	// default resolution (operator's current checkout HEAD per
	// TRD-2026-80ba0665).
	payload := map[string]any{
		"work_id":    wid,
		"project_id": *projectID,
		"workflow":   *workflow,
		"prompt":     *prompt,
	}
	if *backend != "pi" {
		payload["backend"] = *backend
	}
	if *baseBranch != "" {
		payload["base_branch"] = *baseBranch
	}

	return postCommand(c, commandEnvelope{Type: "work.submit", Payload: payload})
}

// isValidWorkflow returns true for the three curated workflow names.
func isValidWorkflow(w string) bool {
	return w == "prd" || w == "trd" || w == "fix"
}
