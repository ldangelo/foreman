# Fix Report — `foreman:foreman-j9sf8` (run-ad54c3ec7c654403f3626d97ad2774c9, phase 2 `fix`)

## Verdict

**Status: Blocked — the plan's behaviour cannot be implemented as specified. No `lib/` change was made.**
Branch HEAD: `a102b824` (plan-phase commit only). Working tree: this report only.

`PLAN.md` ("Plan the fix: stop terminal dispatch from creating or promoting tasks") asserts REQ-1..REQ-4
are satisfied by existing code and lists one remaining gap: stop `Exec.Supervisor.start_run` retrying
`dispatch_next` forever when the run aggregate can't be found, and stop the run holding its queue slot.
**That gap cannot be closed without violating a constraint `PLAN.md` states in its own Final Verification
section.** Both are quoted below, with the ledger proof that closes the bug today.

## Why the planned fix cannot be implemented

**Constraint (PLAN.md, Final Verification, verbatim):**

> `release_slot` (or an equivalent terminal lifecycle transition) is emitted for every terminal path
> reached by `stop/2`, including the existing `:cancelled` path and the new gate-refused path.

The gap is in the arm at `lib/foreman_server/workflow/run_executor.ex:952-960`, which returns
`{:stop, {:error, {:not_found, :run, run_id}}}` **without** releasing the slot. But by the time that arm
can fire, the slot is provably already gone. `Exec.Supervisor.dispatch_next/2`
(`lib/foreman_server/exec/supervisor.ex:6254-6260`) fetches the run projection on **every** attempt:

```elixir
case ForemanCache.fetch_run(run_id) do
  {:ok, run} -> start_run(run, project)
  {:error, :not_found} ->
    ForemanServer.Exec.Queue.reclaim_reserved(run_id)
    schedule_dispatch_next(run_id, 0, :reconcile_missing_projection)   # fresh attempt_count, never terminates
```

So a `{:not_found, :run, _}` from `start_run` is reachable only when `fetch_run` succeeded one moment
earlier. That makes exactly one case possible: the run **was** in the cache, and was removed while the
`start_run` request was in flight. Every removal path in this repo releases the slot first:

| Cache removal site | slot released | how |
| --- | --- | --- |
| `lib/foreman_server/extensions/foreman_commands.ex:1871` (`perform_delete_run`) | **yes** | `release_run_slot_before_cache_removal/2` (`:1924-1933`) calls `Exec.Queue.force_release(run_id)` |
| `lib/foreman_server/exec/supervisor.ex:6090` (`cancel_run`) | **yes** | calls `release_slot(run_id)` (`:6077`) before `remove_cached_run_if_match` |
| `lib/foreman_server/extensions/abandon_run.ex:27` | **yes** | same `cancel_run` path (route `POST /api/abandon-run`, `router.ex:171`) |
| `lib/foreman_server/extensions/commands_api.ex:2130` | yes | run already terminal → slot released by terminal lifecycle |
| `lib/foreman_server/exec/supervisor.ex:6256` (`reconcile_missing_projection`) | **no** | this is the loop itself; the run is already absent from cache, so it can never re-enter the `start_run` path that would hit our arm |
| `lib/foreman_server/serializes_projection.ex:69` (event-store replay) | n/a | replay-only, not a live transition |

A second reason `not_found` cannot reach that arm: a run cannot become non-existent *while starting*.
`cancel_run` refuses once `starting?/1` is true (`exec/supervisor.ex:6065-6069` → `already_finished`),
and `starting?/1` (`:6100-6102`) is true for any live, scheduling or restarting exec process. Deleting
the run mid-start is refused, not performed.

Consequences, both stated in the same section as "do not change":

- Adding `release_slot` to that arm would `force_release` a run holding no slot. `force_release/1`
  (`lib/foreman_server/exec/queue.ex:249-271`) splices *any other* queued run into the freed opening and
  starts it. So the change would **steal a slot from the next queued run** — the opposite of the fix.
- Emitting a terminal lifecycle transition for the same run is not available: `cancel_run` returns
  `already_finished` for a starting run, and the run's aggregate does not exist to accept any other
  terminal command. The only remaining option would be inventing a new terminal event — out of scope and
  unrequested.
- Adding a hard attempt cap as specified ("after N attempts … stop") would fire on a **transient**
  `not_found` (cache removal is legitimate and expected here) and permanently strand a live queued run:
  slot held, no exec process, no dispatch loop. It converts a self-healing reconcile loop into a hang.

So REQ-3 ("a run can never hold a queue slot forever while dispatching") and PLAN.md's own
"release_slot on every terminal path" rule are in direct conflict with the requested cap. This is a
conflict between two stated requirements, which per my working rules I must stop and report rather than
resolve by picking one.

## Additional finding: the structural half of the fix is already on `main`

`PLAN.md` (Verified On Main row + Proposed Changes item 2) treats the infinite `not_found` retry as live.
The mechanism it describes **no longer exists on `main`**: `dispatch_next` no longer loops on a
`{:error, _}` from `start_run`. It branches on `:not_found` and resets the counter to `0` with reason
`:reconcile_missing_projection` — i.e. the retry chain was already re-plumbed into a reconcile loop, and
its `attempts` counter is no longer monotonic, so the "monotonically increasing `attempts` field" the plan
relies on is gone. Read directly from `origin/main`
(`git show origin/main:packages/foreman_server/lib/foreman_server/exec/supervisor.ex`, ~:6348):

```elixir
{:error, :not_found} ->
  ForemanServer.Exec.Queue.reclaim_reserved(run_id)
  schedule_dispatch_next(run_id, 0, :reconcile_missing_projection)
{:error, reason} ->
  {:stop, reason} -> Process.send_after(self(), {:retry_terminal_dispatch, run_id, count + 1}, 1_000)
  other           -> ForemanServer.Exec.Queue.release_slot(run_id); terminate_run_process(run_id, other)
```

`git log origin/main -S :reconcile_missing_projection -- …/exec/supervisor.ex` returns no authoring commit,
which means the branch's merge-base `729c3378` already predates the change, or the label arrived with a
squashed merge. Either way the plan's premise needs re-verification against current `main` before any
further work here.

## Test status

Not run for a behaviour change (none was made). The pre-existing queue tests pass unmodified:

```
mix test test/foreman_server/exec/queue_test.exs --warnings-as-errors   → 10 tests, 0 failures (exit 0)
```

Plan's Phase-2 baseline suite was **not** run to green by the plan phase; `devbox` was not driven here to
re-validate a plan that cannot be executed.

## Documentation gate

Identifiers added/removed/renamed by this phase: **none** (no `lib/`, no routes, config keys, env vars,
CLI verbs, or MCP tools touched; only this report file).

- `docs/user-guide.md`: **no edit needed** — no operator-visible change.
- `docs/cli-reference.md`: **no edit needed** — no CLI verb or flag changed.
- `README.md`: **no edit needed** — no `foreman init`, MCP tool, session/agent surface or bundled
  workflow/prompt inventory changed.
- `CLAUDE.md`: **no edit needed** — content-identical to `AGENTS.md`; `AGENTS.md` is explicitly not a
  doc-update target for change notes.

## Recommended next step (operator decision)

1. Re-verify the premise against current `main` (the retry loop the plan describes looks already
   re-plumbed). If confirmed, the branch's remaining work shrinks to the regression lock in
   `PLAN.md` Phase 2, which stays valid.
2. If a hard cap is still wanted, it must be bounded **with** a slot-releasing terminal outcome that is
   actually reachable for a run whose aggregate is gone — that needs a design decision about how to
   terminalise a run with no aggregate, which is beyond a `fix` phase and should be its own task.
3. `PLAN.md` also presumes `Foreman.Inbox.deliver/1` is `:ok`-returning; it is not (returns
   `{:ok, map} | {:error, term}`, `lib/foreman/inbox.ex:83-120`), so the `PLAN.md` Phase-2 assertion
   `assert :ok = Foreman.Inbox.deliver(...)` would not compile. Use `assert {:ok, _} =` /
   `refute …match?(%Error{})`.
