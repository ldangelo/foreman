Plan written. 225 lines.

**Verdict: real bug.**

- `tools.ex:1881` `tool_foreman_run_status/1` reads only `ProjectionStore.run/1` → `nil` for a slot waiter → `NOT_FOUND`.
- Waiter has no run projection b/c `RunAdmission.start/2` returns `{:ok, :slot_queued}` and `dispatcher.ex:1227` skips `run.start`.
- Honest answer already exists: `ProjectionStore.pending_run/1` (`projection_store.ex:331`/`:4893`) → `%{status: "queued"|"deferred", reason}`. HTTP already uses it (`run_controller.ex:44` `show_pending/2`, 200 not 404). Only MCP tool left behind.

**Fix (4 edits, all in tools.ex):** add `reason` to `RunStatus` DTO; fallback to `pending_run/1` in `tool_foreman_run_status/1`; new `pending_run_status_dto/1` (terminal false, no current_phase, raises on missing identity per §5.3); schema description updated. `NOT_FOUND` still stands for an id with neither run nor pending task.

**Failing check first:** 2 new tests in `tools_test.exs` `describe "foreman_run_status"` (queued + deferred via `project_deferrals` fixture).

**Doc gate:** no new identifier, but operator-visible DTO change → 1-line edits in README.md:385, docs/user-guide.md:2200, docs/cli-reference.md:1569, CLAUDE.md:1033. Listed in the plan.

No code touched; only `docs/reports/foreman-beads:foreman:foreman-24jxg/PLAN.md` created (untracked).