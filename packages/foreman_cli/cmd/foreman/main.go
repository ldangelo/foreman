// Command foreman is the Go CLI for the Foreman Phoenix API.
//
// Usage:
//
//	foreman <subcommand> [flags]
//
// Subcommands:
//
//	project create      POST /api/commands with type=project.register
//	project get <id>    GET /api/projects/:id
//	project update <id> POST /api/commands with type=project.update
//	project delete <id> POST /api/commands with type=project.archive
//	project list        GET /api/projects
//	commands           Generate/install agent command assets
//	task create         POST /api/commands with type=task.create
//	task approve        POST /api/commands with type=task.approve
//	task get <id>       Fetch a task projection
//	run list            List run projections
//	run get <id>        Fetch a run projection
//	run remove          Remove a run and clean worktree/branch
//	run reset           Reset a failed or stuck run projection
//	workflow install    Install workflow assets from --source or --remote
//	init --force        Refresh the installed runtime copy of bundled prompts/workflows
//
// `foreman init --force` is the canonical developer-facing entry point
// for refreshing the runtime asset cache after editing bundled source
// workflows or prompts. The server resolves bundled assets from the
// running `foreman_server` application directory, so the CLI does not
// need to know the installed path.
// Environment:
//
//	FOREMAN_API_URL    Base URL (default http://127.0.0.1:4000)
//	FOREMAN_API_TOKEN  Optional Bearer credential
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const usage = `foreman — Go CLI for the Foreman server

Usage:
  foreman <command> [flags]

Commands:
  project create      Register a new project
  project get <id>    Fetch a project projection
  project update <id> Update a project's task provider
  project delete <id> Soft-delete (archive) a project
  project list        List project projections
  commands           Generate/install agent command assets
  task create         Register a new task
  task approve        Approve a task and bind it to a workflow
  task get <id>      Fetch a task projection
  task list          List task projections [--project <id>] [--status <status>]
  task update        Update a task [--id <id>] [--title <title>] [--priority <0-4>] [--status <status>]
  task retry         Retry a failed task [--id <id>] [--reason <text>]
  run list            List run projections
  run get <id>        Fetch a run projection
  run remove          Remove a run and clean worktree/branch
  run reset           Reset a failed or stuck run projection
  workflow install    Install workflow assets
  init --force        Refresh the installed runtime copy of bundled prompts/workflows
Env:
  FOREMAN_API_URL    Base URL (default http://127.0.0.1:4000)
  FOREMAN_API_TOKEN  Bearer token (optional; bypassed in dev when unset)

Run 'foreman <command> -h' for command-specific help.
`

func main() {
	if len(os.Args) < 2 {
		exitWithError(usageTextError("foreman: missing command", usage))
	}

	if os.Args[1] == "-h" || os.Args[1] == "--help" || os.Args[1] == "help" {
		fmt.Print(usage)
		os.Exit(0)
	}

	c := client.New()
	args := os.Args[2:]

	var err error

	switch os.Args[1] {
	case "project":
		err = runProject(c, args)
	case "commands":
		err = runCommands(args)
	case "task":
		err = runTask(c, args)
	case "run":
		err = runRun(c, args)
	case "workflow":
		err = runWorkflow(c, args)
	case "init":
		err = runInit(c, args)
	default:
		err = usageTextError(fmt.Sprintf("foreman: unknown command %q", os.Args[1]), usage)
	}

	exitWithError(err)
}

func exitWithError(err error) {
	if err == nil {
		return
	}

	var helpErr *client.HelpError
	if errors.As(err, &helpErr) {
		if helpErr.Text != "" {
			fmt.Fprintln(os.Stdout, helpErr.Text)
		}
		os.Exit(client.ExitCode(err))
	}

	if text := err.Error(); text != "" {
		fmt.Fprintln(os.Stderr, text)
	}

	os.Exit(client.ExitCode(err))
}
