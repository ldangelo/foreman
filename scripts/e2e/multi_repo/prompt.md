# {{workflow_name}} :: {{phase_name}}

You are working in {{repositories_count}} git repositories at once. Each repository has its
own checkout. The JSON below lists them: `path` is the checkout directory you must edit and
`primary: true` marks the one that is your current working directory.

{{repositories}}

## Task

{{input.prompt}}

## Rules

- Use the ABSOLUTE `path` from the JSON for every repository that is not your current working
  directory. The sibling checkouts are also exported as `FOREMAN_REPO_<ID>_WORKTREE`
  environment variables.
- Do NOT run `git add`, `git commit` or `git push`: Foreman commits every checkout when you
  finish.
- Do not create or change any other file, and do not touch any path outside these checkouts.
- When every file is written, verify each one with `cat`, then reply with exactly: done
