Phase complete.

## What happened

**Bead was unimplemented.** Branch carried zero production code for the slot-promotion status re-check (phase-2 `FIX_REPORT.md` claimed otherwise). Shipped it here:

`packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
- `@non_startable_task_statuses ~w(closed failed blocked)` (:1438)
- new clause `[%{status: status} | _] when status in @non_startable_task_statuses ->` (:1467) → `terminate_slot(run_id, "task_#{status}")` → dispatches `run_slots.release` + `run_slots.remove_waiter`

Why the old guard missed it: `TaskUpdated`/`TaskExecutionCompleted` move only `status`, never `acknowledged_run_id`, so the acknowledged clause can't see a closed task.

**CodeRabbit 0.9.6** — round 1: 5 major, all in the previous phase's test file (it didn't compile: stray `end})`, undefined `transferred_envelope/1`, bare `ProjectionStore` vs mocked module, `^run_id` inside `:meck.called/3`, undefined `History.recorded/1`). All 5 fixed by rewriting the two new tests. Round 2: 0 findings over 4 files → stop rule satisfied, no round 3.

**Verification**: 10 / 43 / 136 tests passed with `--warnings-as-errors`; `mix format --check-formatted` exit 0.

**Report**: `docs/reports/foreman-beads:foreman:foreman-pjugt/REVIEW_CODERABBIT_REPORT.md`, both machine-read blocks validated against the real parsers (`ReviewFindings.read/1` → `{:ok, …}`; `PrRisk.parse_judgement/1` → `%{status: "recorded", level: "MEDIUM"}`). First draft was malformed (`totals` key, object-valued `reviewed`) and was rewritten.

**Left uncommitted** for Foreman: `dispatcher.ex` +13, test file +85/−28, new report.

Two scope items deliberately left to `beads:foreman:foreman-tepov`: `run.cancel` of a queued run, and task-cancel removing the waiter. `foreman_task_add_comment` isn't exposed to this phase (operator notified via `foreman_inbox_send`, msg_ypbRmqtBypdw2QgptwNdew); advisor review unavailable (Anthropic `invalid_grant`).