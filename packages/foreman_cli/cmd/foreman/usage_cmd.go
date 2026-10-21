package main

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"text/tabwriter"
	"time"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const usageCmdHelp = `Usage of usage:
  foreman usage --project <id> [--from YYYY-MM-DD] [--to YYYY-MM-DD]
                [--by day|model|provider|role|thread] [--limit N] [--format table|json]

Token and cost usage of a project. A cost shown as "-" is unknown (the provider
reported none), never free; "*" marks a partial cost (some events unpriced).
`

var usageGroupings = map[string]bool{"day": true, "model": true, "provider": true, "role": true, "thread": true}

// usageGroupLabel is the key of each breakdown row that names the group.
var usageGroupLabel = map[string]string{
	"day": "date", "model": "model", "provider": "provider", "role": "role", "thread": "thread_id",
}

func runUsage(c *client.Client, args []string) error {
	fs := newFlagSet("usage")
	project := fs.String("project", "", "Project id (required)")
	from := fs.String("from", "", "First UTC day, YYYY-MM-DD")
	to := fs.String("to", "", "Last UTC day, YYYY-MM-DD")
	by := fs.String("by", "model", "Group by day|model|provider|role|thread")
	limit := fs.Int("limit", 0, "Maximum threads returned (server default 50, max 500)")
	format := fs.String("format", "table", "Output format (table|json)")
	fs.Usage = func() { fmt.Fprint(fs.Output(), usageCmdHelp) }
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman usage: unexpected argument %q", fs.Arg(0))
	}
	if *project == "" {
		return usageError(fs, "foreman usage: --project is required")
	}
	for name, value := range map[string]string{"--from": *from, "--to": *to} {
		if value == "" {
			continue
		}
		if _, err := time.Parse("2006-01-02", value); err != nil {
			return usageError(fs, "foreman usage: %s must be a YYYY-MM-DD date, got %q", name, value)
		}
	}
	if !usageGroupings[*by] {
		return usageError(fs, "foreman usage: --by must be one of day, model, provider, role, thread; got %q", *by)
	}
	if *format != "table" && *format != "json" {
		return usageError(fs, "foreman usage: unsupported format %q", *format)
	}
	if *limit < 0 {
		return usageError(fs, "foreman usage: --limit must be positive")
	}

	query := url.Values{"group_by": {*by}}
	if *from != "" {
		query.Set("from", *from)
	}
	if *to != "" {
		query.Set("to", *to)
	}
	if *limit > 0 {
		query.Set("limit", strconv.Itoa(*limit))
	}

	var out map[string]any
	path := client.JoinPath("/api/projects", *project, "usage") + "?" + query.Encode()
	if err := c.GetJSON(path, &out); err != nil {
		return err
	}
	if *format == "json" {
		return printJSON(out)
	}

	return printUsage(out, *by)
}

func printUsage(out map[string]any, by string) error {
	rows, _ := out["by_"+by].([]any)
	totals, _ := out["totals"].(map[string]any)

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintf(w, "%s\tINPUT\tOUTPUT\tCACHE-READ\tCACHE-WRITE\tTOTAL\tCOST\n", usageHeader(by))
	for _, row := range rows {
		if m, ok := row.(map[string]any); ok {
			printUsageRow(w, getStr(m, usageGroupLabel[by]), m)
		}
	}
	printUsageRow(w, "TOTAL", totals)
	if err := w.Flush(); err != nil {
		return err
	}

	if unknown := usageCount(totals["cost_unknown_events"]); unknown > 0 {
		fmt.Printf("\n%d events with unknown cost (\"-\" = no cost reported, \"*\" = partial sum)\n", unknown)
	}
	if limits, ok := out["limits"].(map[string]any); ok {
		if line := usageCapLine(limits); line != "" {
			fmt.Println(line)
		}
	}

	return nil
}

func usageHeader(by string) string {
	switch by {
	case "thread":
		return "THREAD"
	default:
		return map[string]string{"day": "DAY", "model": "MODEL", "provider": "PROVIDER", "role": "ROLE"}[by]
	}
}

func printUsageRow(w *tabwriter.Writer, name string, m map[string]any) {
	fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name,
		usageNumber(m["input_tokens"]), usageNumber(m["output_tokens"]),
		usageNumber(m["cache_read_tokens"]), usageNumber(m["cache_write_tokens"]),
		usageNumber(m["total_tokens"]), usageCost(m))
}

func usageNumber(v any) string {
	if f, ok := v.(float64); ok {
		return strconv.FormatInt(int64(f), 10)
	}
	return "-"
}

func usageCount(v any) int {
	if f, ok := v.(float64); ok {
		return int(f)
	}
	return 0
}

func usageCost(m map[string]any) string {
	cost, ok := m["cost_usd"].(float64)
	if !ok {
		return "-"
	}
	text := strconv.FormatFloat(cost, 'f', 4, 64)
	if usageCount(m["cost_unknown_events"]) > 0 {
		return text + "*"
	}
	return text
}

// usageCapLine renders the daily thread cap, or "" when no cap is configured.
func usageCapLine(limits map[string]any) string {
	capValue, ok := limits["daily_thread_cap"].(float64)
	if !ok {
		return ""
	}
	line := fmt.Sprintf("daily thread cap: threads today: %d/%d", usageCount(limits["threads_started_today"]), int(capValue))
	if resets, ok := limits["resets_at"].(string); ok {
		if t, err := time.Parse(time.RFC3339, resets); err == nil {
			line += ", resets " + t.UTC().Format("15:04") + " UTC"
		}
	}
	if deferred := usageCount(limits["deferred_today"]); deferred > 0 {
		line += fmt.Sprintf(", %d deferred today", deferred)
	}
	return line
}
