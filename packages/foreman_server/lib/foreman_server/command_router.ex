defmodule ForemanServer.CommandRouter do
  @moduledoc """
  Sole append point for the event store.

  All commands from all ingress paths (Phoenix HTTP, worker protocol, overwatch)
  must eventually route through this module. Only this module (or its private
  helpers) call `EventStore.append_to_stream`.

  ## Actor ↔ CommandRouter protocol

  1. Actor sends `{:append, aggregate_id, event_data_list, expected_version, actor_pid}`.
     The `event_data_list` is a list of pre-normalized `%EventData{}` structs.
  2. CommandRouter appends via `EventStore.append_to_stream(stream_uuid, expected_version, event_data_list)`.
     Returns `:ok` on success.
  3. CommandRouter sends result back to `actor_pid`:
     - `{:append_ok, event_count}` on success
     - `{:append_error, reason}` on conflict or other failure
  """

  alias EventStore.EventData
  alias ForemanServer.{EventStore, Aggregate.Actor, Telemetry}
  use GenServer

  @doc """
  Dispatch a command to its aggregate.

  Determines the aggregate module from the aggregate_id prefix, starts the aggregate
  actor, and returns the command result.
  """
  @spec dispatch(command :: map(), timeout :: integer()) ::
          {:ok, event_spec :: map() | nil}
          | {:error, any()}
  def dispatch(%{aggregate_id: aggregate_id} = command, timeout \\ 5_000) do
    started_at_ms = System.monotonic_time(:millisecond)
    aggregate_module = aggregate_module_for(aggregate_id)
    {:ok, _pid} = ForemanServer.Aggregator.start_aggregate(aggregate_module, aggregate_id)

    result =
      aggregate_id
      |> Actor.via()
      |> GenServer.call({:command, command}, timeout)

    finalize_dispatch(result, aggregate_id, started_at_ms)
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  # -------------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------------


  @impl true
  def init(_init_arg) do
    {:ok, %{}}
  end

  @impl true
  def handle_info({:append, aggregate_id, event_data_list, expected_version, ref, actor_pid}, state) do
    append_started_at_ms = System.monotonic_time(:millisecond)
    result = append_events(aggregate_id, expected_version, event_data_list)
    append_latency_ms = elapsed_ms(append_started_at_ms)

    case result do
      :ok ->
        # Apply confirmed events to projection store before notifying actor.
        # This keeps the projection synchronous with the command path.
        _ = ForemanServer.ProjectionStore.apply_events(event_data_list)
        broadcast_debug_updates(event_data_list)
        send(actor_pid, {:append_ok, ref, length(event_data_list), append_latency_ms})

      {:error, reason} ->
        send(actor_pid, {:error, ref, reason, append_latency_ms})
    end

    {:noreply, state}
  end

  # -------------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------------

  # event_data_list is already a list of %EventData{} — pass through directly.
  # EventStore.append_to_stream/4 returns :ok on success.
  defp append_events(aggregate_id, expected_version, event_data_list) when is_list(event_data_list) do
    case EventStore.append_to_stream(aggregate_id, expected_version, event_data_list) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp broadcast_debug_updates(event_data_list) do
    event_data_list
    |> Enum.flat_map(&debug_topics_for_event/1)
    |> MapSet.new()
    |> Enum.each(fn topic ->
      Phoenix.PubSub.broadcast(ForemanServer.PubSub, topic, {:debug_state_changed, topic})
    end)
  end

  defp debug_topics_for_event(%EventData{data: payload}) do
    run_id = Map.get(payload, :run_id) || Map.get(payload, "run_id")
    phase_id = Map.get(payload, :phase_id) || Map.get(payload, "phase_id")
    worker_id = Map.get(payload, :worker_id) || Map.get(payload, "worker_id")

    []
    |> maybe_add_topic("runs")
    |> maybe_add_topic(run_id && "runs:#{run_id}")
    |> maybe_add_topic(phase_id && "phases")
    |> maybe_add_topic(phase_id && "phases:#{phase_id}")
    |> maybe_add_topic(worker_id && "workers")
    |> maybe_add_topic(worker_id && "workers:#{worker_id}")
  end

  defp maybe_add_topic(topics, nil), do: topics
  defp maybe_add_topic(topics, topic), do: [topic | topics]
  defp finalize_dispatch({:telemetry, result, %{append_latency_ms: append_latency_ms}}, aggregate_id, started_at_ms) do
    Telemetry.command_dispatch(
      elapsed_ms(started_at_ms),
      append_latency_ms,
      telemetry_status(result),
      aggregate_id
    )

    result
  end

  defp finalize_dispatch(result, aggregate_id, started_at_ms) do
    Telemetry.command_dispatch(elapsed_ms(started_at_ms), 0, telemetry_status(result), aggregate_id)
    result
  end

  defp telemetry_status({:ok, _}), do: "ok"
  defp telemetry_status(_), do: "error"

  defp elapsed_ms(started_at_ms) do
    max(System.monotonic_time(:millisecond) - started_at_ms, 0)
  end

  defp aggregate_module_for("project:" <> _), do: ForemanServer.Aggregates.Project
  defp aggregate_module_for("task:" <> _), do: ForemanServer.Aggregates.Task
  defp aggregate_module_for("run:" <> _), do: ForemanServer.Aggregates.Run
  defp aggregate_module_for("worker:" <> _), do: ForemanServer.Aggregates.Worker
  defp aggregate_module_for("phase:" <> _), do: ForemanServer.Aggregates.Phase
  defp aggregate_module_for("recovery:" <> _), do: ForemanServer.Aggregates.Recovery
  defp aggregate_module_for("pr_association:" <> _), do: ForemanServer.Aggregates.PrAssociation
  defp aggregate_module_for("scheduler_intent:" <> _), do: ForemanServer.Aggregates.SchedulerIntent
  defp aggregate_module_for("migration:" <> _), do: ForemanServer.Aggregates.ImportMigration
  defp aggregate_module_for("blocking:" <> _), do: ForemanServer.TestSupport.BlockingAggregate
end

