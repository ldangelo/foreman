defmodule ForemanServerWeb.Debug.PresenceBridge do
  @moduledoc false

  use GenServer

  alias ForemanServer.{Event, ProjectionStore}
  alias ForemanServerWeb.{Debug.Views, Presence}

  @event_topic "debug:events"
  @presence_topic "debug:workers"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(ForemanServer.PubSub, @event_topic)
    sync_from_snapshot()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:debug_event, %Event{} = event}, state) do
    sync_event(event)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp sync_event(%Event{event_type: "WorkerStarted", payload: payload}) do
    upsert_worker_presence(payload, map_value(payload, :sequence), "live")
  end

  defp sync_event(%Event{event_type: "WorkerHeartbeat", payload: payload}) do
    upsert_worker_presence(payload, map_value(payload, :sequence), "heartbeat")
  end

  defp sync_event(%Event{event_type: type, payload: payload})
       when type in ["WorkerExited", "WorkerUnresponsive", "WorkerCrashed"] do
    untrack_worker(payload)
  end

  defp sync_event(%Event{event_type: type, payload: %{run_id: run_id}})
       when type in ["RunCompleted", "RunFailed", "RunBlocked", "RunPaused"] do
    untrack_run(run_id)
  end

  defp sync_event(_event), do: :ok

  defp sync_from_snapshot do
    snapshot = ProjectionStore.snapshot()

    for run <- Map.values(Map.get(snapshot, :runs, %{})),
        {worker_id, status} <- Map.get(run, :worker_status, %{}),
        Views.active_worker_status?(status) do
      key = worker_key(Map.get(run, :run_id), worker_id)
      heartbeat = get_in(snapshot, [:worker_heartbeats, key]) || %{}
      sequence = get_in(snapshot, [:worker_sequences, key])

      upsert_worker_presence(
        %{
          run_id: Map.get(run, :run_id),
          worker_id: worker_id,
          phase_id: map_value(heartbeat, :phase_id) || Map.get(run, :current_phase),
          adapter: Map.get(run, :adapter),
          attach: map_value(heartbeat, :attach) || %{},
          observed_at: map_value(heartbeat, :observed_at)
        },
        sequence,
        status
      )
    end
  end

  defp upsert_worker_presence(payload, sequence, status) do
    with run_id when is_binary(run_id) and run_id != "" <- map_value(payload, :run_id),
         worker_id when is_binary(worker_id) and worker_id != "" <- map_value(payload, :worker_id) do
      key = worker_key(run_id, worker_id)
      meta = worker_meta(payload, sequence, status)

      case presence_exists?(key) do
        true ->
          case Presence.update(self(), @presence_topic, key, meta) do
            {:ok, _meta} -> :ok
            {:error, _reason} -> Presence.track(self(), @presence_topic, key, meta)
          end

        false ->
          Presence.track(self(), @presence_topic, key, meta)
      end

      :ok
    else
      _ -> :ok
    end
  end

  defp untrack_worker(payload) do
    with run_id when is_binary(run_id) and run_id != "" <- map_value(payload, :run_id),
         worker_id when is_binary(worker_id) and worker_id != "" <- map_value(payload, :worker_id) do
      Presence.untrack(self(), @presence_topic, worker_key(run_id, worker_id))
      :ok
    else
      _ -> :ok
    end
  end

  defp untrack_run(run_id) when is_binary(run_id) do
    @presence_topic
    |> Presence.list()
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "#{run_id}:"))
    |> Enum.each(&Presence.untrack(self(), @presence_topic, &1))
  end

  defp worker_meta(payload, sequence, status) do
    %{
      run_id: map_value(payload, :run_id),
      worker_id: map_value(payload, :worker_id),
      phase_id: map_value(payload, :phase_id),
      adapter: map_value(payload, :adapter),
      attach: map_value(payload, :attach) || %{},
      observed_at: map_value(payload, :observed_at),
      sequence: sequence,
      status: status
    }
  end

  defp presence_exists?(key) do
    Presence.list(@presence_topic) |> Map.has_key?(key)
  end

  defp worker_key(run_id, worker_id), do: "#{run_id}:#{worker_id}"

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
