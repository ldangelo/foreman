defmodule ForemanServer.Aggregates.BeadsDbLease do
  @moduledoc """
  Takeover assumptions. A hold is called dead, and given up, in exactly two cases, and no clock
  is involved in either:

    * its VM is gone. A hold tagged with a different VM incarnation is taken over because that
      VM is presumed gone (killed or stopped). One lease stream is served by ONE server at a
      time; a second server started while the first is still inside its `br` call (a rolling
      restart overlap) would take that live hold over, so do not run two servers against one
      event store and one beads database.
    * its process is gone. A `with_lease/4` caller that dies inside this VM without running its
      `after` has its entries cleared by its `Keeper`. That assumes only that the keeper outlives
      the caller (it is supervised outside every caller's subtree) and that the lease is keyed
      by `run_id`, as it is (see "Callers that die within one incarnation").

  A hold whose caller is alive is never given up, however long its `br` call runs.

  Per-DB Beads lease aggregate that serializes whole
  `implement-trd-beads` runs against a single Beads database file.

  The aggregate stream is the source of truth for the lease state;
  the projection store is NEVER consulted for acquire/release
  decisions. Atomicity is preserved by routing every command
  through the per-stream Actor (mailbox serialization). Two
  concurrent acquirers against the same configured absolute
  `db_path` cannot both succeed; the second becomes a durable
  waiter. Callers must pass the same absolute path on every
  dispatch — symlink aliasing (e.g. `/tmp/...` vs
  `/private/tmp/...`) is NOT collapsed and will register separate
  lease streams.

  ## Stream id

      beads_db_lease:<db_path>

  ## Commands

      * `lease.acquire`  — atomic acquire-or-enqueue. Emits
        `BeadsDbLeaseAcquired` if free, is a no-op when the same
        `run_id` already holds the lease (idempotent), and emits
        `BeadsDbLeaseWaiterRegistered` when held by a different
        `run_id`. The caller NEVER has to issue a follow-up command
        to enqueue itself, so there is no lost-wakeup window
        between the busy rejection and the enqueue. A caller that
        names its `incarnation` (see below) takes the lease over from
        a holder that names a different one, emitting
        `BeadsDbLeaseAcquired` with
        `provenance: {:reclaimed_stale_holder, run_id}`, instead of
        queueing behind it.

      * `lease.release`  — emits `BeadsDbLeaseReleased` when no
        waiters are queued, or `BeadsDbLeaseTransferred` when a
        waiter is being promoted. Foreign releases (a different
        `run_id` than the holder) and releases against a free lease
        are idempotent no-ops.

      * `lease.remove_waiter`  — removes a queued waiter by
        `run_id` (e.g. when a queued run transitions to terminal
        before being promoted). Emits `BeadsDbLeaseWaiterRemoved`.
        No-op when no waiter with that `run_id` exists.

  ## Self-managing waiter queue

  Waiters live in the lease aggregate stream so a Dispatcher
  restart does not lose queued runs. The lease itself promotes the
  next waiter on release — no external queue needed. Promotion is
  observable via the `BeadsDbLeaseTransferred` event payload
  carrying the promoted `acquired_run_id`; the Dispatcher
  subscribes to that event and re-triggers the run.

  ## Process-bound holds and server incarnations

  `with_lease/4` holds the lease for the duration of one callback in
  one calling process and tags the hold with the
  `ForemanServer.Incarnation` of the server it runs in (`incarnation`
  in the `lease.acquire` payload, kept on the `Holder` and `Waiter`
  and replayed from the events). The hold is durable but its owner is
  not: a server that dies while a call is in flight (`kill -9`, an
  OOM kill, a shutdown that cuts the `try/after` short) leaves a
  `BeadsDbLeaseAcquired` with no release behind it. Every later
  incarnation knows that hold is dead, because the process that took
  it ended with its VM, so a `with_lease/4` caller takes it over at
  once instead of queueing behind it until `:lease_timeout`, and
  `BootReconciliation.scan_lease_orphans/0` releases it. A hold with
  no `incarnation` (`RunAdmission`'s whole-run hold of an
  `implement-trd-beads` run) belongs to a run, not to a process: it
  survives restarts and is reclaimed only through the run's own
  liveness.

  ### Callers that die within one incarnation

  The incarnation tag only separates VMs. A process that ends inside `with_lease/4` without
  running its `after` (`Process.exit(pid, :kill)`, a supervisor's `:shutdown` of a child that
  does not trap exits, the crash of a linked process) leaves a hold of THIS incarnation, which
  no other caller can call dead: its VM is alive. Before keepers (foreman-8qge) that hold kept
  the lease until the next restart, so every caller of that database queued behind it until
  `:lease_timeout`, and a waiter that died in the queue was promoted to a hold nobody would
  release.

  So every `with_lease/4` call is watched by a `Keeper`
  (`ForemanServer.Aggregates.BeadsDbLease.Keeper`, under `KeeperSupervisor`): a process outside
  the caller's own subtree that monitors it and, when it goes down, dispatches
  `lease.remove_waiter` and then `lease.release` for its `run_id` (reason `:caller_down`). There
  is no TTL: a `br` call may legitimately run long and keeps its lease for as long as its caller
  lives. The keeper is armed before `lease.acquire` is dispatched, so no entry of a call can
  exist unwatched, and stopped once the caller's own release landed, so a normal call leaves
  nothing behind. A cleanup arriving late is harmless: `lease.release` is a no-op for a run that
  is not the holder, so a lease that moved on to another run stays with it. See the `Keeper`
  moduledoc for the guarantees and for what happens when a cleanup cannot be dispatched.

  ## Replay contract

  `apply_event/2` accepts both the live `EventStore.RecordedEvent`
  shape (used by `Aggregate.load/2`) and codec-decoded typed
  structs (`%BeadsDbLeaseAcquired{}`, etc.). Both shapes are
  normalised to a plain map via `event_data_to_map/1`.
  """
  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.BeadsDbLease.Keeper
  alias ForemanServer.CommandGateway
  alias ForemanServer.Incarnation

  require Logger

  alias ForemanServer.Events.{
    BeadsDbLeaseAcquired,
    BeadsDbLeaseReleased,
    BeadsDbLeaseTransferred,
    BeadsDbLeaseWaiterRegistered,
    BeadsDbLeaseWaiterRemoved
  }

  @behaviour ForemanServer.Aggregate

  defmodule ReleaseError do
    @moduledoc """
    Raised by `with_lease/4`'s cleanup step when the underlying
    `lease.release` dispatch genuinely fails (not a domain no-op), so a
    stuck lease can never masquerade as a successful `with_lease/4`
    call. Callers that want to treat this as a retriable condition
    (e.g. `BeadsWatcher.with_beads_lease/2`) rescue this specific
    struct rather than a blanket exception, so an unrelated bug raised
    from inside their own callback still propagates and crashes as
    before.
    """
    @enforce_keys [:stream_id, :run_id, :reason]
    @type t :: %__MODULE__{stream_id: String.t(), run_id: String.t(), reason: term()}
    defexception [:stream_id, :run_id, :reason]

    @impl true
    def message(%__MODULE__{stream_id: stream_id, run_id: run_id, reason: reason}) do
      "BeadsDbLease.release failed for #{stream_id} run_id=#{run_id}: #{inspect(reason)}"
    end
  end

  defmodule Holder do
    @moduledoc """
    Single lease holder. At most one per lease stream. `incarnation` is
    the server incarnation whose process holds the lease for one call,
    or `nil` for a hold that belongs to a run.
    """
    @enforce_keys [:run_id, :task_id, :acquired_at_ms]
    @type t :: %__MODULE__{
            run_id: String.t(),
            task_id: String.t(),
            acquired_at_ms: integer(),
            incarnation: String.t() | nil
          }
    defstruct [:run_id, :task_id, :acquired_at_ms, :incarnation]
  end

  defmodule Waiter do
    @moduledoc """
    Durable waiter entry. FIFO order is preserved by `enqueued_at_ms`.
    `incarnation` is as on `Holder`.
    """
    @enforce_keys [:run_id, :task_id, :enqueued_at_ms]
    @type t :: %__MODULE__{
            run_id: String.t(),
            task_id: String.t(),
            enqueued_at_ms: integer(),
            incarnation: String.t() | nil
          }
    defstruct [:run_id, :task_id, :enqueued_at_ms, :incarnation]
  end

  defmodule State do
    @moduledoc "Per-DB Beads lease state."
    @enforce_keys [:exists?, :db_path]
    defstruct [
      :exists?,
      :db_path,
      holder: nil,
      waiters: []
    ]
  end

  @impl true
  def initial_state do
    %State{exists?: false, db_path: nil, holder: nil, waiters: []}
  end

  @impl true
  def handle_command(state, %{type: "lease.acquire"} = command) do
    payload = Map.get(command, :payload) || %{}

    with {:ok, db_path} <- Aggregate.required_binary(Aggregate.get(payload, :db_path), :db_path),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :incarnation), :incarnation),
         {:ok, acquired_at_ms} <-
           positive_integer(Aggregate.get(payload, :acquired_at_ms), :acquired_at_ms) do
      acquire_event(
        state,
        db_path,
        run_id,
        Aggregate.get(payload, :task_id),
        acquired_at_ms,
        Aggregate.get(payload, :incarnation)
      )
    else
      {:error, _} = err -> err
    end
  end

  def handle_command(state, %{type: "lease.release"} = command) do
    payload = Map.get(command, :payload) || %{}

    with {:ok, db_path} <- Aggregate.required_binary(Aggregate.get(payload, :db_path), :db_path),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, released_at_ms} <-
           positive_integer(Aggregate.get(payload, :released_at_ms), :released_at_ms) do
      release_event(
        state,
        db_path,
        run_id,
        released_at_ms,
        Aggregate.get(payload, :reason) || :released
      )
    else
      {:error, _} = err -> err
    end
  end

  def handle_command(state, %{type: "lease.remove_waiter"} = command) do
    payload = Map.get(command, :payload) || %{}

    with {:ok, db_path} <- Aggregate.required_binary(Aggregate.get(payload, :db_path), :db_path),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, removed_at_ms} <-
           positive_integer(Aggregate.get(payload, :removed_at_ms), :removed_at_ms) do
      reason = Aggregate.get(payload, :reason) || :run_cancelled
      remove_waiter_event(state, db_path, run_id, removed_at_ms, reason)
    else
      {:error, _} = err -> err
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------------
  # apply_event — typed structs first, then live-event-shape fallback.
  # ---------------------------------------------------------------------------

  @impl true
  def apply_event(%State{} = state, %BeadsDbLeaseAcquired{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        holder: %Holder{
          run_id: Aggregate.get(payload, :run_id),
          task_id: Aggregate.get(payload, :task_id),
          acquired_at_ms: Aggregate.get(payload, :acquired_at_ms),
          incarnation: Aggregate.get(payload, :incarnation)
        }
    }
  end

  def apply_event(%State{} = state, %BeadsDbLeaseReleased{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        holder: nil
    }
  end

  def apply_event(%State{} = state, %BeadsDbLeaseWaiterRegistered{} = event) do
    payload = event_data_to_map(event)

    new_waiter = %Waiter{
      run_id: Aggregate.get(payload, :run_id),
      task_id: Aggregate.get(payload, :task_id),
      enqueued_at_ms: Aggregate.get(payload, :enqueued_at_ms),
      incarnation: Aggregate.get(payload, :incarnation)
    }

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        waiters: append_waiter(state.waiters, new_waiter)
    }
  end

  def apply_event(%State{} = state, %BeadsDbLeaseWaiterRemoved{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id))
    }
  end

  def apply_event(%State{} = state, %BeadsDbLeaseTransferred{} = event) do
    payload = event_data_to_map(event)

    new_holder = %Holder{
      run_id: Aggregate.get(payload, :acquired_run_id),
      task_id: Aggregate.get(payload, :acquired_task_id),
      acquired_at_ms: Aggregate.get(payload, :acquired_at_ms),
      incarnation: Aggregate.get(payload, :acquired_incarnation)
    }

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        holder: new_holder,
        waiters: drop_head_waiter(state.waiters)
    }
  end

  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "BeadsDbLeaseAcquired" ->
        %State{
          state
          | exists?: true,
            db_path: Aggregate.get(payload, :db_path) || state.db_path,
            holder: %Holder{
              run_id: Aggregate.get(payload, :run_id),
              task_id: Aggregate.get(payload, :task_id),
              acquired_at_ms: Aggregate.get(payload, :acquired_at_ms),
              incarnation: Aggregate.get(payload, :incarnation)
            }
        }

      "BeadsDbLeaseReleased" ->
        %State{
          state
          | exists?: true,
            db_path: Aggregate.get(payload, :db_path) || state.db_path,
            holder: nil
        }

      "BeadsDbLeaseWaiterRegistered" ->
        new_waiter = %Waiter{
          run_id: Aggregate.get(payload, :run_id),
          task_id: Aggregate.get(payload, :task_id),
          enqueued_at_ms: Aggregate.get(payload, :enqueued_at_ms),
          incarnation: Aggregate.get(payload, :incarnation)
        }

        %State{
          state
          | exists?: true,
            db_path: Aggregate.get(payload, :db_path) || state.db_path,
            waiters: append_waiter(state.waiters, new_waiter)
        }

      "BeadsDbLeaseWaiterRemoved" ->
        %State{
          state
          | exists?: true,
            db_path: Aggregate.get(payload, :db_path) || state.db_path,
            waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id))
        }

      "BeadsDbLeaseTransferred" ->
        new_holder = %Holder{
          run_id: Aggregate.get(payload, :acquired_run_id),
          task_id: Aggregate.get(payload, :acquired_task_id),
          acquired_at_ms: Aggregate.get(payload, :acquired_at_ms),
          incarnation: Aggregate.get(payload, :acquired_incarnation)
        }

        %State{
          state
          | exists?: true,
            db_path: Aggregate.get(payload, :db_path) || state.db_path,
            holder: new_holder,
            waiters: drop_head_waiter(state.waiters)
        }

      _ ->
        state
    end
  end

  # How long `with_lease/4` waits to become holder: `{polls, interval_ms}`, 50 polls 100ms apart.
  @default_poll {50, 100}

  @doc """
  Block until this run holds the Beads DB lease, then execute the callback.

  Starts this call's `Keeper` (see the moduledoc), dispatches `lease.acquire`,
  polls aggregate state via Registry until `holder?(state, run_id)` is true,
  runs `callback.()` inside a `try/after`, then releases and stands the keeper
  down. The release is guaranteed to be attempted on a raised exception or
  thrown value from the callback, so a crashing `br` call cannot leave the
  lease permanently held and starve every future claim against the DB. A
  calling process that is killed outright never runs that `after`; its keeper
  notices and gives the lease back, so a dead caller cannot hold the lease or
  keep a place in the queue either.

  Returns `{:ok, result}` on success, `{:error, reason}` on an acquire
  failure or timeout. Raises `ReleaseError` if the release dispatch
  itself genuinely fails (actor timeout/crash, node down) -- this is
  never swallowed to a lying `{:ok, _}`/`{:error, _}` return, since that
  would hide that the lease is still held. A raised `ReleaseError`
  replaces (does not chain with) an exception the callback itself
  raised, per `try/after` semantics. Callers that must not crash on
  this (e.g. `BeadsWatcher.with_beads_lease/2`) should `rescue
  ReleaseError` specifically, not exceptions in general, so a genuine
  bug in their own callback still propagates.

  Use this around every `br` call in BeadsAdapter to serialize
  concurrent writes against the same DB file.

  The hold is tagged with this server's `ForemanServer.Incarnation`, so a
  hold left behind by a server that died mid-call (see the moduledoc) is
  taken over at once instead of being waited for until `:lease_timeout`.

  Returns `{:error, {:lease_keeper_unavailable, reason}}` without touching the
  lease when the keeper cannot be started (the server is starting or
  stopping): a hold nothing would clear is never taken.

  A call that gives up (acquire error, `:lease_timeout`) removes its queue
  entry and then releases the lease: the run may have been promoted to holder
  between its last poll and the removal, and `lease.release` is a no-op unless
  the run is the holder.
  """
  @spec with_lease(String.t(), String.t(), String.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()} | no_return()
  def with_lease(db_path, run_id, task_id, callback)
      when is_binary(db_path) and db_path != "" and is_binary(run_id) and
             run_id != "" and is_binary(task_id) and is_function(callback, 0),
      do: with_lease(db_path, run_id, task_id, callback, @default_poll)

  # The poll budget spelled out: `{polls, interval_ms}`. `with_lease/4` runs with `@default_poll`;
  # a test that must hold a caller between its last poll and the end of its budget (promotion at
  # the timeout) shortens the budget and lengthens the wait.
  @doc false
  @spec with_lease(
          String.t(),
          String.t(),
          String.t(),
          (-> {:ok, term()} | {:error, term()}),
          {pos_integer(), pos_integer()}
        ) :: {:ok, term()} | {:error, term()} | no_return()
  def with_lease(db_path, run_id, task_id, callback, {polls, interval_ms} = poll)
      when is_binary(db_path) and db_path != "" and is_binary(run_id) and
             run_id != "" and is_binary(task_id) and is_function(callback, 0) and
             is_integer(polls) and polls > 0 and is_integer(interval_ms) and interval_ms > 0 do
    # The keeper is armed before anything is written to the lease stream, so no entry of this
    # call (a queued `lease.acquire` included) can exist without a keeper to clear it should
    # this process die.
    case Keeper.watch(self(), db_path, run_id) do
      {:ok, keeper} -> hold_lease(keeper, db_path, run_id, task_id, callback, poll)
      {:error, reason} -> {:error, {:lease_keeper_unavailable, reason}}
    end
  end

  defp hold_lease(keeper, db_path, run_id, task_id, callback, {polls, interval_ms}) do
    stream_id = stream_id(db_path)
    ms = System.system_time(:millisecond)

    with :ok <- lease_acquire(stream_id, db_path, run_id, task_id, ms),
         :ok <- poll_until_holder(stream_id, run_id, polls, interval_ms) do
      try do
        callback.()
      after
        release_ms = System.system_time(:millisecond)
        # Raises on a genuine dispatch failure (see lease_release/4) rather
        # than discarding it -- swallowing it here would report the
        # `with_lease/4` call as successful while the lease stayed held,
        # recreating the exact stuck-lease failure mode this function
        # exists to prevent, just via the release path instead of the
        # callback path.
        lease_release(stream_id, db_path, run_id, release_ms)
        # Only once the release has landed: a failed one raised above, and the keeper that is
        # still armed then clears the hold if this process dies next.
        Keeper.unwatch(keeper)
      end
    else
      {:error, reason} = err ->
        if reason == :lease_timeout, do: log_lease_timeout(stream_id, run_id)
        # Remove timed-out waiter so they don't block future writers.
        _ = lease_remove_waiter(stream_id, db_path, run_id)
        # The run can have been promoted to holder between its last poll and the removal above
        # (which then found no waiter). `lease.release` is a no-op unless this run is the
        # holder, so this gives back exactly that hold, which nothing else would: the keeper
        # stops just below, and the caller never learns it holds. Like the release after the
        # callback it raises on a failed dispatch, and the keeper then stays armed.
        lease_release(stream_id, db_path, run_id, System.system_time(:millisecond))
        Keeper.unwatch(keeper)
        err
    end
  end

  defp lease_acquire(stream_id, db_path, run_id, task_id, ms) do
    case CommandGateway.dispatch_system(%{
           type: "lease.acquire",
           command_id: "beads-adapter:lease-acquire:#{db_path}:#{run_id}:#{ms}",
           aggregate_id: stream_id,
           payload: %{
             db_path: db_path,
             run_id: run_id,
             task_id: task_id,
             acquired_at_ms: ms,
             incarnation: Incarnation.id()
           }
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp lease_release(stream_id, db_path, run_id, release_ms) do
    case CommandGateway.dispatch_system(%{
           type: "lease.release",
           command_id: "beads-adapter:lease-release:#{db_path}:#{run_id}:#{release_ms}",
           aggregate_id: stream_id,
           payload: %{
             db_path: db_path,
             run_id: run_id,
             released_at_ms: release_ms,
             reason: "br_call_complete"
           }
         }) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        # lease.release is idempotent for a free or foreign-held lease (see
        # module doc), so a rejection here is a genuine dispatch failure
        # (actor timeout/crash, node down), not a domain no-op. Raising
        # surfaces it loudly instead of letting `with_lease/4`'s `after`
        # block report success while the lease is still held.
        raise ReleaseError, stream_id: stream_id, run_id: run_id, reason: reason
    end
  end

  defp lease_remove_waiter(stream_id, db_path, run_id) do
    ms = System.system_time(:millisecond)

    case CommandGateway.dispatch_system(%{
           aggregate_id: stream_id,
           type: "lease.remove_waiter",
           command_id: "beads-adapter:lease-remove-waiter:#{db_path}:#{run_id}:#{ms}",
           payload: %{
             db_path: db_path,
             run_id: run_id,
             removed_at_ms: ms,
             reason: :run_cancelled
           }
         }) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  # Names the holder a timed-out acquire queued behind. Without it a
  # `:lease_timeout` cannot be told from plain contention, which is what
  # made a hold stranded by a killed server (foreman-w29up) so hard to see.
  # The stream id is left out: it embeds the absolute DB path.
  defp log_lease_timeout(stream_id, run_id) do
    case Registry.lookup(ForemanServer.AggregateRegistry, stream_id) do
      [{pid, _}] ->
        case ForemanServer.Aggregate.Actor.get_state(pid) do
          %State{holder: %Holder{} = holder} ->
            Logger.warning(
              "BeadsDbLease acquire by run_id=#{run_id} timed out behind holder " <>
                "run_id=#{holder.run_id} task_id=#{holder.task_id} " <>
                "acquired_at_ms=#{holder.acquired_at_ms} incarnation=#{inspect(holder.incarnation)} " <>
                "(this server: #{Incarnation.id()})"
            )

          %State{holder: nil} ->
            :ok
        end

      [] ->
        :ok
    end
  end

  defp poll_until_holder(_stream_id, _run_id, 0, _interval_ms) do
    {:error, :lease_timeout}
  end

  defp poll_until_holder(stream_id, run_id, remaining, interval_ms) do
    case Registry.lookup(ForemanServer.AggregateRegistry, stream_id) do
      [{pid, _}] ->
        state = ForemanServer.Aggregate.Actor.get_state(pid)

        if holder?(state, run_id) do
          :ok
        else
          :timer.sleep(interval_ms)
          poll_until_holder(stream_id, run_id, remaining - 1, interval_ms)
        end

      [] ->
        :timer.sleep(interval_ms)
        poll_until_holder(stream_id, run_id, remaining - 1, interval_ms)
    end
  end

  defp holder?(%State{holder: %Holder{run_id: r}}, run_id), do: r == run_id
  defp holder?(_state, _run_id), do: false

  @doc """
  Build the lease stream id for a Beads database path.

  The key is the configured absolute DB path verbatim. Two callers
  pointing at the same DB through different symlink aliases (e.g.
  `/tmp/...` vs `/private/tmp/...`) currently register separate lease
  streams and will not serialize against each other; pass the same
  absolute path on every dispatch until canonicalization is added.
  """
  @spec stream_id(String.t()) :: String.t()
  def stream_id(db_path) when is_binary(db_path) and db_path != "",
    do: "beads_db_lease:#{db_path}"

  @doc "Return the current holder, or `nil` if the lease is free."
  @spec holder(State.t()) :: Holder.t() | nil
  def holder(%State{holder: nil}), do: nil
  def holder(%State{holder: %Holder{} = holder}), do: holder

  @doc "Return the FIFO waiter list."
  @spec waiters(State.t()) :: [Waiter.t()]
  def waiters(%State{waiters: waiters}), do: waiters

  # ---------------------------------------------------------------------------
  # Acquire decision — atomic acquire-or-enqueue
  # ---------------------------------------------------------------------------

  defp acquire_event(%State{holder: nil}, db_path, run_id, task_id, acquired_at_ms, incarnation) do
    acquired_event(db_path, run_id, task_id, acquired_at_ms, incarnation, {:direct, run_id})
  end

  defp acquire_event(
         %State{holder: %Holder{} = holder} = state,
         db_path,
         run_id,
         task_id,
         acquired_at_ms,
         incarnation
       ) do
    cond do
      # Idempotent: same run_id already holds the lease, under the same incarnation.
      holder.run_id == run_id and holder.incarnation == incarnation ->
        {:ok, nil}

      # The run's own hold was written under another incarnation (or as a
      # run-scoped hold). Claim it under this one, or the next acquirer would
      # reclaim it from under the call that is about to run.
      holder.run_id == run_id ->
        acquired_event(db_path, run_id, task_id, acquired_at_ms, incarnation, {:direct, run_id})

      # The holder's server incarnation has ended: nothing of it can still run,
      # so the hold is dead. Take it over instead of queueing behind it.
      stale_incarnation?(holder.incarnation, incarnation) ->
        acquired_event(
          db_path,
          run_id,
          task_id,
          acquired_at_ms,
          incarnation,
          {:reclaimed_stale_holder, holder.run_id}
        )

      # Held by a different run — atomically enqueue as a waiter.
      true ->
        enqueue_event(state, db_path, run_id, task_id, acquired_at_ms, incarnation)
    end
  end

  defp acquired_event(db_path, run_id, task_id, acquired_at_ms, incarnation, provenance) do
    {:ok,
     %{
       stream_id: stream_id(db_path),
       event_type: "BeadsDbLeaseAcquired",
       payload:
         Aggregate.put_if(
           %{
             db_path: db_path,
             run_id: run_id,
             task_id: task_id,
             acquired_at_ms: acquired_at_ms,
             provenance: provenance
           },
           :incarnation,
           incarnation
         )
     }}
  end

  defp enqueue_event(
         %State{waiters: waiters},
         db_path,
         run_id,
         task_id,
         enqueued_at_ms,
         incarnation
       ) do
    if already_waiting?(waiters, run_id, incarnation) do
      {:ok, nil}
    else
      {:ok,
       %{
         stream_id: stream_id(db_path),
         event_type: "BeadsDbLeaseWaiterRegistered",
         payload:
           Aggregate.put_if(
             %{
               db_path: db_path,
               run_id: run_id,
               task_id: task_id,
               enqueued_at_ms: enqueued_at_ms
             },
             :incarnation,
             incarnation
           )
       }}
    end
  end

  # A hold is dead only when both sides name an incarnation and they differ. A
  # hold without one belongs to a run (`RunAdmission`) and outlives restarts; a
  # caller without one (also `RunAdmission`) cannot say what is dead.
  defp stale_incarnation?(held, current) when is_binary(held) and is_binary(current),
    do: held != current

  defp stale_incarnation?(_held, _current), do: false

  # ---------------------------------------------------------------------------
  # Release decision (single-event transfer when waiters are present)
  # ---------------------------------------------------------------------------

  defp release_event(%State{holder: nil}, _db_path, _run_id, _released_at_ms, _reason),
    do: {:ok, nil}

  defp release_event(
         %State{holder: %Holder{run_id: holder_run_id}},
         _db_path,
         run_id,
         _released_at_ms,
         _reason
       )
       when holder_run_id != run_id do
    # Foreign release: idempotent no-op.
    {:ok, nil}
  end

  defp release_event(
         %State{holder: %Holder{run_id: run_id}, waiters: []},
         db_path,
         run_id,
         released_at_ms,
         reason
       ) do
    {:ok,
     %{
       stream_id: stream_id(db_path),
       event_type: "BeadsDbLeaseReleased",
       payload: %{
         db_path: db_path,
         run_id: run_id,
         released_at_ms: released_at_ms,
         reason: reason
       }
     }}
  end

  defp release_event(
         %State{holder: %Holder{run_id: run_id}, waiters: [%Waiter{} = next | _rest]},
         db_path,
         run_id,
         released_at_ms,
         reason
       ) do
    {:ok,
     %{
       stream_id: stream_id(db_path),
       event_type: "BeadsDbLeaseTransferred",
       payload:
         Aggregate.put_if(
           %{
             db_path: db_path,
             released_run_id: run_id,
             released_at_ms: released_at_ms,
             reason: reason,
             acquired_run_id: next.run_id,
             acquired_task_id: next.task_id,
             acquired_at_ms: next.enqueued_at_ms,
             enqueued_at_ms: next.enqueued_at_ms
           },
           :acquired_incarnation,
           next.incarnation
         )
     }}
  end

  # ---------------------------------------------------------------------------
  # Waiter removal (cancel-before-promotion path)
  # ---------------------------------------------------------------------------

  defp remove_waiter_event(state, db_path, run_id, removed_at_ms, reason) do
    if has_waiter?(state.waiters, run_id) do
      {:ok,
       %{
         stream_id: stream_id(db_path),
         event_type: "BeadsDbLeaseWaiterRemoved",
         payload: %{
           db_path: db_path,
           run_id: run_id,
           removed_at_ms: removed_at_ms,
           reason: reason
         }
       }}
    else
      {:ok, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Normalise a typed event struct into a plain map for `Aggregate.get/3`.
  # `provenance` is a tagged tuple and must be preserved verbatim.
  defp event_data_to_map(%BeadsDbLeaseAcquired{} = e),
    do: %{
      db_path: e.db_path,
      run_id: e.run_id,
      task_id: e.task_id,
      acquired_at_ms: e.acquired_at_ms,
      incarnation: e.incarnation,
      provenance: e.provenance
    }

  defp event_data_to_map(%BeadsDbLeaseReleased{} = e),
    do: %{
      db_path: e.db_path,
      run_id: e.run_id,
      released_at_ms: e.released_at_ms,
      reason: e.reason
    }

  defp event_data_to_map(%BeadsDbLeaseWaiterRegistered{} = e),
    do: %{
      db_path: e.db_path,
      run_id: e.run_id,
      task_id: e.task_id,
      enqueued_at_ms: e.enqueued_at_ms,
      incarnation: e.incarnation
    }

  defp event_data_to_map(%BeadsDbLeaseWaiterRemoved{} = e),
    do: %{
      db_path: e.db_path,
      run_id: e.run_id,
      removed_at_ms: e.removed_at_ms,
      reason: e.reason
    }

  defp event_data_to_map(%BeadsDbLeaseTransferred{} = e),
    do: %{
      db_path: e.db_path,
      released_run_id: e.released_run_id,
      released_at_ms: e.released_at_ms,
      reason: e.reason,
      acquired_run_id: e.acquired_run_id,
      acquired_task_id: e.acquired_task_id,
      acquired_at_ms: e.acquired_at_ms,
      enqueued_at_ms: e.enqueued_at_ms,
      acquired_incarnation: e.acquired_incarnation
    }

  defp positive_integer(value, _key) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, key),
    do: {:error, {:missing_or_invalid, key, value}}

  defp has_waiter?(waiters, run_id) do
    Enum.any?(waiters, fn %Waiter{run_id: r} -> r == run_id end)
  end

  # A waiter queued under the same incarnation (not merely the same run_id): a
  # run queued before a restart that queues again after it must be re-tagged.
  defp already_waiting?(waiters, run_id, incarnation) do
    Enum.any?(waiters, fn %Waiter{run_id: r, incarnation: i} ->
      r == run_id and i == incarnation
    end)
  end

  # A waiter is keyed by run_id. Registering it again under another
  # incarnation re-tags the queued entry in place, keeping its FIFO slot.
  defp append_waiter(waiters, %Waiter{} = waiter) do
    if has_waiter?(waiters, waiter.run_id) do
      Enum.map(waiters, fn
        %Waiter{run_id: run_id} = queued when run_id == waiter.run_id ->
          %Waiter{queued | incarnation: waiter.incarnation}

        queued ->
          queued
      end)
    else
      waiters ++ [waiter]
    end
  end

  defp drop_head_waiter([]), do: []

  defp drop_head_waiter([_head | tail]), do: tail

  defp drop_waiter(waiters, run_id) do
    Enum.reject(waiters, fn %Waiter{run_id: r} -> r == run_id end)
  end
end
