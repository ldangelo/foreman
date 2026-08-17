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
// --project-id <id> [--work-id <id>] [--backend <backend>]`. Posts a JSON-RPC
// 2.0 tools/call request to /mcp targeting foreman_work_submit.
// Per TRD-002 AC: backend is omitted when the default "pi" is used.
func runSubmit(c *client.Client, args []string) error {
	fs := newFlagSet("run submit")
	workID := fs.String("work-id", "", "Work ID (auto-generated if omitted)")
	projectID := fs.String("project-id", "", "Project ID (required)")
	workflow := fs.String("workflow", "", "Workflow name (required)")
	prompt := fs.String("prompt", "", "Input prompt (required)")
	backend := fs.String("backend", "pi", "Backend to use (pi, claude, codex, opencode; default: pi)")

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

	// Build tool arguments; omit backend when it's the default "pi" per TRD-002.
	toolArgs := map[string]any{
		"work_id":    wid,
		"project_id": *projectID,
		"workflow":   *workflow,
		"prompt":     *prompt,
	}
	if *backend != "pi" {
		toolArgs["backend"] = *backend
	}

	// JSON-RPC 2.0 tools/call envelope for /mcp.
	rpcEnvelope := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "foreman_work_submit",
			"arguments": toolArgs,
		},
	}

	var out map[string]any
	err := c.PostJSON("/mcp", rpcEnvelope, &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}

// isValidWorkflow returns true for the three curated workflow names.
func isValidWorkflow(w string) bool {
	return w == "prd" || w == "trd" || w == "fix"
}
