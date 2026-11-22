# PLAN — Make `foreman_run_status` report queued runs (beads:foreman:foreman-24jxg)

## 1. Verdict

**Real bug, present on this tree** (HEAD `796c888c`).

`packages/foreman_server/lib/foreman_server/mcp/tools.ex:1881` `tool_foreman_run_status/1`
reads only `ProjectionStore.run/1`; when that is `nil` it returns
`%ToolError{code: "NOT_FOUND", message: "Run not found"}`. A run waiting on a slot has **no**
run projection (the run aggregate is created only at slot promotion), so the tool answers
NOT_FOUND while `foreman_queue_status` lists the same id under `waiting`.

The honest-status helper already exists and is already used by HTTP:
`ProjectionStore.pending_run/1` (`packages/foreman_server/lib/foreman_server/projection_store.ex:331`,
impl at `:4893`) returns
`%{run_id, task_id, project_id, status: "queued" | "deferred", reason: String.t() | nil}`
for a minted run id whose task is `in_progress` and unacknowledged and which has no run
projection, else `nil`. `ForemanServerWeb.RunController.show_pending/2`
(`packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex:44`) already
answers `200` with it. The MCP tool is the only surface that still lies.

Existing proof the pending status is produced:
`packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs:58`
asserts `%{status: "queued"} = ProjectionStore.pending_run(queued)`.

## 2. Root cause

`tool_foreman_run_status/1` in `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
treats "no run projection" as "unknown run". It never consults
`ProjectionStore.pending_run/1`.

## 3. Failing check first

Add one test to the existing `describe "foreman_run_status"` block in
`packages/foreman_server/test/foreman_server/mcp/tools_test.exs` (insert immediately after
the existing `test "returns NOT_FOUND when run is unknown" do ... end`, around line 341):

```elixir
    test "a run still waiting on a slot reports queued, not NOT_FOUND" do
      task = %{
        task_id: "task-9",
        project_id: "proj-1",
        status: "in_progress",
        run_id: "run-9"
      }

      replace_state(%{runs: %{}, tasks: %{"task-9" => task}})

      assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: "run-9"})
      assert dto.run_id == "run-9"
      assert dto.status == "queued"
      assert dto.terminal == false
      assert dto.project_id == "proj-1"
      assert dto.task_id == "task-9"
      assert dto.current_phase == nil
    end
```

(`replace_state/1` is the local helper at line 21; it merges over
`ProjectionStore.initial_state()`, so `project_deferrals` is present and `pending_run/1`
reports `"queued"` with `reason: nil`.)

Show it red:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/mcp/tools_test.exs --warnings-as-errors'
```

Expected failure before the fix: match on `{:ok, dto}` fails with
`{:error, %ForemanServer.MCP.ToolError{code: "NOT_FOUND", message: "Run not found"}}`.

## 4. Edits

All in `packages/foreman_server/lib/foreman_server/mcp/tools.ex`.

**Edit 1 — `tool_foreman_run_status/1` (line 1881–1888), fall back to the pending read.**

Replace:

```elixir
    result =
      case ProjectionStore.run(run_id) do
        nil -> nil
        run -> run_status_dto(run, ProjectionStore.phases_for_run(run_id))
      end
```

with:

```elixir
    result =
      case ProjectionStore.run(run_id) do
        nil -> pending_run_status_dto(ProjectionStore.pending_run(run_id))
        run -> run_status_dto(run, ProjectionStore.phases_for_run(run_id))
      end
```

Leave the telemetry/outcome lines below it unchanged: a pending DTO is truthy, so the
outcome becomes `:ok` and only a genuinely unknown id still yields `NOT_FOUND`.

**Edit 2 — new private builder, directly above `defp run_status_dto(run, phases)` (line 3583).**

Insert:

```elixir
  # A run id minted by `task.approve` exists before admission produces a run projection: the
  # run may be waiting on a project run slot ("queued") or refused for now ("deferred").
  # That is pending, not unknown — `GET /api/runs/:id` already answers the same way. No run
  # aggregate means no phases, hence no `current_phase` and no timestamps.
  defp pending_run_status_dto(nil), do: nil

  defp pending_run_status_dto(%{run_id: run_id, status: status} = pending)
       when is_binary(run_id) and is_binary(status) do
    %RunStatus{
      run_id: run_id,
      status: status,
      terminal: false,
      project_id: Map.get(pending, :project_id),
      task_id: Map.get(pending, :task_id)
    }
  end
```

Do not add a catch-all clause: `pending_run/1` documents exactly these two shapes, so an
unexpected one must raise (AGENTS.md §5.2). Do not add fields to the `RunStatus` struct;
the deferral `reason` stays on `GET /api/runs/:id`, which already carries it.

**Edit 3 — tool description, `@schema_foreman_run_status` (line 910–912).**

Replace:

```elixir
    description: "Get a bounded run status DTO from run and phase projections",
```

with:

```elixir
    description:
      "Get a bounded run status DTO from run and phase projections. A run that is " <>
        "still waiting on admission reports status queued or deferred with no phases.",
```

**Edit 4 — docs (documentation gate; the tool now reports two new status values).**
Add one sentence to each, next to the existing `foreman_run_status` description:

- `README.md:385` — after the field list: "A run still waiting on a project run slot reports
  `status` `queued` (or `deferred` when admission refused it for now) with no `current_phase`,
  instead of `NOT_FOUND`."
- `CLAUDE.md:1033` (§19, first paragraph after the `ProjectionStore.phases_for_run/1`
  sentence) — "When there is no run projection yet, the DTO is built from
  `ProjectionStore.pending_run/1` (`queued` / `deferred`, `terminal: false`, no phases); only
  an id no task claims is `NOT_FOUND`."
- `docs/user-guide.md:2200` (the `foreman_run_status` bullet in section 9) — same sentence as
  README.
- `docs/cli-reference.md:1599` (the `foreman_run_status` paragraph) — same sentence as README.

No other identifier is added, removed or renamed: no new tool, route, CLI verb, flag, env var
or config key. `docs/cli-reference.md:691` already documents the HTTP pending behaviour and
needs no change.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && mix format'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/mcp/tools_test.exs test/foreman_server/mcp/run_status_test.exs test/foreman_server/mcp/tool_inventory_test.exs test/foreman_server/command_gateway_cancel_queued_run_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = the new test passes, the existing
`test "returns NOT_FOUND when run is unknown"` still passes (empty `tasks`, so
`pending_run/1` is `nil`), and the full suite is green with zero failures. Record the real
counts and exit code in the fix report.

## 6. Out of scope

- `foreman_run_get`, `foreman_run_get_logs`, `foreman_inbox_get` and every other run tool:
  the task names run **status** only.
- Adding `reason` (or any field) to the `RunStatus` struct, and the pinned key-sort assertion
  at `packages/foreman_server/test/foreman_server/mcp/tools_test.exs:260-275` — it must stay
  unchanged.
- `ProjectionStore.pending_run/1`, `queue_status/1`, the run-slot aggregate, the dispatcher,
  `run.cancel` for queued runs, and the task-status enum: other gaps from the same review are
  separate beads.
- `ForemanServerWeb.RunController`: already correct.
