defmodule ForemanServer.Jobsite.Runners.Overwatch do
  @moduledoc """
  `ForemanServer.Jobsite.Runner` implementation that dispatches through
  `ForemanServer.Overwatch.start_phase/2` instead of calling
  `Jido.Harness.Run` directly, so the spawned worker is a supervised
  Overwatch worker: `WorkerStarted`/`WorkerHeartbeat`/`WorkerExited` are
  emitted via `CommandRouter`, and `ProjectionStore` derives the bounded
  stdout/stderr ring buffer behind MCP `foreman_run_get_logs`,
  `run.last_event_at_ms` behind `StuckDetector`'s idle scan, and the active
  phase's activity timestamps behind `StallDetector` from those events.
  `ForemanServer.Jobsite.Runners.Direct` produces none of that.

  `capabilities/0` is `%{iterations: :one, live_stream: false}`: one
  invocation per call, and the normalized result carries text only — no
  session id, no token usage — because
  `ForemanServer.Overwatch.Adapters.JidoHarnessWorker` unwraps
  `Jido.Harness.RunResult.normalize/1`'s 3-tuple to `{:ok, text}` before
  forwarding it, and completion-signal matching is not performed on this
  path — the engine rejects `max_iterations > 1` or a non-empty
  completion-signal list on a runner whose `capabilities().iterations ==
  :one` before any side effect.

  ## Two ways in, one protocol

  A **launch** (`opts[:launch]`) is a fully prepared dispatch built by
  `ForemanServer.Workflow.RunExecutor` for a workflow phase — request, env,
  prompt path, deadline, heartbeat-lease identity — because everything in
  it derives from run state the engine has no view of. Without one (a
  `Jobsite.run/1` script using this runner) `run/4` builds an equivalent
  launch from the agent and the iteration's idle timeout. Both then run the
  one protocol below, so a script and a manifest phase cannot disagree about
  how a worker is started, awaited, or reaped.

  A launch is a map:

    * `:run_id`, `:phase` (the first argument of `Overwatch.start_phase/2`),
      `:phase_index`
    * `:deadline_ms` — absolute `System.system_time(:millisecond)`, or
      `:infinity`
    * `:activation_timeout_ms` — ceiling for worker admission; the effective
      value is `min(ceiling, remaining budget)`
    * `:driver_opts` — `(remaining_ms -> keyword)`, so the driver's own
      timeouts are derived from the budget still left at launch time
    * `:launch_opts` — the rest of the `start_phase/2` options
    * `:lease` — `%{key:, budget_ms:, task_id:}` or `nil`. When present the
      runner holds the `HeartbeatLease` and `RunExecutorLiveness` record for
      exactly the span of the dispatch and releases both on every exit path
    * `:timeout_ms` — optional, reported in an idle-timeout error's details

  ## Outcomes

  The wait is `wait_for_worker_result/4`, moved here verbatim from
  `RunExecutor` when phase execution moved onto the engine. Its outcomes are
  deliberately distinct (AGENTS.md §5.3) and survive into `Error.details`:
  `{:error, %Error{details: %{reason: reason}}}` carries the exact reason the
  executor's phase-failure payload has always reported
  (`:worker_timeout`, `:worker_died_no_result`, `:worker_already_started`,
  `{:overwatch_start_failed, reason}`, or whatever error the worker
  delivered). The `Error.code` is the engine-facing summary of it.

  Phase deadline rules (AGENTS.md, "RunExecutor phase completion rules"):
  the deadline bounds how long this process waits for `{:worker_result, _}`;
  a non-empty success already in the mailbox stays authoritative even past
  it; every timeout path drains stray `{:worker_result, _}` messages before
  returning, because the calling process runs the NEXT phase in the same
  mailbox; and a worker that died without a result is always
  `:worker_died_no_result`, never `:worker_timeout`.
  """

  @behaviour ForemanServer.Jobsite.Runner

  alias ForemanServer.Idempotency.HeartbeatLease
  alias ForemanServer.Jobsite.{Error, IterationResult}
  alias ForemanServer.Overwatch
  alias ForemanServer.RunExecutorLiveness

  require Logger

  @default_adapter ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  @default_activation_timeout_ms 5_000
  @default_idle_timeout_ms 600_000

  @impl true
  def capabilities, do: %{iterations: :one, live_stream: false}

  @impl true
  def run(agent, prompt, sandbox, opts) do
    index = Keyword.get(opts, :index, 1)

    case Keyword.fetch(opts, :launch) do
      {:ok, %{} = launch} ->
        run_launch(launch, index)

      :error ->
        with {:ok, launch} <- scripted_launch(agent, prompt, sandbox, opts) do
          run_launch(launch, index)
        end
    end
  end

  # ---------------------------------------------------------------------
  # Launch + wait
  # ---------------------------------------------------------------------

  defp run_launch(launch, index) do
    launch
    |> dispatch_with_lease()
    |> to_iteration_result(launch, index)
  end

  # TRD-076/077: the heartbeat lease keeps the idempotency key `started` (or
  # moves it to `ambiguous` on expiry) whether the agent completes, crashes
  # or hangs, and `task_id`/`run_id` ride in KeyStore metadata so
  # `CrashRecovery.has_no_side_effects?` can look them up without parsing the
  # composite key. Released on every exit path.
  defp dispatch_with_lease(%{lease: %{} = lease} = launch) do
    HeartbeatLease.acquire(lease.key, lease.budget_ms, lease.task_id, launch.run_id)
    HeartbeatLease.register_worker(launch.run_id, launch.run_id, lease.key)
    RunExecutorLiveness.record(launch.run_id, self(), launch.deadline_ms)

    try do
      dispatch(launch)
    after
      HeartbeatLease.release(lease.key)
      RunExecutorLiveness.clear(launch.run_id, self())
    end
  end

  defp dispatch_with_lease(launch), do: dispatch(launch)

  defp dispatch(launch) do
    remaining_ms = remaining_from(launch.deadline_ms)

    if remaining_ms != :infinity and remaining_ms <= 0 do
      # Floor of 0: once the deadline has elapsed, the driver gets no
      # additional budget, so the FailurePolicy deadline is honoured even
      # when admission/dispatch already consumed it.
      Logger.warning("[#{launch.run_id}] phase #{launch.phase_index} deadline exhausted before worker activation")

      {:error, :worker_timeout}
    else
      # Cap activation by the remaining phase budget: a fixed default would
      # let worker admission alone consume time past the deadline before the
      # deadline-aware receive below even starts. `min(int, :infinity)` is
      # `int` by Erlang term order — intentional, load-bearing.
      activation_timeout_ms = min(launch.activation_timeout_ms, remaining_ms)

      launch_opts =
        [
          run_id: launch.run_id,
          session_id: generate_session_id(),
          # Overridable so integration tests can inject an Overwatch-worker
          # protocol test double instead of spawning a real agent session.
          adapter: Application.get_env(:foreman_server, :worker_adapter, @default_adapter),
          adapter_name: "jido_harness",
          driver_opts: launch.driver_opts.(remaining_ms),
          result_recipient: self(),
          activation_timeout_ms: activation_timeout_ms
        ] ++ launch.launch_opts

      case Overwatch.start_phase(launch.phase, launch_opts) do
        {:ok, %{worker_id: worker_id, launch_pid: launch_pid}} ->
          # Always enter the wait, even when the budget is exhausted at the
          # receive boundary: a result can already be queued after the worker
          # completed but before the final lifecycle dispatch returned, and
          # the receive owns the distinction between an already-delivered
          # success and no result before the deadline.
          wait_for_worker_result(launch_pid, worker_id, launch.run_id, launch.deadline_ms)

        {:error, {:already_started, _pid}} ->
          {:error, :worker_already_started}

        {:error, reason} ->
          {:error, {:overwatch_start_failed, reason}}
      end
    end
  end

  defp to_iteration_result({:ok, output}, _launch, index) do
    {:ok, %IterationResult{index: index, status: :completed, text: output}}
  end

  defp to_iteration_result({:error, :worker_timeout}, launch, _index) do
    details = %{reason: :worker_timeout, run_id: launch.run_id} |> put_timeout(launch)
    {:error, Error.new(:agent_idle_timeout, "worker did not deliver a result in time", details)}
  end

  defp to_iteration_result({:error, :worker_already_started = reason}, launch, _index) do
    {:error, Error.new(:agent_start_failed, "worker already started", %{reason: reason, run_id: launch.run_id})}
  end

  defp to_iteration_result({:error, {:overwatch_start_failed, _} = reason}, launch, _index) do
    {:error, Error.new(:agent_start_failed, "overwatch start_phase failed", %{reason: reason, run_id: launch.run_id})}
  end

  defp to_iteration_result({:error, reason}, launch, _index) do
    {:error, Error.new(:agent_failed, "agent run failed", %{reason: reason, run_id: launch.run_id})}
  end

  defp put_timeout(details, %{timeout_ms: timeout_ms}), do: Map.put(details, :timeout_ms, timeout_ms)
  defp put_timeout(details, _launch), do: details

  # ---------------------------------------------------------------------
  # Script-path launch
  # ---------------------------------------------------------------------

  defp scripted_launch(agent, prompt, sandbox, opts) do
    with {:ok, prompt_path} <- materialize_prompt(prompt) do
      timeout_ms = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)
      cwd = Keyword.get(opts, :cwd) || (sandbox && sandbox.sandbox_repo_path)
      run_id = Keyword.get(opts, :run_id) || (sandbox && sandbox.jobsite_id)

      {:ok,
       %{
         run_id: run_id,
         phase: Keyword.get(opts, :phase, "jobsite:#{run_id}"),
         phase_index: Keyword.get(opts, :index, 1),
         deadline_ms: deadline_from(timeout_ms),
         timeout_ms: timeout_ms,
         activation_timeout_ms: Keyword.get(opts, :activation_timeout_ms, @default_activation_timeout_ms),
         lease: nil,
         driver_opts: fn remaining_ms ->
           [timeout: remaining_ms, await_timeout: remaining_ms, cwd: cwd]
           |> maybe_put(:model, agent.model)
           |> Keyword.merge(provider_options_list(agent))
         end,
         launch_opts:
           [
             prompt_path: prompt_path,
             provider: agent.provider,
             prompt: prompt,
             env_map: agent.env || %{},
             secrets: Keyword.get(opts, :secrets, [])
           ]
           |> Enum.reject(fn {_k, v} -> is_nil(v) end)
       }}
    end
  end

  defp materialize_prompt(prompt) do
    path = Path.join(System.tmp_dir!(), "jobsite-overwatch-prompt-#{System.unique_integer([:positive])}.md")

    case File.write(path, prompt) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, Error.new(:agent_start_failed, "failed to materialize prompt file", %{reason: reason})}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp provider_options_list(%{provider_options: options}) when is_map(options) and map_size(options) > 0,
    do: Map.to_list(options)

  defp provider_options_list(_agent), do: []

  defp generate_session_id, do: "session-" <> Elixir.EventStore.UUID.uuid4()

  # ---------------------------------------------------------------------
  # Deadlines
  # ---------------------------------------------------------------------

  # `policy.timeout_ms` from `FailurePolicy.resolve/2` is either a positive
  # integer (milliseconds) or `:infinity` (`timeout_minutes: 0`, or no
  # timeout configured anywhere). Total over both shapes — no catch-all
  # (AGENTS.md §5.2) — so an unrecognized third shape is a FunctionClauseError,
  # not a silently wrong deadline.
  @doc false
  @spec deadline_from(timeout()) :: timeout()
  def deadline_from(:infinity), do: :infinity
  def deadline_from(ms) when is_integer(ms), do: System.system_time(:millisecond) + ms

  # Mirrors `deadline_from/1`: an `:infinity` deadline never runs out, so the
  # remaining budget is `:infinity` too. `receive ... after` accepts
  # `:infinity` natively; `HeartbeatLease.acquire/4` cannot, which is what
  # `lease_budget/1` is for.
  @doc false
  @spec remaining_from(timeout()) :: timeout()
  def remaining_from(:infinity), do: :infinity

  def remaining_from(deadline) when is_integer(deadline),
    do: max(deadline - System.system_time(:millisecond), 0)

  # `HeartbeatLease.acquire/4` arms a real `Process.send_after/3` timer and
  # requires an integer lease_ms — it cannot accept `:infinity`. The lease is
  # renewed to `HeartbeatLease.default_lease_ms/0` on every worker heartbeat
  # regardless of the phase's own deadline (`Overwatch.Tracker` calls
  # `renew/1` with the default), so handing it that same default when the
  # phase has no deadline keeps the lease's steady-state TTL independent of
  # the phase budget.
  @doc false
  @spec lease_budget(timeout()) :: non_neg_integer()
  def lease_budget(:infinity), do: HeartbeatLease.default_lease_ms()
  def lease_budget(ms) when is_integer(ms), do: ms

  # ---------------------------------------------------------------------
  # Waiting for the worker
  # ---------------------------------------------------------------------

  # `deadline_ms` is the absolute wall-clock budget (System.system_time
  # milliseconds), not a relative timeout: it bounds how long this process
  # BLOCKS waiting for `{:worker_result, result}`. It is not a validity window
  # stamped on the result itself.
  #
  # A result cannot already be sitting in the mailbox when this receive starts:
  # `Overwatch.start_phase/2` returns only after the worker has been spawned
  # (`WorkerSupervisor.start_worker/1` → `LaunchWorker.init/1` →
  # `WorkerProtocol.start_worker/3` → `adapter.start_link/1`, all synchronous in
  # the CALLER), and the adapter sends `{:worker_result, result}` only after
  # activation and agent completion. The earliest a result can exist is after
  # this call has already begun waiting. So the deadline only decides how long
  # we wait; a result that arrives before it is accepted on its merits (a
  # non-empty success is authoritative; a late error result is not). When the
  # deadline elapses with no result, this drains the mailbox — see
  # `drain_worker_result_stubs/3` — so a late arrival cannot leak into the next
  # phase.

  # One deadline rule for every `{:worker_result, _}` arrival path (the direct
  # success arm and the DOWN-first probe arm must not drift apart — they are
  # the same race observed from two orderings):
  #
  #   * within deadline -> the result is the outcome, unconditionally;
  #   * past deadline, non-empty success -> record the completed outcome. The
  #     agent did produce its artifact; failing the phase and discarding real
  #     work because delivery raced the deadline is the outcome-preserving
  #     choice, and it removes the success/error asymmetry where a late error
  #     was rejected but a late success silently determined the result;
  #   * past deadline, error/empty -> reject, then keep scanning the mailbox
  #     through the drain, because a genuine success can still be queued
  #     behind it under scheduler load.
  defp accept_after_deadline(result, deadline_ms, run_id, worker_id, reason) do
    past_deadline? =
      deadline_ms != :infinity and System.system_time(:millisecond) >= deadline_ms

    cond do
      not past_deadline? ->
        result

      completed_worker_success?(result) ->
        Logger.warning(
          "[#{run_id}] worker #{worker_id} successful result arrived after deadline; recording the completed outcome"
        )

        result

      true ->
        Logger.warning(
          "[#{run_id}] worker #{worker_id} error result arrived after deadline; supervisor will reap launch process"
        )

        case drain_worker_result_stubs(run_id, worker_id, reason) do
          {:ok, recovered} -> recovered
          _ -> {:error, reason}
        end
    end
  end

  # Drain and discard any `{:worker_result, _}` still queued in the calling
  # process's mailbox once a timeout has been decided for the current phase.
  #
  # Results are discarded rather than left to the caller's own stray-result
  # handler: that handler only covers results that arrive AFTER a wait has
  # already returned, whereas here the wait is still on the stack and the
  # result must be removed synchronously before this function returns, so the
  # next phase's blocking receive cannot match it even if the current process
  # happens to yield in between.
  #
  # Loops so more than one leaked message cannot survive (e.g. a duplicate
  # LaunchWorker re-launch result queued behind this phase's own). Discarded
  # results are logged with run/worker context, never silently dropped, so an
  # operator can tell "arrived late" from "never arrived".
  @spec drain_worker_result_stubs(String.t(), String.t(), term()) :: :ok | {:ok, term()}
  defp drain_worker_result_stubs(run_id, worker_id, timeout_reason) do
    drain_worker_result_stubs(run_id, worker_id, timeout_reason, 0, nil)
  end

  defp drain_worker_result_stubs(run_id, worker_id, timeout_reason, drained, recovered) do
    # The loop MUST run to mailbox-empty before returning, whatever it finds on
    # the way: any {:worker_result, _} left here is absorbable by the NEXT
    # phase's blocking receive, which would commit the previous phase's output
    # as its own artifact. `recovered` remembers the FIRST successful result
    # seen so the scan can keep discarding strays behind it and still return
    # the outcome.
    receive do
      {:worker_result, result} ->
        if drained_success(result) and is_nil(recovered) do
          Logger.warning(
            "[#{run_id}] worker #{worker_id}: recovered queued worker_result after " <>
              "#{inspect(timeout_reason)} (#{inspect(result)}); continuing to drain"
          )

          drain_worker_result_stubs(run_id, worker_id, timeout_reason, drained + 1, result)
        else
          Logger.warning(
            "[#{run_id}] worker #{worker_id}: discarding queued worker_result after " <>
              "#{inspect(timeout_reason)} (drained #{drained + 1}: #{inspect(result)})"
          )

          drain_worker_result_stubs(run_id, worker_id, timeout_reason, drained + 1, recovered)
        end
    after
      0 ->
        case recovered do
          nil -> :ok
          result -> {:ok, result}
        end
    end
  end

  # A success is worth recovering from the drain path only when its value
  # proves the agent actually produced output — the same bar
  # `completed_worker_success?/1` applies to post-deadline arrivals.
  defp drained_success({:ok, output}) when is_binary(output), do: String.trim(output) != ""
  defp drained_success({:ok, _output}), do: true
  defp drained_success(_other), do: false

  defp completed_worker_success?({:ok, output}) when is_binary(output),
    do: String.trim(output) != ""

  defp completed_worker_success?({:ok, _output}), do: true
  defp completed_worker_success?({:error, _reason}), do: false

  @spec wait_for_worker_result(pid(), String.t(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  defp wait_for_worker_result(launch_pid, worker_id, run_id, deadline_ms) do
    ref = Process.monitor(launch_pid)
    timeout_ms = remaining_from(deadline_ms)

    result =
      receive do
        {:worker_result, result} ->
          # Same deadline rule as the DOWN-branch probe (see
          # `accept_after_deadline/5`): a post-deadline ERROR is rejected — but
          # the scan for a real queued success continues through the drain.
          accept_after_deadline(result, deadline_ms, run_id, worker_id, :worker_timeout)

        {:DOWN, ^ref, :process, ^launch_pid, _reason} ->
          # DOWN arrived first. Probe for a worker_result already queued behind
          # it: a worker that completed does send its result, so DOWN winning
          # the race is not evidence that no result exists.
          receive do
            {:worker_result, result} ->
              accept_after_deadline(result, deadline_ms, run_id, worker_id, :worker_timeout)
          after
            0 ->
              # DOWN with no worker_result behind it: the worker died without
              # producing a result. That is a crash, and it stays
              # `:worker_died_no_result` even when wall time has crossed the
              # deadline (AGENTS.md §5.3). `:worker_timeout` means "deadline
              # elapsed, result unknown/stale" — reporting a result-less death
              # as a timeout once the deadline passed loses a distinction the
              # pause/cancel handling downstream depends on.
              #
              # Nothing matched the probe receive, but a result can still be
              # queued behind the DOWN that the probe's own arm ordering missed
              # (e.g. delivered between the two receives): drain scans the rest
              # of the mailbox, discarding every stub. If a real success turns
              # up, THAT is the phase's outcome and is preserved; nothing else
              # is allowed to survive this return.
              case drain_worker_result_stubs(run_id, worker_id, :worker_died_no_result) do
                {:ok, recovered} -> recovered
                _ -> {:error, :worker_died_no_result}
              end
          end
      after
        timeout_ms ->
          # §5.3 outcome discrimination: `:worker_timeout` means "the deadline
          # elapsed and the result is unknown". If the launch worker is already
          # dead here, the outcome is NOT unknown — it died without producing a
          # result, and that must stay `:worker_died_no_result` even once wall
          # time has crossed the deadline (pause/cancel handling downstream keys
          # off the distinction, see run_executor_run_worktree_test.exs).
          #
          # `Process.alive?/1` is authoritative: the monitor DOWN for this pid
          # cannot be in our mailbox ahead of this arm without also having
          # matched the `{:DOWN, ^ref, ...}` clause above (a queued DOWN for a
          # dead pid is delivered at monitor-install time, before the receive),
          # so a dead pid here means a result-less death whose DOWN we never
          # observed. Drain first so a result that raced the death cannot leak
          # into the next phase.
          if Process.alive?(launch_pid) do
            Logger.warning(
              "[#{run_id}] worker #{worker_id} did not deliver result within #{timeout_ms}ms; supervisor will reap launch process"
            )

            case drain_worker_result_stubs(run_id, worker_id, :worker_timeout) do
              {:ok, recovered} -> recovered
              _ -> {:error, :worker_timeout}
            end
          else
            Logger.warning("[#{run_id}] worker #{worker_id} died without delivering a result")

            case drain_worker_result_stubs(run_id, worker_id, :worker_died_no_result) do
              {:ok, recovered} -> recovered
              _ -> {:error, :worker_died_no_result}
            end
          end
      end

    # Remove the LaunchWorker child spec so nothing for this phase can be
    # relaunched — a plain WorkerExited does NOT seal the Worker aggregate
    # (only WorkerCrashed/RunCompleted/RunFailed do, see
    # aggregates/worker.ex), so a crashed worker would otherwise keep
    # restarting for a phase this process has already finished with.
    #
    # This is cleanup, NOT the guard against relaunching a *finished* phase.
    # It used to be that guard, and it lost: under the old
    # `restart: :permanent` child spec every worker exit relaunched, and in
    # run-de055c18749db5e9c702d24950268cf9 the relaunch beat this task by
    # 56ms and leaked an agent that ran 8m42s past the run's terminal state.
    # `LaunchWorker` now propagates its worker's exit reason to a
    # `restart: :transient` child spec, so a finished or torn-down worker
    # ends its child without depending on this race.
    #
    # `stop_worker/2` internally blocks on
    # `DynamicSupervisor.terminate_child/2`, which waits for LaunchWorker's
    # shutdown to finish; that can need to round-trip through CommandRouter
    # back to THIS run's aggregate actor — i.e. back to the calling process
    # when it is the RunExecutor. Calling it synchronously here deadlocks the
    # executor against itself (confirmed empirically: caused ~300 cascading
    # suite-wide failures once EventStore subscriptions started timing out
    # waiting on a stalled executor mailbox). Run it in a detached task
    # instead so it can't block the caller.
    Task.start(fn -> Overwatch.WorkerSupervisor.stop_worker(worker_id, run_id) end)

    # Once the deadline is exhausted (either receive-timeout branch above,
    # or a late worker_result rejected as timeout), the launch_pid's exit
    # order no longer matters to this call — the detached stop_worker task
    # above reaps it. Blocking here up to 5,000ms to drain a DOWN we no
    # longer need would just add caller-visible latency after the timeout
    # has already been decided (CodeRabbit review); demonitor and flush any
    # already-queued DOWN instead.
    #
    # `:worker_died_no_result` already consumed the DOWN in the receive
    # above — draining again here would just spin the full 5,000ms waiting
    # for a message that can never arrive.
    #
    # Only a real result reaches this point without the DOWN already
    # accounted for: the worker may still be tearing down, so drain it if
    # it hasn't arrived yet, so the process monitor doesn't fire a stray
    # message later.
    case result do
      {:error, :worker_timeout} ->
        Process.demonitor(ref, [:flush])

      {:error, :worker_died_no_result} ->
        Process.demonitor(ref, [:flush])

      _ ->
        receive do
          {:DOWN, ^ref, :process, ^launch_pid, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end

    result
  end

  @doc false
  def __wait_for_worker_result_for_test__(launch_pid, worker_id, run_id, deadline_ms),
    do: wait_for_worker_result(launch_pid, worker_id, run_id, deadline_ms)
end
