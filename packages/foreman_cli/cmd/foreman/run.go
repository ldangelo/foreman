package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"

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
	usage := "Usage:\n  foreman run list [--status <status>] [--project-id <id>] [--limit <n>]\n  foreman run get <id>\n  foreman run cancel --id <run-id> [--reason <reason>]\n  foreman run remove --id <run-id>\n  foreman run reset --id <run-id>\n  foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>]"

	if len(args) == 0 {
		return usageTextError(
			"foreman run: missing subcommand (list, get, cancel, remove, reset, submit)",
			usage,
		)
	}

	switch args[0] {
	case "list":
		return runList(c, args[1:])
	case "get":
		return runGet(c, args[1:])
	case "cancel":
		return runCancel(c, args[1:])
	case "remove":
		return runRemove(c, args[1:])
	case "reset":
		return runReset(c, args[1:])
	case "submit":
		return runSubmit(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman run: unknown subcommand %q", args[0]),
			usage,
		)
	}
}

func runList(c *client.Client, args []string) error {
	fs := newFlagSet("run list")
	status := fs.String("status", "", "Filter by run status")
	projectID := fs.String("project-id", "", "Filter by project ID")
	limit := fs.Int("limit", 0, "Maximum runs to return")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 0 {
		return usageError(fs, "foreman run list: expected no positional arguments")
	}

	values := url.Values{}
	if *status != "" {
		values.Set("status", *status)
	}
	if *projectID != "" {
		values.Set("project_id", *projectID)
	}
	if *limit < 0 {
		return usageError(fs, "foreman run list: --limit must be non-negative")
	}
	if *limit > 0 {
		values.Set("limit", fmt.Sprintf("%d", *limit))
	}

	path := client.JoinPath("/api/runs")
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}

	var out map[string]any
	err := c.GetJSON(path, &out)
	if err != nil {
		return err
	}

	return printJSON(out)
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

func runRemove(c *client.Client, args []string) error {
	fs := newFlagSet("run remove")
	runID := fs.String("id", "", "Run ID (required)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run remove: --id is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.remove", Payload: map[string]any{"run_id": *runID}})
}

func runReset(c *client.Client, args []string) error {
	fs := newFlagSet("run reset")
	runID := fs.String("id", "", "Run ID (required)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run reset: --id is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.reset", Payload: map[string]any{"run_id": *runID}})
}

// runSubmit dispatches `foreman run submit --workflow <name> --prompt <text>
// --project-id <id> [--work-id <id>] [--backend <backend>]`. Posts a work.submit
// command envelope to /api/commands. Backend is omitted when the default "pi"
// is used (per TRD-002 AC). Valid workflow names are: prd, trd, fix.
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

	// Build payload; omit backend when it's the default "pi" per TRD-002.
	payload := map[string]any{
		"work_id":    wid,
		"project_id": *projectID,
		"workflow":   *workflow,
		"prompt":     *prompt,
	}
	if *backend != "pi" {
		payload["backend"] = *backend
	}

	return postCommand(c, commandEnvelope{Type: "work.submit", Payload: payload})
}

// isValidWorkflow returns true for the three curated workflow names.
func isValidWorkflow(w string) bool {
	return w == "prd" || w == "trd" || w == "fix"
}
