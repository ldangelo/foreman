defmodule ForemanServer.Aggregates.BeadsDbLease.Keeper do
  @moduledoc """
  Gives the lease back for a `BeadsDbLease.with_lease/4` caller that died holding or awaiting it.

  `with_lease/4` returns the lease from a `try/after` in the calling process. A process that ends
  from an exit signal it does not trap (`Process.exit(pid, :kill)`, a supervisor's `:shutdown` of
  a child that does not trap exits, the crash of a linked process) never runs that `after`. The
  hold names the incarnation of this VM, and this VM is alive, so no other caller can call it dead
  (that is what `ForemanServer.Incarnation` does for a VM that ended): the lease stayed taken
  until the next restart, and every other caller of that Beads database queued behind it until
  `:lease_timeout`. A dead waiter was worse: it stayed in the queue and was promoted to a hold
  nobody would ever release (foreman-8qge).

  `with_lease/4` starts one keeper per call, under `KeeperSupervisor` and so outside the caller's
  own supervision subtree. The keeper monitors the caller and does nothing while it lives: a `br`
  call may legitimately run long and keeps its lease for as long as it runs, so no timer is
  involved. When the caller goes down the keeper dispatches `lease.remove_waiter` and then
  `lease.release` for the caller's `run_id`, with reason `:caller_down`. That is the cleanup the
  caller's own `after` would have done, in that order: an entry removed from the queue first can
  no longer be promoted in between, and a hold released second goes to the next waiter that is
  still alive (a dead one has a keeper doing the same) or frees the lease.

  Guarantees:

    * **Armed before the lease is touched.** `watch/4` returns once the keeper's `init/1` has set
      its monitor, and `with_lease/4` dispatches `lease.acquire` only after that, so no entry of a
      call can exist without a keeper to clear it. A caller that dies with its `lease.acquire`
      still on the way to the lease actor is covered too: the keeper's commands follow that
      message to the actor.
    * **Gone with the call.** `unwatch/1` stops the keeper once the caller's own release has
      landed, so a normal call leaves no keeper, no monitor and no second `lease.release` behind.
      A release that failed (`BeadsDbLease.ReleaseError`) leaves the keeper armed: the hold may
      still exist, and the keeper clears it if the caller dies next.
    * **A late cleanup is harmless.** `lease.release` and `lease.remove_waiter` are no-ops for a
      run that neither holds nor waits, and a release naming another run than the holder is
      ignored. A cleanup that arrives after the lease moved on (taken over, released by boot
      reconciliation, handed to the next waiter) cannot drop the hold of whoever has it now.
    * **A cleanup that cannot be dispatched is retried, then reported.** The lease actor or the
      `CommandRouter` may be busy or restarting, the event store unreachable. The keeper tries
      again every `:retry_interval_ms`, up to `:max_attempts` attempts in all, then reports it
      with `Logger.error` and stops: the hold stays until the server restarts or somebody
      dispatches `lease.release` for that `run_id`.

  The cleanup is keyed by `run_id`, as the lease is: it does to that `run_id` what the caller's own
  release would have done, no more. Two live processes calling `with_lease/4` under one `run_id` at
  the same time share one hold (an acquire by the run that already holds is idempotent), and the
  first of them to finish releases it for both, with or without a keeper.

  Logs name the `run_id` and never the database path: the path is not something a log line may
  carry.
  """

  use GenServer, restart: :temporary

  require Logger

  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.Aggregates.BeadsDbLease.KeeperSupervisor
  alias ForemanServer.{CommandGateway, CommandRouter, Incarnation}

  @defaults [call_timeout_ms: 5_000, retry_interval_ms: 1_000, max_attempts: 10]

  @typedoc """
  `:call_timeout_ms` bounds each command of the cleanup, `:retry_interval_ms` is the wait before
  another attempt and `:max_attempts` the number of attempts in all. The defaults are the ones
  `with_lease/4` runs with; they are options so a test can drive the retry path in milliseconds.
  """
  @type option ::
          {:call_timeout_ms, pos_integer()}
          | {:retry_interval_ms, pos_integer()}
          | {:max_attempts, pos_integer()}

  defmodule State do
    @moduledoc "State of one `BeadsDbLease.Keeper`: the call it keeps and how far its cleanup is."
    @enforce_keys [
      :caller,
      :monitor,
      :db_path,
      :stream_id,
      :run_id,
      :command_key,
      :call_timeout_ms,
      :retry_interval_ms,
      :max_attempts
    ]
    defstruct @enforce_keys ++ [attempts_made: 0, exit_reason: nil]
  end

  # -- client ----------------------------------------------------------------------------------

  @doc """
  Starts the keeper of a `with_lease/4` call made by `caller` for `run_id` on `db_path` and
  returns once it monitors `caller`.

  `{:error, :keeper_supervisor_not_running}` when `KeeperSupervisor` is not running (the server is
  starting up or shutting down); no lease may be taken then, as nothing would clear it.
  """
  @spec watch(pid(), String.t(), String.t(), [option()]) :: {:ok, pid()} | {:error, term()}
  def watch(caller, db_path, run_id, opts \\ [])
      when is_pid(caller) and is_binary(db_path) and db_path != "" and is_binary(run_id) and
             run_id != "" and is_list(opts) do
    args = %{caller: caller, db_path: db_path, run_id: run_id, options: options!(opts)}

    case DynamicSupervisor.start_child(KeeperSupervisor, {__MODULE__, args}) do
      {:ok, keeper} -> {:ok, keeper}
      {:error, _reason} = error -> error
    end
  catch
    :exit, {:noproc, _call} -> {:error, :keeper_supervisor_not_running}
  end

  @doc """
  Stops `keeper`: the call it watches gave the lease back itself. Returns once the keeper has
  ended, so no monitor is left behind. A keeper that is already gone (it crashed) is not an error:
  there is nothing left to stand down.
  """
  @spec unwatch(pid()) :: :ok
  def unwatch(keeper) when is_pid(keeper) do
    case DynamicSupervisor.terminate_child(KeeperSupervisor, keeper) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # -- server ----------------------------------------------------------------------------------

  @impl true
  def init(%{caller: caller, db_path: db_path, run_id: run_id, options: options}) do
    {:ok,
     %State{
       caller: caller,
       monitor: Process.monitor(caller),
       db_path: db_path,
       stream_id: BeadsDbLease.stream_id(db_path),
       run_id: run_id,
       command_key: System.unique_integer([:positive, :monotonic]),
       call_timeout_ms: Keyword.fetch!(options, :call_timeout_ms),
       retry_interval_ms: Keyword.fetch!(options, :retry_interval_ms),
       max_attempts: Keyword.fetch!(options, :max_attempts)
     }}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _caller, reason}, %State{monitor: monitor} = state) do
    {:noreply, %State{state | exit_reason: reason}, {:continue, :give_back}}
  end

  def handle_info(:retry, %State{} = state), do: give_back(state)

  @impl true
  def handle_continue(:give_back, %State{} = state), do: give_back(state)

  defp give_back(%State{} = state) do
    state = %State{state | attempts_made: state.attempts_made + 1}

    case dispatch_cleanup(state) do
      {:ok, cleared} ->
        log_cleared(state, cleared)
        {:stop, :normal, state}

      {:error, reason} ->
        if state.attempts_made < state.max_attempts do
          if state.attempts_made == 1, do: log_retrying(state, reason)
          Process.send_after(self(), :retry, state.retry_interval_ms)
          {:noreply, state}
        else
          log_gave_up(state, reason)
          {:stop, :normal, state}
        end
    end
  end

  # Both commands are idempotent no-ops when the run holds and awaits nothing, and each reports
  # whether it changed anything. The waiter goes first: see the moduledoc.
  defp dispatch_cleanup(%State{} = state) do
    with :ok <- command_router_ready(),
         {:ok, waiter?} <- dispatch(state, "lease.remove_waiter", :removed_at_ms),
         {:ok, holder?} <- dispatch(state, "lease.release", :released_at_ms) do
      {:ok, %{waiter: waiter?, holder: holder?}}
    end
  end

  # An Actor that gets an append request while no router is registered crashes on the send. The
  # router is a permanent child of the application, so it is either starting, restarting or the
  # server is stopping: all of them are a reason to try again later, not to hit the Actor now.
  defp command_router_ready do
    if is_pid(Process.whereis(CommandRouter)),
      do: :ok,
      else: {:error, :command_router_not_running}
  end

  defp dispatch(%State{} = state, type, at_key) do
    command = %{
      type: type,
      # One id per keeper and command, kept across retries: an attempt that timed out but landed
      # is answered with its own event by the actor instead of being decided again. The
      # incarnation keeps it from meeting the same key in an earlier VM's stream: an event with
      # that id is answered, never decided again, so a repeat would silently skip the cleanup.
      command_id:
        "beads-lease-keeper:#{type}:#{state.db_path}:#{state.run_id}:" <>
          "#{Incarnation.id()}:#{state.command_key}",
      aggregate_id: state.stream_id,
      payload: %{
        :db_path => state.db_path,
        :run_id => state.run_id,
        at_key => System.system_time(:millisecond),
        :reason => :caller_down
      }
    }

    case CommandGateway.dispatch_system(command, state.call_timeout_ms) do
      {:ok, nil} -> {:ok, false}
      {:ok, %{}} -> {:ok, true}
      {:error, reason} -> {:error, {type, brief(reason)}}
      {:error, reason, _details} -> {:error, {type, brief(reason)}}
    end
  rescue
    # A raise out of the command path (a lease actor that could not start, say) is as retryable
    # as an exit; what it was is logged, never swallowed.
    exception -> {:error, {type, {:raised, inspect(exception.__struct__)}}}
  catch
    :exit, reason -> {:error, {type, {:exit, brief(exit_cause(reason))}}}
  end

  # The exit of a failed `GenServer.call` carries the whole call, and the command in it names the
  # database path.
  defp exit_cause({reason, {GenServer, :call, _call}}), do: reason
  defp exit_cause(reason), do: reason

  # -- logging ---------------------------------------------------------------------------------

  defp log_cleared(_state, %{waiter: false, holder: false}), do: :ok

  defp log_cleared(%State{} = state, %{waiter: waiter?, holder: holder?}) do
    cleared =
      [{holder?, "released its hold"}, {waiter?, "removed its queue entry"}]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map_join(" and ", &elem(&1, 1))

    Logger.warning(
      "BeadsDbLease: the caller of with_lease/4 for run_id=#{state.run_id} ended " <>
        "(#{brief(state.exit_reason)}) before it gave the lease back; its keeper #{cleared}"
    )
  end

  defp log_retrying(%State{} = state, reason) do
    Logger.warning(
      "BeadsDbLease keeper could not give back the lease of run_id=#{state.run_id} yet " <>
        "(#{inspect(reason)}); trying again every #{state.retry_interval_ms}ms, " <>
        "#{state.max_attempts} attempts in all"
    )
  end

  defp log_gave_up(%State{} = state, reason) do
    Logger.error(
      "BeadsDbLease keeper could not give back the lease of run_id=#{state.run_id} " <>
        "after #{state.attempts_made} attempts (#{inspect(reason)}). The caller ended " <>
        "(#{brief(state.exit_reason)}); its hold or queue entry stays until the server restarts " <>
        "or `lease.release` / `lease.remove_waiter` for that run_id is dispatched by hand"
    )
  end

  # A reason as a log line may carry it: atoms and the kind of a crash. The rest of a crash reason
  # holds arguments and stacktrace, and the database path can be among them.
  defp brief(reason) when is_atom(reason), do: inspect(reason)

  defp brief({%{__exception__: true} = exception, _stacktrace}),
    do: "crashed: #{inspect(exception.__struct__)}"

  defp brief(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: inspect(elem(reason, 0))

  defp brief(_reason), do: "a reason that is not logged"

  defp options!(opts) do
    options = Keyword.validate!(opts, @defaults)

    for {key, value} <- options, not (is_integer(value) and value > 0) do
      raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end

    options
  end
end
