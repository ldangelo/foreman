defmodule ForemanServer.Aggregates.BeadsDbLease do
  @moduledoc """
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
        between the busy rejection and the enqueue.

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

  ## Replay contract

  `apply_event/2` accepts both the live `EventStore.RecordedEvent`
  shape (used by `Aggregate.load/2`) and codec-decoded typed
  structs (`%BeadsDbLeaseAcquired{}`, etc.). Both shapes are
  normalised to a plain map via `event_data_to_map/1`.
  """

  alias ForemanServer.Aggregate

  alias ForemanServer.Events.{
    BeadsDbLeaseAcquired,
    BeadsDbLeaseReleased,
    BeadsDbLeaseTransferred,
    BeadsDbLeaseWaiterRegistered,
    BeadsDbLeaseWaiterRemoved
  }

  @behaviour ForemanServer.Aggregate

  defmodule Holder do
    @moduledoc "Single lease holder. At most one per lease stream."
    @enforce_keys [:run_id, :task_id, :acquired_at_ms]
    @type t :: %__MODULE__{
            run_id: String.t(),
            task_id: String.t(),
            acquired_at_ms: integer()
          }
    defstruct [:run_id, :task_id, :acquired_at_ms]
  end

  defmodule Waiter do
    @moduledoc "Durable waiter entry. FIFO order is preserved by `enqueued_at_ms`."
    @enforce_keys [:run_id, :task_id, :enqueued_at_ms]
    @type t :: %__MODULE__{
            run_id: String.t(),
            task_id: String.t(),
            enqueued_at_ms: integer()
          }
    defstruct [:run_id, :task_id, :enqueued_at_ms]
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
         {:ok, acquired_at_ms} <-
           positive_integer(Aggregate.get(payload, :acquired_at_ms), :acquired_at_ms) do
      acquire_event(state, db_path, run_id, Aggregate.get(payload, :task_id), acquired_at_ms)
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
  def apply_event(state, %BeadsDbLeaseAcquired{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        holder: %Holder{
          run_id: Aggregate.get(payload, :run_id),
          task_id: Aggregate.get(payload, :task_id),
          acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
        }
    }
  end

  def apply_event(state, %BeadsDbLeaseReleased{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        holder: nil
    }
  end

  def apply_event(state, %BeadsDbLeaseWaiterRegistered{} = event) do
    payload = event_data_to_map(event)

    new_waiter = %Waiter{
      run_id: Aggregate.get(payload, :run_id),
      task_id: Aggregate.get(payload, :task_id),
      enqueued_at_ms: Aggregate.get(payload, :enqueued_at_ms)
    }

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        waiters: append_waiter(state.waiters, new_waiter)
    }
  end

  def apply_event(state, %BeadsDbLeaseWaiterRemoved{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id))
    }
  end

  def apply_event(state, %BeadsDbLeaseTransferred{} = event) do
    payload = event_data_to_map(event)

    new_holder = %Holder{
      run_id: Aggregate.get(payload, :acquired_run_id),
      task_id: Aggregate.get(payload, :acquired_task_id),
      acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
    }

    %State{
      state
      | exists?: true,
        db_path: Aggregate.get(payload, :db_path) || state.db_path,
        holder: new_holder,
        waiters: drop_head_waiter(state.waiters)
    }
  end

  def apply_event(state, event) do
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
              acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
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
          enqueued_at_ms: Aggregate.get(payload, :enqueued_at_ms)
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
          acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
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

  defp acquire_event(%State{holder: nil}, db_path, run_id, task_id, acquired_at_ms) do
    {:ok,
     %{
       stream_id: stream_id(db_path),
       event_type: "BeadsDbLeaseAcquired",
       payload: %{
         db_path: db_path,
         run_id: run_id,
         task_id: task_id,
         acquired_at_ms: acquired_at_ms,
         provenance: {:direct, run_id}
       }
     }}
  end

  defp acquire_event(
         %State{holder: %Holder{run_id: holder_run_id}},
         _db_path,
         run_id,
         _task_id,
         _acquired_at_ms
       )
       when holder_run_id == run_id do
    # Idempotent: same run_id already holds the lease.
    {:ok, nil}
  end

  defp acquire_event(
         %State{holder: %Holder{run_id: holder_run_id}} = state,
         db_path,
         run_id,
         task_id,
         acquired_at_ms
       ) do
    # Held by a different run — atomically enqueue as a waiter.
    _ = holder_run_id

    if already_waiting?(state.waiters, run_id) do
      {:ok, nil}
    else
      {:ok,
       %{
         stream_id: stream_id(db_path),
         event_type: "BeadsDbLeaseWaiterRegistered",
         payload: %{
           db_path: db_path,
           run_id: run_id,
           task_id: task_id,
           enqueued_at_ms: acquired_at_ms
         }
       }}
    end
  end

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
       payload: %{
         db_path: db_path,
         released_run_id: run_id,
         released_at_ms: released_at_ms,
         reason: reason,
         acquired_run_id: next.run_id,
         acquired_task_id: next.task_id,
         acquired_at_ms: next.enqueued_at_ms,
         enqueued_at_ms: next.enqueued_at_ms
       }
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
      enqueued_at_ms: e.enqueued_at_ms
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
      enqueued_at_ms: e.enqueued_at_ms
    }

  defp positive_integer(value, _key) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, key),
    do: {:error, {:missing_or_invalid, key, value}}

  defp has_waiter?(waiters, run_id) do
    Enum.any?(waiters, fn %Waiter{run_id: r} -> r == run_id end)
  end

  defp already_waiting?(waiters, run_id), do: has_waiter?(waiters, run_id)

  defp append_waiter(waiters, %Waiter{} = waiter) do
    if already_waiting?(waiters, waiter.run_id) do
      waiters
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
