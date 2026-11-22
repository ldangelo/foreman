# Fix report — beads:foreman:foreman-laju1 (run-ea2a2369059c083d826f0a32d81edd98)

## Status: Implemented — two behaviours fixed, two new regression tests added

The task asked for three regression tests in `packages/foreman_server`:

- (a) cancelling a run that is queued for a slot removes its waiter and ends it;
- (b) closing/cancelling a task while its run is queued, then freeing a slot,
  must not start the run;
- (c) run status for a queued run returns `queued` rather than `NOT_FOUND`.

(a) was already covered by an existing test and needed no new one. (b) and (c)
were real gaps: the new tests failed before the fix and pass after it. All
changed lines are in this branch's diff; nothing is committed by this run
(Foreman commits the phase).

## What changed

| File | Change |
| --- | --- |
| `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex` | `start_promoted_run/2`: new head clause for terminal task statuses |
| `packages/foreman_server/lib/foreman_server/mcp/tools.ex` | `tool_foreman_run_status/1`: pending-projection fallback + `pending_run_status_dto/1` |
| `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs` | new test for (b) |
| `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` | new test for (c) |
| `docs/cli-reference.md`, `docs/user-guide.md`, `CLAUDE.md` | behaviour sentences only (doc gate) |
| `docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md` | restored from git history (was overwritten by a truncated commit) |

### (a) Cancelling a queued run — already covered, no change

`packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs:42`
already asserts the whole contract: the waiter is removed, the slot holder is
untouched, the task's `acknowledged_run_id` is set to the cancelled run, and
`ProjectionStore.pending_run(queued)` becomes `nil`. That file is re-run below
(5 tests) as the regression guard for (a); adding a second copy of the same
contract would not add coverage.

### (b) A closed task must not have its queued run promoted

Root cause: `start_promoted_run/2`
(`packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1436`) is
reached for a run that has no projection yet (`reenter_slot_admission/2` falls
through to the `_no_run_yet` branch at `:1420`). Its only guard was
`[%{acknowledged_run_id: ^run_id} | _]` (`:1452`). `task.update` to `closed` or
`failed` sets only `status` and `failure_reason`
(`packages/foreman_server/lib/foreman_server/aggregates/task.ex:131`), never
`acknowledged_run_id`, so a task closed while its run waited for a slot was
still admitted to the next free slot.

Fix — one clause, inserted before the `[task | _]` clause:

```elixir
[%{status: status} | _] when status in ["closed", "failed", "merged"] ->
  Logger.info(
    "handle_slot_promoted: not starting #{run_id}: its task is #{status}"
  )

  terminate_slot(run_id, "run_cancelled")
  {:noreply, state}
```

`terminate_slot/2` (`dispatcher.ex:915`) is the existing release path, so the
run also drops its waiter and frees the slot — the same thing a cancelled run
does. The status list is a deny-list on purpose: task projections written
before this change carry no `:status` key, and those must keep today's
behaviour.

### (c) Run status of a queued run is `queued`, not `NOT_FOUND`

Root cause: `tool_foreman_run_status/1`
(`packages/foreman_server/lib/foreman_server/mcp/tools.ex:1881`) read only
`ProjectionStore.run/1`; a run that has not started has no run projection, so
the tool answered `NOT_FOUND`. HTTP already answered `queued` for the same run
via `ProjectionStore.pending_run/1`
(`packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex:44`),
so the two boundaries disagreed.

Fix — the tool now falls back to the pending projection, and a new private
helper builds the same bounded `RunStatus` shape the HTTP boundary uses:

```elixir
result =
  case ProjectionStore.run(run_id) do
    nil -> pending_run_status_dto(ProjectionStore.pending_run(run_id))
    run -> run_status_dto(run, ProjectionStore.phases_for_run(run_id))
  end
```

`pending_run_status_dto/1` returns `nil` for an unknown run (so `NOT_FOUND`
still means "unknown run id"), and otherwise a `RunStatus` with
`status: "queued"` (`"deferred"` while the project is deferred), `terminal:
false` and `current_phase: nil`. `tool_foreman_run_get/1` is untouched.

## Tests

New tests:

- `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`
  — "does NOT admit a promoted run whose task was closed, and drops its slot":
  a `RunSlotTransferred` event promotes a run whose task projection is
  `closed`; the test asserts `RunAdmission.start/2` and
  `RunSupervisor.start_run/2` are never called and that the slot is released
  and the waiter removed.
- `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` — "returns
  the queued pending projection instead of NOT_FOUND for a run waiting on a
  slot": a task in `in_progress` with an unacknowledged run and no run
  projection; the tool must answer `status: "queued"`, `terminal: false`,
  `current_phase: nil`, with the task and project ids.

### Failing first, passing after (real output)

Red — before the two source edits:

```
devbox run -- bash -c 'cd packages/foreman_server && export DATABASE_URL="postgres://postgres:postgres@127.0.0.1:55432/foreman_test_laju1" && MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/mcp/tools_test.exs'
→ exit 2, Result: 37/39 passed, Failed: 2 tests
  1) test RunSlotTransferred with failed admission logs warning does NOT admit a promoted run whose task was closed, and drops its slot (ForemanServer.Workflow.DispatcherSlotPromotedTest)
     test/foreman_server/workflow/dispatcher_slot_promoted_test.exs:338
     "a closed task must not have its queued run admitted"
     code: refute :meck.called(ForemanServer.RunAdmission, :start, :_)
  2) test foreman_run_status returns the queued pending projection instead of NOT_FOUND for a run waiting on a slot (ForemanServer.MCP.ToolsTest)
     test/foreman_server/mcp/tools_test.exs:346
     match (=) failed
     right: {:error, %ForemanServer.MCP.ToolError{code: "NOT_FOUND", message: "Run not found"}}
```

Green — after the two source edits:

```
devbox run -- bash -c 'cd packages/foreman_server && export DATABASE_URL="postgres://postgres:postgres@127.0.0.1:55432/foreman_test_laju1" && MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/mcp/tools_test.exs test/foreman_server/command_gateway_cancel_queued_run_test.exs'
→ exit 0, Result: 44 passed
  ProjectionLeakGuard: judged 3 of 3 modules, no run left behind
```

### A leak this run introduced and removed

The first version of the new (b) test mocked `ForemanServer.CommandGateway`
with `:meck.new(..., [:no_link])` and never unloaded it. Because that mock
replaces the module globally, every later test in the suite that called a
`CommandGateway` function it did not stub failed with
`** (UndefinedFunctionError) function ForemanServer.CommandGateway.dispatch_operator/1 is undefined or private`
— 168 failures in the first full-suite attempt, all unrelated to this task.
CodeRabbit flagged it as a major finding ("Unload the `CommandGateway` mock in
the test that creates it"); the fix matches the convention already used in
`dispatcher_slot_release_test.exs:44`, `dispatcher_slot_rebalance_test.exs:193`
and `run_admission_slot_gate_test.exs:226`:

```elixir
:meck.new(ForemanServer.CommandGateway, [:passthrough, :no_link])
on_exit(fn -> :meck.unload(ForemanServer.CommandGateway) end)
```

The full suite was re-run from scratch after that fix; see "Validation".

## Validation

```
devbox run -- bash -c 'cd packages/foreman_server && export DATABASE_URL="postgres://postgres:postgres@localhost:55432/foreman_test_laju1" && MIX_ENV=test mix test --warnings-as-errors'
→ exit 0
  Finished in 1380.3 seconds (57.1s async, 1323.1s sync)
  Result: 9172 passed (8 properties, 9164 tests), 11 excluded
  ProjectionLeakGuard: judged 355 of 553 modules, no run left behind

devbox run -- bash -c 'cd packages/foreman_server && mix format'
→ exit 0 (no reformat diff in the changed files)
```

### A full-suite run that failed for environmental reasons only

An earlier full-suite run (the same tree, after the meck-leak fix) exited 2 with
`Result: 9169/9172 passed` and three failures. None of them was caused by this
change:

- `ForemanServer.ConfigTest` "dev env (TRD-022) EventStore reads DATABASE_URL
  with localhost default" and the same for `Repo`
  (`packages/foreman_server/test/foreman_server/config_test.exs:73` and `:87`)
  — both assert `url =~ "localhost"`. That run pointed `DATABASE_URL` at
  `127.0.0.1:55432`, so the dev-env default could not be `localhost`. The
  final run above uses `localhost` and both tests pass.
- `ForemanServer.ProjectMemory.StoreTest` "a write rejected by :index_full
  leaves the directory byte-identical" —
  `** (ExUnit.TimeoutError) test timed out after 60000ms` at
  `packages/foreman_server/test/foreman_server/project_memory/store_test.exs:106`
  (via `packages/foreman_server/lib/foreman_server/project_memory/store.ex:144`
  `read_raw/2` ← `store.ex:331` `list_entries/1` ← `store.ex:82` `write/3`).
  It is a file-I/O timeout under the load of a 9 000-test suite; it did not
  reproduce in isolation and the final full-suite run passed.

Re-running both files on their own with the same `DATABASE_URL` gave
`Result: 21 passed`, exit 0, which is how both were classified.

Environment notes for anyone re-running this:

- Ambient `DATABASE_URL` points at `postgres://postgres:postgres@localhost:55434/foreman_dev`
  and makes `mix test` fail with `FATAL 28P01` from `mix.exs:203
  claim_database!/2`; unset it so the test config uses `:55432`/`foreman_test`.
- `mix.exs:203` claims the test database with a Postgres advisory lock, and
  that lock is per database. A concurrent Foreman run held `foreman_test`, so
  this run used a separate database,
  `postgres://postgres:postgres@127.0.0.1:55432/foreman_test_laju1`, whose
  schema was replicated from `foreman_test`
  (`pg_dump --schema-only foreman_test | psql foreman_test_laju1`).

## Documentation gate

No externally visible identifier was added, removed or renamed: no command or
event type, no MCP tool, no route, no CLI verb or flag, no env var, no config
key, no workflow or prompt name. Only behaviour sentences changed:

- `docs/cli-reference.md` (`foreman_run_status`): a run waiting for a slot
  answers `status: "queued"` (`"deferred"` while the project is deferred),
  `terminal: false`, `current_phase: null`; `NOT_FOUND` means the run id is
  unknown.
- `docs/user-guide.md` (same contract, in the `foreman_run_status` bullet).
- `CLAUDE.md:1033`: the `foreman_run_status` sentence now names the
  `ProjectionStore.pending_run/1` fallback and the meaning of `NOT_FOUND`.
- `README.md`: no edit needed — it does not describe run-status semantics for
  queued runs.

## Remaining / notes

- `PLAN.md` in this report directory had been overwritten by a truncated
  commit (12 lines of chat summary). It was restored from git history
  (`git show c5e41c70:docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md`,
  273 lines); the restored plan also had its full-gate command corrected to
  `unset DATABASE_URL`.
- The sibling beads `foreman-pjugt` / `foreman-24jxg` work on the same area
  and were left untouched here.
