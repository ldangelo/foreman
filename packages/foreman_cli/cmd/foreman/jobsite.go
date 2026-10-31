package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const jobsiteUsage = `Usage:
  foreman jobsite template --project-id <id> --prompt <text> [--name <name>] [--provider claude|pi] [--model <model>]
                           [--iterations <n>] [--signal <text>] [--branch <name>] [--sandbox docker|host]
                           [--push[=false]] [--dir <dir>] [--format json]`

func runJobsite(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman jobsite: missing subcommand (template)", jobsiteUsage)
	}

	switch args[0] {
	case "template":
		return jobsiteTemplate(c, args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman jobsite: unknown subcommand %q", args[0]), jobsiteUsage)
	}
}

// jobsiteTemplateRequest is the POST /api/jobsites/template body. Every field
// except project_id and prompt is a pointer so that a flag the user did not set
// is omitted instead of being sent as a zero value.
type jobsiteTemplateRequest struct {
	ProjectID        string           `json:"project_id"`
	Prompt           string           `json:"prompt"`
	Name             *string          `json:"name,omitempty"`
	Agent            *jobsiteAgent    `json:"agent,omitempty"`
	MaxIterations    *int             `json:"max_iterations,omitempty"`
	CompletionSignal *string          `json:"completion_signal,omitempty"`
	Strategy         *jobsiteStrategy `json:"strategy,omitempty"`
	Sandbox          *string          `json:"sandbox,omitempty"`
	Push             *bool            `json:"push,omitempty"`
}

type jobsiteAgent struct {
	Provider *string `json:"provider,omitempty"`
	Model    *string `json:"model,omitempty"`
}

type jobsiteStrategy struct {
	Branch string `json:"branch"`
}

type jobsiteTemplateFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

type jobsiteTemplateResponse struct {
	Name     string                `json:"name"`
	Files    []jobsiteTemplateFile `json:"files"`
	Spec     json.RawMessage       `json:"spec"`
	Features []string              `json:"features"`
	Notes    []string              `json:"notes"`
}

type jobsiteTemplateResult struct {
	Name     string          `json:"name"`
	Written  []string        `json:"written"`
	Skipped  []string        `json:"skipped"`
	Features []string        `json:"features"`
	Notes    []string        `json:"notes"`
	Spec     json.RawMessage `json:"spec"`
}

func jobsiteTemplate(c *client.Client, args []string) error {
	fs := newFlagSet("jobsite template")
	projectID := fs.String("project-id", "", "Registered project the spec is validated against (required)")
	prompt := fs.String("prompt", "", "Natural-language description of the jobsite (required)")
	name := fs.String("name", "", "Template name (file names and default branch derive from it)")
	provider := fs.String("provider", "", "Agent provider: claude or pi (no default)")
	model := fs.String("model", "", "Agent model")
	iterations := fs.Int("iterations", 0, "Maximum loop iterations (max_iterations)")
	signal := fs.String("signal", "", "Completion signal (completion_signal)")
	branch := fs.String("branch", "", "Strategy branch name")
	sandbox := fs.String("sandbox", "", "Sandbox: docker or host")
	push := fs.Bool("push", false, "Push the branch to origin (--push=false to forbid)")
	dir := fs.String("dir", ".", "Directory that receives .foreman/")
	format := fs.String("format", "", `Output format: "" (text) or json`)
	if err := fs.parse(args); err != nil {
		return err
	}

	if fs.NArg() != 0 {
		return usageError(fs, "foreman jobsite template: expected no positional arguments")
	}
	if *projectID == "" {
		return usageError(fs, "foreman jobsite template: --project-id is required")
	}
	if *prompt == "" {
		return usageError(fs, "foreman jobsite template: --prompt is required")
	}
	if *format != "" && *format != "json" {
		return usageError(fs, "foreman jobsite template: --format must be json (or omitted for text), got %q", *format)
	}

	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	req := jobsiteTemplateRequest{ProjectID: *projectID, Prompt: *prompt}
	if set["name"] {
		req.Name = name
	}
	if set["provider"] || set["model"] {
		req.Agent = &jobsiteAgent{}
		if set["provider"] {
			req.Agent.Provider = provider
		}
		if set["model"] {
			req.Agent.Model = model
		}
	}
	if set["iterations"] {
		req.MaxIterations = iterations
	}
	if set["signal"] {
		req.CompletionSignal = signal
	}
	if set["branch"] {
		req.Strategy = &jobsiteStrategy{Branch: *branch}
	}
	if set["sandbox"] {
		req.Sandbox = sandbox
	}
	if set["push"] {
		req.Push = push
	}

	var resp jobsiteTemplateResponse
	if err := c.PostJSON("/api/jobsites/template", req, &resp); err != nil {
		return err
	}

	if err := validateTemplatePaths(resp.Files); err != nil {
		return err
	}

	result := jobsiteTemplateResult{
		Name:     resp.Name,
		Written:  []string{},
		Skipped:  []string{},
		Features: nonNilStrings(resp.Features),
		Notes:    nonNilStrings(resp.Notes),
		Spec:     resp.Spec,
	}

	root := filepath.Join(*dir, ".foreman")
	script := ""
	for _, file := range resp.Files {
		dest := filepath.Join(root, file.Path)
		if script == "" && strings.HasSuffix(file.Path, ".exs") {
			script = dest
		}

		created, err := writeNewFile(dest, file.Content)
		if err != nil {
			return err
		}
		if created {
			result.Written = append(result.Written, dest)
		} else {
			result.Skipped = append(result.Skipped, dest)
		}
	}

	if *format == "json" {
		return printJSON(result)
	}

	printJobsiteTemplateText(result, script, *projectID)
	return nil
}

func printJobsiteTemplateText(result jobsiteTemplateResult, script, projectID string) {
	for _, path := range result.Written {
		fmt.Printf("wrote %s\n", path)
	}
	for _, path := range result.Skipped {
		fmt.Printf("kept %s (already exists; not overwritten)\n", path)
	}

	if len(result.Features) == 0 {
		fmt.Println("features read from the prompt: none")
	} else {
		fmt.Printf("features read from the prompt: %s\n", strings.Join(result.Features, ", "))
	}

	if len(result.Notes) > 0 {
		fmt.Println("notes:")
		for _, note := range result.Notes {
			fmt.Printf("  * %s\n", note)
		}
	}

	if script != "" {
		fmt.Printf("next: FOREMAN_API_TOKEN=... FOREMAN_PROJECT_ID=%s elixir %s\n", projectID, script)
	}
}

// validateTemplatePaths rejects the whole response before anything is written
// when it carries no files or any path that is empty, contains a NUL byte,
// is not a local relative path (absolute, or escaping via ".."), or repeats.
func validateTemplatePaths(files []jobsiteTemplateFile) error {
	if len(files) == 0 {
		return errors.New("foreman: server returned no files; nothing written")
	}

	seen := make(map[string]bool, len(files))
	for _, file := range files {
		switch {
		case file.Path == "":
			return errors.New("foreman: server returned a file with an empty path; nothing written")
		case strings.ContainsRune(file.Path, 0):
			return fmt.Errorf("foreman: server returned a path containing a NUL byte (%q); nothing written", file.Path)
		case !filepath.IsLocal(file.Path):
			return fmt.Errorf("foreman: server returned a path outside .foreman/ (%q); nothing written", file.Path)
		}

		clean := filepath.Clean(file.Path)
		if seen[clean] {
			return fmt.Errorf("foreman: server returned duplicate path %q; nothing written", file.Path)
		}
		seen[clean] = true
	}

	return nil
}

// writeNewFile creates dest with 0o644 and writes content, never replacing an
// existing entry. O_EXCL also refuses to follow an existing (or dangling)
// symlink. It reports created=false, with no error, when dest already exists.
func writeNewFile(dest, content string) (created bool, err error) {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return false, fmt.Errorf("foreman: create directory for %s: %w", dest, err)
	}

	f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return false, nil
		}
		return false, fmt.Errorf("foreman: create %s: %w", dest, err)
	}

	if _, err := f.WriteString(content); err != nil {
		f.Close()
		return false, fmt.Errorf("foreman: write %s: %w", dest, err)
	}
	if err := f.Close(); err != nil {
		return false, fmt.Errorf("foreman: close %s: %w", dest, err)
	}

	return true, nil
}

func nonNilStrings(in []string) []string {
	if in == nil {
		return []string{}
	}
	return in
}
