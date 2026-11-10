defmodule ForemanServer.Aggregates.RunSlots do
  @moduledoc """
  Global run-slot admission gate on stream `run_slots:global`.

  State is `RunSlots.State` (`defstruct [:capacity, holders: %{}, waiters: []]`).

  Serializes all concurrent-run admission decisions globally. Capacity is
  carried on the acquire command and recorded on the emitted event — never
  read from `Application.get_env` during replay — so that history is
  self-describing and replay is deterministic.

  ## Stream id

      run_slots:global

  ## Events folded

      RunSlotAcquired     — run added to holders; capacity set from event
      RunSlotQueued      — run appended to FIFO waiters
      RunSlotReleased    — run removed from holders
      RunSlotTransferred — run removed from holders; FIFO head promoted
      RunSlotWaiterRemoved — run removed from waiters list
      RunSlotRecoveryAttempted — boot cleanup budget of an orphan entry (`recovery`);
                                 dropped when the entry's holder/waiter leaves

  ## Replay contract

  `apply_event/2` accepts both the live `EventStore.RecordedEvent` shape
  (used by `Aggregate.load/2`) and codec-decoded typed structs
  (`%RunSlotAcquired{}`, etc.). Both shapes are normalised to a plain map
  via `event_data_to_map/1`.

  ## Command dispatch

  Commands may be sent either as typed structs (`%RunSlotsAcquire{}`,
  `%RunSlotsRelease{}`) or as map envelopes with `type` field
  (`%{type: "run_slots.acquire", ...}`). Map envelopes are used by
  `CommandGateway.dispatch_system/1`.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.Telemetry
  alias ForemanServer.Commands.{RunSlotsAcquire, RunSlotsRelease, RunSlotsRemoveWaiter}

  alias ForemanServer.Events.{
    RunSlotAcquired,
    RunSlotQueued,
    RunSlotReleased,
    RunSlotRecoveryAttempted,
    RunSlotTransferred,
    RunSlotWaiterRemoved
  }

  @recovery_outcomes ["failed", "exhausted", "dispatched"]
  @recovery_kinds ["slot_release", "waiter_remove"]

  @behaviour ForemanServer.Aggregate

  defmodule Waiter do
    @moduledoc "Durable waiter entry. FIFO order is preserved by `enqueued_at_ms`."
    @enforce_keys [:run_id, :enqueued_at_ms]
    @type t :: %__MODULE__{
            run_id: String.t(),
            enqueued_at_ms: integer()
          }
    defstruct [:run_id, :enqueued_at_ms]
  end

  defmodule State do
    @moduledoc """
    Global run-slot state. `recovery` holds one entry per run whose boot cleanup
    (slot release or waiter removal) failed, `%{attempt, outcome, kind, reason,
    elapsed_since_boot_ms}`; it exists only while the run's holder or waiter does.
    """
    @type recovery_entry :: %{
            attempt: non_neg_integer(),
            outcome: String.t(),
            kind: String.t(),
            reason: String.t() | nil,
            elapsed_since_boot_ms: integer()
          }
    @type t :: %__MODULE__{
            capacity: non_neg_integer() | nil,
            holders: %{optional(String.t()) => %{acquired_at_ms: integer()}},
            waiters: [RunSlots.Waiter.t()],
            recovery: %{optional(String.t()) => recovery_entry()}
          }
    @enforce_keys []
    defstruct [
      :capacity,
      holders: %{},
      waiters: [],
      recovery: %{}
    ]
  end

  @impl true
  def initial_state, do: %State{capacity: nil, holders: %{}, waiters: [], recovery: %{}}

  # -------------------------------------------------------------------------
  # Typed-struct apply_event clauses
  # -------------------------------------------------------------------------

  @spec apply_event(State.t(), any()) :: State.t()
  @impl true
  def apply_event(%State{} = state, %RunSlotAcquired{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | capacity: Aggregate.get(payload, :capacity),
        holders:
          Map.put(
            state.holders,
            Aggregate.get(payload, :run_id),
            %{
              acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
            }
          )
    }
  end

  @impl true
  def apply_event(%State{} = state, %RunSlotQueued{} = event) do
    payload = event_data_to_map(event)

    new_waiter = %Waiter{
      run_id: Aggregate.get(payload, :run_id),
      enqueued_at_ms: Aggregate.get(payload, :enqueued_at_ms)
    }

    %State{
      state
      | waiters: append_waiter(state.waiters, new_waiter)
    }
  end

  @impl true
  def apply_event(%State{} = state, %RunSlotReleased{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | holders: Map.delete(state.holders, Aggregate.get(payload, :run_id)),
        recovery: Map.delete(state.recovery, Aggregate.get(payload, :run_id))
    }
  end

  @impl true
  def apply_event(%State{} = state, %RunSlotTransferred{} = event) do
    payload = event_data_to_map(event)

    new_holder_run_id = Aggregate.get(payload, :acquired_run_id)

    %State{
      state
      | holders:
          state.holders
          |> Map.delete(Aggregate.get(payload, :released_run_id))
          |> Map.put(new_holder_run_id, %{
            acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
          }),
        waiters: drop_waiter(state.waiters, new_holder_run_id),
        recovery:
          state.recovery
          |> Map.delete(Aggregate.get(payload, :released_run_id))
          |> Map.delete(new_holder_run_id)
    }
  end

  @impl true
  def apply_event(%State{} = state, %RunSlotWaiterRemoved{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id)),
        recovery: Map.delete(state.recovery, Aggregate.get(payload, :run_id))
    }
  end

  @impl true
  def apply_event(%State{} = state, %RunSlotRecoveryAttempted{} = event) do
    fold_recovery(state, event_data_to_map(event))
  end

  # -------------------------------------------------------------------------
  # String-type / RecordedEvent apply_event fallback (for Aggregate.load/2)
  # -------------------------------------------------------------------------

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "RunSlotAcquired" ->
        %State{
          state
          | capacity: Aggregate.get(payload, :capacity),
            holders:
              Map.put(
                state.holders,
                Aggregate.get(payload, :run_id),
                %{
                  acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
                }
              )
        }

      "RunSlotQueued" ->
        new_waiter = %Waiter{
          run_id: Aggregate.get(payload, :run_id),
          enqueued_at_ms: Aggregate.get(payload, :enqueued_at_ms)
        }

        %State{
          state
          | waiters: append_waiter(state.waiters, new_waiter)
        }

      "RunSlotReleased" ->
        %State{
          state
          | holders: Map.delete(state.holders, Aggregate.get(payload, :run_id)),
            recovery: Map.delete(state.recovery, Aggregate.get(payload, :run_id))
        }

      "RunSlotTransferred" ->
        new_holder_run_id = Aggregate.get(payload, :acquired_run_id)

        %State{
          state
          | holders:
              state.holders
              |> Map.delete(Aggregate.get(payload, :released_run_id))
              |> Map.put(new_holder_run_id, %{
                acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
              }),
            waiters: drop_waiter(state.waiters, new_holder_run_id),
            recovery:
              state.recovery
              |> Map.delete(Aggregate.get(payload, :released_run_id))
              |> Map.delete(new_holder_run_id)
        }

      "RunSlotWaiterRemoved" ->
        %State{
          state
          | waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id)),
            recovery: Map.delete(state.recovery, Aggregate.get(payload, :run_id))
        }

      "RunSlotRecoveryAttempted" ->
        fold_recovery(state, payload)

      _ ->
        state
    end
  end

  # -------------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------------

  # `failed` and `exhausted` record the run's cleanup budget; `dispatched` clears it.
  defp fold_recovery(%State{} = state, payload) do
    run_id = Aggregate.get(payload, :run_id)

    case Aggregate.get(payload, :outcome) do
      "dispatched" ->
        %State{state | recovery: Map.delete(state.recovery, run_id)}

      outcome ->
        entry = %{
          attempt: Aggregate.get(payload, :attempt),
          outcome: outcome,
          kind: Aggregate.get(payload, :kind),
          reason: Aggregate.get(payload, :reason),
          elapsed_since_boot_ms: Aggregate.get(payload, :elapsed_since_boot_ms)
        }

        %State{state | recovery: Map.put(state.recovery, run_id, entry)}
    end
  end

  defp append_waiter(waiters, %Waiter{} = waiter), do: waiters ++ [waiter]

  defp drop_waiter(waiters, run_id) do
    Enum.reject(waiters, &(&1.run_id == run_id))
  end

  # Converts a RecordedEvent or typed struct to a plain map for field access.
  defp event_data_to_map(%_{} = struct) when is_struct(struct), do: struct

  # -------------------------------------------------------------------------
  # Command handlers — typed structs (for direct testing)
  # -------------------------------------------------------------------------

  @impl true
  def handle_command(%State{} = state, %RunSlotsAcquire{} = cmd) do
    do_acquire(state, cmd.run_id, cmd.capacity)
  end

  @impl true
  def handle_command(%State{} = state, %RunSlotsRelease{} = cmd) do
    do_release(state, cmd.run_id, cmd.capacity)
  end

  @impl true
  def handle_command(%State{} = state, %RunSlotsRemoveWaiter{} = cmd) do
    if Enum.any?(state.waiters, &(&1.run_id == cmd.run_id)) do
      Telemetry.run_slots_waiter_removed(
        cmd.run_id,
        max(length(state.waiters) - 1, 0),
        :aggregate
      )

      {:ok, %RunSlotWaiterRemoved{run_id: cmd.run_id}}
    else
      {:ok, nil}
    end
  end

  # -------------------------------------------------------------------------
  # Command handlers — map envelopes (for CommandGateway.dispatch_system/1)
  # -------------------------------------------------------------------------

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.acquire"} = command) do
    payload = Map.get(command, :payload) || %{}
    run_id = Aggregate.get(payload, :run_id)
    capacity = Aggregate.get(payload, :capacity)

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id),
         {:ok, capacity} <- required_non_neg_integer(capacity, :capacity) do
      do_acquire(state, run_id, capacity)
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.release"} = command) do
    payload = Map.get(command, :payload) || %{}
    run_id = Aggregate.get(payload, :run_id)
    capacity = Aggregate.get(payload, :capacity)

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id) do
      capacity = if is_integer(capacity) and capacity >= 0, do: capacity, else: nil
      do_release(state, run_id, capacity)
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.remove_waiter"} = command) do
    payload = Map.get(command, :payload) || %{}
    run_id = Aggregate.get(payload, :run_id)

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id) do
      if Enum.any?(state.waiters, &(&1.run_id == run_id)) do
        Telemetry.run_slots_waiter_removed(run_id, max(length(state.waiters) - 1, 0), :aggregate)
        {:ok, %RunSlotWaiterRemoved{run_id: run_id}}
      else
        {:ok, nil}
      end
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.recovery_attempt"} = command) do
    payload = Map.get(command, :payload) || %{}
    reason = Aggregate.get(payload, :reason)

    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, attempt} <- required_non_neg_integer(Aggregate.get(payload, :attempt), :attempt),
         {:ok, outcome} <-
           required_member(Aggregate.get(payload, :outcome), @recovery_outcomes, :outcome),
         {:ok, kind} <- required_member(Aggregate.get(payload, :kind), @recovery_kinds, :kind),
         {:ok, elapsed} <-
           required_non_neg_integer(
             Aggregate.get(payload, :elapsed_since_boot_ms),
             :elapsed_since_boot_ms
           ),
         :ok <- optional_binary(reason, :reason) do
      # A failure or exhaustion only describes an entry that still holds or
      # waits: a release by another route between the failure and this record
      # must not leave an orphan recovery entry behind. `dispatched` follows
      # the release, so it needs no membership.
      if outcome == "dispatched" or in_slot_role?(state, run_id) do
        {:ok,
         %RunSlotRecoveryAttempted{
           run_id: run_id,
           attempt: attempt,
           outcome: outcome,
           kind: kind,
           reason: reason,
           elapsed_since_boot_ms: elapsed
         }}
      else
        {:ok, nil}
      end
    else
      {:error, _} = err -> err
    end
  end

  # -------------------------------------------------------------------------
  # Internal command helpers
  # -------------------------------------------------------------------------

  defp do_acquire(state, run_id, capacity) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      Map.has_key?(state.holders, run_id) ->
        {:ok, nil}

      map_size(state.holders) < capacity ->
        Telemetry.run_slots_acquired(run_id, map_size(state.holders) + 1, capacity)
        {:ok, %RunSlotAcquired{run_id: run_id, capacity: capacity, acquired_at_ms: now_ms}}

      true ->
        position = length(state.waiters) + 1
        Telemetry.run_slots_queued(run_id, position, position)
        {:ok, %RunSlotQueued{run_id: run_id, position: position, enqueued_at_ms: now_ms}}
    end
  end

  defp do_release(state, run_id, capacity) do
    if Map.has_key?(state.holders, run_id) do
      now_ms = System.monotonic_time(:millisecond)

      effective_capacity =
        if is_integer(capacity) and capacity >= 0, do: capacity, else: state.capacity

      if Enum.empty?(state.waiters) do
        Telemetry.run_slots_released(run_id, max(map_size(state.holders) - 1, 0), :aggregate)
        {:ok, %RunSlotReleased{run_id: run_id, capacity: effective_capacity}}
      else
        {promoted, remaining} = List.pop_at(state.waiters, 0)
        Telemetry.run_slots_transferred(run_id, promoted.run_id, length(remaining))

        {:ok,
         %RunSlotTransferred{
           released_run_id: run_id,
           acquired_run_id: promoted.run_id,
           capacity: effective_capacity,
           acquired_at_ms: now_ms
         }}
      end
    else
      {:ok, nil}
    end
  end

  defp in_slot_role?(state, run_id) do
    Map.has_key?(state.holders, run_id) or Enum.any?(state.waiters, &(&1.run_id == run_id))
  end

  defp required_member(value, allowed, field) do
    if value in allowed, do: {:ok, value}, else: {:error, {:missing_or_invalid, field}}
  end

  defp optional_binary(nil, _field), do: :ok
  defp optional_binary(value, _field) when is_binary(value), do: :ok
  defp optional_binary(_value, field), do: {:error, {:missing_or_invalid, field}}

  defp required_non_neg_integer(value, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp required_non_neg_integer(_value, field), do: {:error, {:missing_or_invalid, field}}
end
