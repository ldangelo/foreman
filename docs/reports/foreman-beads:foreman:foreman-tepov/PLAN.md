# Plan — queued-run cancellation (`run.cancel` accepts queued runs)

Task: `beads:foreman:foreman-tepov` · Run: `run-64e944e0b6ab3b61eabc61b250737f9c`

## 1. Verdict

**Already fixed. No code change.** The implementer must stop after running the
verification commands in section 5 and recording the result.

The reported behaviour (`run.cancel` on a run that is only a run-slot waiter is
refused as `{:not_found, :run, <run_id>}`) is no longer reachable on this tree.

Evidence:

- `packages/foreman_server/lib/foreman_server/command_gateway.ex:141` — `dispatch_operator/2`
  routes through `cancel_queued_run/2` **before** `dispatch_effected_operator_command/2`,
  so a queued run never reaches the `Run` aggregate that would answer not-found:

  ```elixir
  case cancel_queued_run(effected, timeout) do
    {:cancelled_queued, result} -> result
    :not_queued -> dispatch_effected_operator_command(effected, timeout)
  end
  ```

- `command_gateway.ex:162` `cancel_queued_run/2`, `:179` `queued_slot_project/1`
  (loads `Run` aggregate; only when `%Run.State{exists?: false}` does it scan the
  candidate projects' `RunSlots` waiters), `:221` `remove_slot_waiter_and_ack_task/4`
  (dispatches `run_slots.remove_waiter`, then `release_if_promoted/4`, then
  `ack_cancelled_queued_tasks/4` → `task.run_terminated`).
- `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex:518` handles
  `run_slots.remove_waiter` and emits `RunSlotWaiterRemoved` (`:526`).
- `packages/foreman_server/lib/foreman_server/projection_store.ex:3862` folds
  `RunSlotWaiterRemoved` by rejecting the waiter; `build_queue_status/2` at
  `projection_store.ex:4447` builds `waiting` from `slots.waiters`, so the run
  disappears from `foreman_queue_status` / `GET /api/queue`.
- "never started later": `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1452`
  in `start_promoted_run/2` matches `[%{acknowledged_run_id: ^run_id} | _]` and calls
  `terminate_slot(run_id, "run_cancelled")` instead of starting the run.
- Regression suite already exists and passes:
  `packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs`
  (5 tests, including "cancelling a run that waits for a slot removes it from the
  waiting list and releases its task" and the second-cancel / cross-project /
  missing-`run_id` cases).
- Documented at `docs/cli-reference.md:697` ("A run that is still waiting for a run
  slot … `run cancel` on it removes it from the waiting list and acknowledges its
  task (`task.run_terminated`, with the cancel's reason) rather than answering
  `run_not_found`").

Provenance of the stale report: the finding came from the review of
`run-2ea29453149a2c90cc6e9c56896bed2b`, whose analysis (`analysis.md:3`) states the
reviewed diff "contains no implementation at all" — it graded an **empty** diff and
restated the original bead text as still-present. The fix had in fact landed earlier
in `6bb64a52` ("fix(server): cancelling a run that waits for a run slot removes it
from the waiting list", PR #904, 2026-11-19) and was carried through the per-project
queue rework `4099cce4` (PR #918, 2026-11-20). Both are ancestors of this branch's
HEAD (`796c888c`), and `6bb64a52` is also an ancestor of that run's base
(`6905638c`) — i.e. the behaviour was already present while that run was reviewed.

## 2. Root cause

None on the current tree. Historically the gateway dispatched `run.cancel` straight
to the `Run` aggregate, which does not exist until slot promotion; `6bb64a52`
introduced the `cancel_queued_run/2` pre-step in
`packages/foreman_server/lib/foreman_server/command_gateway.ex`.

## 3. Failing check first

There is no failing check to produce: the bug is not reproducible. Do **not** write a
new test — the behaviour is already covered end to end by
`packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs`,
which exercises exactly the task's "done looks like" conditions:

- `cancel(queued)` returns `{:ok, _}` (not `{:error, {:not_found, :run, _}}`);
- `waiter_ids(project) == []` after the cancel (gone from the waiting list);
- the task carries `acknowledged_run_id == queued` and is no longer in
  `ProjectionStore.deferred_task_ids/1`, so promotion will not start it.

Run it to confirm it is green (command in section 5). If it is green, the plan is
complete: write the fix report stating "already fixed", cite section 1's evidence,
and make no code edit.

If — and only if — that file is **red** on your checkout, stop and report the exact
failure; do not attempt a redesign, because the intended design is the one described
in section 1.

## 4. Edits

None. Do not edit any `.ex`, `.exs`, `.go`, `.yaml` or documentation file.

The only file to write is the fix report the `fix` workflow expects:

```
docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md
```

It must contain: the verdict ("already fixed, no code change"), the evidence from
section 1 (file:line citations, the two commits `6bb64a52` / `4099cce4`), the exact
test command run and its real output (counts and exit code), and the note that the
upstream finding came from a review of an empty diff.

## 5. Verification

Postgres note: this worktree's environment exports a `DATABASE_URL` pointing at
`foreman_dev` on port 55434, which makes `MIX_ENV=test mix test` fail to authenticate.
Unset it so `config/test.exs`'s default (`postgres://postgres:postgres@localhost:55432/foreman_test`)
applies.

Narrowest check (run first):

```bash
devbox run -- bash -c 'unset DATABASE_URL; cd packages/foreman_server && \
  MIX_ENV=test mix test test/foreman_server/command_gateway_cancel_queued_run_test.exs \
  --warnings-as-errors'
```

Expected (verified during planning): `Result: 5 passed`, exit 0.

Adjacent slot/queue coverage:

```bash
devbox run -- bash -c 'unset DATABASE_URL; cd packages/foreman_server && \
  MIX_ENV=test mix test \
  test/foreman_server/command_gateway_cancel_queued_run_test.exs \
  test/foreman_server/projection_store_run_slots_test.exs \
  test/foreman_server/projection_store_queue_status_test.exs \
  test/foreman_server/aggregates/run_slots_release_test.exs \
  --warnings-as-errors'
```

Expected (verified during planning): `Result: 56 passed`, exit 0.

No formatter/lint run is needed because no file changes; if the fix report is the only
new file, `mix format` has nothing to do (Markdown is not formatted by `mix format`).

Success = both commands exit 0 with the counts above and `git diff --stat` shows no
change outside `docs/reports/foreman-beads:foreman:foreman-tepov/`.

## 6. Out of scope

- Do **not** touch `packages/foreman_server/lib/foreman_server/command_gateway.ex`,
  `aggregates/run_slots.ex`, `workflow/dispatcher.ex`, `run_admission.ex`,
  `projection_store.ex`, `mcp/tools.ex`, or `packages/foreman_cli/`.
- Do **not** add a second cancellation path, a `RunCancelled` event for queued runs,
  or any new command/event type — the existing `run_slots.remove_waiter` →
  `RunSlotWaiterRemoved` + `task.run_terminated` pair is the design.
- Do **not** implement the sibling findings from the same stale analysis (task-close
  removing a waiter; `foreman_run_status` reporting `queued`; a `cancelled` task
  status). They are separate beads with their own scope.
- Documentation gate: this change adds, removes and renames **no** externally visible
  identifier (no route, config key, env var, CLI verb, MCP tool, command or event
  type), so `CLAUDE.md`, `README.md`, `docs/user-guide.md` and `docs/cli-reference.md`
  need no edit — `docs/cli-reference.md:697` already documents the queued-cancel
  behaviour.
- Do not create a branch, commit, push, or open a PR beyond what the workflow does.
