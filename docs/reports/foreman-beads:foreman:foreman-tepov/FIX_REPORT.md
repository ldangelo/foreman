# Fix report — queued-run cancellation (`run.cancel` accepts queued runs)

Task: `beads:foreman:foreman-tepov` · Run: `run-64e944e0b6ab3b61eabc61b250737f9c` · Phase 2 (`fix`)

## Verdict

**Already fixed. No code change.** Per plan §1/§3/§4 the behaviour is not
reproducible on this tree, so no edit and no new test were made; I ran plan §5's
verification and record the real output in §5 below.

## 1. Root cause

None on the current tree (plan §2). Historically `CommandGateway` dispatched
`run.cancel` straight to the `Run` aggregate, which does not exist until slot
promotion, so a queued run answered `{:not_found, :run, <run_id>}`. That was fixed
in `6bb64a52` ("fix(server): cancelling a run that waits for a run slot removes it
from the waiting list", PR #904, 2026-11-19) and carried through the per-project
queue rework `4099cce4` (PR #918, 2026-11-20). Both commits are ancestors of this
branch's HEAD.

Current implementation (plan §1 evidence, lines re-checked on this checkout):

- `packages/foreman_server/lib/foreman_server/command_gateway.ex:141` —
  `dispatch_operator/2` routes `run.cancel` through `cancel_queued_run/2` **before**
  `dispatch_effected_operator_command/2`, so a queued run never reaches the `Run`
  aggregate that would answer not-found:
  ```elixir
  case cancel_queued_run(effected, timeout) do
    {:cancelled_queued, result} -> result
    :not_queued -> dispatch_effected_operator_command(effected, timeout)
  end
  ```
- `command_gateway.ex:162` `cancel_queued_run/2`; `:179` `queued_slot_project/1`
  (loads the `Run` aggregate and only when it is `%Run.State{exists?: false}` scans
  the candidate projects' `RunSlots` waiters); `:221`
  `remove_slot_waiter_and_ack_task/4` (dispatches `run_slots.remove_waiter`, then
  `release_if_promoted/4`, then `ack_cancelled_queued_tasks/4` → `task.run_terminated`).
- `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex:518` handles
  `run_slots.remove_waiter` and emits `RunSlotWaiterRemoved` at `:526`.
- `packages/foreman_server/lib/foreman_server/projection_store.ex:3862` folds
  `RunSlotWaiterRemoved` by rejecting the waiter; `build_queue_status/2` at
  `projection_store.ex:4447` builds `waiting` from `slots.waiters`, so the run
  disappears from `foreman_queue_status` / `GET /api/queue`.
- "never started later": `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1452`
  in `start_promoted_run/2` matches `[%{acknowledged_run_id: ^run_id} | _]` and calls
  `terminate_slot(run_id, "run_cancelled")` instead of starting the run.
- Documented at `docs/cli-reference.md:697`.

Provenance of the stale finding: it came from the automated review of
`run-2ea29453149a2c90cc6e9c56896bed2b`, whose `analysis.md:3` states the reviewed
diff "contains no implementation at all" — the review graded an **empty** diff and
restated the original bead text as still-present. `6bb64a52` is also an ancestor of
that run's base (`6905638c`), i.e. the behaviour was already live while that run was
reviewed.

## 2. Change

None. No `.ex`, `.exs`, `.go`, `.yaml` or documentation file was edited. The only
file written by this phase is this report. `git status --short` before verification
was clean (the phase-start `PLAN.md` working-tree restore is a checkout of the
committed file, not a change).

## 3. Deviations from the plan

None.

## 4. Tests

No tests added or updated (plan §3 forbids new tests: the behaviour is already
covered end to end). The regression suite
`packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs`
(5 tests) already asserts the task's "done looks like" conditions:
`cancel(queued)` returns `{:ok, _}` rather than `{:error, {:not_found, :run, _}}`;
`waiter_ids(project) == []` afterwards; the task carries
`acknowledged_run_id == queued` and leaves `ProjectionStore.deferred_task_ids/1` so
promotion will not start it. Second-cancel, cross-project and missing-`run_id` cases
are in the same file.

Failing-before / passing-after: not applicable — no failing check exists. Both
commands were green on first run (§5), so there was nothing to make red.

## 5. Local verification

Both commands run exactly as plan §5 specifies (`DATABASE_URL` unset inside the
`bash -c` so `config/test.exs`'s `postgres://postgres:postgres@localhost:55432/foreman_test`
applies; the worktree environment otherwise exports a `DATABASE_URL` at port 55434
that fails authentication).

Narrowest check — exit code 0:

```
$ devbox run -- bash -c 'unset DATABASE_URL; cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/command_gateway_cancel_queued_run_test.exs --warnings-as-errors'
Running ExUnit with seed: 484915, max_cases: 36
Excluding tags: [:langfuse, :external_llm, :docker]
.....
Finished in 1.1 seconds (0.00s async, 1.1s sync)
Result: 5 passed
ProjectionLeakGuard: judged 0 of 1 modules, no run left behind
```

Adjacent slot/queue coverage — exit code 0:

```
$ devbox run -- bash -c 'unset DATABASE_URL; cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/command_gateway_cancel_queued_run_test.exs test/foreman_server/projection_store_run_slots_test.exs test/foreman_server/projection_store_queue_status_test.exs test/foreman_server/aggregates/run_slots_release_test.exs --warnings-as-errors'
Running ExUnit with seed: 600276, max_cases: 36
Excluding tags: [:langfuse, :external_llm, :docker]
........................................................
Finished in 1.7 seconds (1.0s async, 0.7s sync)
Result: 56 passed
ProjectionLeakGuard: judged 3 of 3 modules, no run left behind
```

`5 passed` and `56 passed` match the plan's expected counts; `--warnings-as-errors`
raised nothing. No formatter/lint run: no file changed, and `mix format` does not
process Markdown.

## 6. Follow-ups

Intentionally left undone (plan §6, out of scope):

- No edits to `command_gateway.ex`, `aggregates/run_slots.ex`,
  `workflow/dispatcher.ex`, `run_admission.ex`, `projection_store.ex`,
  `mcp/tools.ex` or `packages/foreman_cli/`.
- No new `RunCancelled` event or extra cancellation path — the existing
  `run_slots.remove_waiter` → `RunSlotWaiterRemoved` + `task.run_terminated` pair is
  the design.
- Sibling findings from the same stale analysis (task-close removing a waiter,
  `foreman_run_status` reporting `queued`, a `cancelled` task status) are separate
  beads.
- Documentation gate: this change adds, removes and renames **no** externally visible
  identifier (no route, config key, env var, CLI verb, MCP tool, command or event
  type), so `CLAUDE.md`, `README.md`, `docs/user-guide.md` and `docs/cli-reference.md`
  need no edits — `docs/cli-reference.md:697` already documents queued-run cancel.
- Recommend the operator close the upstream review finding as a false positive caused
  by grading an empty diff.

## 7. Postscript — provenance of the truncated copy of this report

`HEAD~1` (`96f162d0`) holds this report as it was written. The next commit,
`dfb441fe` ("Foreman run run-64e944e0b6ab3b61eabc61b250737f9c phase 2"),
replaced it with a 14-line fragment claiming "6 files, +352/−8" and a new
`test/foreman_server/run_cancel_test.exs` with 9 tests. That fragment describes
work this branch never did: `96f162d0` and `0be2791f` each touched only the
report file, the identifiers it names (`RunSlotQueue.cancel_queued/3`,
`RunCancelAdapter`) appear nowhere in the repo's history, and that test file does
not exist in the worktree. The fragment is the truncated working-tree copy
recorded in the phase notes, not a record of real work; §1–§6 above are the
authoritative report and are restored here verbatim from `96f162d0`.

