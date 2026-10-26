defmodule ForemanServer.Aggregates.BeadsDbLease.Keeper do
  @moduledoc """
  Watches one `BeadsDbLease.with_lease/4` call and gives its lease back when the process that made
  the call dies without running the `after` of `with_lease/4`.

  A caller killed outright (`Process.exit(pid, :kill)`, a supervisor's `:shutdown` of a child that
  does not trap exits, a linked crash) never runs that `after`. Its hold names a VM that is alive,
  so nothing could call it dead: every later caller of that Beads database queued behind it until
  the next restart, and a waiter that died in the queue was promoted to a hold nobody released
  (foreman-8qge). The keeper is the process that outlives the caller. It monitors the caller and,
  when it goes down, dispatches `lease.remove_waiter` and then `lease.release` for the call's
  `run_id` (reason `:caller_down`). The waiter goes first: a release first would promote a dead
  waiter, and the removal that follows would find nobody to remove.

  ## Guarantees

    * There is no TTL. A hold whose caller lives is never given up, however long its `br` call
      runs.
    * The keeper is started and registered before `lease.acquire` is dispatched (`watch/4`), so no
      entry of a call exists unwatched.
    * A cleanup that arrives late is a no-op: `lease.release` ignores a run that is not the
      holder and `lease.remove_waiter` one that is not queued, so a lease that moved on to another
      run keeps its holder.
    * A cleanup that cannot be dispatched (the lease actor or the command router is down) is
      retried every `:retry_interval_ms`, `:max_attempts` times in all, then logged with
      `Logger.error`: the hold stays until a restart or a hand-dispatched `lease.release`.
    * The keeper ends with the call. `unwatch/1` stops it once the caller has given the lease back
      itself and returns when it is gone, so a normal call leaves no monitor behind.
    * A keeper that is killed or crashes while its caller lives is restarted (`restart:
      :transient`; a normal stop is terminal) and the replacement monitors the caller afresh. A
      monitor on a dead pid answers at once, so a caller that died meanwhile is still answered. A
      keeper that keeps dying is restarted five times, then logged with `Logger.error` and its
      call runs unwatched. A restart that races the end of the call finds it finished and stands
      down.

  ## One `run_id`, several calls

  The lease is keyed by `run_id`, and a restarted caller reuses its run's stable `run_id`. So a
  new call can find the hold, or the queue entry, of the call that died: `lease.acquire` for the
  holder's own `run_id` is idempotent, the new call takes the hold over without an event, and a
  cleanup that was still on its way for the dead call would release the new call's hold while its
  callback runs. Two rules keep that from happening, both read from the keepers' registrations
  (`{:call, db_path, run_id, id}` in `KeeperRegistry`, valued with the caller):

    * A keeper whose caller died first looks for another LIVE call under the same `run_id`. If
      there is one, the lease belongs to that call now and the keeper only stops: the new call
      releases it itself, or its own keeper does when it dies.
    * `watch/4` of a new call, once its keeper is registered, waits for the keepers of DEAD
      callers under the same `run_id` that are still running: they are either about to find this
      call (and leave the lease alone) or already giving the lease back, and that release must
      land before this call acquires.

  The first rule's registration read and the second's keeper-state read are ordered, so one of
  them always sees the other: the dead caller's keeper registered long before it died, and the new
  call registers its keeper before it acquires. What stays outside them: two LIVE processes using
  one `run_id` at once still share one hold, which the first to finish releases for both, and a
  keeper of a live call that is itself killed at the instant the keeper of a dead call under the
  same `run_id` looks (the restart takes a moment to register again) is not seen.
  """

  use GenServer, restart: :transient

  require Logger

  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.Aggregates.BeadsDbLease.{KeeperRegistry, KeeperSupervisor}
  alias ForemanServer.{CommandGateway, CommandRouter, Incarnation}

  @defaults [call_timeout_ms: 5_000, retry_interval_ms: 1_000, max_attempts: 10]

  # A keeper that crashes again and again is restarted this many times, then left unrestarted.
  @max_restarts 5

  # Slots of the `:atomics` array a call shares with every keeper it has had, across restarts.
  @starts 1
  @finished 2

  @typedoc """
  `:call_timeout_ms` bounds each command of the cleanup, `:retry_interval_ms` is the wait before
  another attempt and `:max_attempts` the number of attempts in all. The defaults are the ones
  `with_lease/4` runs with; they are options so a test can drive the retry path in milliseconds.
  """
  @type option ::
          {:call_timeout_ms, pos_integer()}
          | {:retry_interval_ms, pos_integer()}
          | {:max_attempts, pos_integer()}

  @typedoc "What `watch/4` returns and `unwatch/1` takes: names the call, not one keeper process."
  @opaque watch :: {reference(), :atomics.atomics_ref()}

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
  returns once it monitors `caller` and no keeper of a dead caller under the same `run_id` is
  still running (see the moduledoc: that wait ends with the keeper's own cleanup, bounded by its
  retry budget).

  `{:error, reason}` when no keeper can be started (`KeeperSupervisor` or `KeeperRegistry` is not
  running: the server is starting up or shutting down); no lease may be taken then, as nothing
  would clear it.
  """
  @spec watch(pid(), String.t(), String.t(), [option()]) :: {:ok, watch()} | {:error, term()}
  def watch(caller, db_path, run_id, opts \\ [])
      when is_pid(caller) and is_binary(db_path) and db_path != "" and is_binary(run_id) and
             run_id != "" and is_list(opts) do
    id = make_ref()
    shared = :atomics.new(2, signed: false)

    args = %{
      id: id,
      shared: shared,
      caller: caller,
      db_path: db_path,
      run_id: run_id,
      options: options!(opts)
    }

    case DynamicSupervisor.start_child(KeeperSupervisor, {__MODULE__, args}) do
      {:ok, _keeper} ->
        await_keepers_of_dead_callers(db_path, run_id)
        {:ok, {id, shared}}

      {:error, _reason} = error ->
        error

      :ignore ->
        {:error, :keeper_not_started}
    end
  catch
    :exit, {:noproc, _call} -> {:error, :keeper_supervisor_not_running}
  end

  @doc """
  Stops the keeper of the call `watch` names: the call gave the lease back itself. Returns once
  the keeper has ended, so no monitor is left behind. A keeper that is already gone is not an
  error: there is nothing left to stand down.
  """
  @spec unwatch(watch()) :: :ok
  def unwatch({id, shared}) do
    # Before anything else, so a keeper that restarts from here on finds the call finished.
    :atomics.put(shared, @finished, 1)

    case Registry.lookup(KeeperRegistry, id) do
      [{keeper, _value}] ->
        case DynamicSupervisor.terminate_child(KeeperSupervisor, keeper) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end

      [] ->
        :ok
    end
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{id: id} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {KeeperRegistry, id}})

  # The calling call's keeper is registered (`watch/4` starts it first), so a keeper of a dead
  # caller that looks for live calls from now on finds this one. One that does not is already
  # past that look and giving the lease back: wait for it, or its release could land on the hold
  # this call is about to take.
  defp await_keepers_of_dead_callers(db_path, run_id) do
    for {keeper, caller} <- calls(db_path, run_id), not Process.alive?(caller) do
      ref = Process.monitor(keeper)

      receive do
        {:DOWN, ^ref, :process, ^keeper, _reason} -> :ok
      end
    end

    :ok
  end

  # Every keeper registered for the calls on `db_path` under `run_id`, with the caller it keeps.
  defp calls(db_path, run_id) do
    Registry.select(KeeperRegistry, [
      {{{:call, db_path, run_id, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  # -- server ----------------------------------------------------------------------------------

  @impl true
  def init(%{id: id, shared: shared, caller: caller, db_path: db_path, run_id: run_id} = args) do
    starts = :atomics.add_get(shared, @starts, 1)

    cond do
      # The call ended while this keeper was being restarted: nothing is left to keep.
      :atomics.get(shared, @finished) == 1 ->
        :ignore

      starts > @max_restarts + 1 ->
        Logger.error(
          "BeadsDbLease keeper for run_id=#{run_id} ended abnormally #{starts - 1} times and is " <>
            "not restarted again: its caller's hold or queue entry is no longer watched"
        )

        :ignore

      true ->
        # Registered before `watch/4` returns, which is before this call touches the lease.
        {:ok, _owner} = Registry.register(KeeperRegistry, {:call, db_path, run_id, id}, caller)
        {:ok, new_state(args)}
    end
  end

  defp new_state(%{caller: caller, db_path: db_path, run_id: run_id, options: options}) do
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
    }
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _caller, reason}, %State{monitor: monitor} = state) do
    {:noreply, %State{state | exit_reason: reason}, {:continue, :give_back}}
  end

  def handle_info(:retry, %State{} = state), do: give_back(state)

  @impl true
  def handle_continue(:give_back, %State{} = state) do
    if another_live_call?(state) do
      log_left_to_live_call(state)
      {:stop, :normal, state}
    else
      give_back(state)
    end
  end

  # A later call under the same `run_id` that is alive owns the hold or the queue entry now (the
  # lease cannot tell two calls of one run apart), so releasing it would take it from that call.
  # Its own release, or its own keeper when it dies, gives the lease back.
  defp another_live_call?(%State{db_path: db_path, run_id: run_id, caller: caller}) do
    db_path
    |> calls(run_id)
    |> Enum.any?(fn {_keeper, other} -> other != caller and Process.alive?(other) end)
  end

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

  defp log_left_to_live_call(%State{} = state) do
    Logger.info(
      "BeadsDbLease: the caller of with_lease/4 for run_id=#{state.run_id} ended " <>
        "(#{brief(state.exit_reason)}), but another live call uses that run_id; its keeper " <>
        "leaves the lease to that call"
    )
  end

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
