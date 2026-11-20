defmodule ForemanServer.Aggregates.RunSlots do
  @moduledoc """
  Run-slot admission gate. One aggregate per project, on stream
  `run_slots:<project_id>` (`stream_id/1`); the legacy `run_slots:global`
  stream is still folded for history written before per-project queues.

  State is `RunSlots.State` (`defstruct [:capacity, holders: %{}, waiters: []]`).

  Serializes all concurrent-run admission decisions globally. Capacity is
  carried on the acquire command and recorded on the emitted event — never
  read from `Application.get_env` during replay — so that history is
  self-describing and replay is deterministic.

  ## Stream id

      run_slots:<project_id>      (legacy: run_slots:global)

  ## Events folded

      RunSlotAcquired     — run added to holders (and dropped from waiters, as
                            a promoted or forced waiter leaves the queue);
                            capacity set from event
      RunSlotQueued      — run appended to FIFO waiters
      RunSlotReleased    — run removed from holders
      RunSlotTransferred — run removed from holders; FIFO head promoted
      RunSlotWaiterRemoved — run removed from waiters list

  ## Replay contract

  `apply_event/2` accepts both the live `EventStore.RecordedEvent` shape
  (used by `Aggregate.load/2`) and codec-decoded typed structs
  (`%RunSlotAcquired{}`, etc.). Both shapes are normalised to a plain map
  via `event_data_to_map/1`.

  ## Command dispatch

  Map-envelope commands: `run_slots.acquire`, `run_slots.release`,
  `run_slots.remove_waiter` and `run_slots.promote`.

  `run_slots.acquire` payload flags:

    * `force: true`  — record the run as a holder regardless of capacity
      (adoption of already-running work); a queued run is acquired and the
      fold drops its waiter entry.
    * `enqueue_only: true` — queue the run even when capacity is free (the
      queue is then drained by `run_slots.promote`).

  A run that is already a holder, or already a waiter, yields `{:ok, nil}`
  (never a second slot or queue position).

  `run_slots.promote` (`payload: %{capacity, project_id?}`) emits ONE
  `RunSlotAcquired` (`promoted: true`) for the FIFO head waiter when
  `map_size(holders) < capacity`; otherwise `{:ok, nil}`.

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
    @type t :: %__MODULE__{
            capacity: non_neg_integer() | nil,
            holders: %{optional(String.t()) => %{acquired_at_ms: integer()}},
            waiters: [RunSlots.Waiter.t()]
          }
    @enforce_keys []
    defstruct [
      :capacity,
      holders: %{},
      waiters: []
    ]
  end

  @doc "Stream id of a project's run-slot aggregate."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(project_id) when is_binary(project_id), do: "run_slots:" <> project_id

  @legacy_stream "run_slots:global"

  @doc """
  The ONE builder of a `run_slots.release` command envelope (TRD-002).

  `RunAdmission`, `Dispatcher`, `RunLifecycleReconciler` and `BootReconciliation`
  all release through it. It reads the project's effective run limit once, here
  (never inside an aggregate decision) and carries it as `payload.capacity`, so
  `do_release` can hold the queue when the limit was lowered below the running
  count. The command id is unique per call.

  A `nil`/blank `project_id` targets the legacy `run_slots:global` stream with no
  capacity (the aggregate falls back to the capacity its stream recorded). That
  interim branch exists only until acquire moves to project streams
  (TRD-005..TRD-010).
  """
  @spec release_command(String.t() | nil, String.t(), String.t() | atom()) :: map()
  def release_command(project_id, run_id, reason) when is_binary(run_id) do
    command_id =
      "run_slots:release:#{run_id}:#{System.system_time(:millisecond)}:" <>
        Integer.to_string(System.unique_integer([:positive, :monotonic]))

    base = %{type: "run_slots.release", command_id: command_id}

    if is_binary(project_id) and project_id != "" do
      Map.merge(base, %{
        aggregate_id: stream_id(project_id),
        payload: %{
          run_id: run_id,
          project_id: project_id,
          capacity: project_run_limit(project_id),
          reason: reason
        }
      })
    else
      Map.merge(base, %{
        aggregate_id: @legacy_stream,
        payload: %{run_id: run_id, reason: reason}
      })
    end
  end

  # Effective limit: the project's setting, else the per-project default.
  defp project_run_limit(project_id) do
    settings =
      try do
        ForemanServer.ProjectionStore.project_settings(project_id)
      catch
        :exit, _ -> nil
      end

    limit = settings && Map.get(settings, :max_concurrent_runs)

    if is_integer(limit) and limit >= 1,
      do: limit,
      else: ForemanServer.RunSlots.Config.max_concurrent_runs_per_project()
  end

  @impl true
  def initial_state, do: %State{capacity: nil, holders: %{}, waiters: []}

  # -------------------------------------------------------------------------
  # Typed-struct apply_event clauses
  # -------------------------------------------------------------------------

  @spec apply_event(State.t(), any()) :: State.t()
  @impl true
  def apply_event(%State{} = state, %RunSlotAcquired{} = event) do
    payload = event_data_to_map(event)

    run_id = Aggregate.get(payload, :run_id)

    %State{
      state
      | capacity: Aggregate.get(payload, :capacity),
        holders:
          Map.put(state.holders, run_id, %{
            acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
          }),
        waiters: drop_waiter(state.waiters, run_id)
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
      | holders: Map.delete(state.holders, Aggregate.get(payload, :run_id))
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
        waiters: drop_waiter(state.waiters, new_holder_run_id)
    }
  end

  @impl true
  def apply_event(%State{} = state, %RunSlotWaiterRemoved{} = event) do
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
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "RunSlotAcquired" ->
        run_id = Aggregate.get(payload, :run_id)

        %State{
          state
          | capacity: Aggregate.get(payload, :capacity),
            holders:
              Map.put(state.holders, run_id, %{
                acquired_at_ms: Aggregate.get(payload, :acquired_at_ms)
              }),
            waiters: drop_waiter(state.waiters, run_id)
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
            waiters: drop_waiter(state.waiters, new_holder_run_id)
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

  # Converts a RecordedEvent or typed struct to a plain map for field access.
  defp event_data_to_map(%_{} = struct) when is_struct(struct), do: struct

  # -------------------------------------------------------------------------
  # Command handlers — typed structs (for direct testing)
  # -------------------------------------------------------------------------

  @impl true
  def handle_command(%State{} = state, %RunSlotsAcquire{} = cmd) do
    do_acquire(state, cmd.run_id, cmd.capacity, cmd.project_id)
  end

  @impl true
  def handle_command(%State{} = state, %RunSlotsRelease{} = cmd) do
    do_release(state, cmd.run_id, cmd.capacity, cmd.project_id)
  end

  @impl true
  def handle_command(%State{} = state, %RunSlotsRemoveWaiter{} = cmd) do
    if Enum.any?(state.waiters, &(&1.run_id == cmd.run_id)) do
      Telemetry.run_slots_waiter_removed(
        cmd.run_id,
        max(length(state.waiters) - 1, 0),
        :aggregate
      )

      {:ok, %RunSlotWaiterRemoved{run_id: cmd.run_id, project_id: cmd.project_id}}
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
    project_id = optional_project_id(payload)

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id),
         {:ok, capacity} <- required_non_neg_integer(capacity, :capacity) do
      opts = [
        force: Aggregate.get(payload, :force) == true,
        enqueue_only: Aggregate.get(payload, :enqueue_only) == true
      ]

      do_acquire(state, run_id, capacity, project_id, opts)
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.promote"} = command) do
    payload = Map.get(command, :payload) || %{}

    with {:ok, capacity} <- required_non_neg_integer(Aggregate.get(payload, :capacity), :capacity) do
      case state.waiters do
        [head | _] when map_size(state.holders) < capacity ->
          Telemetry.run_slots_acquired(head.run_id, map_size(state.holders) + 1, capacity)
          {:ok,
           %RunSlotAcquired{
             run_id: head.run_id,
             capacity: capacity,
             acquired_at_ms: System.system_time(:millisecond),
             project_id: optional_project_id(payload),
             promoted: true
           }}

        _ ->
          {:ok, nil}
      end
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.release"} = command) do
    payload = Map.get(command, :payload) || %{}
    run_id = Aggregate.get(payload, :run_id)
    capacity = Aggregate.get(payload, :capacity)

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id) do
      capacity = if is_integer(capacity) and capacity >= 0, do: capacity, else: nil
      do_release(state, run_id, capacity, optional_project_id(payload))
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "run_slots.remove_waiter"} = command) do
    payload = Map.get(command, :payload) || %{}
    run_id = Aggregate.get(payload, :run_id)
    project_id = optional_project_id(payload)

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id) do
      if Enum.any?(state.waiters, &(&1.run_id == run_id)) do
        Telemetry.run_slots_waiter_removed(run_id, max(length(state.waiters) - 1, 0), :aggregate)
        {:ok, %RunSlotWaiterRemoved{run_id: run_id, project_id: project_id}}
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

  defp do_acquire(state, run_id, capacity, project_id, opts \\ []) do
    now_ms = System.system_time(:millisecond)
    force? = Keyword.get(opts, :force, false)
    enqueue_only? = Keyword.get(opts, :enqueue_only, false)
    waiting? = Enum.any?(state.waiters, &(&1.run_id == run_id))

    cond do
      Map.has_key?(state.holders, run_id) ->
        {:ok, nil}

      # force: record a holder regardless of capacity; the fold drops the run
      # from waiters if it was queued, so it never ends up running AND queued.
      force? ->
        Telemetry.run_slots_acquired(run_id, map_size(state.holders) + 1, capacity)

        {:ok,
         %RunSlotAcquired{
           run_id: run_id,
           capacity: capacity,
           acquired_at_ms: now_ms,
           project_id: project_id
         }}

      # A queued run keeps its single position.
      waiting? ->
        {:ok, nil}

      not enqueue_only? and map_size(state.holders) < capacity ->
        Telemetry.run_slots_acquired(run_id, map_size(state.holders) + 1, capacity)
        {:ok, %RunSlotAcquired{run_id: run_id, capacity: capacity,
           acquired_at_ms: now_ms,
           project_id: project_id
         }}

      true ->
        position = length(state.waiters) + 1
        Telemetry.run_slots_queued(run_id, position, position)
        {:ok, %RunSlotQueued{run_id: run_id, position: position,
           enqueued_at_ms: now_ms,
           project_id: project_id
         }}
    end
  end

  defp do_release(state, run_id, capacity, project_id) do
    if Map.has_key?(state.holders, run_id) do
      now_ms = System.system_time(:millisecond)

      effective_capacity =
        if is_integer(capacity) and capacity >= 0, do: capacity, else: state.capacity

      # Promote only while the holders left after this release are below the
      # capacity: a limit lowered under the running count keeps the queue held
      # (AC-003-4). A nil capacity (legacy stream) keeps the old always-promote.
      promote? =
        state.waiters != [] and
          (not is_integer(effective_capacity) or map_size(state.holders) - 1 < effective_capacity)

      if not promote? do
        Telemetry.run_slots_released(run_id, max(map_size(state.holders) - 1, 0), :aggregate)
        {:ok, %RunSlotReleased{run_id: run_id, capacity: effective_capacity, project_id: project_id}}
      else
        {promoted, remaining} = List.pop_at(state.waiters, 0)
        Telemetry.run_slots_transferred(run_id, promoted.run_id, length(remaining))

        {:ok,
         %RunSlotTransferred{
           released_run_id: run_id,
           acquired_run_id: promoted.run_id,
           capacity: effective_capacity,
           acquired_at_ms: now_ms,
           project_id: project_id
         }}
      end
    else
      {:ok, nil}
    end
  end

  defp optional_project_id(payload) do
    case Aggregate.get(payload, :project_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp required_non_neg_integer(value, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp required_non_neg_integer(_value, field), do: {:error, {:missing_or_invalid, field}}
end
