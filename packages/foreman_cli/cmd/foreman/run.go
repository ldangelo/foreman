package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// generateID returns a unique ID string using crypto/rand.
func generateID(prefix string) string {
	b := make([]byte, 8)
	rand.Read(b)
	return fmt.Sprintf("%s-%s", prefix, hex.EncodeToString(b))
}

var validBackends = map[string]bool{"pi": true, "claude": true, "codex": true, "opencode": true}

func runRun(c *client.Client, args []string) error {
	usage := "Usage:\n  foreman run list [--status <status>] [--project-id <id>] [--limit <n>]\n  foreman run get <id>\n  foreman run cancel --id <run-id> [--reason <reason>]\n  foreman run pause --id <run-id> [--reason <reason>]\n  foreman run resume --id <run-id>\n  foreman run remove --id <run-id>\n  foreman run reset --id <run-id>\n  foreman run approve-merge --id <run-id> --approver <name> --identity <github:login> [--repo-id <repo-id>]\n  foreman run merge --id <run-id> [--repo-id <repo-id>]\n  foreman run prs <id>\n  foreman run fix-ci <id> [--pr <url>] [--note <text>]\n  foreman run address-comments <id> [--pr <url>] [--note <text>]\n  foreman run resolve-conflicts <id> [--pr <url>] [--note <text>]\n  foreman run create-pr <id>\n  foreman run retry-pr <id> --repo-id <repo-id>\n  foreman run watch-stop <id> [--pr <url>]\n  foreman run watch-start <id> [--pr <url>]\n  foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>]"

	if len(args) == 0 {
		return usageTextError(
			"foreman run: missing subcommand (list, get, prs, cancel, pause, resume, remove, reset, approve-merge, merge, fix-ci, address-comments, resolve-conflicts, create-pr, retry-pr, watch-stop, watch-start, submit)",
			usage,
		)
	}

	switch args[0] {
	case "list":
		return runList(c, args[1:])
	case "get":
		return runGet(c, args[1:])
	case "cancel":
		return runCancel(c, args[1:])
	case "pause":
		return runPause(c, args[1:])
	case "resume":
		return runResume(c, args[1:])
	case "remove":
		return runRemove(c, args[1:])
	case "reset":
		return runReset(c, args[1:])
	case "approve-merge":
		return runApproveMerge(c, args[1:])
	case "merge":
		return runMerge(c, args[1:])
	case "prs":
		return runPrs(c, args[1:])
	case "fix-ci":
		return runPrFix(c, "fix-ci", "run.pr.fix_ci", args[1:])
	case "address-comments":
		return runPrFix(c, "address-comments", "run.pr.address_comments", args[1:])
	case "resolve-conflicts":
		return runPrFix(c, "resolve-conflicts", "run.pr.resolve_conflicts", args[1:])
	case "create-pr":
		return runCreatePr(c, args[1:])
	case "retry-pr":
		return runRetryPr(c, args[1:])
	case "watch-stop":
		return runPrWatch(c, "watch-stop", "run.pr.watch_stop", args[1:])
	case "watch-start":
		return runPrWatch(c, "watch-start", "run.pr.watch_start", args[1:])
	case "submit":
		return runSubmit(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman run: unknown subcommand %q", args[0]),
			usage,
		)
	}
}

func runList(c *client.Client, args []string) error {
	fs := newFlagSet("run list")
	status := fs.String("status", "", "Filter by run status")
	projectID := fs.String("project-id", "", "Filter by project ID")
	limit := fs.Int("limit", 0, "Maximum runs to return")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 0 {
		return usageError(fs, "foreman run list: expected no positional arguments")
	}

	values := url.Values{}
	if *status != "" {
		values.Set("status", *status)
	}
	if *projectID != "" {
		values.Set("project_id", *projectID)
	}
	if *limit < 0 {
		return usageError(fs, "foreman run list: --limit must be non-negative")
	}
	if *limit > 0 {
		values.Set("limit", fmt.Sprintf("%d", *limit))
	}

	path := client.JoinPath("/api/runs")
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}

	var out map[string]any
	err := c.GetJSON(path, &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}

func runGet(c *client.Client, args []string) error {
	fs := newFlagSet("run get")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman run get: expected one argument: <run-id>")
	}

	var out map[string]any
	err := c.GetJSON(client.JoinPath("/api/runs", fs.Arg(0)), &out)
	if err != nil {
		return err
	}

	return printJSON(out)
}

func runCancel(c *client.Client, args []string) error {
	fs := newFlagSet("run cancel")
	runID := fs.String("id", "", "Run ID (required)")
	reason := fs.String("reason", "operator_cancel", "Cancellation reason (default: operator_cancel)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run cancel: --id is required")
	}

	payload := map[string]any{
		"run_id": *runID,
		"reason": *reason,
	}

	return postCommand(c, commandEnvelope{Type: "run.cancel", Payload: payload})
}

func runPause(c *client.Client, args []string) error {
	fs := newFlagSet("run pause")
	runID := fs.String("id", "", "Run ID (required)")
	reason := fs.String("reason", "operator_pause", "Pause reason (default: operator_pause)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run pause: --id is required")
	}

	payload := map[string]any{
		"run_id": *runID,
		"reason": *reason,
	}

	return postCommand(c, commandEnvelope{Type: "run.pause", Payload: payload})
}

func runResume(c *client.Client, args []string) error {
	fs := newFlagSet("run resume")
	runID := fs.String("id", "", "Run ID (required)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run resume: --id is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.resume", Payload: map[string]any{"run_id": *runID}})
}

// runApproveMerge opens the merge gate of one PR of a run (the primary's, or the
// repository named by --repo-id). The server accepts it only from an allowlisted
// approver identity; the identity is a claim made by whoever holds the API token,
// not an authenticated login. There is no approve-all: one call, one PR.
func runApproveMerge(c *client.Client, args []string) error {
	fs := newFlagSet("run approve-merge")
	runID := fs.String("id", "", "Run ID (required)")
	approver := fs.String("approver", "", "Approver name (required)")
	identity := fs.String("identity", "", "Approver identity, e.g. github:<login> (required)")
	repoID := fs.String("repo-id", "", "Repository whose PR to approve (default: the run's primary repository)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run approve-merge: --id is required")
	}
	if *approver == "" {
		return usageError(fs, "foreman run approve-merge: --approver is required")
	}
	if *identity == "" {
		return usageError(fs, "foreman run approve-merge: --identity is required")
	}

	payload := map[string]any{
		"run_id":            *runID,
		"approver":          *approver,
		"approver_identity": *identity,
	}
	if *repoID != "" {
		payload["repo_id"] = *repoID
	}

	return postCommand(c, commandEnvelope{Type: "merge_approve", Payload: payload})
}

// runMerge squash-merges the PR of an approved run (the primary's, or the one of
// --repo-id). The server builds the whole payload itself from that repository's
// approved PrReady event, so only the run id and repository are sent.
func runMerge(c *client.Client, args []string) error {
	fs := newFlagSet("run merge")
	runID := fs.String("id", "", "Run ID (required)")
	repoID := fs.String("repo-id", "", "Repository whose PR to merge (default: the run's primary repository)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run merge: --id is required")
	}

	payload := map[string]any{"run_id": *runID}
	if *repoID != "" {
		payload["repo_id"] = *repoID
	}

	return postCommand(c, commandEnvelope{Type: "run.pr.merge", Payload: payload})
}

func runRemove(c *client.Client, args []string) error {
	fs := newFlagSet("run remove")
	runID := fs.String("id", "", "Run ID (required)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run remove: --id is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.remove", Payload: map[string]any{"run_id": *runID}})
}

func runReset(c *client.Client, args []string) error {
	fs := newFlagSet("run reset")
	runID := fs.String("id", "", "Run ID (required)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *runID == "" {
		return usageError(fs, "foreman run reset: --id is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.reset", Payload: map[string]any{"run_id": *runID}})
}

// runSubmit dispatches `foreman run submit --workflow <name> --prompt <text>
// --project-id <id> [--work-id <id>] [--backend <backend>] [--base-branch <branch>]`.
// Posts a `task.create` command envelope (provider_tracked: false,
// auto_approve: true) to /api/commands, unifying ad-hoc dispatch onto the
// task path. `--work-id` survives as an alias for the minted task_id so
// existing invocations keep working; when omitted, a `task_id` is minted
// client-side as `adhoc-<hex>` to avoid the server's no-id `task.create`
// flow, which resolves the id through the task provider and is wrong for
// an untracked task. Workflow names are validated server-side by
// `Catalog.load/1`; there is no client-side allowlist.
//
// --base-branch is captured at the protocol level only — server-side consumption
// (PlanContext derivation, plan_base_branch nil fallback, AutoPR skip-when-nil)
// is forthcoming per TRD-2026-80ba0665. When the flag is omitted the key is
// absent from the payload; when supplied, it is forwarded verbatim.
func runSubmit(c *client.Client, args []string) error {
	fs := newFlagSet("run submit")
	workID := fs.String("work-id", "", "Task ID (auto-generated if omitted)")
	projectID := fs.String("project-id", "", "Project ID (required)")
	workflow := fs.String("workflow", "", "Workflow name (required)")
	prompt := fs.String("prompt", "", "Input prompt (required)")
	backend := fs.String("backend", "pi", "Backend to use (pi, claude, codex, opencode; default: pi)")
	baseBranch := fs.String("base-branch", "",
		"Parent branch for the new task's worktree and PR. Protocol-level capture only; server-side consumption forthcoming per TRD-2026-80ba0665.")

	if err := fs.parse(args); err != nil {
		return err
	}

	if *projectID == "" {
		return usageError(fs, "foreman run submit: --project-id is required")
	}
	if *workflow == "" {
		return usageError(fs, "foreman run submit: --workflow is required")
	}
	if *prompt == "" {
		return usageError(fs, "foreman run submit: --prompt is required")
	}
	if !validBackends[*backend] {
		return usageError(fs,
			"foreman run submit: --backend must be one of: pi, claude, codex, opencode (got %s)",
			*backend)
	}

	taskID := *workID
	if taskID == "" {
		taskID = generateID("adhoc")
	}

	title := strings.SplitN(*prompt, "\n", 2)[0]
	if runes := []rune(title); len(runes) > 72 {
		title = string(runes[:72])
	}

	// Build payload; omit backend when it's the default "pi" per TRD-002.
	// Omit base_branch when empty so the server can apply its forthcoming
	// default resolution (operator's current checkout HEAD per
	// TRD-2026-80ba0665).
	payload := map[string]any{
		"task_id":          taskID,
		"project_id":       *projectID,
		"task_type":        "task",
		"workflow_type":    *workflow,
		"prompt":           *prompt,
		"title":            title,
		"provider_tracked": false,
		"auto_approve":     true,
	}
	if *backend != "pi" {
		payload["backend"] = *backend
	}
	if *baseBranch != "" {
		payload["base_branch"] = *baseBranch
	}

	return postCommand(c, commandEnvelope{Type: "task.create", Payload: payload})
}

// prRunID splits a leading positional run id (`foreman run fix-ci <id> --pr ...`)
// from the flags, because the flag parser stops at the first positional. The
// `--id` flag used by the other run verbs still works when no positional is given.
func prRunID(args []string) (string, []string) {
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		return args[0], args[1:]
	}
	return "", args
}

// runPrs lists the watched PRs of a run: `foreman run prs <id>`.
func runPrs(c *client.Client, args []string) error {
	fs := newFlagSet("run prs")
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 1 {
		return usageError(fs, "foreman run prs: expected one argument: <run-id>")
	}

	var out map[string]any
	if err := c.GetJSON(client.JoinPath("/api/runs", fs.Arg(0), "prs"), &out); err != nil {
		return err
	}

	return printJSON(out)
}

// runPrFix requests a fix thread for a watched PR. The server decides everything
// else (head SHA, attempt, caps); the CLI sends only the run, the optional PR and
// the optional operator note.
func runPrFix(c *client.Client, verb, commandType string, args []string) error {
	fs := newFlagSet("run " + verb)
	runID := fs.String("id", "", "Run ID (or pass it as the first argument)")
	prURL := fs.String("pr", "", "PR URL (optional while the run watches exactly one PR)")
	note := fs.String("note", "", "Extra guidance for the fix thread (max 2000 characters)")

	positional, rest := prRunID(args)
	if err := fs.parse(rest); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return usageError(fs, "foreman run %s: unexpected argument %q (use --pr <url> to select a PR)", verb, fs.Arg(0))
	}
	if positional != "" {
		*runID = positional
	}

	if *runID == "" {
		return usageError(fs, "foreman run %s: <run-id> is required", verb)
	}

	payload := map[string]any{"run_id": *runID}
	if *prURL != "" {
		payload["pr_url"] = *prURL
	}
	if *note != "" {
		payload["note"] = *note
	}

	return postCommand(c, commandEnvelope{Type: commandType, Payload: payload})
}

// runCreatePr opens a PR for a finished run that pushed a branch but has none. The
// server derives the head and base branches; only the run id is sent.
func runCreatePr(c *client.Client, args []string) error {
	fs := newFlagSet("run create-pr")
	runID := fs.String("id", "", "Run ID (or pass it as the first argument)")

	positional, rest := prRunID(args)
	if err := fs.parse(rest); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return usageError(fs, "foreman run create-pr: unexpected argument %q", fs.Arg(0))
	}
	if positional != "" {
		*runID = positional
	}

	if *runID == "" {
		return usageError(fs, "foreman run create-pr: <run-id> is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.pr.create", Payload: map[string]any{"run_id": *runID}})
}

// runRetryPr re-opens the PR of one repository of a multi-repository run whose PR
// could not be created, from the worktree preserved for it. Idempotent.
func runRetryPr(c *client.Client, args []string) error {
	fs := newFlagSet("run retry-pr")
	runID := fs.String("id", "", "Run ID (or pass it as the first argument)")
	repoID := fs.String("repo-id", "", "Repository whose PR to open (required)")

	positional, rest := prRunID(args)
	if err := fs.parse(rest); err != nil {
		return err
	}
	if positional != "" {
		*runID = positional
	}

	if *runID == "" {
		return usageError(fs, "foreman run retry-pr: <run-id> is required")
	}
	if *repoID == "" {
		return usageError(fs, "foreman run retry-pr: --repo-id is required")
	}

	return postCommand(c, commandEnvelope{Type: "run.pr.retry", Payload: map[string]any{"run_id": *runID, "repo_id": *repoID}})
}

// runPrWatch stops or restarts watching one PR of a run.
func runPrWatch(c *client.Client, verb, commandType string, args []string) error {
	fs := newFlagSet("run " + verb)
	runID := fs.String("id", "", "Run ID (or pass it as the first argument)")
	prURL := fs.String("pr", "", "PR URL (required when the run watches several PRs)")

	positional, rest := prRunID(args)
	if err := fs.parse(rest); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return usageError(fs, "foreman run %s: unexpected argument %q (use --pr <url> to select a PR)", verb, fs.Arg(0))
	}
	if positional != "" {
		*runID = positional
	}

	if *runID == "" {
		return usageError(fs, "foreman run %s: <run-id> is required", verb)
	}

	payload := map[string]any{"run_id": *runID}
	if *prURL != "" {
		payload["pr_url"] = *prURL
	}

	return postCommand(c, commandEnvelope{Type: commandType, Payload: payload})
}
