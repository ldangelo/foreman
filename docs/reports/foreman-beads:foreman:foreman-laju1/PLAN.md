# PLAN — foreman-laju1: three regression tests for queued-run cancellation / promotion / status

## 1. Verdict

Partly real.

- **(a) cancelling a queued run removes its waiter and ends it — ALREADY COVERED.**
  `packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs:42`
  asserts `waiter_ids(project) == []`, holder untouched, `acknowledged_run_id == queued`,
  `ProjectionStore.pending_run(queued) == nil`. Verified on this tree: that file → `5 passed`,
  exit 0. **Write no new test for (a)**; cite that file:line and output in the fix report.
- **(b) a closed/failed task whose run is queued must not start on promotion — REAL GAP, no test.**
  `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1436 start_promoted_run/2`
  refuses only `[%{acknowledged_run_id: ^run_id} | _]` (dispatcher.ex:1452). A task that went
  `closed`/`failed` without acknowledging the run falls into `[task | _]` (dispatcher.ex:1460) and
  is admitted. `ProjectionStore.tasks_by_run_id/1` (projection_store.ex:2024) filters on
  `acknowledged_run_id` only, never on status.
- **(c) `foreman_run_status` on a queued run — REAL GAP, no test.**
  `packages/foreman_server/lib/foreman_server/mcp/tools.ex:1881 tool_foreman_run_status/1` returns
  `{:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}` whenever
  `ProjectionStore.run(run_id)` is nil. HTTP already answers `queued` (`run_controller.ex`
  `show_pending/2`, test `run_controller_test.exs:123`) via `ProjectionStore.pending_run/1`
  (projection_store.ex:331, impl :4893); the MCP tool has no such fallback.

(b) and (c) are failing-first against missing behaviour, so this plan also adds the two narrow
production fixes that make them green.

## 2. Root cause

1. `dispatcher.ex:1436 start_promoted_run/2` — no task-status re-check before
   `safe_run_admission_start/2`; only run-acknowledgement is consulted.
2. `mcp/tools.ex:1881 tool_foreman_run_status/1` — "no run projection" is treated as "unknown run",
   conflating absent-and-queued with absent-entirely.

## 3. Failing check first

Write both new tests BEFORE the edits and confirm they fail.

- (b) `dispatcher_slot_promoted_test.exs`, in `describe "RunSlotTransferred with failed admission
  logs warning"`: `test "does NOT admit a promoted run whose task was closed, and drops its slot"`
  — fails today on `refute :meck.called(ForemanServer.RunAdmission, :start, :_)`.
- (c) `mcp/tools_test.exs`, in `describe "foreman_run_status"`: `test "returns the queued pending
  projection instead of NOT_FOUND for a run waiting on a slot"` — fails today with
  `{:error, %ToolError{code: "NOT_FOUND"}}`.

Commands (repo root; see §5 for the `DATABASE_URL` gotcha):

```
devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL && MIX_ENV=test mix test \
  test/foreman_server/workflow/dispatcher_slot_promoted_test.exs \
  test/foreman_server/mcp/tools_test.exs'
```

## 4. Edits

### Edit 1 — test (b)

File `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`.
Append inside the last `describe` block (before its closing `end`, currently line 334). Follows the
file's meck style: `ProjectionStore` is already mocked via `MeckScope`, `RunAdmission` and
`RunSupervisor` in `setup`.

```elixir
    test "does NOT admit a promoted run whose task was closed, and drops its slot" do
      task_id = "task-closed-#{unique_id()}"
      run_id = "run-closed-#{unique_id()}"
      project_id = "project-closed-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        status: "closed",
        approval_id: "approval-#{task_id}",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      test_pid = self()
      :meck.new(ForemanServer.CommandGateway, [:no_link])

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
        send(test_pid, {:dispatch_system, command.type, command.payload})
        {:ok, nil}
      end)

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command, _timeout ->
        send(test_pid, {:dispatch_system, command.type, command.payload})
        {:ok, nil}
      end)

      on_exit(fn ->
        if :meck.validate(ForemanServer.CommandGateway),
          do: :meck.unload(ForemanServer.CommandGateway)
      end)

      envelope = %{
        event_type: "RunSlotTransferred",
        data: %{
          released_run_id: "run-old",
          acquired_run_id: run_id,
          acquired_at_ms: System.system_time(:millisecond)
        }
      }

      {:noreply, _state} = Dispatcher.handle_info({:projection_event, envelope}, %{})

      refute :meck.called(ForemanServer.RunAdmission, :start, :_)
      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)

      assert_received {:dispatch_system, "run_slots.release", %{run_id: ^run_id}}
      assert_received {:dispatch_system, "run_slots.remove_waiter", %{run_id: ^run_id}}
    end
```

### Edit 2 — fix for (b)

File `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`, function
`start_promoted_run/2`. Insert a new clause immediately AFTER the existing
`[%{acknowledged_run_id: ^run_id} | _] ->` clause (ends at dispatcher.ex:1459, the
`{:noreply, state}` after `terminate_slot(run_id, "run_cancelled")`) and BEFORE `[task | _] ->`
(dispatcher.ex:1460):

```elixir
      # The task reached a terminal status while its run waited for the slot (closed by an
      # operator, failed, merged). Promotion must not start it; the slot it was just handed
      # is released and its waiter entry dropped.
      [%{status: status} | _] when status in ["closed", "failed", "merged"] ->
        Logger.info(
          "handle_slot_promoted: not starting #{run_id}: its task is #{status}"
        )

        terminate_slot(run_id, "run_cancelled")
        {:noreply, state}
```

Deny-list, not whitelist: live dispatch status is `in_progress`, but existing promoted-run tests and
legacy task projections carry no `:status` key, and a nil status must keep today's admit behaviour.
`terminate_slot/2` (dispatcher.ex:915) already emits `run_slots.release` then
`run_slots.remove_waiter`.

### Edit 3 — test (c)

File `packages/foreman_server/test/foreman_server/mcp/tools_test.exs`. Add inside
`describe "foreman_run_status"`, directly after the existing
`test "returns NOT_FOUND when run is unknown"` (ends at tools_test.exs:342):

```elixir
    test "returns the queued pending projection instead of NOT_FOUND for a run waiting on a slot" do
      replace_state(%{
        runs: %{},
        tasks: %{
          "task-q" => %{
            task_id: "task-q",
            project_id: "proj-q",
            run_id: "run-q",
            status: "in_progress",
            acknowledged_run_id: nil
          }
        }
      })

      assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: "run-q"})
      assert dto.run_id == "run-q"
      assert dto.status == "queued"
      assert dto.terminal == false
      assert dto.task_id == "task-q"
      assert dto.project_id == "proj-q"
      assert dto.current_phase == nil
    end
```

### Edit 4 — fix for (c)

File `packages/foreman_server/lib/foreman_server/mcp/tools.ex`. Replace the body of
`tool_foreman_run_status/1` (tools.ex:1881-1897) — change only the `case` expression:

```elixir
    result =
      case ProjectionStore.run(run_id) do
        nil -> pending_run_status_dto(ProjectionStore.pending_run(run_id))
        run -> run_status_dto(run, ProjectionStore.phases_for_run(run_id))
      end
```

and add this private function immediately after `run_status_dto/2` (which ends at tools.ex:3610):

```elixir
  # A run that has been dispatched but still waits for its project's run slot has no run
  # projection yet. `pending_run/1` is the same source the HTTP `GET /api/runs/<id>` uses;
  # its status is "queued" or "deferred". Only a genuinely unknown id stays NOT_FOUND.
  defp pending_run_status_dto(nil), do: nil

  defp pending_run_status_dto(%{run_id: run_id, status: status} = pending)
       when is_binary(run_id) and is_binary(status) do
    %RunStatus{
      run_id: run_id,
      status: status,
      terminal: false,
      project_id: Map.get(pending, :project_id),
      task_id: Map.get(pending, :task_id),
      workflow_name: nil,
      current_phase: nil,
      started_at_ms: nil,
      last_event_at_ms: nil,
      failure_reason: Map.get(pending, :reason),
      latest_stall: nil,
      provider_session_id: nil,
      provider_sessions: [],
      usage: nil,
      recovery: nil
    }
  end
```

Do NOT touch `tool_foreman_run_get/1` (tools.ex:1482): `foreman_run_get` returns the raw run
projection and keeps its NOT_FOUND.

### Edit 5 — documentation gate

No identifier added, removed or renamed (no route, config key, env var, CLI verb or MCP tool). One
behaviour statement changes, so add the same sentence in both places that describe the tool —
`docs/cli-reference.md:1599` and `docs/user-guide.md:2200`: a run still waiting for a run slot
answers `status: "queued"` (or `"deferred"` with the refusal reason in `failure_reason`),
`terminal: false`, null `current_phase`, instead of `NOT_FOUND`; only an unknown run id is
`NOT_FOUND`.

`CLAUDE.md` and `README.md` need no edit: their run-slot sections (CLAUDE.md §18 ~line 1014,
README.md:211) describe admission and promotion, not the MCP status surface, and neither documents
NOT_FOUND for `foreman_run_status`. `docs/cli-reference.md:697` and `docs/user-guide.md:1094`
already document (a) correctly — leave them.

## 5. Verification

Deps are not vendored in a fresh worktree: run `devbox run -- bash -c 'cd packages/foreman_server &&
mix deps.get'` first (already done on this tree). **The ambient `DATABASE_URL` points at port 55434
(langfuse stack Postgres) and makes `mix test` die with `FATAL 28P01 invalid_password` from
`mix.exs:203 claim_database!/2`. Unset it so `config/test.exs` uses
`postgres://postgres:postgres@localhost:55432/foreman_test` (container `foreman-postgres`).**

Narrow:

```
devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL && MIX_ENV=test mix test \
  --warnings-as-errors \
  test/foreman_server/workflow/dispatcher_slot_promoted_test.exs \
  test/foreman_server/mcp/tools_test.exs \
  test/foreman_server/command_gateway_cancel_queued_run_test.exs'
```

Format, then the full gate:

```
devbox run -- bash -c 'cd packages/foreman_server && mix format'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = exit code 0, zero failures, both new tests in the counts. Record the real exit code and
the real `N tests, 0 failures` line in the fix report, plus the
`command_gateway_cancel_queued_run_test.exs` output as evidence for (a). An unrelated pre-existing
failure is still a failed build: report it, do not wave it through.

## 6. Out of scope

- No `"cancelled"` task status, no change to `@valid_statuses` (`aggregates/task.ex:46`) — bead
  foreman-lxb0m.
- No change to `CommandGateway.cancel_queued_run/2`, `RunAdmission`, `RunSlots` or
  `ProjectionStore.pending_run/1`: (a) is already correct and tested.
- Do not touch `re_dispatch_promoted/3` (dispatcher.ex:1712) or `task_ready_for_approval?/2`
  (dispatcher.ex:1339); the deny-list covers only `start_promoted_run/2`.
- Do not duplicate the existing cancellation test, refactor the mocked setups, or widen the
  deny-list into a status whitelist.
- Do not commit, branch, push or open a PR beyond what the workflow's own phases do.
