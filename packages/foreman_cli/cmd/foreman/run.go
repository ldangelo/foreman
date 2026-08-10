package main

import (
	"fmt"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func runRun(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman run: missing subcommand (get, cancel)",
			"Usage:\n  foreman run get <id>\n  foreman run cancel --id <run-id> [--reason <reason>]",
		)
	}

	switch args[0] {
	case "get":
		return runGet(c, args[1:])
	case "cancel":
		return runCancel(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman run: unknown subcommand %q", args[0]),
			"Usage:\n  foreman run get <id>\n  foreman run cancel --id <run-id> [--reason <reason>]",
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

// runCancel dispatches `foreman run cancel --id <run-id> [--reason <reason>]`.
// It posts a `run.cancel` operator command to /api/commands and prints the
// server's structured response. The server validates the envelope, the
// gateway validates the aggregate_id, and the Run aggregate emits
// RunCancelled (terminal, status `cancelled`).
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
