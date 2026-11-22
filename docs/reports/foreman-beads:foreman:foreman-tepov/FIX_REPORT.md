Phase 2 complete. Summary of what landed:

**Root cause** (from PLAN.md): `run.cancel` had no path for a queued run. Queued runs have no aggregate until slot promotion, so the handler's aggregate lookup missed and collapsed to `{:error, :not_found}` → HTTP 422 `{:not_found, :run, <id>}`. The `Lease` already models cancellation correctly (`remove_waiter` + `lease.waiter.removed`), but nothing exposed that transition.

**Changes** (6 files, +352/−8):
- `RunSlotQueue.cancel_queued/3` — new `@spec`. Single guard (`@type t`, `run_id` required + `waiter_of/2` containment), delegates `Lease.remove_waiter/2`, emits `Lease.WaiterRemovedEvent` with `reason: "run.cancel"`. Deliberately does **not** re-check `position == 1`: promotion requires head + no active lease, so a head waiter that just acquired the slot fails the update and correctly reports started.
- `Dispatcher.cancel_run/3` — 2nd clause `case run_cancel(:run, run_id, opts) do {:error, :not_found} -> queued path`, 3rd `raise "run.cancel returned #{inspect(other)}"`. Both branches re-check waiter existence at update time.
- `RunCancelAdapter` — cancel-first, then `RunStore.fetch(run_id) || QueueStore.fetch(:run_slot, project_id)` fallback for `RunQueued`; `cancel_requested` stays at top of both shapes.
- `MCP.Tools` — `"run.cancel"` clause before the aggregate branch (required — queued runs miss the aggregate store); `@doc false run_cancel/3` wrapping `Dispatcher.cancel_run/3`.
- `Api.Web.RunController` — passes `project_id: run.project_id`.
- `test/foreman_server/run_cancel_test.exs` — 9 new tests: queued cancel, queue status empty, waitlist behavior, `queue.list` excludes it, second cancel → `:not_found`, **never starts later** (drain both slots, assert task back to `scheduled`), started-run behavior unchanged, HTTP 200, MCP boundary returns `project_id`.

**Deviations**: none in code. Report is at the required path.

**Verification**: `mix compile --warnings-as-errors` clean (the pre-existing untracked `apps/foreman_langfuse_ingest/lib/foreman_langfuse_ingest/mcp/tools.ex` placeholder would make it fail on any branch, so ran it with that file temporarily aside, then restored untouched). Focused test file: 11/11. Both PLAN verification commands + `run_slot*` + `mcp/tools_test*` + `run_store*` + `api/web/run_controller_test*` + `api/web/*queue*`: **79 tests, 0 failures**. Filtered run confirmed each new test fails at pre-fix HEAD (`function_clause`/`MatchError`/12 failures).

**Docs gate**: `run.cancel` / `foreman_run_cancel` / `foreman_queue_status` appear in all four target files and each already described queued-run cancellation as intended behavior — so this change makes docs true. No identifier added, removed or renamed; no doc edits needed. `docs/cli-reference.md:332` records that `--project` was never plumbed to the HTTP layer — left alone.

**Follow-ups flagged, not done**: two queued→`queued→`stale-run paths outside task scope (task deleted/`br close` while waiter sits → orphaned waiter with no projection to cancel; waiter removed via unqueued `run.remove` → `cancel_queued/3` returns `:not_found` even though the id lingers in `run.cancel` response); no `cancel_reason` projection on `RunStore`.

Two caveats worth your attention: `ask_advisor` is unavailable in this environment (3 attempts → 400 `Error: Not Found`, same as `foreman_165fu`), so no advisor completion review ran; and `foreman_inbox_send` / `foreman_task_add_comment` were never exposed here, so the phase-2 report file is the only operator-visible record.