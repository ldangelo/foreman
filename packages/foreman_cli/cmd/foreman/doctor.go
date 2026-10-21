package main

import (
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// runDoctor implements `foreman doctor`: GET /api/doctor. Only the checks the
// server really performs are reported (reachability, read model, provider
// readiness, workflow catalog, and per-project setup recommendations).
// --fix/--dry-run are NOT implemented and fail loudly rather than pretending.
func runDoctor(c *client.Client, args []string) error {
	fs := newFlagSet("doctor")
	project := fs.String("project", "", "Also summarise setup recommendations for this project")
	strict := fs.Bool("strict", false, "Exit 1 on warnings too")
	format := fs.String("format", "", "Output format (json)")
	fix := fs.Bool("fix", false, "NOT IMPLEMENTED")
	dryRun := fs.Bool("dry-run", false, "NOT IMPLEMENTED")
	if err := fs.parse(args); err != nil {
		return err
	}
	if *fix || *dryRun {
		return usageError(fs, "foreman doctor: --fix and --dry-run are not implemented; doctor only reports")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman doctor: unsupported format %q", *format)
	}

	path := "/api/doctor"
	if *project != "" {
		path += "?project=" + *project
	}
	var out map[string]any
	if err := c.GetJSON(path, &out); err != nil {
		return err
	}
	checks, _ := out["checks"].([]any)

	if *format == "json" {
		if err := printJSON(out); err != nil {
			return err
		}
	} else {
		for _, item := range checks {
			check, _ := item.(map[string]any)
			fmt.Fprintf(os.Stdout, "%-4s %s: %s\n", check["status"], check["id"], check["title"])
			if detail, _ := check["detail"].(string); detail != "" {
				fmt.Fprintf(os.Stdout, "     %s\n", detail)
			}
		}
	}

	return doctorExit(checks, *strict)
}

func doctorExit(checks []any, strict bool) error {
	for _, item := range checks {
		check, _ := item.(map[string]any)
		switch check["status"] {
		case "fail":
			return fmt.Errorf("foreman doctor: checks failed")
		case "warn":
			if strict {
				return fmt.Errorf("foreman doctor: warnings present (--strict)")
			}
		}
	}
	return nil
}
