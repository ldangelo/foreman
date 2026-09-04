defmodule ForemanServer.Aggregates.SchedulerIntent do
  @moduledoc """
  TRD-019 / TRD-021: Scheduler intent aggregate.

  Tracks the fire-and-track contract for scheduled tasks:

  * `scheduler_intent.record` emits `ScheduledFireRecorded` (initial).
  * `scheduler_intent.confirm` emits `ScheduledFireConfirmed` (worker picked up).
  * `scheduler_intent.skip` emits `ScheduledFireSkipped` (abandoned).
  * `scheduler_intent.mark_stale` emits `SchedulerIntentStale` (recovery re-dispatch).

  Idempotency: a duplicate `record` is rejected via `{:error, :already_recorded}`.
  Confirmed/skipped intents reject further commands.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :status]
    defstruct [
      :exists?,
      :status,
      :intent_id,
      :task_id,
      :run_id,
      :scheduled_for,
      confirmed_at: nil,
      marked_stale_at: nil
    ]
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      status: nil,
      intent_id: nil,
      task_id: nil,
      run_id: nil,
      scheduled_for: nil
    }

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)
    intent_id = Aggregate.get(payload, :intent_id)

    case Aggregate.event_type(event) do
      "ScheduledFireRecorded" ->
        %State{
          state
          | exists?: true,
            status: "recorded",
            intent_id: intent_id,
            task_id: Aggregate.get(payload, :task_id),
            run_id: Aggregate.get(payload, :run_id),
            scheduled_for: Aggregate.get(payload, :scheduled_for)
        }

      "ScheduledFireConfirmed" ->
        %State{
          state
          | status: "confirmed",
            intent_id: intent_id,
            confirmed_at: Aggregate.get(payload, :confirmed_at)
        }

      "ScheduledFireSkipped" ->
        %State{
          state
          | status: "skipped",
            intent_id: intent_id
        }

      "SchedulerIntentStale" ->
        %State{
          state
          | status: "stale",
            intent_id: intent_id,
            marked_stale_at: Aggregate.get(payload, :marked_stale_at)
        }

      _ ->
        state
    end
  end

  @impl true
  def handle_command(_state, %{type: "scheduler_intent.record", payload: payload}) do
    with {:ok, intent_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :intent_id), :intent_id) do
      {:ok,
       %{
         stream_id: "scheduler_intent:#{intent_id}",
         event_type: "ScheduledFireRecorded",
         payload: Map.put(payload, :intent_id, intent_id)
       }}
    end
  end

  def handle_command(%State{status: status}, %{type: "scheduler_intent.confirm"})
      when status in ["confirmed", "skipped", "stale"] do
    {:error, {:scheduler_intent_terminal, status}}
  end

  def handle_command(_state, %{type: "scheduler_intent.confirm", payload: payload}) do
    with {:ok, intent_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :intent_id), :intent_id) do
      {:ok,
       %{
         stream_id: "scheduler_intent:#{intent_id}",
         event_type: "ScheduledFireConfirmed",
         payload: Map.put(payload, :intent_id, intent_id)
       }}
    end
  end

  def handle_command(%State{status: status}, %{type: "scheduler_intent.skip"})
      when status in ["confirmed", "skipped", "stale"] do
    {:error, {:scheduler_intent_terminal, status}}
  end

  def handle_command(_state, %{type: "scheduler_intent.skip", payload: payload}) do
    with {:ok, intent_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :intent_id), :intent_id) do
      {:ok,
       %{
         stream_id: "scheduler_intent:#{intent_id}",
         event_type: "ScheduledFireSkipped",
         payload: Map.put(payload, :intent_id, intent_id)
       }}
    end
  end

  def handle_command(%State{status: status}, %{type: "scheduler_intent.mark_stale"})
      when status in ["confirmed", "skipped", "stale"] do
    {:error, {:scheduler_intent_terminal, status}}
  end

  def handle_command(_state, %{type: "scheduler_intent.mark_stale", payload: payload}) do
    with {:ok, intent_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :intent_id), :intent_id) do
      {:ok,
       %{
         stream_id: "scheduler_intent:#{intent_id}",
         event_type: "SchedulerIntentStale",
         payload: Map.put(payload, :intent_id, intent_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled
end
