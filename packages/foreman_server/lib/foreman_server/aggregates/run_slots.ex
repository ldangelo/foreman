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

  ## Replay contract

  `apply_event/2` accepts both the live `EventStore.RecordedEvent` shape
  (used by `Aggregate.load/2`) and codec-decoded typed structs
  (`%RunSlotAcquired{}`, etc.). Both shapes are normalised to a plain map
  via `event_data_to_map/1`.
  """

  alias ForemanServer.Aggregate

  alias ForemanServer.Events.{
    RunSlotAcquired,
    RunSlotQueued,
    RunSlotReleased,
    RunSlotTransferred,
    RunSlotWaiterRemoved
  }

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
    @moduledoc "Global run-slot state."
    @enforce_keys []
    defstruct [
      :capacity,
      holders: %{},
      waiters: []
    ]
  end

  @impl true
  def initial_state, do: %State{capacity: nil, holders: %{}, waiters: []}

  # -------------------------------------------------------------------------
  # Typed-struct apply_event clauses
  # -------------------------------------------------------------------------

  @impl true
  def apply_event(state, %RunSlotAcquired{} = event) do
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
  def apply_event(state, %RunSlotQueued{} = event) do
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
  def apply_event(state, %RunSlotReleased{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | holders: Map.delete(state.holders, Aggregate.get(payload, :run_id))
    }
  end

  @impl true
  def apply_event(state, %RunSlotTransferred{} = event) do
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
        waiters: drop_head_waiter(state.waiters)
    }
  end

  @impl true
  def apply_event(state, %RunSlotWaiterRemoved{} = event) do
    payload = event_data_to_map(event)

    %State{
      state
      | waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id))
    }
  end

  # -------------------------------------------------------------------------
  # String-type / RecordedEvent apply_event fallback (for Aggregate.load/2)
  # -------------------------------------------------------------------------

  @impl true
  def apply_event(state, event) do
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
          | holders: Map.delete(state.holders, Aggregate.get(payload, :run_id))
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
            waiters: drop_head_waiter(state.waiters)
        }

      "RunSlotWaiterRemoved" ->
        %State{
          state
          | waiters: drop_waiter(state.waiters, Aggregate.get(payload, :run_id))
        }

      _ ->
        state
    end
  end

  # -------------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------------

  defp append_waiter(waiters, %Waiter{} = waiter), do: waiters ++ [waiter]

  defp drop_waiter(waiters, run_id) do
    Enum.reject(waiters, &(&1.run_id == run_id))
  end

  defp drop_head_waiter([]), do: []
  defp drop_head_waiter([_ | tail]), do: tail

  # Converts a RecordedEvent or typed struct to a plain map for field access.
  defp event_data_to_map(%EventStore.RecordedEvent{data: data}) when is_map(data), do: data
  defp event_data_to_map(%EventStore.RecordedEvent{data: nil}), do: %{}
  defp event_data_to_map(%_{} = struct) when is_struct(struct), do: struct
end
