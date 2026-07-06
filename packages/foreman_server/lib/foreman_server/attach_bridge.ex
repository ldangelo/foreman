defmodule ForemanServer.AttachBridge do
  @moduledoc "Event-backed attach and interactive recovery bridge for worker sessions."

  alias ForemanServer.{EventStore, ProjectionStore}

  @unsupported_terminal_statuses MapSet.new(["failed", "blocked", "cancelled"])
  @recent_attach_window_seconds 60

  @type result :: {:ok, map()} | {:error, term()}

  @spec request_attach(map()) :: result()
  def request_attach(input) when is_map(input) do
    with {:ok, run_id} <- required_binary(fetch(input, :run_id), :run_id) do
      snapshot = ProjectionStore.snapshot()
      run = get_in(snapshot, [:runs, run_id])
      worker = attachable_worker(snapshot, run_id, fetch(input, :worker_id))

      cond do
        is_nil(run) ->
          {:error, {:not_found, :run}}

        attach_supported?(run, worker) ->
          append(
            "AttachRequested",
            %{
              run_id: run_id,
              phase_id: worker.phase_id,
              worker_id: worker.worker_id,
              adapter: Map.get(run, :adapter, "pi_sdk"),
              mode: attach_mode(worker),
              session_id: Map.get(worker, :session_id),
              attach: Map.get(worker, :attach, %{}),
              alternatives: alternatives(run_id),
              status: "ready"
            },
            attach_idempotency_key("AttachRequested", run_id, worker.worker_id)
          )

        true ->
          append(
            "AttachUnsupported",
            %{
              run_id: run_id,
              worker_id: fetch(input, :worker_id),
              adapter: Map.get(run, :adapter),
              reason: unsupported_reason(run, worker),
              alternatives: alternatives(run_id),
              status: "unsupported"
            },
            attach_idempotency_key(
              "AttachUnsupported",
              run_id,
              fetch(input, :worker_id) || "default"
            )
          )
      end
    end
  end

  @spec interrupt_phase(map()) :: result()
  def interrupt_phase(input) when is_map(input) do
    with {:ok, run_id} <- required_binary(fetch(input, :run_id), :run_id),
         {:ok, phase_id} <- required_binary(fetch(input, :phase_id), :phase_id),
         :ok <- validate_interruptable(run_id, phase_id) do
      append("HumanInterruptionRecorded", %{
        run_id: run_id,
        phase_id: phase_id,
        worker_id: fetch(input, :worker_id),
        interrupted_by: fetch(input, :interrupted_by) || "operator",
        reason: fetch(input, :reason) || "operator_interrupt",
        next_action: fetch(input, :next_action) || "await_resume",
        status: "interrupted"
      })
    end
  end

  @spec resume_after_interrupt(map()) :: result()
  def resume_after_interrupt(input) when is_map(input) do
    with {:ok, run_id} <- required_binary(fetch(input, :run_id), :run_id),
         {:ok, phase_id} <- required_binary(fetch(input, :phase_id), :phase_id),
         {:ok, next_action} <- required_binary(fetch(input, :next_action), :next_action),
         :ok <- validate_resumable(run_id, phase_id) do
      append("InteractiveRecoveryResumed", %{
        run_id: run_id,
        phase_id: phase_id,
        worker_id: fetch(input, :worker_id),
        requested_by: fetch(input, :requested_by) || "operator",
        next_action: next_action,
        status: "resume_requested"
      })
    end
  end

  defp attachable_worker(snapshot, run_id, requested_worker_id) do
    snapshot.worker_heartbeats
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run_id))
    |> maybe_filter_worker(requested_worker_id)
    |> Enum.sort_by(&Map.get(&1, :observed_at, DateTime.utc_now()), {:desc, DateTime})
    |> List.first()
  end

  defp maybe_filter_worker(workers, nil), do: workers
  defp maybe_filter_worker(workers, ""), do: workers

  defp maybe_filter_worker(workers, worker_id),
    do: Enum.filter(workers, &(&1.worker_id == worker_id))

  defp attach_supported?(run, worker) when is_map(run) and is_map(worker) do
    Map.get(run, :adapter, "pi_sdk") == "pi_sdk" &&
      not unsupported_terminal?(run) &&
      recent_worker?(worker) &&
      (present?(Map.get(worker, :session_id)) || attach_target?(Map.get(worker, :attach, %{})))
  end

  defp attach_supported?(_run, _worker), do: false

  defp validate_interruptable(run_id, phase_id) do
    snapshot = ProjectionStore.snapshot()

    with {:ok, run} <- existing_run(snapshot, run_id),
         :ok <- active_run(run),
         :ok <- known_phase(run, phase_id) do
      :ok
    end
  end

  defp validate_resumable(run_id, phase_id) do
    snapshot = ProjectionStore.snapshot()

    with {:ok, run} <- existing_run(snapshot, run_id),
         :ok <- active_run(run),
         :ok <- known_phase(run, phase_id),
         :ok <- interrupted_phase(snapshot, run_id, phase_id) do
      :ok
    end
  end

  defp existing_run(snapshot, run_id) do
    case get_in(snapshot, [:runs, run_id]) do
      nil -> {:error, {:not_found, :run}}
      run -> {:ok, run}
    end
  end

  defp active_run(%{status: "in_progress"}), do: :ok
  defp active_run(%{status: status}), do: {:error, {:conflict, {:run_not_active, status}}}

  defp known_phase(run, phase_id) do
    known? =
      Map.get(run, :current_phase) == phase_id ||
        Map.has_key?(Map.get(run, :phase_status, %{}), phase_id) ||
        phase_id in Map.get(run, :phase_order, [])

    if known?, do: :ok, else: {:error, {:not_found, :phase}}
  end

  defp interrupted_phase(snapshot, run_id, phase_id) do
    recovery_events = get_in(snapshot, [:interactive_recovery, run_id]) || []

    last_phase_event =
      recovery_events
      |> Enum.filter(&(&1.phase_id == phase_id))
      |> List.last()

    case last_phase_event do
      %{event_type: "HumanInterruptionRecorded"} -> :ok
      _ -> {:error, {:conflict, :phase_not_interrupted}}
    end
  end

  defp attach_target?(attach) when is_map(attach) do
    Enum.any?([:session_path, :session_id, :stream_url, :pty], &present?(Map.get(attach, &1)))
  end

  defp attach_target?(_), do: false

  defp attach_mode(worker) do
    attach = Map.get(worker, :attach, %{})

    cond do
      present?(Map.get(attach, :pty)) -> "interactive"
      present?(Map.get(attach, :session_path)) -> "interactive"
      present?(Map.get(worker, :session_id)) -> "interactive"
      present?(Map.get(attach, :stream_url)) -> "streaming"
      true -> "streaming"
    end
  end

  defp unsupported_reason(run, nil) when is_map(run),
    do: "no worker heartbeat with attach metadata"

  defp unsupported_reason(nil, _worker), do: "run not found"

  defp unsupported_reason(run, worker) when is_map(run) do
    cond do
      unsupported_terminal?(run) ->
        "run is #{Map.get(run, :status)}"

      Map.get(run, :adapter, "pi_sdk") != "pi_sdk" ->
        "provider #{Map.get(run, :adapter)} does not support attach"

      not recent_worker?(worker) ->
        "worker attach metadata is stale"

      true ->
        "worker did not expose an attach or session identifier"
    end
  end

  defp unsupported_terminal?(run),
    do: MapSet.member?(@unsupported_terminal_statuses, Map.get(run, :status))

  defp recent_worker?(worker) when is_map(worker) do
    observed_at = Map.get(worker, :observed_at)

    with %DateTime{} <- observed_at,
         diff <- DateTime.diff(DateTime.utc_now(), observed_at, :second) do
      diff <= @recent_attach_window_seconds
    else
      _ -> false
    end
  end

  defp recent_worker?(_worker), do: false

  defp alternatives(run_id) do
    [
      "foreman run show #{run_id}",
      "foreman debug #{run_id}",
      "foreman logs #{run_id}",
      "foreman run --resume"
    ]
  end

  defp append(event_type, payload, idempotency_key \\ nil) do
    payload = Map.put(payload, :observed_at, DateTime.utc_now())

    idempotency_key =
      idempotency_key || "#{event_type}:#{payload.run_id}:#{System.unique_integer([:positive])}"

    case EventStore.append(%{
           stream_id: "attach:#{payload.run_id}",
           event_type: event_type,
           payload: payload,
           metadata: %{
             correlation_id: payload.run_id,
             idempotency_key: idempotency_key
           }
         }) do
      {:ok, event} ->
        {:ok, %{event: event, projection: ProjectionStore.snapshot(), result: payload}}

      {:error, {:duplicate_idempotency_key, ^idempotency_key}} ->
        snapshot = ProjectionStore.snapshot()
        existing = duplicate_payload(payload.run_id, idempotency_key) || payload
        {:ok, %{event: nil, projection: snapshot, result: existing}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp duplicate_payload(run_id, idempotency_key) do
    "attach:#{run_id}"
    |> EventStore.stream()
    |> Enum.find(&(Map.get(&1.metadata, :idempotency_key) == idempotency_key))
    |> case do
      nil -> nil
      event -> Map.put(event.payload, :event_type, event.event_type)
    end
  end

  defp attach_idempotency_key(event_type, run_id, worker_id),
    do: "#{event_type}:#{run_id}:#{worker_id || "default"}"

  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}
  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value) and value != false
end
