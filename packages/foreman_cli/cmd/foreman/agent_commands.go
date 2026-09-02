package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type agentCommandArg struct {
	Name        string `json:"name"`
	Flag        string `json:"flag,omitempty"`
	Required    bool   `json:"required"`
	Description string `json:"description"`
}

type agentCommandSpec struct {
	ID          string            `json:"id"`
	DisplayName string            `json:"display_name"`
	Description string            `json:"description"`
	Kind        string            `json:"kind"`
	Workflow    string            `json:"workflow,omitempty"`
	Args        []agentCommandArg `json:"args"`
	CLI         []string          `json:"cli"`
	Tags        []string          `json:"tags"`
	Notes       []string          `json:"notes,omitempty"`
}

type agentRenderResult struct {
	Agent                     string            `json:"agent"`
	NativeInstallSupported    bool              `json:"native_install_supported"`
	UnsupportedNativeReason   string            `json:"unsupported_native_reason,omitempty"`
	RecommendedProjectDir     string            `json:"recommended_project_dir,omitempty"`
	RecommendedGlobalDir      string            `json:"recommended_global_dir,omitempty"`
	Files                     map[string]string `json:"files"`
	SkippedNativeInstallNotes []string          `json:"skipped_native_install_notes,omitempty"`
}

var defaultWorkflowSelectors = []string{
	"assess", "discover", "fix", "implement", "implement-trd", "implement-trd-beads", "plan", "prd", "release", "trd", "verify",
}

func runCommands(args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman commands: missing subcommand (inventory|generate|install|validate)", commandsUsage)
	}

	switch args[0] {
	case "inventory":
		return commandsInventory(args[1:])
	case "generate":
		return commandsGenerate(args[1:])
	case "install":
		return commandsInstall(args[1:])
	case "validate":
		return commandsValidate(args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman commands: unknown subcommand %q", args[0]), commandsUsage)
	}
}

const commandsUsage = `Usage:
  foreman commands inventory [--json]
  foreman commands generate --agent <claude|pi|omp|codex|opencode|all> [--output <dir>]
  foreman commands install --agent <claude|pi|omp|codex|opencode> [--scope project|global] [--target <dir>] [--force] [--dry-run]
  foreman commands validate

Generated agent assets are thin wrappers over real foreman CLI verbs. Claude Code
has a verified project-local install path. Pi/OMP, Codex, and OpenCode default to
generate-only output unless this CLI can prove a native command-file contract.
`

func commandsInventory(args []string) error {
	fs := newFlagSet("commands inventory")
	jsonOut := fs.Bool("json", false, "Print JSON inventory")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman commands inventory: expected no positional arguments")
	}

	specs := buildAgentCommandInventory(defaultWorkflowSelectors)
	if err := validateAgentCommandSpecs(specs); err != nil {
		return err
	}
	if *jsonOut {
		return printJSON(specs)
	}
	for _, spec := range specs {
		fmt.Printf("%s\t%s\t%s\n", spec.ID, strings.Join(spec.CLI, " "), spec.Description)
	}
	return nil
}

func commandsGenerate(args []string) error {
	fs := newFlagSet("commands generate")
	agent := fs.String("agent", "", "Target agent: claude, pi, omp, codex, opencode, all")
	output := fs.String("output", "", "Write generated files under this directory instead of printing JSON")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman commands generate: expected no positional arguments")
	}
	if *agent == "" {
		return usageError(fs, "foreman commands generate: --agent is required")
	}

	results, err := renderForAgents(*agent)
	if err != nil {
		return err
	}
	if *output == "" {
		return printJSON(results)
	}
	for _, result := range results {
		for rel, body := range result.Files {
			path := filepath.Join(*output, result.Agent, filepath.FromSlash(rel))
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
				return err
			}
		}
	}
	fmt.Printf("Generated Foreman command assets under %s\n", *output)
	return nil
}

func commandsInstall(args []string) error {
	fs := newFlagSet("commands install")
	agent := fs.String("agent", "", "Target agent: claude, pi, omp, codex, opencode")
	scope := fs.String("scope", "project", "Install scope: project or global")
	target := fs.String("target", "", "Explicit verified target directory")
	force := fs.Bool("force", false, "Overwrite existing files")
	dryRun := fs.Bool("dry-run", false, "Print planned writes without writing files")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman commands install: expected no positional arguments")
	}
	if *agent == "" {
		return usageError(fs, "foreman commands install: --agent is required")
	}
	if *agent == "all" {
		return usageError(fs, "foreman commands install: --agent all is not allowed for install; choose one agent")
	}
	if *scope != "project" && *scope != "global" {
		return usageError(fs, "foreman commands install: --scope must be project or global")
	}

	results, err := renderForAgents(*agent)
	if err != nil {
		return err
	}
	result := results[0]
	if !result.NativeInstallSupported {
		return fmt.Errorf("foreman commands install: native install unsupported for %s: %s; use `foreman commands generate --agent %s --output <dir>` for copyable assets", result.Agent, result.UnsupportedNativeReason, result.Agent)
	}

	dir := *target
	if dir == "" {
		if *scope == "global" {
			return fmt.Errorf("foreman commands install: --scope global requires --target with a verified global command directory")
		}
		dir = result.RecommendedProjectDir
	}
	if dir == "" {
		return fmt.Errorf("foreman commands install: no verified install directory for %s", result.Agent)
	}

	paths := make(map[string]string, len(result.Files))
	for rel, body := range result.Files {
		path := filepath.Join(dir, filepath.FromSlash(rel))
		paths[path] = body
		if strings.Contains(body, os.Getenv("FOREMAN_API_TOKEN")) && os.Getenv("FOREMAN_API_TOKEN") != "" {
			return fmt.Errorf("foreman commands install: refusing to write asset containing FOREMAN_API_TOKEN literal: %s", path)
		}
		if _, err := os.Stat(path); err == nil && !*force {
			return fmt.Errorf("foreman commands install: target exists; pass --force to overwrite: %s", path)
		} else if err != nil && !os.IsNotExist(err) {
			return err
		}
	}

	orderedPaths := make([]string, 0, len(paths))
	for path := range paths {
		orderedPaths = append(orderedPaths, path)
	}
	sort.Strings(orderedPaths)
	for _, path := range orderedPaths {
		body := paths[path]
		if *dryRun {
			fmt.Printf("Would write %s\n", path)
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			return err
		}
		fmt.Printf("Wrote %s\n", path)
	}
	return nil
}

func commandsValidate(args []string) error {
	fs := newFlagSet("commands validate")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usageError(fs, "foreman commands validate: expected no positional arguments")
	}
	specs := buildAgentCommandInventory(defaultWorkflowSelectors)
	if err := validateAgentCommandSpecs(specs); err != nil {
		return err
	}
	for _, agent := range []string{"claude", "pi", "omp", "codex", "opencode"} {
		results, err := renderForAgents(agent)
		if err != nil {
			return err
		}
		for rel, body := range results[0].Files {
			if strings.Contains(body, "{{") || strings.Contains(body, "}}") || strings.Contains(body, "<TODO") {
				return fmt.Errorf("foreman commands validate: unresolved template variable in %s/%s", agent, rel)
			}
			if strings.Contains(body, os.Getenv("FOREMAN_API_TOKEN")) && os.Getenv("FOREMAN_API_TOKEN") != "" {
				return fmt.Errorf("foreman commands validate: generated asset contains FOREMAN_API_TOKEN literal in %s/%s", agent, rel)
			}
		}
	}
	fmt.Println("Foreman command asset validation passed.")
	return nil
}

func buildAgentCommandInventory(workflows []string) []agentCommandSpec {
	selectors := append([]string(nil), workflows...)
	sort.Strings(selectors)
	specs := make([]agentCommandSpec, 0, len(selectors)+5)
	for _, workflow := range selectors {
		args := []agentCommandArg{
			{Name: "project", Flag: "--project", Required: true, Description: "Foreman project ID"},
			{Name: "title", Flag: "--title", Required: true, Description: "Task title"},
			{Name: "description", Flag: "--description", Description: "Optional task description"},
			{Name: "id", Flag: "--id", Description: "Optional task ID"},
		}
		if workflow == "implement-trd" || workflow == "implement-trd-beads" {
			args = append(args, agentCommandArg{Name: "trd-path", Flag: "--trd-path", Required: true, Description: "Project-relative TRD path"})
		}
		specs = append(specs, agentCommandSpec{
			ID:          "foreman-task-" + workflow,
			DisplayName: "Foreman task: " + workflow,
			Description: "Create a Foreman task for the " + workflow + " workflow. Task creation requires later approval.",
			Kind:        "task",
			Workflow:    workflow,
			Args:        args,
			CLI:         []string{"foreman", "task", "create", "--project", "$PROJECT", "--title", "$TITLE", "--workflow-type", workflow},
			Tags:        []string{"foreman", "task", workflow},
		})
	}
	specs = append(specs,
		agentCommandSpec{ID: "foreman-run-submit", DisplayName: "Foreman run submit", Description: "Submit an ad-hoc Foreman run in one step. Backend is a client-side selector; pi is default, codex/opencode acceptance does not prove runtime provider readiness.", Kind: "run", Args: []agentCommandArg{{Name: "project-id", Flag: "--project-id", Required: true, Description: "Foreman project ID"}, {Name: "workflow", Flag: "--workflow", Required: true, Description: "Workflow selector"}, {Name: "prompt", Flag: "--prompt", Required: true, Description: "Run prompt"}, {Name: "work-id", Flag: "--work-id", Description: "Optional caller supplied work/task ID"}, {Name: "backend", Flag: "--backend", Description: "pi, claude, codex, or opencode; runtime readiness is server/provider dependent"}, {Name: "base-branch", Flag: "--base-branch", Description: "Optional base branch passthrough"}}, CLI: []string{"foreman", "run", "submit", "--workflow", "$WORKFLOW", "--prompt", "$PROMPT", "--project-id", "$PROJECT_ID"}, Tags: []string{"foreman", "run"}},
		agentCommandSpec{ID: "foreman-run-list", DisplayName: "Foreman run list", Description: "List Foreman runs, optionally filtered by status, project ID, or limit.", Kind: "run", Args: []agentCommandArg{{Name: "status", Flag: "--status", Description: "Optional run status"}, {Name: "project-id", Flag: "--project-id", Description: "Optional project ID"}, {Name: "limit", Flag: "--limit", Description: "Optional max result count"}}, CLI: []string{"foreman", "run", "list"}, Tags: []string{"foreman", "run"}},
		agentCommandSpec{ID: "foreman-run-get", DisplayName: "Foreman run detail", Description: "Fetch one Foreman run projection by run ID.", Kind: "run", Args: []agentCommandArg{{Name: "run-id", Required: true, Description: "Run ID positional argument"}}, CLI: []string{"foreman", "run", "get", "$RUN_ID"}, Tags: []string{"foreman", "run"}},
		agentCommandSpec{ID: "foreman-task-get", DisplayName: "Foreman task detail", Description: "Fetch one Foreman task projection by task ID.", Kind: "task", Args: []agentCommandArg{{Name: "task-id", Required: true, Description: "Task ID positional argument"}}, CLI: []string{"foreman", "task", "get", "$TASK_ID"}, Tags: []string{"foreman", "task"}},
	)
	return specs
}

func validateAgentCommandSpecs(specs []agentCommandSpec) error {
	// Extract allowed flags from Go source at runtime so the validator
	// stays in sync with the actual CLI rather than drifting from a stale
	// hardcoded map. AC-014-2 (TRD-014) requires validation against
	// source or fresh build output; we parse source directly since it is
	// authoritative and does not require a separate build step.
	allowed, err := extractAllowedCLIFlags()
	if err != nil {
		return fmt.Errorf("validateAgentCommandSpecs: could not extract CLI flags from source: %w", err)
	}

	seen := map[string]bool{}
	for _, spec := range specs {
		if spec.ID == "" || seen[spec.ID] {
			return fmt.Errorf("invalid command spec id %q", spec.ID)
		}
		seen[spec.ID] = true
		if len(spec.CLI) < 3 || spec.CLI[0] != "foreman" {
			return fmt.Errorf("%s: cli must start with foreman <command> <subcommand>", spec.ID)
		}
		key := spec.CLI[1] + " " + spec.CLI[2]
		flags, ok := allowed[key]
		if !ok {
			return fmt.Errorf("%s: unsupported foreman command %s", spec.ID, key)
		}
		for _, token := range spec.CLI[3:] {
			if strings.HasPrefix(token, "--") && !flags[token] {
				return fmt.Errorf("%s: unsupported flag %s for foreman %s", spec.ID, token, key)
			}
		}
		if !containsString(spec.Tags, "foreman") || (!containsString(spec.Tags, "task") && !containsString(spec.Tags, "run")) {
			return fmt.Errorf("%s: tags must include foreman and task or run", spec.ID)
		}
	}
	return nil
}

// extractAllowedCLIFlags returns the canonical flag set for each subcommand by
// parsing packages/foreman_cli/cmd/foreman/task.go and run.go at runtime.
// This validation is a development/CI-time tool; it requires source access.
// Returns error if source cannot be found.
func extractAllowedCLIFlags() (map[string]map[string]bool, error) {
	return extractCLIFlagsFromSource()
}

// extractCLIFlagsFromSource parses packages/foreman_cli/cmd/foreman/task.go and run.go
// using go/parser and go/ast, extracting flag names from FlagSet method calls.
// This ensures validateAgentCommandSpecs validates against the real CLI contract.
// Returns error if source cannot be found.
func extractCLIFlagsFromSource() (map[string]map[string]bool, error) {
	allowed := map[string]map[string]bool{
		"task create": {},
		"task get":    {},
		"run submit":  {},
		"run list":    {},
		"run get":     {},
	}

	cliRoot, err := findCLIRoot()
	if err != nil {
		return nil, fmt.Errorf("findCLIRoot: %w (continuing with embedded contract)", err)
	}

	taskPath := filepath.Join(cliRoot, "cmd", "foreman", "task.go")
	runPath := filepath.Join(cliRoot, "cmd", "foreman", "run.go")

	// task create flags
	if err := extractFlagsFromAST(taskPath, "taskCreate", allowed["task create"]); err != nil {
		return nil, fmt.Errorf("extractFlagsFromAST task.go: %w", err)
	}

	// run submit and run list flags
	if err := extractFlagsFromAST(runPath, "runSubmit", allowed["run submit"]); err != nil {
		return nil, fmt.Errorf("extractFlagsFromAST run.go (runSubmit): %w", err)
	}
	if err := extractFlagsFromAST(runPath, "runList", allowed["run list"]); err != nil {
		return nil, fmt.Errorf("extractFlagsFromAST run.go (runList): %w", err)
	}

	return allowed, nil
}

// findCLIRoot locates the packages/foreman_cli root by walking upward from the
// running binary's own module path, then from the current working directory.
// This is stable at runtime and does not depend solely on cwd.
func findCLIRoot() (string, error) {
	// Try exe-based lookup first
	exe, err := os.Executable()
	if err == nil {
		for dir := filepath.Dir(exe); dir != "." && dir != "/"; dir = filepath.Dir(dir) {
			if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
				if _, err := os.Stat(filepath.Join(dir, "cmd", "foreman")); err == nil {
					return dir, nil
				}
			}
		}
	}

	// Try cwd-based lookup
	cwd, err := os.Getwd()
	if err == nil {
		for dir := cwd; dir != "." && dir != "/"; dir = filepath.Dir(dir) {
			if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
				if _, err := os.Stat(filepath.Join(dir, "cmd", "foreman")); err == nil {
					return dir, nil
				}
			}
		}
	}
	// Last resort: FOREMAN_CLI_ROOT env var
	fallback := os.Getenv("FOREMAN_CLI_ROOT")
	if fallback != "" {
		if _, err := os.Stat(filepath.Join(fallback, "cmd", "foreman", "task.go")); err == nil {
			return fallback, nil
		}
	}

	return "", fmt.Errorf("findCLIRoot: could not locate packages/foreman_cli root (set FOREMAN_CLI_ROOT for development)")
}

// extractFlagsFromAST parses a Go source file using go/parser/go/ast and extracts
// flag names from FlagSet method calls within the named function body.
// Properly handles flags inside strings and comments (unlike regex+brace-counting).
func extractFlagsFromAST(path, functionName string, flags map[string]bool) error {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, 0)
	if err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}

	// Find the target function declaration
	var targetFunc *ast.FuncDecl
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok && fn.Name.Name == functionName {
			targetFunc = fn
			break
		}
	}

	if targetFunc == nil {
		return fmt.Errorf("function %s not found in %s", functionName, path)
	}

	// Walk the function body AST to find FlagSet method calls.
	// Look for patterns like: fs.String("flag-name", ...) or fs.Bool("flag-name", ...)
	ast.Inspect(targetFunc.Body, func(node ast.Node) bool {
		// Look for method calls: fs.String, fs.Bool, fs.Int, etc.
		if call, ok := node.(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
				// Receiver is "fs" and method is one of String, Bool, Int, etc.
				if ident, ok := sel.X.(*ast.Ident); ok && ident.Name == "fs" {
					// First argument should be a string literal containing the flag name
					if len(call.Args) > 0 {
						if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Kind == token.STRING {
							// Unquote the string literal
							flagName, err := strconv.Unquote(lit.Value)
							if err == nil && flagName != "" {
								flags["--"+flagName] = true
							}
						}
					}
				}
			}
		}
		return true
	})

	return nil
}
func renderForAgents(agent string) ([]agentRenderResult, error) {
	agents := []string{agent}
	if agent == "all" {
		agents = []string{"claude", "pi", "omp", "codex", "opencode"}
	}
	var results []agentRenderResult
	for _, a := range agents {
		switch a {
		case "claude", "pi", "omp", "codex", "opencode":
			results = append(results, renderAgentCommands(a, buildAgentCommandInventory(defaultWorkflowSelectors)))
		default:
			return nil, fmt.Errorf("unsupported agent %q", a)
		}
	}
	return results, nil
}

func renderAgentCommands(agent string, specs []agentCommandSpec) agentRenderResult {
	result := agentRenderResult{Agent: agent, Files: map[string]string{}}
	switch agent {
	case "claude":
		result.NativeInstallSupported = true
		result.RecommendedProjectDir = ".claude/commands/foreman"
	case "pi", "omp":
		result.UnsupportedNativeReason = "Pi/OMP native command-file path and format are not verified by Foreman; generated Markdown is copyable only."
	case "codex":
		result.UnsupportedNativeReason = "Codex native command-file contract is unverified; generated Markdown is copyable only."
	case "opencode":
		result.UnsupportedNativeReason = "OpenCode native command-file contract is unverified; generated Markdown is copyable only."
	}
	if !result.NativeInstallSupported {
		result.SkippedNativeInstallNotes = []string{result.UnsupportedNativeReason}
	}
	for _, spec := range specs {
		result.Files[spec.ID+".md"] = renderCommandMarkdown(agent, spec)
	}
	return result
}

func renderCommandMarkdown(agent string, spec agentCommandSpec) string {
	var b bytes.Buffer
	fmt.Fprintf(&b, "---\nname: %s\ndescription: %s\nagent: %s\ntags: %s\n---\n\n", spec.ID, spec.Description, agent, strings.Join(spec.Tags, ","))
	fmt.Fprintf(&b, "# %s\n\n%s\n\n", spec.DisplayName, spec.Description)
	fmt.Fprintf(&b, "Thin wrapper over `%s`. Inherits FOREMAN_API_URL and FOREMAN_API_TOKEN; no secrets are embedded.\n\n", strings.Join(spec.CLI, " "))
	fmt.Fprintln(&b, "## Arguments")
	for _, arg := range spec.Args {
		req := "optional"
		if arg.Required {
			req = "required"
		}
		name := arg.Name
		if arg.Flag != "" {
			name = arg.Flag
		}
		fmt.Fprintf(&b, "- `%s` (%s): %s\n", name, req, arg.Description)
	}
	fmt.Fprintln(&b, "\n## Command body")
	fmt.Fprintln(&b, "```bash")
	fmt.Fprint(&b, shellBodyForSpec(spec))
	fmt.Fprintln(&b, "```")
	if len(spec.Notes) > 0 {
		fmt.Fprintln(&b, "\n## Notes")
		for _, note := range spec.Notes {
			fmt.Fprintf(&b, "- %s\n", note)
		}
	}
	return b.String()
}

func shellBodyForSpec(spec agentCommandSpec) string {
	var b bytes.Buffer
	fmt.Fprintln(&b, "set -euo pipefail")
	for _, arg := range spec.Args {
		if !arg.Required {
			continue
		}
		varName := envName(arg.Name)
		fmt.Fprintf(&b, ": \"${%s:?missing required %s}\"\n", varName, arg.Name)
	}
	switch spec.ID {
	case "foreman-run-list":
		fmt.Fprintln(&b, "args=(foreman run list)")
		fmt.Fprintln(&b, "[ -n \"${STATUS:-}\" ] && args+=(--status \"$STATUS\")")
		fmt.Fprintln(&b, "[ -n \"${PROJECT_ID:-}\" ] && args+=(--project-id \"$PROJECT_ID\")")
		fmt.Fprintln(&b, "[ -n \"${LIMIT:-}\" ] && args+=(--limit \"$LIMIT\")")
	case "foreman-run-get":
		fmt.Fprintln(&b, "args=(foreman run get \"$RUN_ID\")")
	case "foreman-task-get":
		fmt.Fprintln(&b, "args=(foreman task get \"$TASK_ID\")")
	case "foreman-run-submit":
		fmt.Fprintln(&b, "args=(foreman run submit --workflow \"$WORKFLOW\" --prompt \"$PROMPT\" --project-id \"$PROJECT_ID\")")
		fmt.Fprintln(&b, "[ -n \"${WORK_ID:-}\" ] && args+=(--work-id \"$WORK_ID\")")
		fmt.Fprintln(&b, "[ -n \"${BACKEND:-}\" ] && args+=(--backend \"$BACKEND\")")
		fmt.Fprintln(&b, "[ -n \"${BASE_BRANCH:-}\" ] && args+=(--base-branch \"$BASE_BRANCH\")")
	default:
		fmt.Fprintf(&b, "args=(foreman task create --project \"$PROJECT\" --title \"$TITLE\" --workflow-type %q)\n", spec.Workflow)
		fmt.Fprintln(&b, "[ -n \"${DESCRIPTION:-}\" ] && args+=(--description \"$DESCRIPTION\")")
		fmt.Fprintln(&b, "[ -n \"${ID:-}\" ] && args+=(--id \"$ID\")")
		if spec.Workflow == "implement-trd" || spec.Workflow == "implement-trd-beads" {
			fmt.Fprintln(&b, "args+=(--trd-path \"$TRD_PATH\")")
		}
	}
	fmt.Fprintln(&b, "exec \"${args[@]}\"")
	return b.String()
}

func envName(name string) string {
	return strings.ToUpper(strings.ReplaceAll(name, "-", "_"))
}

func containsString(items []string, want string) bool {
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}

func marshalJSON(v any) string {
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}
