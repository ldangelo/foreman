defmodule ForemanServer.Coordinator.Commands do
  @moduledoc """
  Builders and dispatchers for the coordinator's own stream commands
  (`coordinator.append`, `.turn.*`, `.action.record`, `.usage.record`). Every command
  id is a pure function of its inputs, so repeating a step after a crash appends
  nothing twice (`CommandRouter` derives the event id from the command id).
  """

  alias ForemanServer.Aggregates.Coordinator, as: Aggregate
  alias ForemanServer.Coordinator.{Dispatch, Redact}
  alias ForemanServer.Usage

  @doc "Append a coordinator/system message. `message_id` MUST be deterministic."
  @spec append(module(), String.t(), String.t(), map()) :: Dispatch.result()
  def append(gateway, project_id, message_id, attrs) do
    text = project_id |> Redact.text(Map.fetch!(attrs, :text)) |> clip()

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

  @doc """
  Record the provider usage of the open turn (`coordinator.usage.record`).

  The command id comes from the turn id alone, so replaying a turn appends
  nothing twice. `provider` is the provider's name (`"pi"`), `model` may be
  `nil` (the project pins none). The aggregate refuses an all-nil usage.
  """
  @spec record_usage(module(), String.t(), String.t(), String.t(), String.t() | nil, Usage.t()) ::
          Dispatch.result()
  def record_usage(gateway, project_id, turn_id, provider, model, %Usage{} = usage) do
    payload =
      usage
      |> Usage.to_event_fields()
      |> Map.merge(%{project_id: project_id, turn_id: turn_id, provider: provider, model: model})

    send_command(
      gateway,
      project_id,
      "coordinator.usage.record",
      "coordinator:usage:#{project_id}:#{turn_id}",
      payload
    )
  end

  # The aggregate refuses text over the message cap; a long model reply must be
  # shortened (visibly), never lost.
  @marker "\n[truncated]"

  defp clip(text) do
    max = Aggregate.max_message_bytes()

    if byte_size(text) <= max do
      text
    else
      keep = max - byte_size(@marker)
      text |> binary_part(0, keep) |> trim_partial_codepoint() |> Kernel.<>(@marker)
    end
  end

  defp trim_partial_codepoint(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(0, byte_size(binary) - 1) |> trim_partial_codepoint()
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
