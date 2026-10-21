package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"text/tabwriter"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const projectMemoryUsage = `Usage:
  foreman project memory list [--format=json|table] <project-id>
  foreman project memory read --name=<topic> [--format=json|table] <project-id>
  foreman project memory write --name=<topic> [--description=<text>] (--file=<path>|--file=-) [--format=json|table] <project-id>
  foreman project memory forget --name=<topic> <project-id>
  foreman project memory sync [--format=json|table] <project-id>

Project memory lives under <project>/.foreman/memory/ (MEMORY.md index plus one
<topic>.md file per topic). Content is redacted before it is stored. 'sync'
records hand-edited files in the audit trail. --format=json on list prints
one JSON object per topic (NDJSON).`

// memoryStdin is where `write --file=-` reads; a variable so tests can feed it.
var memoryStdin io.Reader = os.Stdin

// projectMemory dispatches `foreman project memory <verb>`.
func projectMemory(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman project memory: missing subcommand (list|read|write|forget|sync)", projectMemoryUsage)
	}

	switch args[0] {
	case "list":
		return projectMemoryList(c, args[1:])
	case "read":
		return projectMemoryRead(c, args[1:])
	case "write":
		return projectMemoryWrite(c, args[1:])
	case "forget":
		return projectMemoryForget(c, args[1:])
	case "sync":
		return projectMemorySync(c, args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman project memory: unknown subcommand %q", args[0]), projectMemoryUsage)
	}
}

func memoryBase(projectID string) string {
	return client.JoinPath("/api/projects", url.PathEscape(projectID), "memory")
}

func memoryTopicPath(projectID, name string) string {
	return client.JoinPath(memoryBase(projectID), url.PathEscape(name))
}

func checkMemoryFormat(fs *flagSet, verb, format string) error {
	switch format {
	case "", "table", "json":
		return nil
	default:
		return usageError(fs, "foreman project memory %s: unsupported format %q", verb, format)
	}
}

func projectMemoryList(c *client.Client, args []string) error {
	fs := newFlagSet("project memory list")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project memory list: expected one argument: <project-id>")
	}
	if err := checkMemoryFormat(fs, "list", *format); err != nil {
		return err
	}

	var out struct {
		Index   string           `json:"index"`
		Entries []map[string]any `json:"entries"`
	}
	if err := c.GetJSON(memoryBase(fs.Arg(0)), &out); err != nil {
		return err
	}

	if *format == "json" {
		enc := json.NewEncoder(os.Stdout)
		for _, entry := range out.Entries {
			if err := enc.Encode(entry); err != nil {
				return err
			}
		}
		return nil
	}

	tw := tabwriter.NewWriter(os.Stdout, 0, 8, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tBYTES\tAUTHOR\tUPDATED\tDESCRIPTION")
	for _, entry := range out.Entries {
		fmt.Fprintf(tw, "%s\t%v\t%s\t%s\t%s\n",
			getStr(entry, "name"), entry["bytes"], getStr(entry, "author_kind"),
			getStr(entry, "updated_at"), getStr(entry, "description"))
	}
	return tw.Flush()
}

func projectMemoryRead(c *client.Client, args []string) error {
	fs := newFlagSet("project memory read")
	name := fs.String("name", "", "Topic name (required)")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 || *name == "" {
		return usageError(fs, "foreman project memory read: --name and <project-id> are required")
	}
	if err := checkMemoryFormat(fs, "read", *format); err != nil {
		return err
	}

	var out map[string]any
	if err := c.GetJSON(memoryTopicPath(fs.Arg(0), *name), &out); err != nil {
		return err
	}

	if *format == "json" {
		return printJSON(out)
	}
	_, err := fmt.Fprint(os.Stdout, getStr(out, "content"))
	return err
}

func projectMemoryWrite(c *client.Client, args []string) error {
	fs := newFlagSet("project memory write")
	name := fs.String("name", "", "Topic name (required)")
	description := fs.String("description", "", "One-line description shown in the MEMORY.md index")
	file := fs.String("file", "", "File with the content, or - for stdin (required)")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 || *name == "" || *file == "" {
		return usageError(fs, "foreman project memory write: --name, --file and <project-id> are required")
	}
	if err := checkMemoryFormat(fs, "write", *format); err != nil {
		return err
	}

	var raw []byte
	var err error
	if *file == "-" {
		raw, err = io.ReadAll(memoryStdin)
	} else {
		raw, err = os.ReadFile(*file)
	}
	if err != nil {
		return fmt.Errorf("foreman project memory write: read content: %w", err)
	}

	body := map[string]any{"content": string(raw)}
	if *description != "" {
		body["description"] = *description
	}

	var out map[string]any
	if err := c.PutJSON(memoryTopicPath(fs.Arg(0), *name), body, &out); err != nil {
		return err
	}

	if *format == "json" {
		return printJSON(out)
	}
	_, err = fmt.Fprintf(os.Stdout, "wrote memory topic %s\n", *name)
	return err
}

func projectMemoryForget(c *client.Client, args []string) error {
	fs := newFlagSet("project memory forget")
	name := fs.String("name", "", "Topic name (required)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 || *name == "" {
		return usageError(fs, "foreman project memory forget: --name and <project-id> are required")
	}

	if err := c.DeleteJSON(memoryTopicPath(fs.Arg(0), *name), nil); err != nil {
		return err
	}
	_, err := fmt.Fprintf(os.Stdout, "forgot memory topic %s\n", *name)
	return err
}

func projectMemorySync(c *client.Client, args []string) error {
	fs := newFlagSet("project memory sync")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project memory sync: expected one argument: <project-id>")
	}
	if err := checkMemoryFormat(fs, "sync", *format); err != nil {
		return err
	}

	var out struct {
		Recorded  []string         `json:"recorded"`
		Forgotten []string         `json:"forgotten"`
		Failed    []map[string]any `json:"failed"`
	}
	if err := c.PostJSON(client.JoinPath(memoryBase(fs.Arg(0)), "sync"), nil, &out); err != nil {
		return err
	}

	if *format == "json" {
		if err := printJSON(out); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(os.Stdout, "recorded %d, forgotten %d, failed %d\n", len(out.Recorded), len(out.Forgotten), len(out.Failed))
	}

	if len(out.Failed) > 0 {
		for _, f := range out.Failed {
			fmt.Fprintf(os.Stderr, "sync failed for %s: %s (%s)\n", getStr(f, "name"), getStr(f, "message"), getStr(f, "error"))
		}
		return fmt.Errorf("foreman project memory sync: %d topic(s) failed", len(out.Failed))
	}
	return nil
}
