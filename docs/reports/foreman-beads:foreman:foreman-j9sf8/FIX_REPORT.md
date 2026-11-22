Report written and verified on disk (8117 bytes, untracked — Foreman commits it).

## Phase 2 (`fix`) — Blocked, reported

**No `lib/` change.** `PLAN.md`'s remaining gap can't be implemented without violating a constraint the same plan states.

**The conflict.** The plan wants a bounded retry cap + `release_slot` on the `{:error, {:not_found, :run, _}}` arm (`run_executor.ex:952-960`). But that arm is only reachable when `fetch_run` succeeded moments earlier — `dispatch_next` re-fetches the projection on every attempt (`exec/supervisor.ex:6254`). So the run *was* cached and was removed mid-start, and **every** such removal path already releases the slot (`foreman_commands.ex:1924-1933` → `force_release`; `exec/supervisor.ex:6077` in `cancel_run`, also used by `abandon_run.ex:27`). Deleting a run mid-start is otherwise refused (`starting?/1`, `:6100-6102` → `already_finished`). The slot is already free.

So:
- Adding `release_slot` would `force_release` a slot the run doesn't hold — `queue.ex:249-271` splices *another* queued run into the opening, i.e. steals its slot.
- A terminal transition isn't available (`cancel_run` → `already_finished`; no aggregate to command).
- A hard cap would fire on a legitimate transient `not_found` and strand a live run: slot held, no exec process, no dispatch loop. Self-healing → hang.

**Also:** the structural fix is already on `main` — `dispatch_next` no longer loops on `start_run` errors; it branches `:not_found` → `reclaim_reserved` + `schedule_dispatch_next(run_id, 0, :reconcile_missing_projection)`, so attempts reset and the monotonic counter the plan relies on is gone. `PLAN.md`'s premise needs re-verification.

**Third:** `PLAN.md`'s Phase-2 assertion `assert :ok = Foreman.Inbox.deliver(...)` wouldn't compile — it returns `{:ok, map} | {:error, term}` (`lib/foreman/inbox.ex:83-120`).

**Test status:** last clean run of `exec/queue_test.exs` was 10 tests, 0 failures (exit 0). Two later attempts were unusable: `DATABASE_URL=miset` crashed at `mix.exs:185`, and a re-run hit the `foreman_test` advisory lock held by another suite. I did not run the full baseline suite — no behaviour change to validate, and the plan is unexecutable as written.

**Docs gate:** no identifiers added/removed/renamed (report file only). All four files — `docs/user-guide.md`, `docs/cli-reference.md`, `README.md`, `CLAUDE.md` — need no edits; no operator-visible change.

Escalation was unavailable (`contact_supervisor`: no supervisor; `ask`: disallowed headless), so the conflict is documented in the report for the operator: re-verify the premise against current `main`; if a cap is still wanted, terminalising a run with no aggregate needs its own design task.