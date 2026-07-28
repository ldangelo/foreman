defmodule ForemanServer.CommandRouter do
  @moduledoc """
  Sole append point for the event store.

  All commands from all ingress paths (Phoenix HTTP, worker protocol, overwatch)
  must eventually route through this module. Only this module (or its private
  helpers) call `Commanded.EventStore.append_to_stream` via the adapter.

  ## Actor ↔ CommandRouter protocol

  1. Actor sends `{:append, aggregate_id, event_data_list, expected_version, ref, actor_pid}`.
     The `event_data_list` is a list of `%EventStore.EventData{}` structs produced by
     `Actor.normalize_to_event_data`, each carrying a deterministic `event_id`.
  2. CommandRouter calls `Commanded.EventStore.append_to_stream(stream_uuid, expected_version, event_data_list)`.
     The `EventStoreAdapter` receives the raw `%EventStore.EventData{}` list and appends
     directly to `ForemanServer.EventStore`, preserving `event_id` in the database.
     Returns `:ok` on success.
  3. CommandRouter sends result back to `actor_pid`:
     - `{:append_ok, ref, event_count}` on success
     - `{:error, ref, reason}` on conflict or other failure
  """

  alias ForemanServer.CommandedApplication
  alias ForemanServer.Aggregate.Actor
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
    aggregate_module = aggregate_module_for(aggregate_id)
    {:ok, _pid} = ForemanServer.Aggregator.start_aggregate(aggregate_module, aggregate_id)

    Actor.via(aggregate_id)
    |> GenServer.call({:command, command}, timeout)
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_init_arg) do
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:append, aggregate_id, event_data_list, expected_version, ref, actor_pid},
        state
      ) do
    result = append_events(aggregate_id, expected_version, event_data_list)

    case result do
      :ok ->
        _ = ForemanServer.ProjectionStore.apply_events(event_data_list)
        send(actor_pid, {:append_ok, ref, length(event_data_list)})

      {:error, reason} ->
        send(actor_pid, {:error, ref, reason})
    end

    {:noreply, state}
  end

  # Append events via the Commanded path.
  # Passes raw %EventStore.EventData{} structs (with event_id) unchanged.
  # The EventStoreAdapter.append_to_stream receives these and calls
  # ForemanServer.EventStore.append_to_stream directly, preserving event_id.
  defp append_events(aggregate_id, expected_version, event_data_list)
       when is_list(event_data_list) do
    case Commanded.EventStore.append_to_stream(
           CommandedApplication,
           aggregate_id,
           expected_version,
           event_data_list
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp aggregate_module_for("project:" <> _), do: ForemanServer.Aggregates.Project
  defp aggregate_module_for("task:" <> _), do: ForemanServer.Aggregates.Task
  defp aggregate_module_for("run:" <> _), do: ForemanServer.Aggregates.Run
  defp aggregate_module_for("worker:" <> _), do: ForemanServer.Aggregates.Worker
  defp aggregate_module_for("phase:" <> _), do: ForemanServer.Aggregates.Phase
  defp aggregate_module_for("blocking:" <> _), do: ForemanServer.TestSupport.BlockingAggregate

  defp aggregate_module_for(aggregate_id),
    do: raise("Unknown aggregate_id prefix: #{aggregate_id}")
end
