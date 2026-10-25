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
//	project settings <id> GET /api/projects/:id/settings
//	project recommend <id> GET /api/projects/:id/recommendations
//	project adopt       POST /api/project-adoptions
//	project pause <id>  POST /api/commands with type=project.pause
//	project resume <id> POST /api/commands with type=project.resume
//	project reactivate <id> POST /api/commands with type=project.reactivate
//	project delete <id> POST /api/commands with type=project.archive (soft delete)
//	project list        GET /api/projects
//	project memory      list|read|write|forget|sync a project's memory (/api/projects/:id/memory)
//	project library     list|add|replace|remove the project library (/api/projects/:id/library)
//	project schedule list|create|pause|resume|delete  scheduled tasks (GET /api/projects/:id/schedules, POST /api/commands schedule.*)
//	project chat <id>   POST/GET /api/projects/:id/coordinator/messages (long-poll), /coordinator, /coordinator/restart
//	commands           Generate/install agent command assets
//	run list            List run projections
//	run get <id>        Fetch a run projection
//	run pause           Pause a run
//	run resume          Resume a paused run
//	run remove          Remove a run and clean worktree/branch
//	run reset           Reset a failed or stuck run projection
//	thread list|get|stop|resolve|reopen|steer|rereview  Inspect and act on threads
//	workflow install    Install workflow assets from --source or --remote
//	init --force        Refresh the installed runtime copy of bundled prompts/workflows
//	doctor              GET /api/doctor
//
// `foreman init --force` is the canonical developer-facing entry point
// for refreshing the runtime asset cache after editing bundled source
// workflows or prompts. The server resolves bundled assets from the
// running `foreman_server` application directory, so the CLI does not
// need to know the installed path.
// Environment:
//
//	FOREMAN_API_URL    Base URL (default http://127.0.0.1:4766)
//	FOREMAN_API_TOKEN  Bearer credential (required unless the server opts into allow_insecure_local)
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
  project update <id> Update project settings (goal, instructions, models, limits) and/or task provider
  project settings <id> Show project status, settings and limits
  project context <id> Show the standing context an agent launch would receive
  project env <id>    list|set|unset project environment variables
  project secret <id> list|set|unset project secrets (--from-env)
  project setup-script <id> show|set|clear the project setup script
  project network <id> show|set the project network policy (--mode --allow)
  project recommend <id> Setup recommendations (--format json, --fail-on warn|action)
  project adopt       Move/continue/mint a project from a session (--kind --id --into|--new-project)
  project pause <id>  Pause a project (--reason text)
  project resume <id> Resume a paused project
  project reactivate <id> Reactivate an archived project
  project delete <id> Soft-delete (archive) a project; history is kept, reactivate to restore
  project list        List project projections
  project memory      list|read|write|forget|sync project memory topics
  project library     list|add|replace|remove project library files
  project schedule list|create|pause|resume|delete  Manage scheduled tasks (--project-id <id>)
  project repo        add|remove|list a project's repositories (add --id --path <abs-path> <project-id>)
  project chat <id> [message...] Chat with a project's coordinator (--no-wait --since --history --format --restart)
  approvals list|approve|deny  Agent tool-permission requests (list --project|--run, approve/deny --run --call)
  questions list|answer        Operator questions (list --project, answer --run --question --text)
  usage --project <id> Show token/cost usage (--from, --to, --by day|model|provider|role|thread, --limit, --format table|json)
  commands           inventory|generate|install|validate agent command assets
  run list            List run projections
  run get <id>        Fetch a run projection
  run cancel          Cancel a run (--id, --reason)
  run pause           Pause a run
  run resume          Resume a paused run
  run remove          Remove a run and clean worktree/branch
  run reset           Reset a failed or stuck run projection
  run submit          Submit an ad-hoc run (--project-id --workflow --prompt --work-id --backend)
  run approve-merge   Record the operator's merge approval for a run (--id --approver --identity --head-sha [--repo-id])
  run merge           Merge an approved run's PR (--id [--repo-id])
  run prs <id>        List the run's pull requests
  run fix-ci <id>     Request a CI-fix thread for a watched PR (--pr --note)
  run address-comments <id> Request a thread to address PR review comments (--pr --note)
  run resolve-conflicts <id> Request a thread to resolve PR merge conflicts (--pr --note)
  run create-pr <id>  Create the run's pull request
  run retry-pr        Re-open the PR of one repository of a multi-repo run (--id --repo-id)
  run watch-start <id> Start watching a run's PR (--pr)
  run watch-stop <id>  Stop watching a run's PR (--pr)
  thread list         List a project's threads (--project <id>)
  thread get <id>     Fetch a thread
  thread stop <id>    Stop a thread (workflow run or jobsite)
  thread resolve <id> Mark a thread resolved
  thread reopen <id>  Reopen a resolved thread
  thread steer <id>   Send an operator message to a thread (--message)
  thread rereview <id> Re-run an undetermined review (workflow run or jobsite)
  workflow install    Install workflow assets
  workflow remove     Remove installed workflow assets (--all)
  init --force        Refresh the installed runtime copy of bundled prompts/workflows
  doctor              Server, provider, workflow and project-setup checks (--project, --strict, --format json)
Env:
  FOREMAN_API_URL    Base URL (default http://127.0.0.1:4766)
  FOREMAN_API_TOKEN  Bearer token (required unless the server opts into allow_insecure_local)

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
	case "usage":
		err = runUsage(c, args)
	case "approvals":
		err = runApprovals(c, args)
	case "questions":
		err = runQuestions(c, args)
	case "commands":
		err = runCommands(args)
	case "run":
		err = runRun(c, args)
	case "thread":
		err = runThread(c, args)
	case "workflow":
		err = runWorkflow(c, args)
	case "init":
		err = runInit(c, args)
	case "doctor":
		err = runDoctor(c, args)
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
