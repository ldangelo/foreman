defmodule ForemanServer.AttachBridge do
  @moduledoc "Event-backed attach and interactive recovery bridge for worker sessions."

  alias ForemanServer.{EventStore, ProjectionStore}

  @terminal_statuses MapSet.new(["completed", "failed", "blocked"])

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
          append("AttachRequested", %{
            run_id: run_id,
            phase_id: worker.phase_id,
            worker_id: worker.worker_id,
            adapter: Map.get(run, :adapter, "pi_sdk"),
            mode: attach_mode(worker),
            session_id: Map.get(worker, :session_id),
            attach: Map.get(worker, :attach, %{}),
            alternatives: alternatives(run_id),
            status: "ready"
          })

        true ->
          append("AttachUnsupported", %{
            run_id: run_id,
            worker_id: fetch(input, :worker_id),
            adapter: Map.get(run, :adapter),
            reason: unsupported_reason(run, worker),
            alternatives: alternatives(run_id),
            status: "unsupported"
          })
      end
    end
  end

  @spec interrupt_phase(map()) :: result()
  def interrupt_phase(input) when is_map(input) do
    with {:ok, run_id} <- required_binary(fetch(input, :run_id), :run_id),
         {:ok, phase_id} <- required_binary(fetch(input, :phase_id), :phase_id) do
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
         {:ok, next_action} <- required_binary(fetch(input, :next_action), :next_action) do
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
      not terminal?(run) &&
      (present?(Map.get(worker, :session_id)) || attach_target?(Map.get(worker, :attach, %{})))
  end

  defp attach_supported?(_run, _worker), do: false

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

  defp unsupported_reason(run, _worker) when is_map(run) do
    cond do
      terminal?(run) ->
        "run is #{Map.get(run, :status)}"

      Map.get(run, :adapter, "pi_sdk") != "pi_sdk" ->
        "provider #{Map.get(run, :adapter)} does not support attach"

      true ->
        "worker did not expose an attach or session identifier"
    end
  end

  defp terminal?(run), do: MapSet.member?(@terminal_statuses, Map.get(run, :status))

  defp alternatives(run_id) do
    [
      "foreman run show #{run_id}",
      "foreman debug #{run_id}",
      "foreman logs #{run_id}",
      "foreman run --resume"
    ]
  end

  defp append(event_type, payload) do
    payload = Map.put(payload, :observed_at, DateTime.utc_now())

    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "attach:#{payload.run_id}",
             event_type: event_type,
             payload: payload,
             metadata: %{
               correlation_id: payload.run_id,
               idempotency_key:
                 "#{event_type}:#{payload.run_id}:#{System.unique_integer([:positive])}"
             }
           }) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), result: payload}}
    end
  end

  defp fetch(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}
  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value) and value != false
end
