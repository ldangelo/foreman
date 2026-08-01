defmodule ForemanServer.Aggregates.Scheduler do
  @moduledoc "Scheduler/capacity aggregate: records auditable scheduling decisions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state, do: %{claims: %{}, skips: %{}, last_tick: nil, fire_intent: nil}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "SchedulerTicked" ->
        Map.put(state, :last_tick, payload)

      "SchedulerTaskClaimed" ->
        put_in(state, [:claims, Aggregate.get(payload, :task_id)], payload)

      "SchedulerTaskSkipped" ->
        put_in(state, [:skips, Aggregate.get(payload, :task_id)], payload)

      "ScheduledFireRecorded" ->
        Map.put(state, :fire_intent, Map.put(payload, :status, "recorded"))

      "ScheduledFireConfirmed" ->
        Map.put(state, :fire_intent, Map.put(payload, :status, "confirmed"))

      "SchedulerIntentStale" ->
        Map.put(state, :fire_intent, Map.put(payload, :status, "stale"))

      "ScheduledFireSkipped" ->
        Map.put(state, :fire_intent, Map.put(payload, :status, "skipped"))

      _ ->
        state
    end
  end

  @impl true
  def handle_command(_state, %{type: "scheduler.tick", payload: payload}) do
    project_id = Aggregate.get(payload, :project_id, "global")

    {:ok,
     %{
       stream_id: "scheduler:#{project_id}",
       event_type: "SchedulerTicked",
       payload: Map.put_new(payload, :project_id, project_id)
     }}
  end

  def handle_command(state, %{type: "scheduler.claim", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- reject_duplicate_claim(state, task_id) do
      project_id = Aggregate.get(payload, :project_id, "global")

      {:ok,
       %{
         stream_id: "scheduler:#{project_id}",
         event_type: "SchedulerTaskClaimed",
         payload: Map.merge(payload, %{project_id: project_id, task_id: task_id})
       }}
    end
  end

  def handle_command(_state, %{type: "scheduler.skip", payload: payload}) do
    with {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id) do
      project_id = Aggregate.get(payload, :project_id, "global")

      {:ok,
       %{
         stream_id: "scheduler:#{project_id}",
         event_type: "SchedulerTaskSkipped",
         payload: Map.merge(payload, %{project_id: project_id, task_id: task_id})
       }}
    end
  end

  def handle_command(state, %{type: "scheduler.fire.record", payload: payload}) do
    with {:ok, fire_id} <- Aggregate.required_binary(Aggregate.get(payload, :fire_id), :fire_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         :ok <- allow_record_fire(state) do
      attempt = next_attempt(state, payload)

      {:ok,
       %{
         stream_id: fire_stream_id(fire_id),
         event_type: "ScheduledFireRecorded",
         payload:
           payload
           |> Map.put(:fire_id, fire_id)
           |> Map.put(:run_id, run_id)
           |> Map.put(:task_id, task_id)
           |> Map.put(:attempt, attempt)
       }}
    end
  end

  def handle_command(state, %{type: "scheduler.fire.confirm", payload: payload}) do
    with {:ok, fire_id} <- Aggregate.required_binary(Aggregate.get(payload, :fire_id), :fire_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_pending_fire(state, fire_id) do
      {:ok,
       %{
         stream_id: fire_stream_id(fire_id),
         event_type: "ScheduledFireConfirmed",
         payload:
           payload
           |> Map.put(:fire_id, fire_id)
           |> Map.put(:run_id, run_id)
           |> Map.put_new(:attempt, current_attempt(state))
       }}
    end
  end

  def handle_command(state, %{type: "scheduler.intent.stale", payload: payload}) do
    with {:ok, fire_id} <- Aggregate.required_binary(Aggregate.get(payload, :fire_id), :fire_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_pending_fire(state, fire_id) do
      {:ok,
       %{
         stream_id: fire_stream_id(fire_id),
         event_type: "SchedulerIntentStale",
         payload:
           payload
           |> Map.put(:fire_id, fire_id)
           |> Map.put(:run_id, run_id)
           |> Map.put_new(:attempt, current_attempt(state))
       }}
    end
  end

  def handle_command(state, %{type: "scheduler.fire.skip", payload: payload}) do
    with {:ok, fire_id} <- Aggregate.required_binary(Aggregate.get(payload, :fire_id), :fire_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_skippable_fire(state, fire_id) do
      {:ok,
       %{
         stream_id: fire_stream_id(fire_id),
         event_type: "ScheduledFireSkipped",
         payload:
           payload
           |> Map.put(:fire_id, fire_id)
           |> Map.put(:run_id, run_id)
           |> Map.put_new(:attempt, current_attempt(state))
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp reject_duplicate_claim(%{claims: claims}, task_id) do
    if Map.has_key?(claims, task_id), do: {:error, {:already_claimed, task_id}}, else: :ok
  end

  defp allow_record_fire(%{fire_intent: %{status: "confirmed"}}),
    do: {:error, {:fire_already_confirmed, :confirmed}}

  defp allow_record_fire(%{fire_intent: %{status: "skipped"}}),
    do: {:error, {:fire_already_skipped, :skipped}}

  defp allow_record_fire(_state), do: :ok

  defp require_pending_fire(%{fire_intent: %{fire_id: fire_id, status: status}}, fire_id)
       when status in ["recorded", "stale"],
       do: :ok

  defp require_pending_fire(%{fire_intent: %{status: status}}, _fire_id),
    do: {:error, {:no_pending_fire_intent, status}}

  defp require_pending_fire(_state, fire_id),
    do: {:error, {:fire_intent_not_found, fire_id}}

  defp require_skippable_fire(state, fire_id), do: require_pending_fire(state, fire_id)

  defp current_attempt(%{fire_intent: %{attempt: attempt}}) when is_integer(attempt) and attempt > 0,
    do: attempt

  defp current_attempt(_state), do: 0

  defp next_attempt(_state, %{attempt: attempt}) when is_integer(attempt) and attempt > 0,
    do: attempt

  defp next_attempt(state, _payload), do: current_attempt(state) + 1

  defp fire_stream_id(fire_id), do: "scheduler_fire:#{fire_id}"
end
