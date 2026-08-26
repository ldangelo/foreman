defmodule ForemanServer.RunExecutorLiveness do
  @moduledoc """
  Active-phase deadline registry for `RunExecutor`.

  `RunExecutor.execute_agent/4` blocks synchronously inside
  `handle_info(:kickoff)` while the agent subprocess is running (up to
  the per-phase `FailurePolicy.timeout_ms`). A `GenServer.call/2` to
  the executor would deadlock while that block is in flight, so the
  executor publishes its active invocation deadline here BEFORE calling
  `AgentRuntime.execute/3` and clears it AFTER the call returns.

  Each entry stores BOTH the executor PID that recorded the deadline
  AND the wall-clock deadline. The PID is what makes this safe across
  crashes: a brutally-killed executor cannot clear its own entry, and
  the supervisor's replacement will register a new PID under
  `RunExecutorRegistry` for the same run. The liveness exemption
  therefore requires the stored PID to match the registered PID — a
  stale future deadline left behind by a dead executor can never
  exempt a run that has since been respawned.

  `StuckDetector.scan/1` reads this table to decide whether a run is
  actively progressing (deadline still in the future AND owner matches
  the registered executor) past the 15-minute idle threshold. A wedged
  agent whose deadline has expired is still flagged; a fresh respawn
  with no entry yet is also flagged until `execute_agent/4` records
  its own deadline.

  The table is owned by this GenServer so its lifetime is bound to
  the application supervisor, not to whichever transient caller
  triggered lazy initialisation. Without a long-lived owner, an ETS
  table created by a test process dies when that process exits, losing
  liveness state for invocations that span process boundaries.
  """

  use GenServer

  @table __MODULE__

  ## -- GenServer ---------------------------------------------------------

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # This is the only path that creates the ETS table. Public functions
    # do not call ensure_table/0 — that would let a transient caller
    # steal ownership during a GenServer restart, recreating the
    # original lazy-init race. If the GenServer is down, public
    # functions will hit :undefined and fail; the supervisor restarts
    # us quickly under :permanent.
    ensure_table()
    {:ok, %{}}
  end

  ## -- public API --------------------------------------------------------

  @doc """
  Records an active invocation deadline for `run_id`, owned by `owner`.

  `deadline_ms` is the absolute wall-clock millisecond timestamp at
  which the in-flight invocation will time out. `owner` is the PID of
  the `RunExecutor` process that is currently blocking on
  `AgentRuntime.execute/3`; it MUST be the process that is also
  registered under `RunExecutorRegistry` for `run_id`. Callers MUST
  publish the deadline BEFORE blocking into the agent and call
  `clear/1` AFTER the agent returns (success or failure) so the table
  never records a deadline past completion.

  Storing the owner PID is what makes the StuckDetector exemption
  safe across a brutal executor kill: a respawned executor's PID will
  not match the dead owner's stored PID, so any future-looking
  deadline left behind by the dead owner will not exempt the run.
  """
  @spec record(String.t(), pid(), non_neg_integer()) :: :ok
  def record(run_id, owner, deadline_ms)
      when is_binary(run_id) and is_pid(owner) and is_integer(deadline_ms) do
    :ets.insert(@table, {run_id, {owner, deadline_ms}})
    :ok
  end

  @doc """
  Returns the liveness status for `run_id`:

    * `:none` — no entry recorded; the run is either idle, terminated,
      or was started before this process came up.
    * `{:active, owner, deadline_ms}` — an entry is recorded,
      `now_ms` is strictly before `deadline_ms`, and `owner` is the PID
      that recorded the deadline. The in-flight invocation is still
      within its timeout window.
    * `{:expired, owner, deadline_ms}` — an entry is recorded but
      `now_ms >= deadline_ms`. The in-flight invocation has exceeded
      its timeout window; the StuckDetector should flag the run.

  Callers that want to exempt a run from stuck detection MUST compare
  the returned `owner` against the currently-registered executor PID
  via `RunExecutor.pid_for/1`. A match-against-stored-PID is the
  only thing that prevents a stale entry from a brutally-killed
  predecessor from exempting a freshly-respawned executor.
  """
  @spec lookup(String.t(), non_neg_integer()) ::
          :none
          | {:active, pid(), non_neg_integer()}
          | {:expired, pid(), non_neg_integer()}
  def lookup(run_id, now_ms) when is_binary(run_id) and is_integer(now_ms) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, {owner, deadline_ms}}] when now_ms < deadline_ms ->
        {:active, owner, deadline_ms}

      [{^run_id, {owner, deadline_ms}}] ->
        {:expired, owner, deadline_ms}

      [] ->
        :none
    end
  end

  @doc """
  Removes the liveness entry for `run_id`. No-op when no entry exists.
  Use this only for test setup/teardown or operator admin. Production
  callers MUST use `clear/2` so a late cleanup from a brutally-killed
  predecessor cannot delete a freshly-recorded replacement entry.
  """
  @spec clear(String.t()) :: :ok
  def clear(run_id) when is_binary(run_id) do
    :ets.delete(@table, run_id)
    :ok
  end

  @doc """
  Atomically removes the liveness entry for `run_id` ONLY if the stored
  owner is `owner`. This is the production call site for the
  `execute_agent/4` `try/after` cleanup. The owner guard makes the
  call safe across a crash/restart: a predecessor that resumes its
  `after` block after a respawned executor has already recorded a
  new entry will see the owner mismatch and become a no-op instead of
  deleting the live replacement's deadline.
  """
  @spec clear(String.t(), pid()) :: :ok
  def clear(run_id, owner) when is_binary(run_id) and is_pid(owner) do
    match_spec = [{{run_id, {owner, :_}}, [], [true]}]
    :ets.select_delete(@table, match_spec)
    :ok
  end

  @doc """
  Clears every recorded deadline. Useful for tests.
  """
  @spec clear_all() :: :ok
  def clear_all do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end
  end

  @doc """
  Returns the current number of recorded entries. Useful for tests.
  """
  @spec size() :: non_neg_integer()
  def size do
    case :ets.info(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  ## -- private -----------------------------------------------------------

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
