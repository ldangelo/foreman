defmodule ForemanServer.AgentRuntime.JidoHarness.Driver do
  @moduledoc false

  alias Jido.Harness.Process, as: HarnessProcess
  alias Jido.Harness.Run

  @live_process_states [:starting, :running, :stopping]

  # How long a stop waits for an agent to exit: after `Run.cancel/1` the harness escalates
  # SIGINT -> SIGTERM -> SIGKILL on its own schedule (5 s per step by default), then drains the
  # agent's output.
  @exit_wait_ms 15_000

  @spec run(atom(), String.t(), keyword()) ::
          {:ok, Jido.Harness.RunResult.t()} | {:ok, map()} | map() | {:error, term()}
  def run(provider, prompt, opts) when is_atom(provider) and is_binary(prompt) do
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    case Run.start(provider, prompt, upstream_opts(opts)) do
      {:ok, harness_run_id} ->
        notify_on_start(opts[:on_start], harness_run_id)
        Run.await(harness_run_id, await_timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec await(String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.RunResult.t())
  def await(run_id, timeout), do: Run.await(run_id, timeout)

  @doc """
  Blocks until the OS processes the harness started for `harness_run_id` have exited, for at
  most `timeout_ms` (default #{@exit_wait_ms}, the harness's own escalation plus slack) in total.

  `Run.cancel/1` finalizes a run as soon as it has signalled the agent (SIGINT); the harness then
  escalates to SIGTERM and SIGKILL on its own schedule, so a cancelled run reads as over while
  its agent can still be running. Until the agent is gone, the tool processes it started are
  still its children: only afterwards are they orphans, re-parented to pid 1, which is how
  `ForemanServer.Workflow.OrphanReaper` recognises them. A run whose processes are already
  terminal (or pruned, or never had any) returns `:ok` at once.
  """
  @spec await_exit(String.t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def await_exit(harness_run_id, timeout_ms \\ @exit_wait_ms)
      when is_binary(harness_run_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    for %{process_id: process_id, metadata: metadata} <- live_processes(),
        Map.get(metadata, :run_id) == harness_run_id or
          Map.get(metadata, "run_id") == harness_run_id,
        reduce: :ok do
      acc ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        case HarnessProcess.await(process_id, remaining) do
          {:ok, _info} -> acc
          # Pruned between the listing and the wait: it ended.
          {:error, :not_found} -> acc
          {:error, :timeout} -> {:error, :timeout}
        end
    end
  end

  @doc """
  The OS pid of every agent process the harness has running (still starting, running or
  being stopped), whichever run owns it.
  """
  @spec agent_os_pids() :: [pos_integer()]
  def agent_os_pids do
    for %{os_pid: os_pid} when is_integer(os_pid) <- live_processes(), do: os_pid
  end

  # The harness registry only exists while the harness application runs.
  defp live_processes do
    if Process.whereis(Jido.Harness.ProcessRegistry),
      do: HarnessProcess.list(states: @live_process_states),
      else: []
  end

  defp notify_on_start(nil, _harness_run_id), do: :ok

  defp notify_on_start(on_start, harness_run_id) when is_function(on_start, 1),
    do: on_start.(harness_run_id)

  defp upstream_opts(opts) do
    opts = Keyword.drop(opts, [:on_start, :await_timeout])
    timeouts = Keyword.get_values(opts, :timeout)
    rest = Keyword.drop(opts, [:timeout])

    case List.last(timeouts) do
      nil ->
        rest

      timeout ->
        if Keyword.has_key?(rest, :runtime_timeout_ms) do
          rest
        else
          Keyword.put(rest, :runtime_timeout_ms, timeout)
        end
    end
  end
end
