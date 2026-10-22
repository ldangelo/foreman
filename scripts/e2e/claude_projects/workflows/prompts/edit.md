{{workflow_name}} :: {{phase_name}}

## Task

{{input.prompt}}

## Rules

- Work only inside the current working directory (a git worktree).
- Do NOT run `git add`, `git commit` or `git push`: Foreman commits when you finish.
- When finished, reply with exactly: done
