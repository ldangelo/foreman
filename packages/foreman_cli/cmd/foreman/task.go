package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path"
	"strings"
	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// runTask dispatches `foreman task <subcommand>`.
func runTask(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman task: missing subcommand (create|approve|retry|get|list|update)",
			"Usage:\n  foreman task create [flags]\n  foreman task approve [flags]\n  foreman task retry --id <task-id> [--reason <text>]\n  foreman task get <id>\n  foreman task list [--project <id>] [--status <status>]\n  foreman task update --id <id> [--title <title>] [--description <desc>] [--priority <0-4>] [--status <status>]",
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
	case "list":
		return taskList(c, args[1:])
	case "update":
		return taskUpdate(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman task: unknown subcommand %q", args[0]),
			"Usage:\n  foreman task create [flags]\n  foreman task approve [flags]\n  foreman task retry --id <task-id> [--reason <text>]\n  foreman task get <id>\n  foreman task list [--project <id>] [--status <status>]\n  foreman task update --id <id> [--title <title>] [--description <desc>] [--priority <0-4>] [--status <status>]",
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
	taskID := fs.String("id", "", "Task ID (optional; omit to auto-generate via backend provider)")
	projectID := fs.String("project", "", "Project ID (required)")
	title := fs.String("title", "", "Task title (required)")
	description := fs.String("description", "", "Task description")
	status := fs.String("status", "open", "Initial status (default: open)")
	taskType := fs.String("task-type", "", "Task type discriminator (legacy field; preserves existing task classification)")
	workflowType := fs.String("workflow-type", "", "Workflow selector; maps to a server workflow manifest name")
	trdPath := fs.String("trd-path", "", "Project-relative TRD path; required for implement-trd workflows")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *projectID == "" || *title == "" {
		return usageError(fs, "foreman task create: --project and --title are required; --id is optional")
	}

	workflowTypeValue := strings.TrimSpace(*workflowType)
	trdPathValue := strings.TrimSpace(*trdPath)

	if requiresTrdPath(workflowTypeValue) && trdPathValue == "" {
		return usageError(fs, "foreman task create: --trd-path is required for --workflow-type %s", workflowTypeValue)
	}
	if trdPathValue != "" {
		if err := validateProjectRelativePath("trd-path", trdPathValue); err != nil {
			return err
		}
	}

	payload := map[string]any{
		"project_id": *projectID,
		"title":      *title,
		"status":     *status,
	}

	if *taskID != "" {
		payload["task_id"] = *taskID
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
	if workflowTypeValue != "" {
		payload["workflow_type"] = workflowTypeValue
	}

	if trdPathValue != "" {
		payload["trd_path"] = trdPathValue
	}

	body := commandEnvelope{Type: "task.create", Payload: payload}
	return postCommand(c, body)
}

// requiresTrdPath identifies workflow selectors whose approval-time
// implementation context needs a committed TRD path. Other workflow
// names are server manifest selectors and do not imply TRD inputs at
// creation time.
func requiresTrdPath(s string) bool {
	return s == "implement-trd" || s == "implement-trd-beads"
}

// validateProjectRelativePath rejects absolute paths and traversals
// that could escape the project root. The server's
// ImplementationContext re-validates via Path.safe_relative/2 and
// rejects symlink escapes; this gate catches obvious mistakes at the
// CLI boundary for a clearer error message.
func validateProjectRelativePath(flagName, raw string) error {
	if path.IsAbs(raw) {
		return fmt.Errorf("foreman task create: --%s must be project-relative (got %q)", flagName, raw)
	}
	cleaned := path.Clean(raw)
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.Contains(cleaned, "/../") || strings.HasSuffix(cleaned, "/..") {
		return fmt.Errorf("foreman task create: --%s must not traverse outside the project root (got %q)", flagName, raw)
	}
	return nil
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

func taskList(c *client.Client, args []string) error {
	fs := newFlagSet("task list")
	projectID := fs.String("project", "", "Filter by project ID")
	status := fs.String("status", "", "Filter by status")
	if err := fs.parse(args); err != nil {
		return err
	}

	query := url.Values{}
	if *projectID != "" {
		query.Set("project_id", *projectID)
	}
	if *status != "" {
		query.Set("status", *status)
	}

	var out struct {
		Tasks []map[string]any `json:"tasks"`
		Total int              `json:"total"`
	}
	path := "/api/tasks"
	if qs := query.Encode(); qs != "" {
		path += "?" + qs
	}
	if err := c.GetJSON(path, &out); err != nil {
		return err
	}

	if len(out.Tasks) == 0 {
		fmt.Println("No tasks found.")
		return nil
	}

	// Print table: task_id, project, status, title
	fmt.Printf("%-24s %-10s %-12s %s\n", "TASK ID", "PROJECT", "STATUS", "TITLE")
	fmt.Println(strings.Repeat("-", 24) + " " + strings.Repeat("-", 10) + " " + strings.Repeat("-", 12) + " " + strings.Repeat("-", 50))
	for _, t := range out.Tasks {
		tid := getStr(t, "task_id")
		proj := getStr(t, "project_id")
		stat := getStr(t, "status")
		title := getStr(t, "title")
		if title == "" {
			title = "(no title)"
		}
		// Truncate title to fit
		if len(title) > 50 {
			title = title[:47] + "..."
		}
		fmt.Printf("%-24s %-10s %-12s %s\n", tid, proj, stat, title)
	}
	fmt.Printf("\n%d tasks\n", len(out.Tasks))
	return nil
}

func getStr(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func taskUpdate(c *client.Client, args []string) error {
	fs := newFlagSet("task update")
	taskID := fs.String("id", "", "Task ID (required)")
	title := fs.String("title", "", "New task title")
	description := fs.String("description", "", "New task description")
	priority := fs.Int("priority", -1, "Priority 0-4 (0=critical, 4=backlog; omit to leave unchanged)")
	status := fs.String("status", "", "New status")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *taskID == "" {
		return usageError(fs, "foreman task update: --id is required")
	}

	// Detect which flags were explicitly set via Visit
	var setTitle, setDesc, setPriority, setStatus bool
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "title":
			setTitle = true
		case "description":
			setDesc = true
		case "priority":
			setPriority = true
		case "status":
			setStatus = true
		}
	})

	if !setTitle && !setDesc && !setPriority && !setStatus {
		return usageError(fs, "foreman task update: at least one of --title, --description, --priority, --status is required")
	}

	payload := map[string]any{"task_id": *taskID}
	if setTitle {
		payload["title"] = *title
	}
	if setDesc {
		payload["description"] = *description
	}
	if setPriority {
		payload["priority"] = *priority
	}
	if setStatus {
		payload["status"] = *status
	}

	body := commandEnvelope{Type: "task.update", Payload: payload}
	return postCommand(c, body)
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
