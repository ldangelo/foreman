# PLAN — RunExecutor terminal-dispatch loop is unbounded on `{:not_found, :run, id}`

## 1. Verdict

**Real bug, present on HEAD (796c888c).**

`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:6222` —
`defp next_terminal_dispatch_step(:slow, _attempt), do: {@terminal_dispatch_slow_interval_ms, :slow}`
has no attempt limit and no reason discrimination. Caller
`finalize_terminal_dispatch/4` (run_executor.ex:6172) exits only on `:ok` or
`{:error, {:run_terminal, _}}` (run_executor.ex:6174, 6181); every other error —
including `{:not_found, :run, id}`, returned by the Run aggregate's `require_exists/2`
(`packages/foreman_server/lib/foreman_server/aggregates/run.ex:1609`) for a stream it
cannot fold — re-schedules `{:retry_terminal_dispatch, ...}` forever
(run_executor.ex:6197). No `RunFailed` is ever published, so
`Workflow.Dispatcher.handle_run_terminated/3` → `terminate_slot/2`
(`packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:682`, `:915`) never
runs and the slot stays held (`running_runs` = `map_size(slots.holders)`,
`projection_store.ex:4471`).

The `RunLifecycleReconciler` backstop cannot save it: the sweep releases an absent run
only when `not admission_in_flight?(run_id)`
(`packages/foreman_server/lib/foreman_server/run_lifecycle_reconciler.ex:383`), and the
task is still `in_progress` because the failed `with` chain in `emit_phase_failure/4`
(run_executor.ex:2568-2574) short-circuits before `finish_task_failure/3`.

## 2. Root cause

`run_executor.ex`, `next_terminal_dispatch_step/2` + `finalize_terminal_dispatch/4`
(lines 6160-6225): the retry ladder is reason-blind and the slow phase is unbounded, so
a permanently unsatisfiable dispatch (`{:not_found, :run, _}` — a run aggregate that
does not exist cannot become failable by waiting) retries forever while holding the
project's run slot and leaving the task `in_progress`.

## 3. Failing check first

Two new tests in
`packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs`,
placed right after the existing test
`"initialization failure retries run.fail dispatch instead of silently stopping"`
(lines 1621-1774). Copy that test's body as the starting point — it already seeds
project/task/run, registers the `:bash` unsupported-action phase (rejected by
`validate_phase_action/2`, no worktree needed), sets the
`:run_executor_test_dispatch_failure` seam, keeps the
`expect(BrRunnerMock, :cmd, 1, ...)` claim stub, and starts the executor with
`restart: :temporary`.

Test 1 — `"an unrecoverable run.fail (:not_found) abandons the dispatch, fails the task and releases the slot"`:

- injection fn always returns `{:error, {:not_found, :run, run_id}}` (never
  `:passthrough`), still sending `{:dispatch_injection_attempt, attempt_count}`.
- `assert_receive {:dispatch_injection_attempt, 4}, @poll_timeout_ms`
- `refute_receive {:dispatch_injection_attempt, 5}, 2_000` — 3 attempts inside the
  helper plus the one from `emit_run_failure`, no fifth.
- poll until `Process.alive?(run_pid)` is false (same shape as lines 1766-1771).
- `poll_until` on `ProjectionStore.queue_status(project_id)`: `run_id not in
  status.running` and `status.running_runs == 0`.
- `poll_until` on `ProjectionStore.task_projection(task_id)`: `%{status: "failed"}`.

Test 2 — `"a run already terminal stops the executor without scheduling a retry"`:
same skeleton, injection fn always `{:error, {:run_terminal, "failed"}}`;
`assert_receive {:dispatch_injection_attempt, 2}`,
`refute_receive {:dispatch_injection_attempt, 3}, 2_000`, then poll for process exit.

Before the fix test 1 hangs in the slow loop and times out at `@poll_timeout_ms`:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/run_executor_command_test.exs --warnings-as-errors'
```

## 4. Edits

All edits in `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
unless stated otherwise.

**Edit 1 — alias (near line 56, in the existing alias block, keep alphabetical-ish
placement next to `alias ForemanServer.CommandGateway`):**

```elixir
  alias ForemanServer.Aggregates.RunSlots
```

**Edit 2 — new attribute constants, after line 6163
(`@terminal_dispatch_slow_interval_ms 60_000`):**

```elixir
  # A run aggregate that does not exist cannot become failable by waiting, so
  # `{:not_found, :run, _}` gets a small bounded budget and then abandons.
  @max_terminal_dispatch_not_found_attempts 3
  # Absolute cap on the slow phase (attempt numbers are cumulative across both
  # phases), so no run can hold a project slot forever.
  @max_terminal_dispatch_slow_attempts 10
```

**Edit 3 — `finalize_terminal_dispatch/4`, replace the `{:error, dispatch_reason}`
clause (lines 6189-6203) with:**

```elixir
      {:error, dispatch_reason} ->
        case next_terminal_dispatch_step(attempt_kind, attempt, dispatch_reason) do
          {:retry, backoff_ms, next_kind} ->
            Logger.warning(
              "RunExecutor #{state.run_id} terminal dispatch #{attempt_kind} attempt #{attempt} " <>
                "failed: #{inspect(dispatch_reason)}; retrying in #{backoff_ms}ms as #{next_kind}"
            )

            Process.send_after(
              self(),
              {:retry_terminal_dispatch, reason, next_kind, attempt + 1},
              backoff_ms
            )

            :retry

          :abandon ->
            abandon_terminal_dispatch(state, dispatch_reason, attempt_kind, attempt)
        end
```

**Edit 4 — replace the three `next_terminal_dispatch_step/2` clauses (lines 6207-6224)
with reason-aware `/3` clauses, in this order:**

```elixir
  # Reason-blind waiting cannot heal a missing aggregate: give it a small
  # budget and then stop holding the slot.
  defp next_terminal_dispatch_step(_attempt_kind, attempt, {:not_found, :run, _run_id})
       when attempt >= @max_terminal_dispatch_not_found_attempts,
       do: :abandon

  defp next_terminal_dispatch_step(:fast, attempt, _dispatch_reason)
       when attempt >= @max_terminal_dispatch_attempts do
    {:retry, @terminal_dispatch_slow_interval_ms, :slow}
  end

  defp next_terminal_dispatch_step(:fast, attempt, _dispatch_reason) do
    backoff_ms =
      @terminal_dispatch_backoff_base_ms
      |> Kernel.*(:math.pow(2, attempt - 1))
      |> min(@terminal_dispatch_backoff_cap_ms)
      |> trunc()

    {:retry, backoff_ms, :fast}
  end

  defp next_terminal_dispatch_step(:slow, attempt, _dispatch_reason)
       when attempt >= @max_terminal_dispatch_attempts + @max_terminal_dispatch_slow_attempts,
       do: :abandon

  defp next_terminal_dispatch_step(:slow, _attempt, _dispatch_reason) do
    {:retry, @terminal_dispatch_slow_interval_ms, :slow}
  end
```

**Edit 5 — new private functions, immediately after the clauses added in Edit 4:**

```elixir
  # The run cannot be marked failed on its own stream. Stop pretending it will
  # heal: say so loudly, flip the TASK terminal (a task left `in_progress`
  # keeps `RunLifecycleReconciler`'s backstop sweep from releasing an absent
  # run's slot, run_lifecycle_reconciler.ex:383) and hand the project's slot
  # back, then let the executor exit normally.
  defp abandon_terminal_dispatch(state, dispatch_reason, attempt_kind, attempt) do
    Logger.error(
      "RunExecutor #{state.run_id} abandoning terminal dispatch after #{attempt_kind} " <>
        "attempt #{attempt}: #{inspect(dispatch_reason)}; run.fail cannot be recorded, " <>
        "failing the task and releasing the run slot",
      run_id: state.run_id,
      task_id: task_id(state),
      operation: "run_executor.terminal_dispatch",
      outcome: "error",
      reason: inspect(dispatch_reason)
    )

    _ = dispatch_task_execution_fail(state, {:run_fail_unrecoverable, dispatch_reason})
    _ = release_run_slot(state, "terminal_dispatch_abandoned")

    :ok
  end

  # `RunSlots.release_command/3` is the ONE release-envelope builder (TRD-002);
  # a run with no project id has no stream to release on, and the backstop
  # sweep is the only thing that can reach it.
  defp release_run_slot(state, reason) do
    case project_id(state) do
      id when is_binary(id) and id != "" ->
        _ = CommandGateway.dispatch_system(RunSlots.release_command(id, state.run_id, reason))
        :ok

      _ ->
        Logger.warning(
          "RunExecutor #{state.run_id} cannot resolve a project; run slot release " <>
            "(#{reason}) skipped, backstop sweep will release it"
        )

        :ok
    end
  end
```

`:ok` from `abandon_terminal_dispatch/4` makes
`handle_info({:retry_terminal_dispatch, ...})` (run_executor.ex:443) and
`finalize_terminal_and_stop/2` (run_executor.ex:6228) stop `:normal` — the intended
terminal outcome.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && mix format'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/run_executor_command_test.exs test/foreman_server/aggregates/run_slots_release_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = both new tests pass, `run_slots_release_test.exs` (the one-builder source
contract, which asserts no module outside `RunSlots` hand-builds the envelope) still
passes, zero warnings, zero failures. Any failure is a failed build.

Documentation gate: no externally visible identifier added, removed or renamed (no
route, config key, env var, CLI verb, MCP tool, command or event type); the new
`{:run_fail_unrecoverable, reason}` appears only inside an existing
`task.execution_fail` reason string. `grep` for `terminal_dispatch` /
`run_slots.release` in `CLAUDE.md`, `README.md`, `docs/user-guide.md`,
`docs/cli-reference.md` returns nothing — none of the four needs an edit.

## 6. Out of scope

- Why the Run aggregate was not found for a run that is present in projections
  (bead item (c)) — a separate investigation; do not change stream-id derivation,
  `Identity.run_fail_command_id/1` or `CommandRouter`.
- The `git_worktree_create_failed ... already exists` worktree collision (bead item (d)) —
  do not touch `cleanup_run_worktree/2`, `ensure_run_worktree/2` or `Workflow.Worktree`.
- `StuckDetector`, `BootReconciliation`, `RunLifecycleReconciler`, `Dispatcher`: no edits.
- Do not change the fast-phase budget/backoff values, and do not make the executor exit
  `:abnormal` (the shared supervisor restart budget is the reason it stays alive).
- No refactor of `emit_phase_failure/4`'s `with` chain or of adjacent dispatch helpers.
