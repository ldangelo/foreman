Work through this repository's open issues tagged `foreman-exec`, in
dependency order, using the beads CLIs (`br`, `bv`) available in this sandbox.
To use a different tracker (Jira, Linear, ...), replace the commands below.

Each turn:

1. Run `bv --robot-next` (or `bv --robot-plan --label foreman-exec` and take the
   first item of a track). Only pick issues labeled `foreman-exec`. If there are
   none left, you are finished: skip to the completion step.
2. Read it with `br show <id> --json`, implement it, and run the project's tests.
3. Commit your work, then `br close <id> --reason "<what you did>"`. Never close
   an issue whose work is incomplete or whose tests fail; leave it open and say why.
4. Stop the turn. The next turn picks the next issue, so dependents only start
   after their blockers are closed.

Completion: when — and only when — no `foreman-exec` issue is actionable, end
your final message with exactly:

    <promise>COMPLETE</promise>

Do not emit that tag early; Jobsite stops iterating the moment it appears.
Set `max_iterations` in `iterate.exs` to at least the number of issues expected.
