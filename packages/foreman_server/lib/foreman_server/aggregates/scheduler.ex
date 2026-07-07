defmodule ForemanServer.Aggregates.Scheduler do
  @moduledoc "Scheduler/capacity aggregate: records auditable scheduling decisions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state, do: %{claims: %{}, skips: %{}, last_tick: nil}

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

  def handle_command(_state, _command), do: :unhandled

  defp reject_duplicate_claim(%{claims: claims}, task_id) do
    if Map.has_key?(claims, task_id), do: {:error, {:already_claimed, task_id}}, else: :ok
  end
end
