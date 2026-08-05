// Command foreman is the Go CLI for the Foreman Phoenix API.
//
// Usage:
//
//	foreman <subcommand> [flags]
//
// Subcommands:
//
//	task create       POST /api/commands with type=task.create
//	task approve      POST /api/commands with type=task.approve
//	task get <id>     GET /api/tasks/:id
//	run get <id>      GET /api/runs/:id
//	workflow install  POST /api/admin/workflows/install
//
// Environment:
//
//	FOREMAN_API_URL    Base URL (default http://127.0.0.1:4000)
//	FOREMAN_API_TOKEN  Optional Bearer credential
package main

import (
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const usage = `foreman — Go CLI for the Foreman server

Usage:
  foreman <command> [flags]

Commands:
  task create        Register a new task
  task approve       Approve a task and bind it to a workflow
  task get <id>      Fetch a task projection
  run get <id>       Fetch a run projection
  workflow install   Install a workflow from a directory

Env:
  FOREMAN_API_URL    Base URL (default http://127.0.0.1:4000)
  FOREMAN_API_TOKEN  Bearer token (optional; bypassed in dev when unset)

Run 'foreman <command> -h' for command-specific help.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(2)
	}

	if os.Args[1] == "-h" || os.Args[1] == "--help" || os.Args[1] == "help" {
		fmt.Print(usage)
		os.Exit(0)
	}

	c := client.New()
	args := os.Args[2:]

	var err error

	switch os.Args[1] {
	case "task":
		err = runTask(c, args)
	case "run":
		err = runRun(c, args)
	case "workflow":
		err = runWorkflow(c, args)
	default:
		fmt.Fprintf(os.Stderr, "foreman: unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "foreman:", err)
		os.Exit(1)
	}
}
