# CodeRabbit Review — `beads:foreman:foreman-j9sf8`

Run `run-ad54c3ec7c654403f3626d97ad2774c9`, phase 3 (`coderabbit-review`), workflow `fix`.

## Review engine

Command run from the worktree root, twice (round 1 and round 2), exit code `0` both times:

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

`FOREMAN_BASE_BRANCH=main`, so the diff range is `main...HEAD` for this worktree. The engine
reported `review_completed` with `patched_set info: No files in patch set` and
`reviewedFiles: [".../FIX_REPORT.md", ".../PLAN.md"]`. Nothing in the run's own `lib/` was
reviewed, because nothing in `lib/` changed — see the Escalation section.

Round 3 was not run: per the phase contract, a round that yields no `Critical` or `Major`
finding you fixed stops the loop, and round 2 fixed nothing.

## Rounds

### Round 1 — 4 findings, 0 fixed, 4 declined

| Severity | Finding | Location | Disposition |
| --- | --- | --- | --- |
| major | Analyze the terminal-dispatch path that the plan changes. | `FIX_REPORT.md:7` | declined |
| major | Keep abandoned-run slot release and task failure from failing silently. | `PLAN.md:174-177` | declined |
| minor | Remove the unsupported test blocker. | `FIX_REPORT.md:16` | declined |
| minor | Keep the run slot until the abandoned run is terminal, or document the window. | `PLAN.md:145-147` | declined |

### Round 2 — 3 findings, 0 fixed, 3 declined

Same engine, same range, re-run to capture the full finding text. It re-reported the two
document-anchored items at `major` and dropped the two `minor` ones.

| Severity | Finding | Location | Disposition |
| --- | --- | --- | --- |
| major | Define the terminal state for a run whose `run.fail` is abandoned. | `PLAN.md:145-147` | declined |
| major | Check the results of both abandonment dispatches before returning `:ok`. | `PLAN.md:174-177` | declined |
| major | Re-anchor the Phase 2 analysis to the path `PLAN.md` changes. | `FIX_REPORT.md:7` | declined |

The three round-2 findings are the same three distinct issues as round 1's items 1-4, so the
union is **3 distinct findings**, all declined, all addressed below.

## Fixed

Nothing. No `lib/` code exists on this branch to fix, and every finding is a critique of a
planned implementation rather than of written code.

## Declined

**1. Re-anchor the Phase 2 analysis to the path `PLAN.md` changes** (`FIX_REPORT.md:7`, major)
— declined as not actionable in this phase, and noted as **valid**. The finding is correct:
`FIX_REPORT.md` reasons about a `{:not_found, :run, _}` arm it places at
`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:952-960` and about
`dispatch_next`, while `PLAN.md` caps the loop in `next_terminal_dispatch_step/2`
(`run_executor.ex:6222`) reached from `finalize_terminal_dispatch/4` (`run_executor.ex:6172`).
I verified the finding rather than acting on it: `grep -n "not_found, :run" run_executor.ex`
returns **no match** anywhere in the file, and `grep -rn "dispatch_next"
packages/foreman_server/lib/` returns **no match** in the whole `lib/` tree. The lines at
948-960 are `stop_interrupted/2` (pause/cancel handling) with no `:not_found` clause. So the
Phase 2 block rests on a location that does not exist. Correcting another phase's report is a
rewrite of its conclusion, which is not a review-phase edit; the actionable form of this
finding is the escalation below, not a diff from me.

**2. Check the results of both abandonment dispatches before returning `:ok`**
(`PLAN.md:174-177`, major) — declined: this phase cannot review code that has not been written.
The finding is correct about the snippet as planned — `abandon_terminal_dispatch/4` discards
`dispatch_task_execution_fail/2` and `release_run_slot/2` and returns `:ok`, so a failed task
dispatch would leave the task `in_progress` while the slot is gone. It targets a *planned*
function, so there is nothing to fix; to satisfy it here I would have to author this run's
implementation, and then this phase would be reviewing a change it wrote itself — a diff
CodeRabbit would never have reviewed independently. That is the failure mode the phase
separation exists to prevent.

**3. Define the terminal state for a run whose `run.fail` is abandoned** (`PLAN.md:145-147`,
major) — declined for the same reason, and it is not a question I can answer truthfully here.
`{:not_found, :run, id}` is produced by `require_exists/2`
(`packages/foreman_server/lib/foreman_server/aggregates/run.ex:1609`), which means the Run
aggregate is absent. There is no aggregate and therefore no stream to append a `RunFailed` to,
so "record the run terminal state" is not a free choice — it needs an aggregate-less terminal
record with a stream that does not exist yet, and `RunLifecycleReconciler` releases slot holders
only when the run is terminal or absent and writes no run state. Guessing a mechanism and
writing it into the plan would be a fabricated design, so it belongs to the implementation
phase that owns the decision, or to the operator.

## Verification

Commands run in this phase, with exit codes.

| Command | Exit | Result |
| --- | --- | --- |
| `coderabbit review --agent --base main` (round 1) | 0 | 4 findings, `review_completed` |
| `coderabbit review --agent --base main` (round 2) | 0 | 3 findings, `review_completed` |
| `git diff --stat "$FOREMAN_BASE_BRANCH"...HEAD` | 0 | 2 files, 256 insertions, both under `docs/reports/` |
| `git diff --name-only "$FOREMAN_BASE_BRANCH"...HEAD -- 'packages/foreman_server/lib'` | 0 | empty — no implementation on branch |
| `grep -n "not_found, :run" packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | 1 | no match (finding 1 verified) |
| `grep -rn "dispatch_next" packages/foreman_server/lib/` | 1 | no match (finding 1 verified) |
| `grep -n "Foreman.Inbox.deliver" docs/reports/.../PLAN.md` | 1 | no match (finding 4 verified) |
| `sed -n '945,960p' packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | 0 | `stop_interrupted/2`, no `:not_found` arm |
| `find packages/foreman_server -name "supervisor.ex" -o -name "queue*.ex" -o -name "foreman_commands*.ex"` | 0 | only `coordinator/supervisor.ex`, `aggregate/supervisor.ex`, `agent_runtime/supervisor.ex` — `exec/supervisor.ex`, `exec/queue.ex`, `foreman_commands.ex` do not exist |
| `grep -rn "force_release\|reclaim_reserved" packages/foreman_server/lib/` | 1 | no match |
| `find packages/foreman_server -name "inbox*.ex" -o -name "queue_test.exs"` | 0 | no `lib/foreman/inbox.ex`, no `exec/queue_test.exs` |

No test or formatter command was run: no file outside this report was edited, so there is
nothing for them to check. The full CI suite will run on the PR.

## Documentation gate

This phase changed no externally visible identifier — no route, config key, env var, CLI verb,
command/event type, MCP tool or workflow/prompt name was added, removed or renamed. `PLAN.md`
and `FIX_REPORT.md` are run artifacts, not documentation targets. Checked anyway: none of the
four gate files (`CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`) needed
an edit, because there is no operator-visible change from this phase.

## Escalation: the run's work is not implemented

The important finding is the one CodeRabbit could not name, because it is a *missing* change.
The task for this run is a real defect and this branch does not fix it.

- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:6222` still reads
  `defp next_terminal_dispatch_step(:slow, _attempt), do: {@terminal_dispatch_slow_interval_ms, :slow}`
  with no attempt cap, and `finalize_terminal_dispatch/4` (`run_executor.ex:6172-6201`) still
  exits its error loop only on `:ok` or `{:error, {:run_terminal, _}}`. A `run.fail` that
  returns `{:error, {:not_found, :run, id}}` still retries every 60 s indefinitely and keeps
  its slot, exactly as the task describes.
- Phase 2 (`fix`) shipped no code and declared itself Blocked. Its stated blockers do not hold
  up against this repository's source. The report anchors its argument on
  `run_executor.ex:952-960` holding a `{:not_found, :run, _}` arm (it does not — those lines are
  `stop_interrupted/2`), on `dispatch_next` re-fetching the projection on every attempt in
  `exec/supervisor.ex:6254`, on `force_release` in `foreman_commands.ex:1924-1933` and on
  `exec/queue.ex:249-271`. None of those paths exist in this repository: `exec/supervisor.ex`,
  `exec/queue.ex` and `foreman_commands.ex` are absent from `packages/foreman_server/lib/`, and
  `dispatch_next`, `force_release` and `reclaim_reserved` appear nowhere in `lib/`. Its second
  blocker — that `PLAN.md`'s `assert :ok = Foreman.Inbox.deliver(...)` "wouldn't compile" — names
  an assertion `PLAN.md` does not contain and a module (`lib/foreman/inbox.ex`) that does not
  exist. So the block rests on a different codebase's layout, not on an obstacle in this one.
- So the block appears to come from a misread diff, not from a real obstacle. `PLAN.md` is
  coherent, names a failing-first test at
  `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs`, and
  scopes itself to `run_executor.ex`; the resolved questions it lists (the `run.fail` stream id,
  and the abandonment dispatch-result semantics of findings 2 and 3 above) are exactly the
  decisions an implementation phase should make.

Recommended operator action: re-run the `fix` phase against `PLAN.md`, or decide that findings
2 and 3 are the design you want before it does. I did not implement the fix here, so that the
code and its review stay independent.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-j9sf8/FIX_REPORT.md", "line": 7, "description": "The Phase 2 block analysis is anchored to a run.fail path that does not exist (run_executor.ex:952-960 and dispatch_next), not to finalize_terminal_dispatch/4 and next_terminal_dispatch_step/2 which PLAN.md changes, so its \"slot is already free\" conclusion never inspects the path being fixed.", "disposition": "declined", "source": "coderabbit"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-j9sf8/PLAN.md", "line": 176, "description": "The planned abandon_terminal_dispatch/4 discards the results of dispatch_task_execution_fail/2 and release_run_slot/2 and returns :ok, so a failed task-failure dispatch would leave the task in_progress while the slot is gone and the backstop sweep would not release the holder.", "disposition": "declined", "source": "coderabbit"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-j9sf8/PLAN.md", "line": 146, "description": "The plan fails the task and releases the slot on abandonment but never defines how the run reaches a terminal state, so no RunFailed event is recorded and components reacting to run-terminal events never run.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-j9sf8/FIX_REPORT.md", "line": 16, "description": "The report's test blocker cites an assert :ok = Foreman.Inbox.deliver(...) assertion in PLAN.md that PLAN.md does not contain, so the stated compile-time blocker is unsupported.", "disposition": "declined", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The branch diff is two run-report documents under docs/reports/ and no production code, so nothing can regress at runtime; the risk of merging this diff itself is low. That low level describes the diff only, not the task outcome: the RunExecutor unbounded terminal-dispatch retry the run was filed to fix is still present at run_executor.ex:6222 and three review findings remain unresolved."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
