defmodule ForemanServer.Coordinator.Conversation do
  @moduledoc """
  Pure read model of one project's coordinator conversation, folded by
  `ForemanServer.ProjectionStore` from the `coordinator:<project_id>` stream.

  `seq` is a per-project counter assigned during the fold, so it is identical
  after a rebuild from the event log. Messages are plain atom-keyed maps; the
  newest `@max_messages` are kept and `truncated_before_seq` says where the
  window starts. Recorded actions are kept (bounded) so the Executor can tell
  what already happened and `approve_proposed` can find earlier proposals.

  The fold never raises on a malformed payload: a field of the wrong type
  leaves the state untouched.
  """

  @max_messages 1_000
  @max_turns 50
  @max_actions 500
  @default_unhealthy_after 3

  @type message :: %{
          seq: pos_integer(),
          message_id: String.t(),
          role: String.t(),
          kind: String.t(),
          text: String.t(),
          source: String.t() | nil,
          thread_ref: map() | nil,
          report_key: String.t() | nil,
          turn_id: String.t() | nil,
          suppressed: boolean(),
          at: String.t() | nil
        }

  @type action :: %{
          action_id: String.t(),
          turn_id: String.t(),
          kind: String.t(),
          status: String.t(),
          params: map(),
          reason: String.t() | nil,
          result_ref: map() | nil,
          at: String.t() | nil
        }

  @type t :: %{
          messages: [message()],
          next_seq: pos_integer(),
          truncated_before_seq: pos_integer() | nil,
          turns: %{String.t() => map()},
          turn_order: [String.t()],
          actions: %{String.t() => action()},
          action_order: [String.t()],
          open_turn: map() | nil,
          last_cursor_seq: non_neg_integer(),
          consecutive_failures: non_neg_integer(),
          unhealthy_after: pos_integer(),
          unhealthy?: boolean(),
          last_error: map() | nil,
          last_activity_at: String.t() | nil
        }

  @doc "An empty conversation."
  @spec new() :: t()
  def new do
    %{
      messages: [],
      next_seq: 1,
      truncated_before_seq: nil,
      turns: %{},
      turn_order: [],
      actions: %{},
      action_order: [],
      open_turn: nil,
      last_cursor_seq: 0,
      consecutive_failures: 0,
      unhealthy_after: @default_unhealthy_after,
      unhealthy?: false,
      last_error: nil,
      last_activity_at: nil
    }
  end

  @doc "Fold one event (string event type, atom- or string-keyed payload) into the conversation."
  @spec apply_event(t(), String.t(), map()) :: t()
  def apply_event(conv, "CoordinatorMessageAppended", payload) do
    with {:ok, id} <- text_field(payload, :message_id),
         {:ok, role} <- text_field(payload, :role),
         {:ok, kind} <- text_field(payload, :kind),
         {:ok, text} <- text_field(payload, :text),
         false <- Enum.any?(conv.messages, &(&1.message_id == id)) do
      message = %{
        seq: conv.next_seq,
        message_id: id,
        role: role,
        kind: kind,
        text: text,
        source: opt_text(payload, :source),
        thread_ref: opt_map(payload, :thread_ref),
        report_key: opt_text(payload, :report_key),
        turn_id: opt_text(payload, :turn_id),
        suppressed: field(payload, :suppressed) == true,
        at: opt_text(payload, :at)
      }

      trim(%{
        conv
        | messages: conv.messages ++ [message],
          next_seq: conv.next_seq + 1,
          last_activity_at: message.at || conv.last_activity_at
      })
    else
      _ -> conv
    end
  end

  def apply_event(conv, "CoordinatorTurnStarted", payload) do
    with {:ok, turn_id} <- text_field(payload, :turn_id) do
      turn = %{
        turn_id: turn_id,
        attempt: int_field(payload, :attempt, 1),
        trigger_message_ids: list_field(payload, :trigger_message_ids),
        started_at: opt_text(payload, :at),
        status: "open"
      }

      conv
      |> put_turn(turn)
      |> Map.put(:open_turn, turn)
      |> touch(payload)
    else
      _ -> conv
    end
  end

  def apply_event(conv, "CoordinatorActionRecorded", payload) do
    with {:ok, action_id} <- text_field(payload, :action_id),
         {:ok, turn_id} <- text_field(payload, :turn_id),
         {:ok, kind} <- text_field(payload, :kind),
         {:ok, status} <- text_field(payload, :status) do
      action = %{
        action_id: action_id,
        turn_id: turn_id,
        kind: kind,
        status: status,
        params: opt_map(payload, :params) || %{},
        reason: opt_text(payload, :reason),
        result_ref: opt_map(payload, :result_ref),
        at: opt_text(payload, :at)
      }

      order = [action_id | List.delete(conv.action_order, action_id)]
      {kept, dropped} = Enum.split(order, @max_actions)

      %{
        conv
        | actions: conv.actions |> Map.put(action_id, action) |> Map.drop(dropped),
          action_order: kept
      }
      |> touch(payload)
    else
      _ -> conv
    end
  end

  def apply_event(conv, "CoordinatorTurnCompleted", payload) do
    with {:ok, turn_id} <- text_field(payload, :turn_id),
         {:ok, cursor_id} <- text_field(payload, :cursor_message_id) do
      cursor_seq =
        case Enum.find(conv.messages, &(&1.message_id == cursor_id)) do
          %{seq: seq} -> max(seq, conv.last_cursor_seq)
          nil -> conv.last_cursor_seq
        end

      conv
      |> close_turn(turn_id, "completed")
      |> Map.merge(%{
        last_cursor_seq: cursor_seq,
        consecutive_failures: 0,
        unhealthy?: false,
        last_error: nil
      })
      |> touch(payload)
    else
      _ -> conv
    end
  end

  def apply_event(conv, "CoordinatorTurnFailed", payload) do
    with {:ok, turn_id} <- text_field(payload, :turn_id) do
      failures = conv.consecutive_failures + 1
      threshold = int_field(payload, :unhealthy_after, @default_unhealthy_after)

      conv
      |> close_turn(turn_id, "failed")
      |> Map.merge(%{
        consecutive_failures: failures,
        unhealthy_after: threshold,
        unhealthy?: failures >= threshold,
        last_error: %{
          turn_id: turn_id,
          code: opt_text(payload, :error_code),
          message: opt_text(payload, :message),
          at: opt_text(payload, :at)
        }
      })
      |> touch(payload)
    else
      _ -> conv
    end
  end

  def apply_event(conv, "CoordinatorRestarted", payload) do
    %{conv | open_turn: nil, consecutive_failures: 0, unhealthy?: false, last_error: nil}
    |> touch(payload)
  end

  def apply_event(conv, _event_type, _payload), do: conv

  @doc """
  True when a message should start a coordinator turn. The `/setup` command
  (`SetupProposal.request?/1`) does not: `SetupProposer` answers it without a model.
  """
  @spec trigger?(message()) :: boolean()
  def trigger?(%{role: "operator"} = message),
    do: not ForemanServer.Coordinator.SetupProposal.request?(message)

  def trigger?(%{role: role, kind: "report", suppressed: false}) when role in ["system", "agent"],
    do: true

  def trigger?(_message), do: false

  @doc "Trigger messages not yet consumed by a completed turn, oldest first."
  @spec pending(t()) :: [message()]
  def pending(conv) do
    Enum.filter(conv.messages, &(&1.seq > conv.last_cursor_seq and trigger?(&1)))
  end

  @doc "Health status: `:unhealthy`, `:turn_open` or `:idle`."
  @spec status(t()) :: :idle | :turn_open | :unhealthy
  def status(%{unhealthy?: true}), do: :unhealthy
  def status(%{open_turn: turn}) when is_map(turn), do: :turn_open
  def status(_conv), do: :idle

  @doc "Messages after `after_seq`, at most `limit`, with the paging envelope."
  @spec page(t(), non_neg_integer(), pos_integer()) :: map()
  def page(conv, after_seq, limit) do
    newer = Enum.filter(conv.messages, &(&1.seq > after_seq))
    page = Enum.take(newer, limit)

    next_cursor =
      case List.last(page) do
        %{seq: seq} -> seq
        nil -> after_seq
      end

    %{
      messages: page,
      next_cursor: next_cursor,
      has_more: length(newer) > length(page),
      truncated_before_seq: conv.truncated_before_seq
    }
  end

  # ------------------------------------------------------------------ internals

  defp trim(%{messages: messages} = conv) when length(messages) > @max_messages do
    {dropped, kept} = Enum.split(messages, length(messages) - @max_messages)
    %{conv | messages: kept, truncated_before_seq: List.last(dropped).seq + 1}
  end

  defp trim(conv), do: conv

  defp put_turn(conv, %{turn_id: id} = turn) do
    order = [id | List.delete(conv.turn_order, id)]
    {kept, dropped} = Enum.split(order, @max_turns)
    %{conv | turns: conv.turns |> Map.put(id, turn) |> Map.drop(dropped), turn_order: kept}
  end

  defp close_turn(conv, turn_id, status) do
    turns =
      case Map.fetch(conv.turns, turn_id) do
        {:ok, turn} -> Map.put(conv.turns, turn_id, %{turn | status: status})
        :error -> conv.turns
      end

    %{conv | turns: turns, open_turn: nil}
  end

  defp touch(conv, payload),
    do: %{conv | last_activity_at: opt_text(payload, :at) || conv.last_activity_at}

  defp field(payload, key) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

  defp text_field(payload, key) do
    case field(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp opt_text(payload, key) do
    case field(payload, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp opt_map(payload, key) do
    case field(payload, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp list_field(payload, key) do
    case field(payload, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp int_field(payload, key, default) do
    case field(payload, key) do
      value when is_integer(value) and value >= 1 -> value
      _ -> default
    end
  end
end
