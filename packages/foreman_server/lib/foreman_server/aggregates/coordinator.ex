defmodule ForemanServer.Aggregates.Coordinator do
  @moduledoc """
  The coordinator conversation of one project, stream `coordinator:<project_id>`.

  Commands:

    * `coordinator.message` (operator-allowed) -> `CoordinatorMessageAppended`
      with role `operator`; the operator's `message_id` is the idempotency key.
    * `coordinator.restart` (operator-allowed) -> `CoordinatorRestarted`
    * `coordinator.append` (system only) -> `CoordinatorMessageAppended` with
      role `coordinator | system | agent`; a `report_key` already seen emits
      nothing.
    * `coordinator.turn.start`, `coordinator.action.record`,
      `coordinator.turn.complete`, `coordinator.turn.fail` (system only).
    * `coordinator.usage.record` (system only) -> `CoordinatorUsageRecorded`:
      the provider usage of the open turn. It feeds the usage rollup and
      changes no conversation state (`apply_event/2` ignores it).

  A duplicate `message_id` or `report_key` is a no-op (`{:ok, nil}`). At most
  one turn is open at a time. `turn.fail` counts consecutive failures and moves
  the status to `:unhealthy` at `unhealthy_after` (default 3); `restart` and
  `turn.complete` clear the counter. `apply_event/2` ends in a catch-all so an
  event type this module does not know never crashes replay.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @sources ~w(cli http mcp dashboard system)
  @append_roles ~w(coordinator system agent)
  @append_kinds ~w(reply report notice setup_proposal)
  @action_statuses ~w(executed proposed rejected failed)
  @default_max_message_bytes 16_000
  @default_unhealthy_after 3
  @seen_cap 1_000
  @usage_counts ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens total_tokens)a

  @doc "Stream id for a project's coordinator conversation."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(project_id), do: "coordinator:" <> project_id

  @doc "Maximum bytes of one message's text."
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes do
    Application.get_env(:foreman_server, :coordinator, [])
    |> Keyword.get(:max_message_bytes, @default_max_message_bytes)
  end

  defmodule State do
    @moduledoc "Conversation state: idempotency sets, open turn and health."
    @type t :: %__MODULE__{
            seen_message_ids: MapSet.t(String.t()),
            seen_order: :queue.queue(String.t()),
            seen_report_keys: MapSet.t(String.t()),
            last_cursor_message_id: String.t() | nil,
            open_turn: %{turn_id: String.t(), attempt: pos_integer()} | nil,
            consecutive_failures: non_neg_integer(),
            status: :idle | :turn_open | :unhealthy
          }
    defstruct seen_message_ids: MapSet.new(),
              seen_order: :queue.new(),
              seen_report_keys: MapSet.new(),
              last_cursor_message_id: nil,
              open_turn: nil,
              consecutive_failures: 0,
              status: :idle
  end

  @impl true
  def initial_state, do: %State{}

  # ---------------------------------------------------------------- apply

  @impl true
  def apply_event(%State{} = state, event) do
    payload = event |> Aggregate.event_payload() |> then(&(&1 || %{}))

    case Aggregate.event_type(event) do
      "CoordinatorMessageAppended" ->
        apply_message(state, payload)

      "CoordinatorTurnStarted" ->
        apply_turn_started(state, payload)

      "CoordinatorTurnCompleted" ->
        apply_turn_completed(state, payload)

      "CoordinatorTurnFailed" ->
        apply_turn_failed(state, payload)

      "CoordinatorRestarted" ->
        %State{state | open_turn: nil, consecutive_failures: 0, status: :idle}

      _ ->
        state
    end
  end

  defp apply_message(%State{} = state, payload) do
    %State{} = state = remember_message_id(state, Aggregate.get(payload, :message_id))

    case Aggregate.get(payload, :report_key) do
      key when is_binary(key) and key != "" ->
        %State{state | seen_report_keys: MapSet.put(state.seen_report_keys, key)}

      _ ->
        state
    end
  end

  defp remember_message_id(%State{} = state, id) when is_binary(id) and id != "" do
    if MapSet.member?(state.seen_message_ids, id) do
      state
    else
      queue = :queue.in(id, state.seen_order)
      ids = MapSet.put(state.seen_message_ids, id)

      if MapSet.size(ids) > @seen_cap do
        {{:value, oldest}, queue} = :queue.out(queue)
        %State{state | seen_message_ids: MapSet.delete(ids, oldest), seen_order: queue}
      else
        %State{state | seen_message_ids: ids, seen_order: queue}
      end
    end
  end

  defp remember_message_id(%State{} = state, _id), do: state

  defp apply_turn_started(%State{} = state, payload) do
    turn = %{
      turn_id: Aggregate.get(payload, :turn_id),
      attempt: Aggregate.get(payload, :attempt) || 1
    }

    %State{state | open_turn: turn, status: :turn_open}
  end

  defp apply_turn_completed(%State{} = state, payload) do
    %State{
      state
      | open_turn: nil,
        consecutive_failures: 0,
        status: :idle,
        last_cursor_message_id: Aggregate.get(payload, :cursor_message_id)
    }
  end

  defp apply_turn_failed(%State{} = state, payload) do
    failures = state.consecutive_failures + 1
    threshold = Aggregate.get(payload, :unhealthy_after) || @default_unhealthy_after
    status = if failures >= threshold, do: :unhealthy, else: :idle
    %State{state | open_turn: nil, consecutive_failures: failures, status: status}
  end

  # --------------------------------------------------------------- commands

  @impl true
  def handle_command(%State{} = state, %{type: "coordinator.message", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, message_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :message_id), :message_id),
         {:ok, text} <- validate_text(Aggregate.get(payload, :text)),
         {:ok, source} <- validate_source(Aggregate.get(payload, :source) || "http"),
         {:ok, thread_ref} <- validate_thread_ref(Aggregate.get(payload, :thread_ref)) do
      if duplicate_message?(state, message_id) do
        {:ok, nil}
      else
        {:ok,
         message_event(project_id, %{
           message_id: message_id,
           role: "operator",
           kind: "message",
           text: text,
           source: source,
           thread_ref: thread_ref
         })}
      end
    end
  end

  def handle_command(%State{} = state, %{type: "coordinator.append", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, message_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :message_id), :message_id),
         {:ok, role} <- validate_role(Aggregate.get(payload, :role)),
         {:ok, kind} <- validate_kind(Aggregate.get(payload, :kind)),
         {:ok, text} <- validate_text(Aggregate.get(payload, :text)),
         {:ok, thread_ref} <- validate_thread_ref(Aggregate.get(payload, :thread_ref)),
         :ok <- optional_binary(payload, :report_key),
         :ok <- optional_binary(payload, :turn_id) do
      report_key = Aggregate.get(payload, :report_key)

      cond do
        duplicate_message?(state, message_id) ->
          {:ok, nil}

        is_binary(report_key) and MapSet.member?(state.seen_report_keys, report_key) ->
          {:ok, nil}

        true ->
          {:ok,
           message_event(project_id, %{
             message_id: message_id,
             role: role,
             kind: kind,
             text: text,
             source: "system",
             thread_ref: thread_ref,
             report_key: report_key,
             turn_id: Aggregate.get(payload, :turn_id),
             suppressed: Aggregate.get(payload, :suppressed) == true
           })}
      end
    end
  end

  def handle_command(%State{} = state, %{type: "coordinator.turn.start", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, turn_id} <- Aggregate.required_binary(Aggregate.get(payload, :turn_id), :turn_id),
         {:ok, attempt} <- validate_attempt(Aggregate.get(payload, :attempt)),
         {:ok, ids} <- validate_id_list(Aggregate.get(payload, :trigger_message_ids)),
         :ok <- ensure_no_open_turn(state),
         :ok <- ensure_healthy(state) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "CoordinatorTurnStarted",
         payload: %{
           project_id: project_id,
           turn_id: turn_id,
           attempt: attempt,
           trigger_message_ids: ids,
           at: now()
         }
       }}
    end
  end

  def handle_command(%State{} = state, %{type: "coordinator.action.record", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, turn_id} <- Aggregate.required_binary(Aggregate.get(payload, :turn_id), :turn_id),
         {:ok, action_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :action_id), :action_id),
         {:ok, kind} <- Aggregate.required_binary(Aggregate.get(payload, :kind), :kind),
         {:ok, status} <- validate_action_status(Aggregate.get(payload, :status)),
         {:ok, params} <- validate_map(Aggregate.get(payload, :params), :params),
         {:ok, result_ref} <-
           validate_optional_map(Aggregate.get(payload, :result_ref), :result_ref),
         :ok <- optional_binary(payload, :reason),
         :ok <- ensure_turn_open(state, turn_id) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "CoordinatorActionRecorded",
         payload: %{
           project_id: project_id,
           turn_id: turn_id,
           action_id: action_id,
           kind: kind,
           params: params,
           status: status,
           reason: Aggregate.get(payload, :reason),
           result_ref: result_ref,
           at: now()
         }
       }}
    end
  end

  def handle_command(%State{} = state, %{type: "coordinator.turn.complete", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, turn_id} <- Aggregate.required_binary(Aggregate.get(payload, :turn_id), :turn_id),
         {:ok, cursor} <-
           Aggregate.required_binary(
             Aggregate.get(payload, :cursor_message_id),
             :cursor_message_id
           ),
         :ok <- optional_binary(payload, :outcome),
         :ok <- ensure_turn_open(state, turn_id) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "CoordinatorTurnCompleted",
         payload: %{
           project_id: project_id,
           turn_id: turn_id,
           cursor_message_id: cursor,
           outcome: Aggregate.get(payload, :outcome),
           at: now()
         }
       }}
    end
  end

  def handle_command(%State{} = state, %{type: "coordinator.turn.fail", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, turn_id} <- Aggregate.required_binary(Aggregate.get(payload, :turn_id), :turn_id),
         {:ok, attempt} <- validate_attempt(Aggregate.get(payload, :attempt)),
         {:ok, error_code} <-
           Aggregate.required_binary(Aggregate.get(payload, :error_code), :error_code),
         :ok <- optional_binary(payload, :message),
         {:ok, threshold} <- validate_threshold(Aggregate.get(payload, :unhealthy_after)),
         :ok <- ensure_turn_open(state, turn_id) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "CoordinatorTurnFailed",
         payload: %{
           project_id: project_id,
           turn_id: turn_id,
           attempt: attempt,
           error_code: error_code,
           message: Aggregate.get(payload, :message),
           unhealthy_after: threshold,
           at: now()
         }
       }}
    end
  end

  def handle_command(%State{} = state, %{type: "coordinator.usage.record", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         {:ok, turn_id} <- Aggregate.required_binary(Aggregate.get(payload, :turn_id), :turn_id),
         {:ok, provider} <-
           Aggregate.required_binary(Aggregate.get(payload, :provider), :provider),
         :ok <- optional_binary(payload, :model),
         {:ok, usage} <- validate_usage(payload),
         :ok <- ensure_turn_open(state, turn_id) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "CoordinatorUsageRecorded",
         payload:
           Map.merge(usage, %{
             project_id: project_id,
             turn_id: turn_id,
             provider: provider,
             model: Aggregate.get(payload, :model),
             at: now()
           })
       }}
    end
  end

  def handle_command(%State{}, %{type: "coordinator.restart", payload: payload}) do
    with {:ok, project_id} <- project_id(payload),
         :ok <- optional_binary(payload, :by) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "CoordinatorRestarted",
         payload: %{project_id: project_id, by: Aggregate.get(payload, :by), at: now()}
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ------------------------------------------------------------- validation

  defp project_id(payload),
    do: Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id)

  defp validate_text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:error, {:missing_or_invalid, :text}}

      not String.valid?(text) ->
        {:error, {:missing_or_invalid, :text}}

      byte_size(text) > max_message_bytes() ->
        {:error, {:message_too_large, byte_size(text), max_message_bytes()}}

      true ->
        {:ok, text}
    end
  end

  defp validate_text(_), do: {:error, {:missing_or_invalid, :text}}

  defp validate_source(source) when source in @sources, do: {:ok, source}

  defp validate_source(source) when is_binary(source) and source != "",
    do: {:error, {:invalid_source, source}}

  defp validate_source(_), do: {:error, {:missing_or_invalid, :source}}

  defp validate_role(role) when role in @append_roles, do: {:ok, role}

  defp validate_role(role) when is_binary(role) and role != "",
    do: {:error, {:invalid_role, role}}

  defp validate_role(_), do: {:error, {:missing_or_invalid, :role}}

  defp validate_kind(kind) when kind in @append_kinds, do: {:ok, kind}

  defp validate_kind(kind) when is_binary(kind) and kind != "",
    do: {:error, {:invalid_kind, kind}}

  defp validate_kind(_), do: {:error, {:missing_or_invalid, :kind}}

  defp validate_action_status(status) when status in @action_statuses, do: {:ok, status}

  defp validate_action_status(status) when is_binary(status) and status != "",
    do: {:error, {:invalid_action_status, status}}

  defp validate_action_status(_), do: {:error, {:missing_or_invalid, :status}}

  defp validate_thread_ref(nil), do: {:ok, nil}
  defp validate_thread_ref(ref) when is_map(ref), do: {:ok, ref}
  defp validate_thread_ref(_), do: {:error, {:missing_or_invalid, :thread_ref}}

  defp validate_attempt(attempt) when is_integer(attempt) and attempt >= 1, do: {:ok, attempt}
  defp validate_attempt(_), do: {:error, {:missing_or_invalid, :attempt}}

  defp validate_threshold(nil), do: {:ok, @default_unhealthy_after}
  defp validate_threshold(n) when is_integer(n) and n >= 1, do: {:ok, n}
  defp validate_threshold(_), do: {:error, {:missing_or_invalid, :unhealthy_after}}

  # Token counts are non-negative integers and the cost a non-negative number;
  # `nil` means the provider did not report it (never 0). A usage with nothing
  # reported is refused: an all-nil event would read as "recorded, unknown".
  defp validate_usage(payload) do
    with {:ok, counts} <- validate_counts(payload),
         {:ok, cost} <- validate_cost(Aggregate.get(payload, :cost_usd)) do
      usage = Map.put(counts, :cost_usd, cost)

      if Enum.all?(Map.values(usage), &is_nil/1),
        do: {:error, {:missing_or_invalid, :usage}},
        else: {:ok, usage}
    end
  end

  defp validate_counts(payload) do
    Enum.reduce_while(@usage_counts, {:ok, %{}}, fn key, {:ok, counts} ->
      case Aggregate.get(payload, key) do
        nil -> {:cont, {:ok, Map.put(counts, key, nil)}}
        n when is_integer(n) and n >= 0 -> {:cont, {:ok, Map.put(counts, key, n)}}
        _ -> {:halt, {:error, {:missing_or_invalid, key}}}
      end
    end)
  end

  defp validate_cost(nil), do: {:ok, nil}
  defp validate_cost(cost) when is_number(cost) and cost >= 0, do: {:ok, cost * 1.0}
  defp validate_cost(_), do: {:error, {:missing_or_invalid, :cost_usd}}

  defp validate_id_list(nil), do: {:ok, []}

  defp validate_id_list(ids) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      do: {:ok, ids},
      else: {:error, {:missing_or_invalid, :trigger_message_ids}}
  end

  defp validate_id_list(_), do: {:error, {:missing_or_invalid, :trigger_message_ids}}

  defp validate_map(nil, _key), do: {:ok, %{}}
  defp validate_map(map, _key) when is_map(map), do: {:ok, map}
  defp validate_map(_, key), do: {:error, {:missing_or_invalid, key}}

  defp validate_optional_map(nil, _key), do: {:ok, nil}
  defp validate_optional_map(map, _key) when is_map(map), do: {:ok, map}
  defp validate_optional_map(_, key), do: {:error, {:missing_or_invalid, key}}

  defp optional_binary(payload, key),
    do: Aggregate.optional_binary(Aggregate.get(payload, key), key)

  defp duplicate_message?(%State{seen_message_ids: ids}, id), do: MapSet.member?(ids, id)

  defp ensure_no_open_turn(%State{open_turn: nil}), do: :ok

  defp ensure_no_open_turn(%State{open_turn: %{turn_id: id}}),
    do: {:error, {:turn_already_open, id}}

  defp ensure_healthy(%State{status: :unhealthy}), do: {:error, :coordinator_unhealthy}
  defp ensure_healthy(%State{}), do: :ok

  defp ensure_turn_open(%State{open_turn: %{turn_id: id}}, id), do: :ok
  defp ensure_turn_open(_state, turn_id), do: {:error, {:turn_not_open, turn_id}}

  defp message_event(project_id, fields) do
    %{
      stream_id: stream_id(project_id),
      event_type: "CoordinatorMessageAppended",
      payload:
        Map.merge(
          %{
            project_id: project_id,
            thread_ref: nil,
            report_key: nil,
            turn_id: nil,
            suppressed: false,
            at: now()
          },
          fields
        )
    }
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
