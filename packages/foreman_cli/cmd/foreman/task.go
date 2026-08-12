package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// runTask dispatches `foreman task <subcommand>`.
func runTask(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman task: missing subcommand (create|approve|retry|get)",
			"Usage:\n  foreman task create [flags]\n  foreman task approve [flags]\n  foreman task retry --id <task-id> [--reason <text>]\n  foreman task get <id>",
		)
	}

	switch args[0] {
	case "create":
		return taskCreate(c, args[1:])
	case "approve":
		return taskApprove(c, args[1:])
	case "retry":
		return taskRetry(c, args[1:])
	case "get":
		return taskGet(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman task: unknown subcommand %q", args[0]),
			"Usage:\n  foreman task create [flags]\n  foreman task approve [flags]\n  foreman task retry --id <task-id> [--reason <text>]\n  foreman task get <id>",
		)
	}
}

func taskRetry(c *client.Client, args []string) error {
	fs := newFlagSet("task retry")
	taskID := fs.String("id", "", "Task ID (required)")
	reason := fs.String("reason", "", "Optional reason recorded on the retry event")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *taskID == "" {
		return usageError(fs, "foreman task retry: --id is required")
	}

	payload := map[string]any{"task_id": *taskID}
	if *reason != "" {
		payload["reason"] = *reason
	}

	body := commandEnvelope{Type: "task.retry", Payload: payload}
	return postCommand(c, body)
}

// commandEnvelope is the JSON envelope sent to /api/commands.
// The server derives the aggregate_id from the payload.
type commandEnvelope struct {
	Type      string         `json:"type"`
	CommandID string         `json:"command_id,omitempty"`
	Payload   map[string]any `json:"payload"`
}

func taskCreate(c *client.Client, args []string) error {
	fs := newFlagSet("task create")
	taskID := fs.String("id", "", "Task ID (required)")
	projectID := fs.String("project", "", "Project ID (required)")
	title := fs.String("title", "", "Task title (required)")
	description := fs.String("description", "", "Task description")
	status := fs.String("status", "open", "Initial status (default: open)")
	taskType := fs.String("task-type", "", "Task type discriminator (legacy field; preserves existing task classification)")
	workflowType := fs.String("workflow-type", "", "Workflow type used by server-side approval precedence (workflow_type || task_type || default)")
	trdPath := fs.String("trd-path", "", "Path to the TRD document that drives this task; consumed by ForemanServer.Workflow.ImplementationContext")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *taskID == "" || *projectID == "" || *title == "" {
		return usageError(fs, "foreman task create: --id, --project, --title are required")
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

	// workflow_type is independent of task_type: it captures the
	// workflow-name precedence used at approval time (workflow_type
	// || task_type || default). Existing task_type classification is
	// preserved for backward compatibility.
	if *workflowType != "" {
		payload["workflow_type"] = *workflowType
	}

	if *trdPath != "" {
		payload["trd_path"] = *trdPath
	}

	body := commandEnvelope{Type: "task.create", Payload: payload}
	return postCommand(c, body)
}

func taskApprove(c *client.Client, args []string) error {
	fs := newFlagSet("task approve")
	taskID := fs.String("id", "", "Task ID (required)")
	approvedBy := fs.String("approved-by", "operator", "Approver name (default: operator)")
	commandID := fs.String("command-id", "", "Optional client-supplied command_id; doubles as approval_id")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *taskID == "" {
		return usageError(fs, "foreman task approve: --id is required")
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
	fs := newFlagSet("task get")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman task get: expected one argument: <task-id>")
	}

	var out map[string]any

	err := c.GetJSON(client.JoinPath("/api/tasks", fs.Arg(0)), &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}

// postCommandWithResponse centralizes the POST /api/commands path.
// The server returns 201 on success with `{status: "accepted", result: ...}`.
func postCommandWithResponse(c *client.Client, body any) (map[string]any, error) {
	var out map[string]any
	if err := c.PostJSON("/api/commands", body, &out); err != nil {
		return nil, err
	}

	return out, nil
}

func postCommand(c *client.Client, body any) error {
	out, err := postCommandWithResponse(c, body)
	if err != nil {
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
