package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// severityRank orders and gates recommendations: action > warn > info.
var severityRank = map[string]int{"action": 0, "warn": 1, "info": 2}

// projectRecommend implements `foreman project recommend`, a read-only
// GET /api/projects/:id/recommendations.
func projectRecommend(c *client.Client, args []string) error {
	fs := newFlagSet("project recommend")
	format := fs.String("format", "", "Output format (json)")
	failOn := fs.String("fail-on", "", "Exit 1 when a recommendation at or above this severity exists (warn|action)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project recommend: expected one argument: <project-id>")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project recommend: unsupported format %q", *format)
	}
	switch *failOn {
	case "", "warn", "action":
	default:
		return usageError(fs, "foreman project recommend: --fail-on must be warn or action, got %q", *failOn)
	}

	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/projects", fs.Arg(0), "recommendations"), &out); err != nil {
		return err
	}
	recs, _ := out["recommendations"].([]any)

	if *format == "json" {
		if err := printJSON(out); err != nil {
			return err
		}
	} else {
		printRecommendations(fs.Arg(0), recs)
	}

	if *failOn != "" && hasSeverityAtLeast(recs, *failOn) {
		return fmt.Errorf("foreman project recommend: recommendations at or above %q severity exist", *failOn)
	}
	return nil
}

func hasSeverityAtLeast(recs []any, threshold string) bool {
	limit := severityRank[threshold]
	for _, r := range recs {
		rec, _ := r.(map[string]any)
		sev, _ := rec["severity"].(string)
		if rank, ok := severityRank[sev]; ok && rank <= limit {
			return true
		}
	}
	return false
}

func printRecommendations(projectID string, recs []any) {
	if len(recs) == 0 {
		fmt.Fprintf(os.Stdout, "Project %s looks ready: no setup recommendations.\n", projectID)
		return
	}
	for _, r := range recs {
		rec, _ := r.(map[string]any)
		sev, _ := rec["severity"].(string)
		id, _ := rec["id"].(string)
		title, _ := rec["title"].(string)
		detail, _ := rec["detail"].(string)
		fmt.Fprintf(os.Stdout, "[%s] %s: %s\n", sev, id, title)
		if detail != "" {
			fmt.Fprintf(os.Stdout, "    %s\n", detail)
		}
		if fix, ok := rec["fix"].(map[string]any); ok {
			fmt.Fprintf(os.Stdout, "    fix: %s\n", describeFix(projectID, fix))
		}
	}
}

// describeFix renders a command fix as the exact `foreman ...` invocation when
// one exists, else as the raw command name and payload; manual fixes verbatim.
func describeFix(projectID string, fix map[string]any) string {
	if kind, _ := fix["kind"].(string); kind == "manual" {
		text, _ := fix["text"].(string)
		return text
	}
	typ, _ := fix["type"].(string)
	payload, _ := fix["payload"].(map[string]any)
	switch typ {
	case "project.resume":
		return "foreman project resume " + projectID
	case "project.update":
		if tp, ok := payload["task_provider"].(map[string]any); ok {
			provider, _ := tp["provider"].(string)
			cmd := "foreman project update " + projectID + " --task-provider " + provider
			if cfg, ok := tp["config"].(map[string]any); ok {
				if db, ok := cfg["database_path"].(string); ok {
					cmd += " --task-provider-database-path " + db
				}
			}
			return cmd
		}
	}
	return "POST /api/commands type=" + typ + " payload=" + strings.TrimSpace(fmt.Sprint(payload))
}
