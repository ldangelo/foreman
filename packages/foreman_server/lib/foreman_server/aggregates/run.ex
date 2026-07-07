defmodule ForemanServer.Aggregates.Run do
  @moduledoc "Run aggregate: validates run lifecycle commands and folds legacy run/worker phase events."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @terminal_statuses MapSet.new(["completed", "failed", "blocked", "cancelled", "deleted"])

  @impl true
  def initial_state,
    do: %{exists?: false, status: nil, phase_status: %{}, worker_status: %{}, retry_history: []}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "RunStarted" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "in_progress")
        |> Map.put_new(:phase_status, %{})
        |> Map.put_new(:worker_status, %{})
        |> Map.put_new(:retry_history, [])

      "RunUpdated" ->
        state |> Map.merge(payload) |> Map.put(:exists?, true)

      "RunCompleted" ->
        state |> Map.merge(payload) |> Map.put(:status, "completed") |> Map.put(:terminal?, true)

      "RunFailed" ->
        state |> Map.merge(payload) |> Map.put(:status, "failed") |> Map.put(:terminal?, true)

      "RunBlocked" ->
        state |> Map.merge(payload) |> Map.put(:status, "blocked") |> Map.put(:terminal?, true)

      "RunDeleted" ->
        state |> Map.put(:status, "deleted") |> Map.put(:terminal?, true)

      "PhaseStarted" ->
        put_phase(state, payload, "in_progress")

      "PhaseCompleted" ->
        put_phase(state, payload, "completed")

      "PhaseFailed" ->
        put_phase(state, payload, "failed")

      "PhaseTimedOut" ->
        put_phase(state, payload, "timed_out")

      "PhaseRetried" ->
        put_phase(state, payload, "retrying")

      "WorkerStarted" ->
        put_worker(state, payload, "running")

      "WorkerHeartbeat" ->
        put_worker(state, payload, "heartbeat")

      "ToolCallFinished" ->
        put_worker(state, payload, "running")

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "run.start", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_absent(state, run_id) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunStarted",
         payload: payload |> Map.put(:run_id, run_id) |> Map.put(:status, "in_progress")
       }}
    end
  end

  def handle_command(state, %{type: "run.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunUpdated",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> drop_lifecycle_fields()
       }}
    end
  end

  def handle_command(state, %{type: "run.delete", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunDeleted",
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in ["run.complete", "run.fail", "run.block"] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      event_type =
        %{
          "run.complete" => "RunCompleted",
          "run.fail" => "RunFailed",
          "run.block" => "RunBlocked"
        }[type]

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: event_type,
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp put_phase(state, payload, status) do
    case Aggregate.get(payload, :phase_id) do
      phase_id when is_binary(phase_id) and phase_id != "" ->
        state
        |> Map.put(:current_phase, phase_id)
        |> update_in([:phase_status], &Map.put(&1 || %{}, phase_id, status))

      _ ->
        state
    end
  end

  defp put_worker(state, payload, status) do
    case Aggregate.get(payload, :worker_id) do
      worker_id when is_binary(worker_id) and worker_id != "" ->
        update_in(state, [:worker_status], &Map.put(&1 || %{}, worker_id, status))

      _ ->
        state
    end
  end

  defp drop_lifecycle_fields(payload) do
    Map.drop(payload, [:status, "status", :terminal?, "terminal?", :completed_at, "completed_at", :failed_at, "failed_at", :blocked_at, "blocked_at"])
  end

  defp require_absent(%{exists?: true}, run_id), do: {:error, {:already_exists, :run, run_id}}
  defp require_absent(_state, _run_id), do: :ok

  defp require_exists(%{exists?: true}, _run_id), do: :ok
  defp require_exists(_state, run_id), do: {:error, {:not_found, :run, run_id}}

  defp reject_terminal_mutation(%{status: status}) do
    if MapSet.member?(@terminal_statuses, status),
      do: {:error, {:run_terminal, status}},
      else: :ok
  end
end
