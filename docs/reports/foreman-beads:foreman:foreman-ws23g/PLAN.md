# PLAN — failed runs leave live pi workers; relaunch can add a second writer

Elixir sources are under `packages/foreman_server/`; paths below are repo-relative.

## 1. Verdict

**Real bug on this tree.** Three findings:

- **A. A terminal run never stops its Overwatch worker tree.** `lib/foreman_server/workflow/dispatcher.ex`
  `handle_run_terminated/3` (~:641-665) only calls `RunControl.request(run_id, :cancel)` +
  `RunControl.cancel_agent(run_id)`; never `WorkerSupervisor.stop_worker/2` or `list_pids_for_run/1`.
  And `RunControl` is an ETS cache the executor **wipes on exit**
  (`lib/foreman_server/workflow/run_executor.ex:399-403`, `terminate/2 -> RunControl.clear/1`), and the
  executor stops `:normal` right after dispatching `run.fail`. So when `RunFailed` lands,
  `cancel_agent/1` reads `{nil, nil}` → `{:error, :no_agent}` and nothing is signalled — the observed
  "failed 02:21:47Z, pi alive at 02:34Z". The failure cleanup
  (`cleanup_run_worktree/3:4915 -> reap_run_agents(state, "failed")`) only reaps **ppid-1 orphans**
  (`lib/foreman_server/workflow/orphan_reaper.ex:66-80`), so a pi still parented to a live exec-port is
  not matched. The cancel path is fine — it calls `await_agent_exit/1` first (`run_executor.ex:4997`).
- **B. A dead BEAM worker does not stop its OS agent.**
  `lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` has **no `terminate/2`** and does not
  trap exits; the agent runs in `Task.async` (:165) and the harness run id only reaches `RunControl`
  (:288). When the worker dies the harness run is never cancelled, `pi` survives, and the
  `restart: :transient` child spec relaunches a **second** worker into the same worktree (pid 5660 in
  the report).
- **C. Reviewer agents on failed runs are BY DESIGN, not a bug.** `lib/foreman_server/review/analyzer.ex:54`
  `@terminal_events ~w(RunCompleted RunFailed RunCancelled ...)`; the report's tmp path matches
  `lib/foreman_server/review/evaluator/agent.ex:169`. **No code change for expectation (3)**; see §6.

## 2. Root cause

1. No terminal-run stop path independent of `RunControl`'s wipeable ETS cache (`dispatcher.ex`).
2. `JidoHarnessWorker` owns the live harness run but has no teardown that cancels it.
3. `Overwatch.start_phase/2` (`lib/foreman_server/overwatch.ex:113`) has no single-writer guard.

## 3. Failing check first

New `packages/foreman_server/test/foreman_server/overwatch/worker_stop_test.exs`, `use ExUnit.Case, async: false`.
Fake adapter modelled on `test/foreman_server/overwatch_test.exs` `FakeAdapter` (answers
`{:overwatch_activate, _, _, launcher}` with `send(launcher, {:overwatch_activated, self()})`), plus
`Process.flag(:trap_exit, true)` in `init/1` and a `terminate/2` sending `{:fake_worker_terminated, self()}`
to the test pid. `start_supervised!({Overwatch, []})`; wait with `ForemanServer.TestSupport.Eventually.await/1`.

1. `"stop_run_workers/1 stops every LaunchWorker and its adapter"` — one `Overwatch.start_phase/2`, then
   `assert %StopReport{stopped: [_], unstopped: []} = WorkerSupervisor.stop_run_workers(run_id)`;
   `assert_receive {:fake_worker_terminated, _}`; `list_pids_for_run(run_id) == []`.
2. `"a RunFailed event stops the run's live workers"` —
   `Dispatcher.handle_info({:projection_event, %{"event_type" => "RunFailed", "data" => %{"run_id" => run_id}}}, %{})`,
   then `list_pids_for_run(run_id) == []`.
3. `"a second start_phase for a run with a live worker is refused"` —
   `assert {:error, {:worker_already_running, ^run_id}} = Overwatch.start_phase("p2", <same run_id>, ...)`.
4. New `test/foreman_server/overwatch/adapters/jido_harness_worker_stop_test.exs` (`async: false`, `:meck`
   passthrough on `ForemanServer.AgentRuntime.JidoHarness.Driver`; see `test/support/meck_scope.ex`): start
   the worker with the opts shape of `jido_harness_worker_env_test.exs`, send `{:harness_run_started, "hr-1"}`,
   `GenServer.stop(pid, :shutdown)`, assert `Driver.stop/2` was called with `"hr-1"`; a worker stopped
   `:normal` after `:agent_done` must NOT call it.

Failing-before command:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/overwatch/worker_stop_test.exs test/foreman_server/overwatch/adapters/jido_harness_worker_stop_test.exs'
```

Expect `UndefinedFunctionError` for `stop_run_workers/1` and `Driver.stop/2`, and the refusal assertion failing.

## 4. Edits

**1. New `lib/foreman_server/overwatch/stop_report.ex`** (§5.1 typed return):

```elixir
defmodule ForemanServer.Overwatch.StopReport do
  @moduledoc "Outcome of stopping every worker of one run: what died, what refused to."
  @enforce_keys [:run_id, :stopped, :unstopped]
  defstruct [:run_id, :stopped, :unstopped]
  @type t :: %__MODULE__{run_id: String.t(), stopped: [pid()], unstopped: [pid()]}
end
```

**2. `lib/foreman_server/overwatch/worker_supervisor.ex`** — keep `stop_worker/2` as is; add
`require Logger` and `alias ForemanServer.Overwatch.StopReport` at the top, add `shutdown: 20_000` to the
`child_spec` in `start_worker/1` (:85-90) so the teardown fits the shutdown budget (harness escalates
SIGINT→SIGTERM→SIGKILL, 5 s apart), and add after `stop_worker/2`:

```elixir
@doc """
Stop every LaunchWorker of `run_id` and report the ones that would not die.
Each child's shutdown runs `LaunchWorker.terminate/2`, which stops the worker
and the agent it owns.
"""
@spec stop_run_workers(String.t()) :: StopReport.t()
def stop_run_workers(run_id) when is_binary(run_id) and run_id != "" do
  pids = list_pids_for_run(run_id)
  sup = Process.whereis(__MODULE__)

  {stopped, unstopped} =
    Enum.split_with(pids, fn pid ->
      sup != nil and DynamicSupervisor.terminate_child(sup, pid) == :ok
    end)

  if unstopped != [] do
    Logger.error(
      "Overwatch: run #{run_id} has #{length(unstopped)} worker(s) that would not stop: " <>
        inspect(unstopped)
    )
  end

  %StopReport{run_id: run_id, stopped: stopped, unstopped: unstopped}
end

def stop_run_workers(_), do: %StopReport{run_id: "", stopped: [], unstopped: []}
```

**3. `lib/foreman_server/overwatch/launch_worker.ex`** — it already traps exits (:114). Add after the
`handle_info/2` clauses, before `safe_stop/1`:

```elixir
@worker_stop_timeout_ms 18_000

@impl true
def terminate(_reason, %{worker_pid: pid}) when is_pid(pid) do
  # The worker owns the live agent: stopping it through GenServer.stop runs its
  # terminate/2, which cancels the harness run, so no OS agent outlives the run.
  if Process.alive?(pid) do
    try do
      GenServer.stop(pid, :shutdown, @worker_stop_timeout_ms)
    catch
      :exit, _ -> safe_stop(pid)
    end
  end

  :ok
end

def terminate(_reason, _state), do: :ok
```

**4. `lib/foreman_server/agent_runtime/jido_harness/driver.ex`** — add next to `await_exit/2`:

```elixir
@doc """
Cancel `harness_run_id` and wait (bounded) for its OS processes to exit.
`{:error, :timeout}` means the agent was still running when the wait ran out.
"""
@spec stop(String.t(), non_neg_integer()) :: :ok | {:error, :timeout}
def stop(harness_run_id, timeout_ms \\ @exit_wait_ms) when is_binary(harness_run_id) do
  _ = Run.cancel(harness_run_id)
  await_exit(harness_run_id, timeout_ms)
end
```

**5. `lib/foreman_server/overwatch/adapters/jido_harness_worker.ex`**:

- `init/1` (:81): first line `Process.flag(:trap_exit, true)`; add `harness_run_id: nil` to the state map (:90-110).
- `handle_info({:harness_run_started, harness_run_id}, %{tail: nil} = state)` (:192): return
  `{:noreply, %{state | harness_run_id: harness_run_id, tail: start_tail(harness_run_id)}}`.
- `handle_info({:agent_done, ...})` (:217): return `{:stop, :normal, %{state | harness_run_id: nil}}` so the
  normal path does not cancel an already-finished run.
- Add **before** the `handle_info(_msg, state)` catch-all (:265) — trapping exits turns the linked
  `Task.async` crash into a message the catch-all would swallow, hanging the phase:

```elixir
# The agent task is linked: its crash must still take this worker down with the
# same reason, which is what LaunchWorker turns into the relaunch decision.
def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
```

- Add a `terminate/2` at the end of the callbacks:

```elixir
@impl true
def terminate(_reason, %{harness_run_id: harness_run_id} = state)
    when is_binary(harness_run_id) do
  case Driver.stop(harness_run_id) do
    :ok ->
      :ok

    {:error, :timeout} ->
      Logger.error(
        "JidoHarnessWorker #{state.run_id}: agent #{harness_run_id} was still running when " <>
          "the stop wait ran out; it may outlive the run",
        run_id: state.run_id,
        worker_id: state.worker_id,
        operation: "worker.stop"
      )
  end

  :ok
end

def terminate(_reason, _state), do: :ok
```

**6. `lib/foreman_server/overwatch.ex`** — single writer per run. In `start_phase/2` replace the `with`
head (:124) with `with :ok <- ensure_single_writer(run_id),` followed by the existing
`{:ok, env_map, resolved_secrets} <- build_launch_env(project_id, opts) do`. Add `require Logger` and:

```elixir
# One worker per run, so two agents can never write the same worktree. The
# previous phase's LaunchWorker is torn down by a detached task
# (`Exec.Runners.Overwatch`), so a short wait distinguishes "still exiting"
# from a genuine second writer.
@single_writer_wait_ms 2_000
@single_writer_poll_ms 50

defp ensure_single_writer(run_id), do: ensure_single_writer(run_id, @single_writer_wait_ms)

defp ensure_single_writer(run_id, remaining_ms) do
  case WorkerSupervisor.list_pids_for_run(run_id) do
    [] ->
      :ok

    pids when remaining_ms <= 0 ->
      Logger.error(
        "Overwatch: refusing a second worker for run #{run_id}; #{length(pids)} already live"
      )

      {:error, {:worker_already_running, run_id}}

    _pids ->
      Process.sleep(@single_writer_poll_ms)
      ensure_single_writer(run_id, remaining_ms - @single_writer_poll_ms)
  end
end
```

`Exec.Runners.Overwatch` already maps any `{:error, reason}` from `start_phase/2` to
`{:error, {:overwatch_start_failed, reason}}` (:305) — no change there.

**7. `lib/foreman_server/workflow/dispatcher.ex`** — add `alias ForemanServer.Overwatch.WorkerSupervisor`
(alias block :58-70). In `handle_run_terminated/3`, inside
`if event_type in @agent_killing_terminal_event_types do` (:647-650), after the two `RunControl` calls:

```elixir
# RunControl is an ETS cache the executor wipes in terminate/2, so by the time
# this event lands cancel_agent/1 can be a no-op. The Overwatch registry is the
# authoritative list of this run's live workers. Detached: stopping a worker can
# take seconds and must not block the projection subscriber.
Task.start(fn -> WorkerSupervisor.stop_run_workers(run_id) end)
```

Add the same `Task.start(...)` line in `handle_run_stopped/3` (RunPaused, :674-705) after the
`RunControl.cancel_agent/1` case.

**8. `docs/user-guide.md`** (run-lifecycle bullets, :1080-1100) — one new bullet after the `run cancel`
bullet: a run reaching `failed`, `cancelled` or `paused` stops every worker Foreman started for it,
including the `pi`/`claude` OS process (cancel plus a bounded ~15 s wait, then the worktree sweep); a
worker that will not stop is logged at `:error` naming the run; while a worker for a run is live Foreman
refuses to start a second one (single writer per worktree); automated review of a *failed* run is
deliberate (`ForemanServer.Review.Analyzer`).

**9. `CLAUDE.md`** (:60-68) — after the "`stop_worker/2` is cleanup, not a guard" paragraph, one sentence:
the terminal/pause stop path is `WorkerSupervisor.stop_run_workers/1`, driven from the Overwatch registry
by `Workflow.Dispatcher`, because `RunControl` is cleared by the executor's `terminate/2`.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/overwatch test/foreman_server/overwatch_test.exs \
  test/foreman_server/workflow/dispatcher_test.exs \
  test/foreman_server/workflow/run_executor_failure_reap_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = every command exits 0, both new test files pass, zero warnings. A failing test is a failed
build: do not skip or tag anything.

## 6. Out of scope — do NOT touch

- **Reviewer agents on terminal runs.** `Review.Analyzer`'s `@terminal_events` (`analyzer.ex:54`) is the
  feature. Do not filter `RunFailed`/`RunCancelled` out of it and do not add a config key for it.
- `RunExecutor`'s cancel path (`reap_cancelled_run_agents/1`, `await_agent_exit/1`) and
  `cleanup_run_worktree/3` — already correct; the failure gap is fixed at the dispatcher.
- `OrphanReaper` matching rules (cwd-in-worktree + ppid 1), `BootReconciliation`, `CrashLoopDetector`.
- `LaunchWorker`'s `restart: :transient` policy and its `:normal`/`:shutdown`/crash exit mapping.
- `packages/jido_harness/**` and `packages/foreman_cli/**`. No CLI verb, HTTP route, MCP tool, env var or
  config key is added, removed or renamed by this change.
- Do not reroute the existing `stop_worker/2` callers (`Exec.Runners.Overwatch:679`,
  `CrashLoopDetector:551`): they stop one named worker, not a run.
