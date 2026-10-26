package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"strings"
	"text/tabwriter"
	"unicode"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const approvalsHelp = `Usage of approvals:
  foreman approvals list (--project <id> | --run <id>) [--all] [--format table|json]
  foreman approvals approve --run <id> --call <tool_call_id> [--by <name>] [--reason <text>]
  foreman approvals deny    --run <id> --call <tool_call_id> [--by <name>] [--reason <text>]

Agent tool-permission requests. approve/deny decide ONE request (tool.approve /
tool.deny); they are unrelated to the run merge gate, which is only ever
'foreman run approve-merge/merge'. What an approval grants depends on the
request's approval_delivery:
  inflight              a Claude phase in approval_mode prompt: the agent's call is
                        blocked, and approve/deny answers that ONE call.
  resume_with_override  post-hoc: the phase ended denied and the run is paused. An
                        approval resumes it with a relaxed approval mode for the NEXT
                        PHASE as a whole (auto_edit when the tool edits files,
                        auto_approve otherwise), so EVERY tool of that phase is
                        allowed, not only the approved one: there is no per-tool grant
                        on this path.
  live                  ACP providers: answers the provider session's own request.
`

const questionsHelp = `Usage of questions:
  foreman questions list --project <id> [--all] [--format table|json]
  foreman questions answer --run <id|global> --question <id> --text <answer> [--by <name>]

Questions agents asked the operator.
`

func newNeedsYouID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return "cli-" + hex.EncodeToString(b)
}

func runApprovals(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman approvals: missing subcommand", approvalsHelp)
	}
	switch args[0] {
	case "list":
		return approvalsList(c, args[1:])
	case "approve":
		return approvalsDecide(c, "tool.approve", args[1:])
	case "deny":
		return approvalsDecide(c, "tool.deny", args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman approvals: unknown subcommand %q", args[0]), approvalsHelp)
	}
}

func approvalsList(c *client.Client, args []string) error {
	fs := newFlagSet("approvals list")
	project := fs.String("project", "", "Project id")
	run := fs.String("run", "", "Run or jobsite id")
	all := fs.Bool("all", false, "Include decided, expired and finished requests")
	format := fs.String("format", "table", "Output format (table|json)")
	fs.Usage = func() { fmt.Fprint(fs.Output(), approvalsHelp) }
	if err := fs.parse(args); err != nil {
		return err
	}
	if (*project == "") == (*run == "") {
		return usageError(fs, "foreman approvals list: pass exactly one of --project or --run")
	}
	path := client.JoinPath("/api/projects", *project, "approvals")
	if *run != "" {
		path = client.JoinPath("/api/runs", *run, "approvals")
	}
	return listNeedsYou(c, path, *all, *format, "approvals",
		[]string{"tool_call_id", "run_id", "tool_name", "status", "approval_delivery", "input_summary"})
}

func approvalsDecide(c *client.Client, kind string, args []string) error {
	fs := newFlagSet("approvals " + kind)
	run := fs.String("run", "", "Run id (required)")
	call := fs.String("call", "", "Tool call id (required)")
	by := fs.String("by", "", "Decider name recorded on the decision")
	reason := fs.String("reason", "", "Reason (max 500 chars)")
	fs.Usage = func() { fmt.Fprint(fs.Output(), approvalsHelp) }
	if err := fs.parse(args); err != nil {
		return err
	}
	if *run == "" || *call == "" {
		return usageError(fs, "foreman approvals: --run and --call are required")
	}
	payload := map[string]any{"run_id": *run, "tool_call_id": *call}
	if *by != "" {
		payload["decided_by"] = *by
	}
	if *reason != "" {
		payload["reason"] = *reason
	}
	return postNeedsYou(c, kind, payload)
}

func runQuestions(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman questions: missing subcommand", questionsHelp)
	}
	switch args[0] {
	case "list":
		fs := newFlagSet("questions list")
		project := fs.String("project", "", "Project id (required)")
		all := fs.Bool("all", false, "Include answered and expired questions")
		format := fs.String("format", "table", "Output format (table|json)")
		fs.Usage = func() { fmt.Fprint(fs.Output(), questionsHelp) }
		if err := fs.parse(args[1:]); err != nil {
			return err
		}
		if *project == "" {
			return usageError(fs, "foreman questions list: --project is required")
		}
		return listNeedsYou(c, client.JoinPath("/api/projects", *project, "questions"), *all, *format, "questions",
			[]string{"question_id", "run_id", "agent_id", "status", "text"})
	case "answer":
		fs := newFlagSet("questions answer")
		run := fs.String("run", "", "Run id, or global (required)")
		question := fs.String("question", "", "Question id (required)")
		text := fs.String("text", "", "Answer text (required, max 8000 chars)")
		by := fs.String("by", "", "Answerer name")
		fs.Usage = func() { fmt.Fprint(fs.Output(), questionsHelp) }
		if err := fs.parse(args[1:]); err != nil {
			return err
		}
		if *run == "" || *question == "" || *text == "" {
			return usageError(fs, "foreman questions answer: --run, --question and --text are required")
		}
		payload := map[string]any{"run_id": *run, "question_id": *question, "text": *text}
		if *by != "" {
			payload["answered_by"] = *by
		}
		return postNeedsYou(c, "question.answer", payload)
	default:
		return usageTextError(fmt.Sprintf("foreman questions: unknown subcommand %q", args[0]), questionsHelp)
	}
}

func postNeedsYou(c *client.Client, kind string, payload map[string]any) error {
	var out map[string]any
	body := map[string]any{"type": kind, "command_id": newNeedsYouID(), "payload": payload}
	if err := c.PostJSON("/api/commands", body, &out); err != nil {
		return err
	}
	return printJSON(out)
}

func listNeedsYou(c *client.Client, path string, all bool, format, key string, cols []string) error {
	if format != "table" && format != "json" {
		return fmt.Errorf("unsupported format %q", format)
	}
	if all {
		path += "?" + url.Values{"status": {"all"}}.Encode()
	}
	var out map[string]any
	if err := c.GetJSON(path, &out); err != nil {
		return err
	}
	if format == "json" {
		return printJSON(out)
	}
	rows, _ := out[key].([]any)
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	for i, col := range cols {
		if i > 0 {
			fmt.Fprint(w, "\t")
		}
		fmt.Fprint(w, col)
	}
	fmt.Fprintln(w)
	for _, r := range rows {
		row, _ := r.(map[string]any)
		for i, col := range cols {
			if i > 0 {
				fmt.Fprint(w, "\t")
			}
			fmt.Fprint(w, sanitizeCell(row[col]))
		}
		fmt.Fprintln(w)
	}
	return w.Flush()
}

// sanitizeCell makes one table cell safe: a JSON null or a key the server did not
// send is an empty cell (never Go's `<nil>`), and control characters (newline,
// tab, carriage return, ANSI escapes) in agent-supplied text become spaces, so a
// value can neither forge extra rows nor rewrite the terminal.
func sanitizeCell(v any) string {
	if v == nil {
		return ""
	}
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, fmt.Sprint(v))
}
