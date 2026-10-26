package main

import (
	"fmt"
	"os"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

// projectAdopt implements `foreman project adopt`: POST /api/project-adoptions.
func projectAdopt(c *client.Client, args []string) error {
	fs := newFlagSet("project adopt")
	kind := fs.String("kind", "", "Subject kind: run|jobsite|task (required)")
	id := fs.String("id", "", "Subject id (required)")
	into := fs.String("into", "", "Target project id (move or continue)")
	newProject := fs.Bool("new-project", false, "Mint a new project from the session archive")
	projectID := fs.String("project-id", "", "Id for the minted project (with --new-project)")
	path := fs.String("path", "", "Repository path for the minted project (with --new-project)")
	goal := fs.String("goal", "", "Goal for the minted project (with --new-project)")
	cont := fs.Bool("continue", false, "Continue the session as a new thread instead of moving it")
	prompt := fs.String("prompt", "", "Continuation instruction (with --continue)")
	fork := fs.Bool("fork", false, "With --continue: fork the session's provider session (the agent remembers it) instead of seeding the prompt from the archive")
	fromSourceBranch := fs.Bool("from-source-branch", false, "With --continue: cut the new thread's worktree from the branch of the session being continued instead of the project's current branch")
	addRepo := fs.Bool("add-repo", false, "With a move (--into without --continue): attach the session's repository to the target project first if it is not one of its repositories")
	format := fs.String("format", "", "Output format (json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if *kind == "" || *id == "" {
		return usageError(fs, "foreman project adopt: --kind and --id are required")
	}
	switch {
	case *newProject && (*into != "" || *cont):
		return usageError(fs, "foreman project adopt: --new-project cannot be combined with --into or --continue")
	case !*newProject && *into == "":
		return usageError(fs, "foreman project adopt: one of --into or --new-project is required")
	case *fork && !*cont:
		return usageError(fs, "foreman project adopt: --fork requires --continue")
	case *fromSourceBranch && !*cont:
		return usageError(fs, "foreman project adopt: --from-source-branch requires --continue")
	case *addRepo && (*cont || *newProject):
		return usageError(fs, "foreman project adopt: --add-repo applies only to a move (--into without --continue)")
	case *cont && *prompt == "":
		return usageError(fs, "foreman project adopt: --continue requires --prompt")
	}
	switch *format {
	case "", "json":
	default:
		return usageError(fs, "foreman project adopt: unsupported format %q", *format)
	}

	body := map[string]any{"subject_kind": *kind, "subject_id": *id}
	switch {
	case *newProject:
		body["mode"] = "mint"
		np := map[string]any{}
		for k, v := range map[string]string{"id": *projectID, "path": *path, "goal": *goal} {
			if v != "" {
				np[k] = v
			}
		}
		body["new_project"] = np
	case *cont:
		body["mode"] = "continue"
		body["target_project_id"] = *into
		body["prompt"] = *prompt
		if *fork {
			body["fork"] = true
		}
		if *fromSourceBranch {
			body["from_source_branch"] = true
		}
	default:
		body["mode"] = "move"
		body["target_project_id"] = *into
		if *addRepo {
			body["add_repo"] = true
		}
	}

	var out map[string]any
	if err := c.PostJSON("/api/project-adoptions", body, &out); err != nil {
		return err
	}
	if *format == "json" {
		return printJSON(out)
	}
	adoption, _ := out["adoption"].(map[string]any)
	_, err := fmt.Fprintf(os.Stdout, "%s %s %s -> project %v (from %v)\n",
		adoption["mode"], adoption["subject_kind"], adoption["subject_id"],
		adoption["project_id"], adoption["from_project_id"])
	return err
}
