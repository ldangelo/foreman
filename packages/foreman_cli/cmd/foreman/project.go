package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
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
const projectUsageText = "Usage:\n  foreman project create [flags]\n  foreman project get [--format=json] <id>\n  foreman project update [flags] <id>   (settings flags: --goal --instructions --instructions-file --thread-model --thread-effort --coordinator-provider --coordinator-model --coordinator-effort --max-concurrent-runs --daily-thread-cap --clear <setting>; provider flags: --task-provider --task-provider-database-path)\n  foreman project settings [--format=json] <id>\n  foreman project recommend [--format=json] [--fail-on warn|action] <id>\n  foreman project adopt --kind run|jobsite|task --id ID (--into PROJECT | --new-project [--project-id X --path P --goal G]) [--continue --prompt TEXT] [--format=json]\n  foreman project pause [--reason=<text>] [--idempotency-key=<key>] <id>\n  foreman project resume [--idempotency-key=<key>] <id>\n  foreman project reactivate [--idempotency-key=<key>] <id>\n  foreman project delete [--force] [--idempotency-key=<key>] <id>   (soft delete = archive)\n  foreman project list [--include-archived] [--format=json|ndjson]\n  foreman project memory list|read|write|forget|sync [flags] <project-id>\n  foreman project schedule list|create|pause|resume|delete --project-id <id> ...   (scheduled tasks; see `foreman project schedule`)"

// runProject dispatches `foreman project <subcommand>`.
func runProject(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman project: missing subcommand (create|get|update|settings|pause|resume|reactivate|delete|list|recommend|adopt|memory|schedule)",
			projectUsageText,
		)
	}

	switch args[0] {
	case "create":
		return projectCreate(c, args[1:])
	case "get":
		return projectGet(c, args[1:])
	case "update":
		return projectUpdate(c, args[1:])
	case "settings":
		return projectSettings(c, args[1:])
	case "pause":
		return projectPause(c, args[1:])
	case "resume":
		return projectLifecycle(c, "project resume", "project.resume", "resumed", args[1:])
	case "reactivate":
		return projectLifecycle(c, "project reactivate", "project.reactivate", "reactivated", args[1:])
	case "delete":
		return projectDelete(c, args[1:])
	case "list":
		return projectList(c, args[1:])
	case "recommend":
		return projectRecommend(c, args[1:])
	case "adopt":
		return projectAdopt(c, args[1:])
	case "memory":
		return projectMemory(c, args[1:])
	case "schedule":
		return projectSchedule(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman project: unknown subcommand %q", args[0]),
			projectUsageText,
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

// repeatedFlag collects every occurrence of a repeatable string flag.
type repeatedFlag []string

func (r *repeatedFlag) String() string { return strings.Join(*r, ",") }

func (r *repeatedFlag) Set(v string) error {
	*r = append(*r, v)
	return nil
}

func projectUpdate(c *client.Client, args []string) error {
	fs := newFlagSet("project update")
	taskProvider := fs.String("task-provider", "", "Task provider (required only when changing provider)")
	taskProviderDatabasePath := fs.String("task-provider-database-path", "", "Task provider database path (required for beads)")
	goal := fs.String("goal", "", "Project goal")
	instructions := fs.String("instructions", "", "Project instructions (mutually exclusive with --instructions-file)")
	instructionsFile := fs.String("instructions-file", "", "Read project instructions from this file (mutually exclusive with --instructions)")
	threadModel := fs.String("thread-model", "", "Default thread model")
	threadEffort := fs.String("thread-effort", "", "Default thread effort (low|medium|high)")
	coordinatorProvider := fs.String("coordinator-provider", "", "Coordinator provider (pi|claude)")
	coordinatorModel := fs.String("coordinator-model", "", "Coordinator model")
	coordinatorEffort := fs.String("coordinator-effort", "", "Coordinator effort (low|medium|high)")
	maxConcurrentRuns := fs.Int("max-concurrent-runs", 0, "Maximum concurrent runs")
	dailyThreadCap := fs.Int("daily-thread-cap", 0, "Maximum threads started per day")
	var clear repeatedFlag
	fs.Var(&clear, "clear", "Clear a setting back to its default (repeatable)")
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	format := fs.String("format", "", "Output format (json)")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project update:\n  foreman project update [flags] <id>\n\nUpdate project settings and/or task provider. At least one change flag is required.\nThe server validates values and its errors are shown verbatim.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman project update: expected one argument: <project-id>")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project update: unsupported format %q", *format)
	}

	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	if set["instructions"] && set["instructions-file"] {
		return usageError(fs, "foreman project update: --instructions and --instructions-file are mutually exclusive")
	}

	payload := map[string]any{"project_id": fs.Arg(0)}
	changes := 0

	if set["task-provider-database-path"] && *taskProvider == "" {
		return usageError(fs, "foreman project update: --task-provider-database-path requires --task-provider")
	}
	if *taskProvider != "" {
		if err := validateTaskProviderConfig(fs, *taskProvider, *taskProviderDatabasePath, "foreman project update"); err != nil {
			return err
		}
		payload["task_provider"] = taskProviderPayload(*taskProvider, *taskProviderDatabasePath)
		changes++
	}

	for name, value := range map[string]*string{
		"goal":                 goal,
		"instructions":         instructions,
		"thread_model":         threadModel,
		"thread_effort":        threadEffort,
		"coordinator_provider": coordinatorProvider,
		"coordinator_model":    coordinatorModel,
		"coordinator_effort":   coordinatorEffort,
	} {
		if set[strings.ReplaceAll(name, "_", "-")] {
			payload[name] = *value
			changes++
		}
	}
	if set["instructions-file"] {
		data, err := os.ReadFile(*instructionsFile)
		if err != nil {
			return fmt.Errorf("foreman project update: read --instructions-file: %w", err)
		}
		payload["instructions"] = string(data)
		changes++
	}
	if set["max-concurrent-runs"] {
		payload["max_concurrent_runs"] = *maxConcurrentRuns
		changes++
	}
	if set["daily-thread-cap"] {
		payload["daily_thread_cap"] = *dailyThreadCap
		changes++
	}
	if len(clear) > 0 {
		payload["cleared_settings"] = []string(clear)
		changes++
	}

	if changes == 0 {
		return usageError(fs, "foreman project update: at least one change flag is required")
	}

	projectID := fs.Arg(0)
	body := commandEnvelope{
		Type:      "project.update",
		CommandID: projectUpdateCommandID(payload, *idempotencyKey),
		Payload:   payload,
	}

	out, err := postCommandWithResponse(c, body)
	if err != nil {
		return err
	}

	switch *format {
	case "":
		summary := "updated project " + projectID
		if *taskProvider != "" {
			summary += " with task provider " + *taskProvider
		}
		_, err = fmt.Fprintln(os.Stdout, summary)
		return err
	case "json":
		return printJSON(out)
	default:
		panic("projectUpdate format validated before POST")
	}
}

func projectPause(c *client.Client, args []string) error {
	fs := newFlagSet("project pause")
	reason := fs.String("reason", "", "Reason recorded with the pause")
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project pause:\n  foreman project pause [--reason=<text>] [--idempotency-key=<key>] <id>\n\nPause a project: new tasks and run reservations are refused until `foreman project resume <id>`.\n\nFlags:\n")
		fs.PrintDefaults()
	}
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project pause: expected one argument: <project-id>")
	}

	projectID := fs.Arg(0)
	payload := map[string]any{"project_id": projectID}
	seed := "project.pause." + projectID
	if *reason != "" {
		payload["reason"] = *reason
		seed += "." + *reason
	}
	commandID := sha256Hex(seed)
	if *idempotencyKey != "" {
		commandID = sha256Hex("project.pause." + *idempotencyKey)
	}

	if _, err := postCommandWithResponse(c, commandEnvelope{Type: "project.pause", CommandID: commandID, Payload: payload}); err != nil {
		return err
	}

	_, err := fmt.Fprintf(os.Stdout, "paused project %s; resume with `foreman project resume %s`\n", projectID, projectID)
	return err
}

func projectLifecycle(c *client.Client, name, commandType, verb string, args []string) error {
	fs := newFlagSet(name)
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman %s: expected one argument: <project-id>", name)
	}

	projectID := fs.Arg(0)
	commandID := sha256Hex(commandType + "." + projectID)
	if *idempotencyKey != "" {
		commandID = sha256Hex(commandType + "." + *idempotencyKey)
	}

	body := commandEnvelope{Type: commandType, CommandID: commandID, Payload: map[string]any{"project_id": projectID}}
	if _, err := postCommandWithResponse(c, body); err != nil {
		return err
	}

	_, err := fmt.Fprintf(os.Stdout, "%s project %s\n", verb, projectID)
	return err
}

func projectSettings(c *client.Client, args []string) error {
	fs := newFlagSet("project settings")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project settings: expected one argument: <project-id>")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project settings: unsupported format %q", *format)
	}

	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/projects", fs.Arg(0), "settings"), &out); err != nil {
		return err
	}
	if *format == "json" {
		return printJSON(out)
	}

	return printProjectSettings(out)
}

var projectSettingNames = []string{
	"goal", "instructions", "thread_model", "thread_effort",
	"coordinator_provider", "coordinator_model", "coordinator_effort",
	"max_concurrent_runs", "daily_thread_cap",
}

var projectLimitNames = []string{
	"max_concurrent_runs", "active_runs", "daily_thread_cap", "threads_started_today",
	"remaining_today", "cap_reached?", "resets_at", "deferred_tasks", "deferred_today",
}

func printProjectSettings(out map[string]any) error {
	fmt.Printf("project: %s\n", projectStringField(out, "project_id"))
	fmt.Printf("status: %s\n", projectStringField(out, "status"))

	settings, _ := out["settings"].(map[string]any)
	fmt.Println("settings:")
	for _, name := range projectSettingNames {
		fmt.Printf("  %s: %s\n", name, projectSettingValue(settings[name]))
	}

	limits, _ := out["limits"].(map[string]any)
	fmt.Println("limits:")
	for _, name := range projectLimitNames {
		fmt.Printf("  %s: %s\n", strings.TrimSuffix(name, "?"), projectSettingValue(limits[name]))
	}

	return nil
}

func projectSettingValue(v any) string {
	switch value := v.(type) {
	case nil:
		return "(unset)"
	case string:
		if strings.Contains(value, "\n") {
			return strconv.Quote(value)
		}
		return value
	case float64:
		return strconv.FormatFloat(value, 'f', -1, 64)
	default:
		return fmt.Sprint(value)
	}
}

func projectDelete(c *client.Client, args []string) error {
	fs := newFlagSet("project delete")
	force := fs.Bool("force", false, "Print active run ids if archive is blocked")
	idempotencyKey := fs.String("idempotency-key", "", "Idempotency key")
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), "Usage of project delete:\n  foreman project delete [--force] [--idempotency-key=<key>] <id>\n\nSoft delete: archives the project; it does not purge anything. Runs, tasks and the event history are kept;\nreactivate with `foreman project reactivate <id>`. The server rejects the archive while active runs remain.\n\nFlags:\n")
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

	_, err := fmt.Fprintf(os.Stdout, "archived project %s (soft delete: runs, tasks and event history are kept); reactivate with `foreman project reactivate %s`\n", projectID, projectID)
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
	version := intField(project, "version")
	registered := projectStringField(project, "registered_at")

	// Task provider info
	taskProvider := ""
	databasePath := ""
	if tp, ok := project["task_provider"].(map[string]any); ok {
		taskProvider = projectStringField(tp, "provider")
		if cfg, ok := tp["config"].(map[string]any); ok {
			databasePath = projectStringField(cfg, "database_path")
		}
	}

	// Health
	healthOK := ""
	if health, ok := project["health"].(map[string]any); ok {
		if ok, _ := health["ok"].(bool); ok {
			healthOK = "ok"
		} else {
			healthOK = "degraded"
		}
	}

	fmt.Printf("project: %s\n", projectID)
	if status != "" {
		fmt.Printf("status: %s\n", status)
	}
	fmt.Printf("path: %s\n", path)
	fmt.Printf("version: %d\n", version)
	fmt.Printf("health: %s\n", healthOK)
	fmt.Printf("registered: %s\n", registered)
	if taskProvider != "" {
		fmt.Printf("task_provider: %s\n", taskProvider)
	}
	if databasePath != "" {
		fmt.Printf("database_path: %s\n", databasePath)
	}

	return nil
}

func intField(m map[string]any, key string) int {
	if v, ok := m[key].(float64); ok {
		return int(v)
	}
	return 0
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

// projectUpdateCommandID hashes the full payload so two different updates for
// one project are two commands while an identical retry stays idempotent.
// json.Marshal sorts map keys, so the encoding is deterministic.
func projectUpdateCommandID(payload map[string]any, idempotencyKey string) string {
	if idempotencyKey != "" {
		return sha256Hex("project.update." + idempotencyKey)
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		panic(fmt.Sprintf("project update payload is not JSON-encodable: %v", err))
	}

	return sha256Hex("project.update." + string(encoded))
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
