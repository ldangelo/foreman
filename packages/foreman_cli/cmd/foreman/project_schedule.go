package main

import (
	"fmt"
	"net/url"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const projectScheduleUsageText = "Usage:\n" +
	"  foreman project schedule list --project-id <id> [--json]\n" +
	"  foreman project schedule create --project-id <id> --name <name> (--every <30m> | --cron \"<expr>\") [--timezone <tz>] (--prompt <text> | --prompt-file <path>) --workflow <workflow> [--auto-approve[=false]] [--overlap skip|allow] [--id <schedule-id>]\n" +
	"  foreman project schedule pause --project-id <id> --id <schedule-id>\n" +
	"  foreman project schedule resume --project-id <id> --id <schedule-id>\n" +
	"  foreman project schedule delete --project-id <id> --id <schedule-id>"

// projectSchedule dispatches `foreman project schedule <verb>`.
func projectSchedule(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman project schedule: missing subcommand (list|create|pause|resume|delete)",
			projectScheduleUsageText,
		)
	}

	switch args[0] {
	case "list":
		return projectScheduleList(c, args[1:])
	case "create":
		return projectScheduleCreate(c, args[1:])
	case "pause":
		return projectScheduleLifecycle(c, "pause", "paused", args[1:])
	case "resume":
		return projectScheduleLifecycle(c, "resume", "resumed", args[1:])
	case "delete":
		return projectScheduleLifecycle(c, "delete", "deleted", args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman project schedule: unknown subcommand %q", args[0]),
			projectScheduleUsageText,
		)
	}
}

func projectScheduleList(c *client.Client, args []string) error {
	fs := newFlagSet("project schedule list")
	projectID := fs.String("project-id", "", "Project ID (required)")
	asJSON := fs.Bool("json", false, "Echo the server response as JSON")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project schedule list:\n  foreman project schedule list --project-id <id> [--json]\n\nList a project's schedules. Table columns: ID, NAME, SPEC, STATUS, NEXT FIRE, LAST OUTCOME.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman project schedule list: expected no positional arguments")
	}
	if *projectID == "" {
		return usageError(fs, "foreman project schedule list: --project-id is required")
	}

	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/projects", url.PathEscape(*projectID), "schedules"), &out); err != nil {
		return err
	}

	if *asJSON {
		return printJSON(out)
	}

	return printScheduleTable(out)
}

func printScheduleTable(body map[string]any) error {
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	if _, err := fmt.Fprintln(writer, "ID\tNAME\tSPEC\tSTATUS\tNEXT FIRE\tLAST OUTCOME"); err != nil {
		return err
	}

	schedules, _ := body["schedules"].([]any)
	for _, raw := range schedules {
		schedule, _ := raw.(map[string]any)
		if _, err := fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\n",
			getStr(schedule, "schedule_id"),
			getStr(schedule, "name"),
			scheduleSpecText(schedule["spec"]),
			getStr(schedule, "status"),
			dashIfEmpty(getStr(schedule, "next_fire_at")),
			scheduleOutcomeText(schedule["last_outcome"]),
		); err != nil {
			return err
		}
	}

	if err := writer.Flush(); err != nil {
		return err
	}

	ticker := getStr(body, "ticker")
	if _, err := fmt.Fprintf(os.Stdout, "ticker: %s\n", dashIfEmpty(ticker)); err != nil {
		return err
	}
	if ticker == "disabled" {
		_, err := fmt.Fprintln(os.Stdout, "warning: the schedule ticker is disabled; schedules will not fire")
		return err
	}

	return nil
}

func scheduleSpecText(raw any) string {
	spec, _ := raw.(map[string]any)
	if every := getStr(spec, "every"); every != "" {
		return "every " + every
	}
	if cron := getStr(spec, "cron"); cron != "" {
		return "cron " + cron
	}
	return "-"
}

func scheduleOutcomeText(raw any) string {
	outcome, _ := raw.(map[string]any)
	kind := getStr(outcome, "kind")
	if kind == "" {
		return "-"
	}
	if reason := getStr(outcome, "reason"); reason != "" {
		return kind + ": " + reason
	}
	return kind
}

func dashIfEmpty(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func projectScheduleCreate(c *client.Client, args []string) error {
	fs := newFlagSet("project schedule create")
	projectID := fs.String("project-id", "", "Project ID (required)")
	name := fs.String("name", "", "Schedule name")
	every := fs.String("every", "", "Fixed interval, e.g. 30m or 1h (exclusive with --cron)")
	cron := fs.String("cron", "", "Cron expression, e.g. \"0 9 * * 1-5\" (exclusive with --every)")
	timezone := fs.String("timezone", "", "IANA timezone for the spec")
	prompt := fs.String("prompt", "", "Prompt for the scheduled task (or --prompt-file)")
	promptFile := fs.String("prompt-file", "", "Read the prompt from this file (or --prompt)")
	workflow := fs.String("workflow", "", "Workflow to run")
	autoApprove := fs.Bool("auto-approve", true, "Auto-approve created tasks (use --auto-approve=false to disable)")
	overlap := fs.String("overlap", "skip", "Overlap policy: skip|allow")
	scheduleID := fs.String("id", "", "Schedule ID (server-generated when omitted)")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project schedule create:\n  foreman project schedule create --project-id <id> --name <name> (--every <30m> | --cron \"<expr>\") [--timezone <tz>] (--prompt <text> | --prompt-file <path>) --workflow <workflow> [--auto-approve[=false]] [--overlap skip|allow] [--id <schedule-id>]\n\nCreate a schedule that submits a task on a recurring spec.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}

	const cmd = "foreman project schedule create"
	switch {
	case fs.NArg() != 0:
		return usageError(fs, "%s: expected no positional arguments", cmd)
	case *projectID == "":
		return usageError(fs, "%s: --project-id is required", cmd)
	case (*every == "") == (*cron == ""):
		return usageError(fs, "%s: exactly one of --every or --cron is required", cmd)
	case (*prompt == "") == (*promptFile == ""):
		return usageError(fs, "%s: exactly one of --prompt or --prompt-file is required", cmd)
	case *overlap != "skip" && *overlap != "allow":
		return usageError(fs, "%s: --overlap must be skip or allow, got %q", cmd, *overlap)
	}

	promptText := *prompt
	if *promptFile != "" {
		data, err := os.ReadFile(*promptFile)
		if err != nil {
			return fmt.Errorf("foreman project schedule create: read --prompt-file: %w", err)
		}
		promptText = string(data)
		if strings.TrimSpace(promptText) == "" {
			return usageError(fs, "%s: --prompt-file %s is empty", cmd, *promptFile)
		}
	}

	spec := map[string]any{}
	if *every != "" {
		spec["every"] = *every
	} else {
		spec["cron"] = *cron
	}
	if *timezone != "" {
		spec["timezone"] = *timezone
	}

	payload := map[string]any{
		"project_id":   *projectID,
		"spec":         spec,
		"prompt":       promptText,
		"auto_approve": *autoApprove,
		"overlap":      *overlap,
	}
	if *name != "" {
		payload["name"] = *name
	}
	if *workflow != "" {
		payload["workflow"] = *workflow
	}
	if *scheduleID != "" {
		payload["schedule_id"] = *scheduleID
	}

	out, err := postCommandWithResponse(c, commandEnvelope{Type: "schedule.create", Payload: payload})
	if err != nil {
		return err
	}

	createdID := *scheduleID
	if result, ok := out["result"].(map[string]any); ok {
		if id := getStr(result, "schedule_id"); id != "" {
			createdID = id
		}
	}

	_, err = fmt.Fprintf(os.Stdout, "created schedule %s in project %s\n", createdID, *projectID)
	return err
}

func projectScheduleLifecycle(c *client.Client, verb, done string, args []string) error {
	name := "project schedule " + verb
	fs := newFlagSet(name)
	projectID := fs.String("project-id", "", "Project ID (required)")
	scheduleID := fs.String("id", "", "Schedule ID (required)")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "Usage of %s:\n  foreman %s --project-id <id> --id <schedule-id>\n\nFlags:\n", name, name)
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman %s: expected no positional arguments", name)
	}
	if *projectID == "" || *scheduleID == "" {
		return usageError(fs, "foreman %s: --project-id and --id are required", name)
	}

	body := commandEnvelope{
		Type:    "schedule." + verb,
		Payload: map[string]any{"project_id": *projectID, "schedule_id": *scheduleID},
	}
	if _, err := postCommandWithResponse(c, body); err != nil {
		return err
	}

	_, err := fmt.Fprintf(os.Stdout, "%s schedule %s in project %s\n", done, *scheduleID, *projectID)
	return err
}
