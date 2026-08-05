package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func runWorkflow(c *client.Client, args []string) error {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "foreman workflow: missing subcommand (install)")
		os.Exit(2)
	}

	switch args[0] {
	case "install":
		return workflowInstall(c, args[1:])
	default:
		fmt.Fprintf(os.Stderr, "foreman workflow: unknown subcommand %q\n", args[0])
		os.Exit(2)
		return nil
	}
}

// workflowInstall sends a POST /api/admin/workflows/install request
// with the keyword options the server's WorkflowTemplate.Installer
// understands. The body is NOT a manifest string — the installer
// consumes `:source_dir` / `:target_dir` / `:remote_url` plus retry
// knobs. See WorkflowInstallController for the canonical mapping.
func workflowInstall(c *client.Client, args []string) error {
	fs := flag.NewFlagSet("workflow install", flag.ExitOnError)
	targetDir := fs.String("target", "", "Target directory (required)")
	sourceDir := fs.String("source", "", "Source directory of workflow assets")
	remoteURL := fs.String("remote", "", "Remote URL of the workflow bundle")
	retryAttempts := fs.Int("retries", 3, "Retry attempts for remote installs")
	retryDelay := fs.Int("retry-delay-ms", 250, "Delay between retries (ms)")
	_ = fs.Parse(args)

	if *targetDir == "" {
		fmt.Fprintln(os.Stderr, "foreman workflow install: --target is required")
		fs.Usage()
		os.Exit(2)
	}

	if *sourceDir == "" && *remoteURL == "" {
		fmt.Fprintln(os.Stderr, "foreman workflow install: --source or --remote is required")
		fs.Usage()
		os.Exit(2)
	}

	abs, err := filepath.Abs(*targetDir)
	if err != nil {
		return fmt.Errorf("foreman workflow install: resolve target: %w", err)
	}

	opts := map[string]any{
		"target_dir":     abs,
		"retry_attempts": *retryAttempts,
		"retry_delay_ms": *retryDelay,
	}

	if *sourceDir != "" {
		absSrc, err := filepath.Abs(*sourceDir)
		if err != nil {
			return fmt.Errorf("foreman workflow install: resolve source: %w", err)
		}

		opts["source_dir"] = absSrc
	}

	if *remoteURL != "" {
		opts["remote_url"] = *remoteURL
	}

	var out map[string]any
	if err := c.PostJSON("/api/admin/workflows/install", opts, &out); err != nil {
		return err
	}

	return printJSON(out)
}
