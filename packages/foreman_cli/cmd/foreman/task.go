package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// runTask dispatches `foreman task <subcommand>`.
func runTask(c *client.Client, args []string) error {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "foreman task: missing subcommand (create|approve|get)")
		os.Exit(2)
	}

	switch args[0] {
	case "create":
		return taskCreate(c, args[1:])
	case "approve":
		return taskApprove(c, args[1:])
	case "get":
		return taskGet(c, args[1:])
	default:
		fmt.Fprintf(os.Stderr, "foreman task: unknown subcommand %q\n", args[0])
		os.Exit(2)
		return nil
	}
}

// commandEnvelope is the JSON envelope sent to /api/commands.
// The server derives the aggregate_id from the payload.
type commandEnvelope struct {
	Type      string         `json:"type"`
	CommandID string         `json:"command_id,omitempty"`
	Payload   map[string]any `json:"payload"`
}
func taskCreate(c *client.Client, args []string) error {
	fs := flag.NewFlagSet("task create", flag.ExitOnError)
	taskID := fs.String("id", "", "Task ID (required)")
	projectID := fs.String("project", "", "Project ID (required)")
	title := fs.String("title", "", "Task title (required)")
	description := fs.String("description", "", "Task description")
	status := fs.String("status", "open", "Initial status (default: open)")
	taskType := fs.String("task-type", "", "Task type discriminator")
	_ = fs.Parse(args)

	if *taskID == "" || *projectID == "" || *title == "" {
		fmt.Fprintln(os.Stderr, "foreman task create: --id, --project, --title are required")
		fs.Usage()
		os.Exit(2)
	}

	payload := map[string]any{
		"task_id":    *taskID,
		"project_id": *projectID,
		"title":      *title,
		"status":     *status,
	}

	if *description != "" {
		payload["description"] = *description
	}

	if *taskType != "" {
		payload["task_type"] = *taskType
	}

	body := commandEnvelope{Type: "task.create", Payload: payload}
	return postCommand(c, body)
}

func taskApprove(c *client.Client, args []string) error {
	fs := flag.NewFlagSet("task approve", flag.ExitOnError)
	taskID := fs.String("id", "", "Task ID (required)")
	approvedBy := fs.String("approved-by", "operator", "Approver name (default: operator)")
	commandID := fs.String("command-id", "", "Optional client-supplied command_id; doubles as approval_id")
	_ = fs.Parse(args)

	if *taskID == "" {
		fmt.Fprintln(os.Stderr, "foreman task approve: --id is required")
		fs.Usage()
		os.Exit(2)
	}

	// The server enriches approval_id, approved_at, run_id,
	// workflow_name, workflow_digest, and workflow_snapshot from the
	// task projection's task_type via AssetCatalog. Reserved fields
	// supplied by the operator (approval_id / approved_at / run_id /
	// workflow_snapshot) are rejected by CommandGateway — they must
	// not appear in this payload.
	payload := map[string]any{
		"task_id":     *taskID,
		"approved_by": *approvedBy,
	}

	env := commandEnvelope{Type: "task.approve", Payload: payload}
	if *commandID != "" {
		env.CommandID = *commandID
	}

	return postCommand(c, env)
}

func taskGet(c *client.Client, args []string) error {
	fs := flag.NewFlagSet("task get", flag.ExitOnError)
	_ = fs.Parse(args)

	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "foreman task get: expected one argument: <task-id>")
		fs.Usage()
		os.Exit(2)
	}

	var out map[string]any

	err := c.GetJSON(client.JoinPath("/api/tasks", fs.Arg(0)), &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}

// postCommand centralizes the POST /api/commands path. The server
// returns 201 on success with `{status: "accepted", result: ...}`.
func postCommand(c *client.Client, body any) error {
	var out map[string]any
	if err := c.PostJSON("/api/commands", body, &out); err != nil {
		return err
	}

	return printJSON(out)
}

// printJSON pretty-prints a value to stdout.
func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
