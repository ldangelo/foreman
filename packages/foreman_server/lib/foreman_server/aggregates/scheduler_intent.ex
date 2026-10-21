defmodule ForemanServer.Aggregates.SchedulerIntent do
  @moduledoc """
  TRD-019 / TRD-021: Scheduler intent aggregate.

  Tracks the fire-and-track contract for scheduled tasks:

  * `scheduler_intent.record` emits `ScheduledFireRecorded` (initial).
  * `scheduler_intent.confirm` emits `ScheduledFireConfirmed` (worker picked up).
  * `scheduler_intent.skip` emits `ScheduledFireSkipped` (abandoned).
  * `scheduler_intent.mark_stale` emits `SchedulerIntentStale` (recovery re-dispatch).

  Idempotency: `CommandRouter` dedupes an identical retry (same `command_id`)
  before this aggregate runs. A `record` under a DIFFERENT command id for an
  intent that already exists is `{:error, {:scheduler_intent_exists, intent_id}}`.
  Confirmed, skipped and stale intents reject further `confirm`/`skip`/
  `mark_stale` with `{:error, {:scheduler_intent_terminal, status}}`.

  Event payloads are built from the typed event structs (enforced keys,
  declared fields only), so unknown payload keys are dropped, not persisted.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  alias ForemanServer.Events.{
    ScheduledFireConfirmed,
    ScheduledFireRecorded,
    ScheduledFireSkipped,
    SchedulerIntentStale
  }

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
  def handle_command(%State{exists?: true, intent_id: existing}, %{
        type: "scheduler_intent.record"
      }),
      do: {:error, {:scheduler_intent_exists, existing}}

  def handle_command(%State{}, %{type: "scheduler_intent.record", payload: payload}),
    do: emit(ScheduledFireRecorded, "ScheduledFireRecorded", payload)

  def handle_command(%State{status: status}, %{type: type})
      when type in [
             "scheduler_intent.confirm",
             "scheduler_intent.skip",
             "scheduler_intent.mark_stale"
           ] and
             status in ["confirmed", "skipped", "stale"] do
    {:error, {:scheduler_intent_terminal, status}}
  end

  def handle_command(%State{}, %{type: "scheduler_intent.confirm", payload: payload}),
    do: emit(ScheduledFireConfirmed, "ScheduledFireConfirmed", payload)

  def handle_command(%State{}, %{type: "scheduler_intent.skip", payload: payload}),
    do: emit(ScheduledFireSkipped, "ScheduledFireSkipped", payload)

  def handle_command(%State{}, %{type: "scheduler_intent.mark_stale", payload: payload}),
    do: emit(SchedulerIntentStale, "SchedulerIntentStale", payload)

  def handle_command(_state, _command), do: :unhandled

  defp emit(module, event_type, payload) do
    with {:ok, intent_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :intent_id), :intent_id) do
      fields =
        module.__struct__()
        |> Map.from_struct()
        |> Map.new(fn {key, _default} -> {key, Aggregate.get(payload, key)} end)
        |> Map.put(:intent_id, intent_id)

      {:ok,
       %{
         stream_id: "scheduler_intent:#{intent_id}",
         event_type: event_type,
         payload: module |> struct!(fields) |> Map.from_struct()
       }}
    end
  end
end
