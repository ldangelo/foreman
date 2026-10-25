package main

import (
	"fmt"
	"net/url"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// threadUsage lists every `foreman thread` verb. Pinned by TestThreadUsageListsEveryVerb.
const threadUsage = `Usage:
  foreman thread list --project <project-id> [--status <status>] [--door workflow|jobsite] [--limit <n>]
  foreman thread get <thread-id>
  foreman thread stop [--reason <reason>] <thread-id>
  foreman thread resolve [--reason <reason>] <thread-id>
  foreman thread reopen <thread-id>
  foreman thread steer --message <text> [--message-id <id>] [--no-resume] <thread-id>
  foreman thread rereview <thread-id>`

var threadVerbs = []string{"list", "get", "stop", "resolve", "reopen", "steer", "rereview"}

func runThread(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman thread: missing subcommand (list, get, stop, resolve, reopen, steer, rereview)", threadUsage)
	}

	switch args[0] {
	case "list":
		return threadList(c, args[1:])
	case "get":
		return threadGet(c, args[1:])
	case "stop":
		return threadStop(c, args[1:])
	case "resolve":
		return threadResolve(c, args[1:])
	case "reopen":
		return threadReopen(c, args[1:])
	case "steer":
		return threadSteer(c, args[1:])
	case "rereview":
		return threadRereview(c, args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman thread: unknown subcommand %q", args[0]), threadUsage)
	}
}

func threadList(c *client.Client, args []string) error {
	fs := newFlagSet("thread list")
	project := fs.String("project", "", "Project ID (required)")
	status := fs.String("status", "", "Filter by raw thread status")
	door := fs.String("door", "", "Filter by door: workflow or jobsite")
	limit := fs.Int("limit", 0, "Maximum threads to return")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 0 {
		return usageError(fs, "foreman thread list: expected no positional arguments")
	}
	if *project == "" {
		return usageTextError("foreman thread list: --project is required", threadUsage)
	}
	if *limit < 0 {
		return usageError(fs, "foreman thread list: --limit must be non-negative")
	}

	values := url.Values{}
	if *status != "" {
		values.Set("status", *status)
	}
	if *door != "" {
		values.Set("door", *door)
	}
	if *limit > 0 {
		values.Set("limit", fmt.Sprintf("%d", *limit))
	}

	path := client.JoinPath("/api/projects", *project, "threads")
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}

	var out map[string]any
	if err := c.GetJSON(path, &out); err != nil {
		return err
	}

	return printJSON(out)
}

func threadGet(c *client.Client, args []string) error {
	fs := newFlagSet("thread get")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman thread get: expected one argument: <thread-id>")
	}

	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/threads", fs.Arg(0)), &out); err != nil {
		return err
	}

	return printJSON(out)
}

func threadStop(c *client.Client, args []string) error {
	fs := newFlagSet("thread stop")
	reason := fs.String("reason", "", "Why the thread is stopped (default operator_stop)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman thread stop: expected one argument: <thread-id>")
	}

	body := map[string]any{}
	if *reason != "" {
		body["reason"] = *reason
	}

	var out map[string]any
	if err := c.PostJSON(client.JoinPath("/api/threads", fs.Arg(0), "stop"), body, &out); err != nil {
		return err
	}

	return printJSON(out)
}

func threadResolve(c *client.Client, args []string) error {
	fs := newFlagSet("thread resolve")
	reason := fs.String("reason", "", "Why the thread is resolved")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman thread resolve: expected one argument: <thread-id>")
	}

	extra := map[string]any{"source": "cli"}
	if *reason != "" {
		extra["reason"] = *reason
	}

	return threadDisposition(c, "thread.resolve", fs.Arg(0), extra)
}

func threadReopen(c *client.Client, args []string) error {
	fs := newFlagSet("thread reopen")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman thread reopen: expected one argument: <thread-id>")
	}

	return threadDisposition(c, "thread.reopen", fs.Arg(0), map[string]any{"source": "cli"})
}

// threadDisposition posts a thread.resolve / thread.reopen command. The
// aggregate requires the owning project, which the operator does not type:
// it is read from the thread itself, so an unknown thread fails with the
// server's 404 before any command is sent.
func threadDisposition(c *client.Client, commandType, threadID string, extra map[string]any) error {
	var got struct {
		Thread struct {
			ProjectID string `json:"project_id"`
		} `json:"thread"`
	}
	if err := c.GetJSON(client.JoinPath("/api/threads", threadID), &got); err != nil {
		return err
	}
	if got.Thread.ProjectID == "" {
		return fmt.Errorf("foreman thread: thread %q has no project; cannot %s", threadID, commandType)
	}

	payload := map[string]any{
		"thread_id":  threadID,
		"project_id": got.Thread.ProjectID,
	}
	for k, v := range extra {
		payload[k] = v
	}

	return postCommand(c, commandEnvelope{
		Type:        commandType,
		AggregateID: "thread:" + threadID,
		Payload:     payload,
	})
}

func threadSteer(c *client.Client, args []string) error {
	fs := newFlagSet("thread steer")
	message := fs.String("message", "", "Operator message delivered to the thread (required)")
	messageID := fs.String("message-id", "", "Idempotency id; re-sending the same id is a no-op")
	noResume := fs.Bool("no-resume", false, "Queue the message but keep a paused run paused")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman thread steer: expected one argument: <thread-id>")
	}
	if strings.TrimSpace(*message) == "" {
		return usageTextError("foreman thread steer: --message is required", threadUsage)
	}

	body := map[string]any{"text": *message}
	if *messageID != "" {
		body["message_id"] = *messageID
	}
	if *noResume {
		body["resume"] = false
	}

	var out map[string]any
	if err := c.PostJSON(client.JoinPath("/api/threads", fs.Arg(0), "steer"), body, &out); err != nil {
		return err
	}

	return printJSON(out)
}

func threadRereview(c *client.Client, args []string) error {
	fs := newFlagSet("thread rereview")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman thread rereview: expected one argument: <thread-id>")
	}

	var out map[string]any
	if err := c.PostJSON(client.JoinPath("/api/threads", fs.Arg(0), "rereview"), map[string]any{}, &out); err != nil {
		return err
	}

	return printJSON(out)
}
