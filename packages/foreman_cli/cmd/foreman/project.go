package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// runProject dispatches `foreman project <subcommand>`.
func runProject(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman project: missing subcommand (create|get|update|delete|list)",
			"Usage:\n  foreman project create [flags]\n  foreman project get [--format=json] <id>\n  foreman project update [--format=json] [--idempotency-key=<key>] --task-provider=<provider> [--task-provider-database-path=<path>] <id>\n  foreman project delete [--force] [--idempotency-key=<key>] <id>\n  foreman project list [--include-archived] [--format=json|ndjson]",
		)
	}

	switch args[0] {
	case "create":
		return projectCreate(c, args[1:])
	case "get":
		return projectGet(c, args[1:])
	case "update":
		return projectUpdate(c, args[1:])
	case "delete":
		return projectDelete(c, args[1:])
	case "list":
		return projectList(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman project: unknown subcommand %q", args[0]),
			"Usage:\n  foreman project create [flags]\n  foreman project get [--format=json] <id>\n  foreman project update [--format=json] [--idempotency-key=<key>] --task-provider=<provider> [--task-provider-database-path=<path>] <id>\n  foreman project delete [--force] [--idempotency-key=<key>] <id>\n  foreman project list [--include-archived] [--format=json|ndjson]",
		)
	}
}

func projectCreate(c *client.Client, args []string) error {
	fs := newFlagSet("project create")
	projectID := fs.String("id", "", "Project ID (required)")
	path := fs.String("path", "", "Project path (required)")
	taskProvider := fs.String("task-provider", "", "Task provider (required)")
	taskProviderDatabasePath := fs.String("task-provider-database-path", "", "Task provider database path (required for beads)")
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *projectID == "" || *path == "" || *taskProvider == "" {
		return usageError(fs, "foreman project create: --id, --path, and --task-provider are required")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project create: unsupported format %q", *format)
	}
	if err := validateTaskProviderConfig(fs, *taskProvider, *taskProviderDatabasePath, "foreman project create"); err != nil {
		return err
	}

	body := commandEnvelope{
		Type:      "project.register",
		CommandID: projectCreateCommandID(*path, *taskProvider, *taskProviderDatabasePath, *idempotencyKey),
		Payload: map[string]any{
			"project_id":    *projectID,
			"path":          *path,
			"task_provider": taskProviderPayload(*taskProvider, *taskProviderDatabasePath),
		},
	}

	out, err := postCommandWithResponse(c, body)
	if err != nil {
		return err
	}

	switch *format {
	case "":
		_, err = fmt.Fprintf(os.Stdout, "registered project %s at %s with task provider %s\n", *projectID, *path, *taskProvider)
		return err
	case "json":
		return printJSON(out)
	default:
		panic("projectCreate format validated before POST")
	}
}

func projectGet(c *client.Client, args []string) error {
	fs := newFlagSet("project get")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman project get: expected one argument: <project-id>")
	}

	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project get: unsupported format %q", *format)
	}

	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/projects", fs.Arg(0)), &out); err != nil {
		return err
	}

	if *format == "json" {
		return printJSON(out)
	}

	return printProject(out)
}

func projectUpdate(c *client.Client, args []string) error {
	fs := newFlagSet("project update")
	taskProvider := fs.String("task-provider", "", "Task provider (required)")
	taskProviderDatabasePath := fs.String("task-provider-database-path", "", "Task provider database path (required for beads)")
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 || *taskProvider == "" {
		return usageError(fs, "foreman project update: --task-provider and <project-id> are required")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project update: unsupported format %q", *format)
	}
	if err := validateTaskProviderConfig(fs, *taskProvider, *taskProviderDatabasePath, "foreman project update"); err != nil {
		return err
	}

	projectID := fs.Arg(0)
	body := commandEnvelope{
		Type:      "project.update",
		CommandID: projectUpdateCommandID(projectID, *taskProvider, *taskProviderDatabasePath, *idempotencyKey),
		Payload: map[string]any{
			"project_id":    projectID,
			"task_provider": taskProviderPayload(*taskProvider, *taskProviderDatabasePath),
		},
	}

	out, err := postCommandWithResponse(c, body)
	if err != nil {
		return err
	}

	switch *format {
	case "":
		_, err = fmt.Fprintf(os.Stdout, "updated project %s with task provider %s\n", projectID, *taskProvider)
		return err
	case "json":
		return printJSON(out)
	default:
		panic("projectUpdate format validated before POST")
	}
}

func projectDelete(c *client.Client, args []string) error {
	fs := newFlagSet("project delete")
	force := fs.Bool("force", false, "Print active run ids if archive is blocked")
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project delete:\n  foreman project delete [--force] [--idempotency-key=<key>] <id>\n\nSoft-delete (archive) a project. The server rejects the archive while active runs remain.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman project delete: expected one argument: <project-id>")
	}

	projectID := fs.Arg(0)
	body := commandEnvelope{
		Type:      "project.archive",
		CommandID: projectDeleteCommandID(projectID, *idempotencyKey),
		Payload: map[string]any{
			"project_id": projectID,
		},
	}

	if _, err := postCommandWithResponse(c, body); err != nil {
		if *force {
			printProjectDeleteConflictDetails(err)
		}

		return err
	}

	_, err := fmt.Fprintf(os.Stdout, "archived project %s\n", projectID)
	return err
}

type projectListResponse struct {
	Projects []map[string]any `json:"projects"`
	Meta     projectListMeta  `json:"meta"`
}

type projectListMeta struct {
	Truncated bool `json:"truncated"`
}

func projectList(c *client.Client, args []string) error {
	fs := newFlagSet("project list")
	includeArchived := fs.Bool("include-archived", false, "Include archived projects")
	format := fs.String("format", "", "Output format (json|ndjson)")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project list:\n  foreman project list [--include-archived] [--format=json|ndjson]\n\nList project projections. Default table columns: ID, PATH, ARCHIVED, REGISTERED, VERSION.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 0 {
		return usageError(fs, "foreman project list: expected no positional arguments")
	}

	switch *format {
	case "", "json", "ndjson":
	default:
		return usageError(fs, "foreman project list: unsupported format %q", *format)
	}

	var out projectListResponse
	path := client.JoinPath("/api/projects") + client.URLValues(map[string]string{
		"include_archived": strconv.FormatBool(*includeArchived),
	})

	if err := c.GetJSON(path, &out); err != nil {
		return err
	}

	if out.Projects == nil {
		out.Projects = []map[string]any{}
	}

	if out.Meta.Truncated {
		if _, err := fmt.Fprintln(os.Stderr, "warning: project list truncated by server cap; inspect X-Total-Count for the full matching count"); err != nil {
			return err
		}
	}

	switch *format {
	case "json":
		return printJSON(out.Projects)
	case "ndjson":
		return printProjectListNDJSON(out.Projects)
	default:
		return printProjectListTable(out.Projects)
	}
}

func printProjectListNDJSON(projects []map[string]any) error {
	encoder := json.NewEncoder(os.Stdout)

	for _, project := range projects {
		if err := encoder.Encode(project); err != nil {
			return err
		}
	}

	return nil
}

func printProjectListTable(projects []map[string]any) error {
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	if _, err := fmt.Fprintln(writer, "ID\tPATH\tARCHIVED\tREGISTERED\tVERSION"); err != nil {
		return err
	}

	for _, project := range projects {
		if _, err := fmt.Fprintf(
			writer,
			"%s\t%s\t%s\t%s\t%s\n",
			projectTableField(project, "project_id"),
			projectTableField(project, "path"),
			projectArchivedField(project),
			projectTableField(project, "registered", "registered_at"),
			projectTableField(project, "version"),
		); err != nil {
			return err
		}
	}

	return writer.Flush()
}

func projectTableField(project map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := project[key]
		if !ok {
			continue
		}

		return projectValueString(value)
	}

	return ""
}

func projectArchivedField(project map[string]any) string {
	if value := projectTableField(project, "archived", "archived?"); value != "" {
		return value
	}

	switch projectStringField(project, "status") {
	case "active":
		return "false"
	case "archived":
		return "true"
	default:
		return ""
	}
}

func projectValueString(value any) string {
	if value == nil {
		return ""
	}

	return fmt.Sprint(value)
}

func printProject(out map[string]any) error {
	project, ok := out["project"].(map[string]any)
	if !ok {
		return printJSON(out)
	}

	projectID := projectStringField(project, "project_id")
	path := projectStringField(project, "path")
	status := projectStringField(project, "status")

	if status != "" {
		_, err := fmt.Fprintf(os.Stdout, "project %s (%s)\npath: %s\n", projectID, status, path)
		return err
	}

	_, err := fmt.Fprintf(os.Stdout, "project %s\npath: %s\n", projectID, path)
	return err
}

func projectStringField(project map[string]any, key string) string {
	value, _ := project[key].(string)
	return value
}

func taskProviderPayload(provider, databasePath string) map[string]any {
	payload := map[string]any{"provider": provider}
	if databasePath != "" {
		payload["config"] = map[string]any{"database_path": databasePath}
	}
	return payload
}

func validateTaskProviderConfig(fs *flagSet, provider, databasePath, command string) error {
	if provider == "beads" && databasePath == "" {
		return usageError(fs, "%s", command+": --task-provider-database-path is required when --task-provider=beads")
	}
	if databasePath != "" && !filepath.IsAbs(databasePath) {
		return usageError(fs, "%s", command+": --task-provider-database-path must be absolute")
	}
	return nil
}

func projectCreateCommandID(path, taskProvider, taskProviderDatabasePath, idempotencyKey string) string {
	if idempotencyKey != "" {
		return sha256Hex("project.create." + idempotencyKey)
	}

	seed := "project.create." + path + "." + taskProvider
	if taskProviderDatabasePath != "" {
		seed += "." + taskProviderDatabasePath
	}
	return sha256Hex(seed)
}

func projectUpdateCommandID(projectID, taskProvider, taskProviderDatabasePath, idempotencyKey string) string {
	if idempotencyKey != "" {
		return sha256Hex("project.update." + idempotencyKey)
	}

	seed := "project.update." + projectID + "." + taskProvider
	if taskProviderDatabasePath != "" {
		seed += "." + taskProviderDatabasePath
	}
	return sha256Hex(seed)
}

func projectDeleteCommandID(projectID, idempotencyKey string) string {
	if idempotencyKey != "" {
		return sha256Hex("project.delete." + idempotencyKey)
	}

	return sha256Hex("project.delete." + projectID)
}

func printProjectDeleteConflictDetails(err error) {
	httpErr, ok := err.(*client.Error)
	if !ok || httpErr.Status != http.StatusConflict {
		return
	}

	var body map[string]any
	if unmarshalErr := json.Unmarshal([]byte(httpErr.Body), &body); unmarshalErr != nil {
		return
	}

	runIDs := projectDeleteRunIDs(body)
	if len(runIDs) == 0 {
		return
	}

	_, _ = fmt.Fprintf(os.Stderr, "project archive blocked by active runs: %s\n", strings.Join(runIDs, ", "))
}

func projectDeleteRunIDs(body map[string]any) []string {
	runIDs := stringSliceField(body, "run_ids")
	if len(runIDs) > 0 {
		return runIDs
	}

	result, ok := body["result"].(map[string]any)
	if !ok {
		return nil
	}

	return stringSliceField(result, "run_ids")
}

func stringSliceField(body map[string]any, key string) []string {
	values, ok := body[key].([]any)
	if !ok {
		return nil
	}

	items := make([]string, 0, len(values))
	for _, value := range values {
		item, ok := value.(string)
		if !ok || item == "" {
			continue
		}

		items = append(items, item)
	}

	return items
}

func sha256Hex(input string) string {
	sum := sha256.Sum256([]byte(input))
	return hex.EncodeToString(sum[:])
}
