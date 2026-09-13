package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"strings"
	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// runTask dispatches `foreman task <subcommand>`.
func runTask(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman task: missing subcommand (list|update)",
			"Usage:\n  foreman task list [--project <id>] [--status <status>]\n  foreman task update --id <id> [--title <title>] [--description <desc>] [--priority <0-4>] [--status <status>]",
		)
	}

	switch args[0] {
	case "list":
		return taskList(c, args[1:])
	case "update":
		return taskUpdate(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman task: unknown subcommand %q", args[0]),
			"Usage:\n  foreman task list [--project <id>] [--status <status>]\n  foreman task update --id <id> [--title <title>] [--description <desc>] [--priority <0-4>] [--status <status>]",
		)
	}
}

// commandEnvelope is the JSON envelope sent to /api/commands.
// The server derives the aggregate_id from the payload.
type commandEnvelope struct {
	Type      string         `json:"type"`
	CommandID string         `json:"command_id,omitempty"`
	Payload   map[string]any `json:"payload"`
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
