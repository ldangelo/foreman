defmodule ForemanServer.SimulationHarness do
  @moduledoc "Deterministic in-memory orchestration simulation helpers for tests and CLI smoke flows."

  alias ForemanServer.{EventStore, ProjectionStore, RunActor, WorkerProtocol}

  @type step :: map()
  @type result :: %{events: [String.t()], projection: map(), ready: map()}

  @spec run([step()]) :: {:ok, result()} | {:error, term()}
  def run(steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, events} ->
      case apply_step(step) do
        {:ok, new_events} -> {:cont, {:ok, events ++ List.wrap(new_events)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} ->
        {:ok, %{events: events, projection: ProjectionStore.snapshot(), ready: readiness()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec readiness() :: map()
  def readiness do
    %{
      ok: true,
      active_projects: ForemanServer.active_projects(),
      supervised: %{
        event_store: alive?(ForemanServer.EventStore),
        projection_store: alive?(ForemanServer.ProjectionStore),
        scheduler: alive?(ForemanServer.Scheduler)
      }
    }
  end

  defp apply_step(%{action: :start_run, run_id: run_id, phases: phases} = step) do
    with {:ok, _pid} <-
           ForemanServer.start_run(%{
             run_id: run_id,
             task_id: Map.get(step, :task_id),
             phases: phases,
             max_retries: Map.get(step, :max_retries, 0)
           }) do
      {:ok, event_ids("run:#{run_id}")}
    end
  end

  defp apply_step(%{action: :phase_pass, run_id: run_id}) do
    with {:ok, _state} <- RunActor.pass(run_id) do
      {:ok, event_ids("run:#{run_id}")}
    end
  end

  defp apply_step(%{action: :phase_fail, run_id: run_id} = step) do
    with {:ok, _state} <- RunActor.fail(run_id, Map.get(step, :details, %{})) do
      {:ok, event_ids("run:#{run_id}")}
    end
  end

  defp apply_step(%{action: :worker_start, phase_id: phase_id, payload: payload}) do
    with {:ok, %{event: event}} <- WorkerProtocol.start_phase(phase_id, payload) do
      {:ok, event.event_id}
    end
  end

  defp apply_step(%{action: :worker_event, payload: payload}) do
    with {:ok, %{event: event}} <- WorkerProtocol.ingest_event(payload) do
      {:ok, event.event_id}
    end
  end

  defp apply_step(%{action: :heartbeat, payload: payload}) do
    with {:ok, %{event: event}} <- WorkerProtocol.heartbeat(payload) do
      {:ok, event.event_id}
    end
  end

  defp apply_step(
         %{action: :worker_failure, run_id: run_id, phase_id: phase_id, worker_id: worker_id} =
           step
       ) do
    reason = Map.get(step, :reason, "simulated_worker_failure")

    with {:ok, failed} <-
           append("WorkerFailureSimulated", %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             reason: reason
           }),
         {:ok, recovery} <-
           append("WorkerRecoveryRequired", %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             reason: reason,
             recovery_action: Map.get(step, :recovery_action, "restart_phase")
           }) do
      {:ok, [failed.event_id, recovery.event_id]}
    end
  end

  defp apply_step(%{action: :server_ready}) do
    ready = readiness()
    if ready.ok, do: {:ok, []}, else: {:error, {:not_ready, ready}}
  end

  defp apply_step(step), do: {:error, {:unknown_simulation_step, step}}

  defp append(event_type, %{run_id: run_id, worker_id: worker_id} = payload) do
    EventStore.append(%{
      stream_id: "simulation:#{run_id}:#{worker_id}",
      event_type: event_type,
      payload: Map.put(payload, :observed_at, DateTime.utc_now()),
      metadata: %{correlation_id: run_id, idempotency_key: "#{event_type}:#{run_id}:#{worker_id}"}
    })
  end

  defp event_ids(stream_id) do
    stream_id
    |> EventStore.stream()
    |> Enum.map(& &1.event_id)
  end

  defp alive?(name), do: is_pid(Process.whereis(name))
end
