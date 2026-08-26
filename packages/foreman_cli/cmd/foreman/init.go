package main

import "github.com/fortium/foreman/packages/foreman_cli/internal/client"

// runInit is the operator-facing "refresh bundled assets" entry point.
//
// `foreman init --force` posts to `POST /api/admin/workflows/install` and
// omits every install option so the server resolves both the source
// (`Application.app_dir(:foreman_server, "priv/defaults/workflows")`) and
// the target (`System.user_home!()/.foreman/workflows` via
// `Installer.target_dir/1`) from its own configuration. The CLI does not
// resolve any path so that:
//   - remote CLI invocations don't install into the operator's own $HOME,
//   - the server's `Workflow.Catalog` polls that same root and reloads
//     installed manifests on the next poll cycle (default 2s).
//
// The `--force` flag is a CLI-side operator confirmation. The Installer
// already overwrites same-named targets via `File.cp/2` and `File.write/2`,
// so the flag is a safety message and is not forwarded to the server.
func runInit(c *client.Client, args []string) error {
	fs := newFlagSet("init")
	force := fs.Bool("force", false, "Confirm refresh of installed runtime prompts and workflows")
	if err := fs.parse(args); err != nil {
		return err
	}

	if !*force {
		return usageError(
			fs,
			"foreman init: --force is required to refresh the installed runtime copy",
		)
	}

	// Empty body: server resolves source from the running app's bundled
	// priv/defaults/workflows and target from the configured catalog root.
	opts := map[string]any{}

	var out map[string]any
	if err := c.PostJSON("/api/admin/workflows/install", opts, &out); err != nil {
		return err
	}

	return printJSON(out)
}
