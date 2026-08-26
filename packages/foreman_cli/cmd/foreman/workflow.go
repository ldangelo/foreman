package main

import (
	"fmt"
	"path/filepath"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

func runWorkflow(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError(
			"foreman workflow: missing subcommand (install)",
			"Usage:\n  foreman workflow install [flags]",
		)
	}

	switch args[0] {
	case "install":
		return workflowInstall(c, args[1:])
	case "remove":
		return workflowRemove(c, args[1:])
	default:
		return usageTextError(
			fmt.Sprintf("foreman workflow: unknown subcommand %q", args[0]),
			"Usage:\n  foreman workflow [install|remove] [flags]",
		)
	}
}

// workflowInstall sends a POST /api/admin/workflows/install request
// with the keyword options the server's WorkflowTemplate.Installer
// understands. The body is NOT a manifest string — the installer
// consumes `:source_dir` / `:target_dir` / `:remote_url` plus retry
// knobs. See WorkflowInstallController for the canonical mapping.
func workflowInstall(c *client.Client, args []string) error {
	fs := newFlagSet("workflow install")
	targetDir := fs.String("target", "", "Target directory (required)")
	sourceDir := fs.String("source", "", "Source directory of workflow assets")
	remoteURL := fs.String("remote", "", "Remote URL of the workflow bundle")
	retryAttempts := fs.Int("retries", 3, "Retry attempts for remote installs")
	retryDelay := fs.Int("retry-delay-ms", 250, "Delay between retries (ms)")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *targetDir == "" {
		return usageError(fs, "foreman workflow install: --target is required")
	}

	if *sourceDir == "" && *remoteURL == "" {
		return usageError(fs, "foreman workflow install: --source or --remote is required")
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

// workflowRemove calls POST /api/admin/workflows/remove with {"remove_all": true}
// after interactive confirmation from the operator.
func workflowRemove(c *client.Client, args []string) error {
	fs := newFlagSet("workflow remove")
	removeAll := fs.Bool("all", false, "Confirm removal of all legacy workflows")
	if err := fs.parse(args); err != nil {
		return err
	}

	if !*removeAll {
		return usageError(fs, "foreman workflow remove: --all flag is required")
	}

	fmt.Print("Remove legacy workflows (discover, assess, implement, verify, release)? [y/N] ")
	var response string
	fmt.Scanln(&response)
	if response != "y" && response != "Y" {
		fmt.Println("Aborted.")
		return nil
	}

	opts := map[string]any{"remove_all": true}
	var out map[string]any
	if err := c.PostJSON("/api/admin/workflows/remove", opts, &out); err != nil {
		return err
	}

	return printJSON(out)
}
