# PLAN — Re-check task status at slot promotion (`beads:foreman:foreman-pjugt`)

## 1. Verdict

**Real bug on the current tree** (HEAD `796c888c`).

`packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`, `start_promoted_run/2`
(line 1436) matches `ProjectionStore.tasks_by_run_id(run_id)` with exactly three clauses:

- `[]` — no task (follow-up path),
- `[%{acknowledged_run_id: ^run_id} | _]` (line 1452) — the task acknowledged this run as ended,
- `[task | _]` (line 1460) — **everything else is admitted and started**, with no read of
  `task.status`.

So a task closed (or failed/blocked) while its run sat in the run-slot queue still gets
`safe_run_admission_start/2` + `RunSupervisor.start_run/2` as soon as a slot frees, because
closing a task emits `TaskUpdated`/`TaskExecutionCompleted` (projection sets `:status`,
`projection_store.ex:3104`) and never touches `acknowledged_run_id` (only
`TaskRunTerminated` does, `projection_store.ex:3128`). `task_ready_for_approval?/2`
(line 1339) exists but is called only from `handle_task_approved/2` (line 1091).

No existing test covers a promoted run whose task is closed:
`test/foreman_server/workflow/dispatcher_slot_promoted_test.exs` has 6 tests, every task
fixture is `%{task_id:, project_id:, approval_id:, workflow_snapshot:}` — no `:status` key.

## 2. Root cause

`dispatcher.ex` `start_promoted_run/2`: the promoted-run path re-reads the task projection but
only to build the admission payload; it never re-checks `task.status`, so a status that ended
the work after the run was queued is ignored.

## 3. Failing check first

Add to `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`
a new `describe` block **at the end of the file, before the `# Helpers` section**:

```elixir
  describe "RunSlotTransferred for a task that is no longer startable" do
    test "does not start a closed task's run and drops its waiter" do
      task_id = "task-closed-#{unique_id()}"
      run_id = "run-closed-#{unique_id()}"
      project_id = "project-closed-test"

      task = %{
        task_id: task_id,
        project_id: project_id,
        approval_id: "approval-#{task_id}",
        status: "closed",
        workflow_snapshot: %{implementation: %{}}
      }

      :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn ^run_id -> [task] end)

      test_pid = self()
      :meck.new(ForemanServer.CommandGateway, [:no_link])

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
        send(test_pid, {:dispatch_system, command})
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

      assert_receive {:dispatch_system,
                      %{type: "run_slots.release", payload: %{run_id: ^run_id}}},
                     2_000

      assert_receive {:dispatch_system,
                      %{type: "run_slots.remove_waiter", payload: %{run_id: ^run_id}}},
                     2_000
    end

    test "still starts a ready task's promoted run" do
      # Copy the body of the existing test
      # "calls RunSupervisor.start_run when admission returns {:ok, _run_started_event}"
      # (same file, describe "RunSlotTransferred with successful admission starts supervisor"),
      # changing only the ids (use "task-ready-"/"run-ready-"/"project-ready-test") and
      # adding `status: "ready"` to the task fixture map. Final assertion unchanged:
      #   assert :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end
```

Show it failing **before** the edits:

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/workflow/dispatcher_slot_promoted_test.exs'
```

Expected failure: the first test fails — `RunAdmission.start` IS called and no
`run_slots.release` / `run_slots.remove_waiter` arrives. The second test passes already
(it is the regression guard against over-firing).

## 4. Edits

All edits in `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`.

**Edit 1 — add the status list next to the existing promotion code.** Insert immediately
*above* `defp start_promoted_run(run_id, state) do` (line 1436):

```elixir
  # Task statuses that mean the queued work is over or withheld: an operator closed
  # (cancelled) it, it failed, or it was blocked while its run waited for a slot.
  # Promotion must neither admit nor start such a run, and the slot it was just handed
  # has to go back so the queue behind it keeps moving.
  @non_startable_task_statuses ~w(closed failed blocked)
```

**Edit 2 — skip and release.** In `start_promoted_run/2`, insert a new clause between the
existing `[%{acknowledged_run_id: ^run_id} | _]` clause (ends line 1458 with
`{:noreply, state}`) and the `[task | _] ->` clause (line 1460):

```elixir
      # The task ended (or was blocked) while this run waited for a slot: `TaskUpdated` /
      # `TaskExecutionCompleted` move only `status`, never `acknowledged_run_id`, so the
      # clause above does not catch it. Read the CURRENT status at promotion time.
      [%{status: status} | _] when status in @non_startable_task_statuses ->
        Logger.info(
          "handle_slot_promoted: not starting #{run_id}: its task is #{status}"
        )

        terminate_slot(run_id, "task_#{status}")
        {:noreply, state}
```

Nothing else changes: `terminate_slot/2` (line 915) already dispatches both
`run_slots.release` and `run_slots.remove_waiter` on the project's slot stream, and resolves
the project from the run projection, then the task projection. The new clause does not match a
task map without a `:status` key, so the existing fixtures and legacy projections keep the old
behaviour.

## 5. Verification

```bash
# narrowest
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/workflow/dispatcher_slot_promoted_test.exs \
  test/foreman_server/workflow/dispatcher_slot_rebalance_test.exs \
  test/foreman_server/workflow/dispatcher_slot_release_test.exs \
  test/foreman_server/workflow/dispatcher_followup_test.exs --warnings-as-errors'

# format + full suite (a failing test is a failed build)
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = both new tests pass, the 6 pre-existing tests in
`dispatcher_slot_promoted_test.exs` still pass, 0 failures in the full suite, formatter clean.

**Documentation gate:** no externally visible identifier is added, removed or renamed —
`@non_startable_task_statuses` and the new clause are private, and `"task_closed"` /
`"task_failed"` / `"task_blocked"` are internal `run_slots.release` reason strings (only
read by `@capacity_freeing_release_reasons`, a `not in` check, and by telemetry/logs). No
edit to `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`. State this
in the fix report.

## 6. Out of scope — do NOT touch

- `re_dispatch_promoted/3` (line 1712, Beads-lease promotion) has the same missing status
  re-read. It is a different queue and a different bead; leave it alone and note it in the
  fix report as a follow-up.
- `task_ready_for_approval?/2` (line 1339) and `handle_task_approved/2` — unchanged.
- Do not add a `cancelled` / `superseded` task status: `@valid_statuses` in
  `lib/foreman_server/aggregates/task.ex:46` is `open ready in_progress blocked closed failed`
  and closing is how a task is cancelled here. No aggregate, event, codec, projection, MCP
  tool or CLI change.
- Do not change `terminate_slot/2`, `RunSlots` aggregate, `RunAdmission`, or run-cancel
  handling for queued runs (separate beads from the same review).
- Do not reformat or re-comment adjacent clauses.
