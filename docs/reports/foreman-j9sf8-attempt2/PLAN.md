# PLAN — RunExecutor retries `run.fail` forever on `{:not_found, :run, id}`

All paths are relative to the repo root. Everything is inside `packages/foreman_server`.

## 1. Verdict

**Real bug, live on this tree** (HEAD `176546c1`). Verified by reading
`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`:

- `defp next_terminal_dispatch_step(:slow, _attempt)` (line 6264) returns
  `{@terminal_dispatch_slow_interval_ms, :slow}` unconditionally — no ceiling.
- `defp finalize_terminal_dispatch(state, reason, attempt_kind, attempt)` (line 6214) exits only on
  `:ok` and `{:error, {:run_terminal, _status}}`; every other error, including
  `{:error, {:not_found, :run, id}}`, falls into the generic retry clause (line 6230) and schedules
  `{:retry_terminal_dispatch, reason, next_kind, attempt + 1}` (line 6239).
- `{:not_found, :run, run_id}` comes from `lib/foreman_server/aggregates/run.ex:1609`
  `defp require_exists(%State{}, run_id)` — no run aggregate. Waiting cannot create it.
- Slot consequence: `RunExecutor` never touches run slots (`grep -n "RunSlots" run_executor.ex` → no
  hits). `lib/foreman_server/workflow/dispatcher.ex` `terminate_slot/2` (line 915) releases it from
  `handle_run_terminated/3` (line 681-682), which keys off `RunFailed`. No accepted `run.fail` ⇒ no
  `RunFailed` ⇒ the slot stays in `ProjectionStore.queue_status(project_id).running_runs` forever.

## 2. Root cause

`finalize_terminal_dispatch/4` treats an unsatisfiable rejection
(`{:not_found, :run, _}`) as a transient transport error and retries it forever, and nothing on that
path releases the run's slot.

## 3. Failing check first

Add ONE test to the existing
`packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs`
(it already owns the dispatch-injection seam and the seeding helpers; do not create a new file).

Insert it immediately after the existing test
`"initialization failure retries run.fail dispatch instead of silently stopping"`
(ends at line 1777), and copy that test's structure verbatim except for the four differences listed
below. Name:

```
test "a run.fail that is rejected with not_found stops the executor and releases the slot"
```

Differences from the copied test:

1. Injection function always fails with `not_found` (build it AFTER `run_id` is bound):

```elixir
    Application.put_env(:foreman_server, :run_executor_test_dispatch_failure, fn attempt_count ->
      send(test_pid, {:dispatch_injection_attempt, attempt_count})
      {:error, {:not_found, :run, run_id}}
    end)
```

2. Assertions replacing the "run reached terminal failed" block:

```elixir
    # 1 dispatch from `emit_phase_failure` + 3 bounded attempts in the helper.
    assert_receive {:dispatch_injection_attempt, 1}, @poll_timeout_ms
    assert_receive {:dispatch_injection_attempt, 2}, @poll_timeout_ms
    assert_receive {:dispatch_injection_attempt, 3}, @poll_timeout_ms
    assert_receive {:dispatch_injection_attempt, 4}, @poll_timeout_ms
    refute_receive {:dispatch_injection_attempt, 5}, 1_500

    poll_until(
      fn -> if Process.alive?(run_pid), do: {:error, :still_alive}, else: {:ok, :exited} end,
      "executor exit"
    )

    {:ok, _} =
      poll_until(
        fn ->
          case ProjectionStore.queue_status(project_id) do
            %{running: running} -> if run_id in running, do: {:error, running}, else: {:ok, :released}
          end
        end,
        "run slot released"
      )
```

3. Keep the single `expect(BrRunnerMock, :cmd, 1, ...)` claim expectation unchanged.
4. Keep `ref = Process.monitor(run_pid)` out; use the `Process.alive?/1` poll as the copied test does.

A second case for `{:error, {:run_terminal, _}}` is NOT needed as new code: the existing test at
line 1621 already proves the non-`not_found` path still stops normally. Do not weaken it.

Red command (expect this test to FAIL before the edits in §4 — the executor stays alive, so
`poll_until(..., "executor exit")` flunks after 8 s):

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/run_executor_command_test.exs'
```

Capture and paste that red output in the final report.

## 4. Edits

All in `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`.

**Edit 1 — alias.** After line 87 `alias ForemanServer.Aggregates.BeadsDbLease` add:

```elixir
  alias ForemanServer.Aggregates.RunSlots
```

**Edit 2 — new attribute.** After line 6205 `@terminal_dispatch_slow_interval_ms 60_000` add:

```elixir
  # `{:not_found, :run, _}` means the run aggregate does not exist
  # (`ForemanServer.Aggregates.Run.require_exists/2`). Waiting cannot create it, so this
  # rejection gets a small ceiling instead of the unbounded slow loop. Every other
  # error keeps the fast-then-slow behaviour described above.
  @max_not_found_dispatch_attempts 3
```

**Edit 3 — give-up clause.** In `finalize_terminal_dispatch/4`, insert this clause BETWEEN the
`{:error, {:run_terminal, _status}}` clause (ends line 6229) and the generic
`{:error, dispatch_reason} ->` clause (line 6230):

```elixir
      {:error, {:not_found, :run, _id}} when attempt >= @max_not_found_dispatch_attempts ->
        # No aggregate, so there is no stream to write `RunFailed` to: there is no terminal
        # event to emit here. Ending the loop and releasing the slot IS the outcome.
        Logger.error(
          "RunExecutor #{state.run_id} terminal dispatch gave up after #{attempt} " <>
            "#{attempt_kind} attempts: the run aggregate does not exist, so run.fail can " <>
            "never be accepted; releasing the run slot and stopping"
        )

        release_run_slot(state, "run_aggregate_not_found")
        :ok
```

**Edit 4 — slot release helper.** Immediately after `next_terminal_dispatch_step(:slow, _attempt)`
(ends line 6266) add:

```elixir
  # The Dispatcher releases a run's slot from the `RunFailed` event
  # (`terminate_slot/2`). A run whose aggregate does not exist never publishes one, so
  # the executor releases it here through the ONE release builder
  # (`RunSlots.release_command/3`, TRD-002). A `GenServer.call` exit must not crash the
  # executor: an abnormal exit spends the shared supervisor restart budget, and the
  # `RunLifecycleReconciler` backstop sweep covers the lost attempt.
  defp release_run_slot(state, reason) do
    case project_id(state) do
      project_id when is_binary(project_id) and project_id != "" ->
        case CommandGateway.dispatch_system(
               RunSlots.release_command(project_id, state.run_id, reason)
             ) do
          {:ok, _} ->
            :ok

          {:error, release_reason} ->
            Logger.error(
              "RunExecutor #{state.run_id} run_slots.release (#{reason}) failed: " <>
                "#{inspect(release_reason)}; the backstop sweep will release it"
            )

            :ok
        end

      _ ->
        Logger.error(
          "RunExecutor #{state.run_id} cannot resolve a project id; run_slots release " <>
            "(#{reason}) skipped, the backstop sweep will release it"
        )

        :ok
    end
  catch
    :exit, exit_reason ->
      Logger.error(
        "RunExecutor #{state.run_id} run_slots.release (#{reason}) exited: " <>
          "#{inspect(exit_reason)}; the backstop sweep will release it"
      )

      :ok
  end
```

`project_id/1` already exists at line 2379. No other call site changes: `finalize_terminal_and_stop/2`
(line 6270) and `handle_info({:retry_terminal_dispatch, ...})` (line 454) already map `:ok` to
`{:stop, :normal, ...}`.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/run_executor_command_test.exs test/foreman_server/aggregates/run_slots_release_test.exs --warnings-as-errors'
```

Success = both files fully green and zero warnings. `run_slots_release_test.exs` is mandatory: line
386 asserts no module outside `aggregates/run_slots.ex` hand-builds a `type: "run_slots.release"`
envelope — Edit 4 passes it only because it calls `RunSlots.release_command/3`. Never inline it.

Report changed files exactly as `git diff --stat` prints them, plus the red and green outputs.

The task prompt's "two pre-existing failures in `run_executor_stall_detection_test.exs`" cannot be
reproduced: that file does not exist here (`ls test/foreman_server/workflow/ | grep -i stall` →
`stall_policy_test.exs` only). State that; do not invent a result.

## 6. Out of scope

- Do NOT cap the `:slow` loop for any other error (prompt item b): `next_terminal_dispatch_step(:slow, _)`
  stays as-is.
- Do NOT investigate why the aggregate was missing, and do NOT touch worktree creation,
  `cleanup_run_worktree/2`, `ensure_workspace`/`register_run` ordering, or `RunAdmission` (prompt
  items c and d are separate beads).
- Do NOT emit any new terminal event for the not-found run; there is no stream to write it to.
- Do NOT touch `lib/foreman_server/workflow/dispatcher.ex`, `run_lifecycle_reconciler.ex`,
  `boot_reconciliation.ex`, or `aggregates/run_slots.ex`.
- Do NOT refactor `emit_phase_failure/4` or `emit_run_failure/2`.
- Documentation gate: this diff adds no externally visible identifier (no route, config key, env var,
  CLI verb, MCP tool, command or event type — `@max_not_found_dispatch_attempts`, `release_run_slot/2`
  are module-private). The release `reason` string `"run_aggregate_not_found"` is a free-text audit
  field on an existing command. No edit to `CLAUDE.md`, `README.md`, `docs/user-guide.md` or
  `docs/cli-reference.md` is required; say so explicitly in the report.
