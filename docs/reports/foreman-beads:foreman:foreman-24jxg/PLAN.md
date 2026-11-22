# PLAN — foreman_run_status must report queued runs

## 1. Verdict

**Real bug on the current tree** (HEAD `796c888c`).

`packages/foreman_server/lib/foreman_server/mcp/tools.ex:1881` `tool_foreman_run_status/1`
reads **only** `ProjectionStore.run/1`:

```elixir
    result =
      case ProjectionStore.run(run_id) do
        nil -> nil
        run -> run_status_dto(run, ProjectionStore.phases_for_run(run_id))
      end
    ...
      else: {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
```

A run waiting for a project run slot has **no run projection** (`RunAdmission.start/2`
returns `{:ok, :slot_queued}` and `Workflow.Dispatcher.admit_and_start_run/5` skips
`run.start`, `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1227`), so
`ProjectionStore.run/1` is `nil` → `NOT_FOUND`, while
`ProjectionStore.queue_status/1` lists the id under `waiting`
(`packages/foreman_server/lib/foreman_server/projection_store.ex:4447`).

The honest answer already exists: `ProjectionStore.pending_run/1`
(`packages/foreman_server/lib/foreman_server/projection_store.ex:331`, impl at `:4893`)
returns `%{run_id, task_id, project_id, status: "queued" | "deferred", reason}`.
The HTTP read model already uses it
(`packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex:44`
`show_pending/2` → 200 instead of 404). Only the MCP tool was left behind.

Existing proof `pending_run/1` is populated for a slot waiter:
`packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs:58`
`assert %{status: "queued"} = ProjectionStore.pending_run(queued)`.

## 2. Root cause

`ForemanServer.MCP.Tools.tool_foreman_run_status/1` has no pending-run fallback; it treats
"no run projection" as "unknown run". Fix = mirror the controller: fall back to
`ProjectionStore.pending_run/1` and build a `RunStatus` DTO from it.

## 3. Failing check first

Add two tests to the existing `describe "foreman_run_status"` block in
`packages/foreman_server/test/foreman_server/mcp/tools_test.exs` (block starts at line 201;
insert **after** the `"returns NOT_FOUND when run is unknown"` test, ~line 341):

```elixir
    test "reports a run that is waiting for a slot as queued, not NOT_FOUND" do
      replace_state(%{
        runs: %{},
        phases: %{},
        tasks: %{
          "task-q" => %{
            task_id: "task-q",
            project_id: "proj-1",
            run_id: "run-queued",
            status: "in_progress"
          }
        }
      })

      assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: "run-queued"})
      assert dto.run_id == "run-queued"
      assert dto.status == "queued"
      assert dto.terminal == false
      assert dto.task_id == "task-q"
      assert dto.project_id == "proj-1"
      assert dto.current_phase == nil
      assert dto.reason == nil
      assert {:ok, _json} = Jason.encode(dto)
    end

    test "reports a deferred run with its refusal reason" do
      replace_state(%{
        runs: %{},
        phases: %{},
        tasks: %{
          "task-d" => %{
            task_id: "task-d",
            project_id: "proj-1",
            run_id: "run-deferred",
            status: "in_progress"
          }
        },
        project_deferrals: %{
          "proj-1" => %{
            "2026-11-22" => %{"run_limit_exceeded" => MapSet.new(["task-d"])}
          }
        }
      })

      assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: "run-deferred"})
      assert dto.status == "deferred"
      assert dto.reason == "run_limit_exceeded"
      assert dto.terminal == false
    end
```

Run it red (expect `{:error, %ToolError{code: "NOT_FOUND"}}` and an unknown `:reason` key):

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/mcp/tools_test.exs --warnings-as-errors'
```

## 4. Edits

All in `packages/foreman_server/lib/foreman_server/mcp/tools.ex`.

**Edit 1 — `RunStatus` DTO gains `reason` (module `RunStatus`, lines 30–65).**
In `@type t`, after the `status: String.t(),` line add:

```elixir
            reason: String.t() | nil,
```

In `defstruct`, after `:status,` add `:reason,`. (Default `nil`; `run_status_dto/1` needs no
change — a real run never sets it.)

**Edit 2 — fallback in `tool_foreman_run_status/1` (line 1881).** Replace the `result =`
case with:

```elixir
    result =
      case ProjectionStore.run(run_id) do
        nil ->
          case ProjectionStore.pending_run(run_id) do
            nil -> nil
            pending -> pending_run_status_dto(pending)
          end

        run ->
          run_status_dto(run, ProjectionStore.phases_for_run(run_id))
      end
```

Leave the telemetry/outcome lines and the `NOT_FOUND` else-branch exactly as they are: an id
with neither a run nor a pending task is still `NOT_FOUND`.

**Edit 3 — new private builder.** Insert directly **above** `defp run_status_dto(run, phases)`
(line 3583):

```elixir
  # A run id minted by `task.approve` that has no run projection yet (waiting for a
  # project run slot, or deferred by an admission refusal) is pending, not missing.
  # Same honest shape the HTTP read model already serves
  # (`ForemanServerWeb.RunController.show_pending/2`).
  defp pending_run_status_dto(pending) when is_map(pending) do
    run_id = Map.get(pending, :run_id)
    status = Map.get(pending, :status)

    unless is_binary(run_id) and is_binary(status) do
      raise ArgumentError,
            "pending_run_status_dto: pending run missing required identity fields " <>
              "(run_id: #{inspect(run_id)}, status: #{inspect(status)})"
    end

    %RunStatus{
      run_id: run_id,
      status: status,
      terminal: false,
      project_id: Map.get(pending, :project_id),
      task_id: Map.get(pending, :task_id),
      reason: Map.get(pending, :reason)
    }
  end
```

**Edit 4 — tool schema description (line 912).** Replace:

```elixir
    description: "Get a bounded run status DTO from run and phase projections",
```

with:

```elixir
    description:
      "Get a bounded run status DTO from run and phase projections; a run still " <>
        "waiting for a slot or deferred by admission reports status queued or deferred",
```

Do **not** change `inputSchema` (`tools_test.exs:158` asserts `required == ["run_id"]`).

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/mcp/tools_test.exs test/foreman_server/mcp/run_status_test.exs test/foreman_server/command_gateway_cancel_queued_run_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = both new tests pass, no other test changes behaviour, formatter clean, full suite
green (a failing test is a failed build).

## 6. Documentation gate

No new/removed/renamed route, command/event type, MCP tool name, CLI verb, env var or config
key. One operator-visible DTO change: `foreman_run_status` now answers for a pending run and
its DTO carries `reason`. Update these four (each one sentence, do not restructure):

1. `README.md:385` — after the field list, add: "A run that has no run projection yet
   (waiting for a slot, or deferred by an admission refusal) answers with `status` `queued`
   or `deferred` and `reason` instead of `NOT_FOUND`."
2. `docs/user-guide.md:2200` — in the `foreman_run_status` bullet, add the same sentence.
3. `docs/cli-reference.md:1569` — append to the `foreman_run_status` sentence: "a run
   waiting for a slot or deferred by admission answers `status` `queued`/`deferred` with
   `reason` and no `current_phase`, matching `GET /api/runs/<id>`."
4. `CLAUDE.md:1033` (§19) — add: "`foreman_run_status` falls back to
   `ProjectionStore.pending_run/1` when there is no run projection, so a queued or deferred
   run is never `NOT_FOUND`."

`docs/cli-reference.md:691` already documents the HTTP 200-for-pending behaviour; leave it.

## 7. Out of scope

- `foreman_run_get`, `foreman_run_get_logs`, `foreman_pr_status` and every other tool that
  returns `NOT_FOUND` from `ProjectionStore.run/1` — do not touch them.
- `ProjectionStore.pending_run/1`, `queue_status/1`, `RunAdmission`, `Dispatcher`,
  `RunController` — no changes; this is a read-model fallback in one MCP tool.
- No new command, event, projection field or config key. No refactor of `run_status_dto/1`,
  `current_phase/2` or the telemetry helpers.
- Do not commit the ledger, create branches, or open a PR beyond the workflow's own steps.
