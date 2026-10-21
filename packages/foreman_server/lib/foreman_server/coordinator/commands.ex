defmodule ForemanServer.Coordinator.Commands do
  @moduledoc """
  Builders and dispatchers for the coordinator's own stream commands
  (`coordinator.append`, `.turn.*`, `.action.record`). Every command id is a pure
  function of its inputs, so repeating a step after a crash appends nothing
  twice (`CommandRouter` derives the event id from the command id).
  """

  alias ForemanServer.Aggregates.Coordinator, as: Aggregate
  alias ForemanServer.Coordinator.{Dispatch, Redact}

  @doc "Append a coordinator/system message. `message_id` MUST be deterministic."
  @spec append(module(), String.t(), String.t(), map()) :: Dispatch.result()
  def append(gateway, project_id, message_id, attrs) do
    text = Redact.text(project_id, Map.fetch!(attrs, :text))

    payload =
      attrs
      |> Map.take([:role, :kind, :thread_ref, :report_key, :turn_id, :suppressed])
      |> Map.merge(%{project_id: project_id, message_id: message_id, text: text})

    send_command(
      gateway,
      project_id,
      "coordinator.append",
      "coordinator:append:#{project_id}:#{message_id}",
      payload
    )
  end

  @spec turn_start(module(), String.t(), String.t(), pos_integer(), [String.t()]) ::
          Dispatch.result()
  def turn_start(gateway, project_id, turn_id, attempt, trigger_ids) do
    send_command(
      gateway,
      project_id,
      "coordinator.turn.start",
      "coordinator:turn:#{project_id}:#{turn_id}",
      %{
        project_id: project_id,
        turn_id: turn_id,
        attempt: attempt,
        trigger_message_ids: trigger_ids
      }
    )
  end

  @spec turn_complete(module(), String.t(), String.t(), String.t(), String.t()) ::
          Dispatch.result()
  def turn_complete(gateway, project_id, turn_id, cursor_message_id, outcome) do
    send_command(
      gateway,
      project_id,
      "coordinator.turn.complete",
      "coordinator:turn-complete:#{project_id}:#{turn_id}",
      %{
        project_id: project_id,
        turn_id: turn_id,
        cursor_message_id: cursor_message_id,
        outcome: outcome
      }
    )
  end

  @spec turn_fail(
          module(),
          String.t(),
          String.t(),
          pos_integer(),
          atom() | String.t(),
          String.t(),
          pos_integer()
        ) ::
          Dispatch.result()
  def turn_fail(gateway, project_id, turn_id, attempt, code, message, unhealthy_after) do
    send_command(
      gateway,
      project_id,
      "coordinator.turn.fail",
      "coordinator:turn-fail:#{project_id}:#{turn_id}",
      %{
        project_id: project_id,
        turn_id: turn_id,
        attempt: attempt,
        error_code: to_string(code),
        message: message |> to_string() |> String.slice(0, 500),
        unhealthy_after: unhealthy_after
      }
    )
  end

  @spec record_action(module(), String.t(), String.t(), map()) :: Dispatch.result()
  def record_action(gateway, project_id, turn_id, %{action_id: action_id, status: status} = attrs) do
    payload =
      attrs
      |> Map.take([:action_id, :kind, :params, :status, :reason, :result_ref])
      |> Map.merge(%{project_id: project_id, turn_id: turn_id})

    send_command(
      gateway,
      project_id,
      "coordinator.action.record",
      "coordinator:action:#{project_id}:#{action_id}:#{status}",
      payload
    )
  end

  defp send_command(gateway, project_id, type, command_id, payload) do
    Dispatch.system(gateway, %{
      command_id: command_id,
      aggregate_id: Aggregate.stream_id(project_id),
      type: type,
      payload: payload
    })
  end
end
