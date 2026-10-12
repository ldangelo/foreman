Work through this repository's open issues labeled `foreman-exec`, in
dependency order, one issue per turn, using the beads CLIs (`br`, `bv`) and the
ensemble skills installed in this sandbox. To use a different tracker (Jira,
Linear, ...), replace the `br`/`bv` commands.

Each turn:

1. Run `bv --robot-next` (or `bv --robot-plan --label foreman-exec` and take the
   first item of a track). Only pick issues labeled `foreman-exec`. If none are
   actionable, you are finished: go to Completion.
2. Read it with `br show <id> --json` and route on its type. Pass the issue's
   title and description as the skill's input, plus `--foreman`:
   - `bug`, `task`: invoke the `ensemble-fix-issue` skill (Claude Code plugin
     command: `/ensemble:fix-issue`). It implements the change.
   - `story`, `epic`: invoke the `ensemble-feature` skill with `--skip-refine`
     (Claude Code: `/ensemble:feature`). It plans only: it writes a PRD and a
     TRD and creates the child beads. Then run
     `ensemble-implement-trd-beads <TRD_PATH> --plan --foreman` on the TRD it
     produced (it reuses the beads that already exist and, with `--foreman`,
     labels the task beads `foreman-exec`), so later turns pick them up.
   - any other type: treat it like `task`.
3. Run the project's tests. Only when the work is complete and tests pass, commit
   and `br close <id> --reason "<what you did>"`. A story or epic is complete once
   its plan and child beads exist. Never close an issue whose work is incomplete
   or whose tests fail: leave it open and say why.
4. Stop the turn. The next turn picks the next issue, so dependents only start
   after their blockers are closed.

Completion: when — and only when — no `foreman-exec` issue is actionable, end
your final message with exactly:

    <promise>COMPLETE</promise>

Do not emit that tag early; Jobsite stops iterating the moment it appears.
Set `max_iterations` in `iterate.exs` to at least the number of issues expected,
plus the child beads that story and epic issues will create.
