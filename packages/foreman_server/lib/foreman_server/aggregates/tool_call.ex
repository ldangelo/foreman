defmodule ForemanServer.Aggregates.ToolCall do
  @moduledoc """
  Tool-call aggregate (`tool_call:<run_id>:<tool_call_id>`): an agent's request
  for permission to use a tool, and the decision on it.

  State machine: `requested -> approved | denied | expired`, `approved ->
  finished`, `requested -> finished` (decision delivered some other way). Denied,
  expired and finished are terminal.

  Commands:

    * `tool.request` (system) - payload `run_id`, `tool_call_id`, `tool_name`,
      optional `input_summary`, `project_id`, `provider`, `requested_by`,
      `delivery`. `input_summary` is redacted and cut to 500 characters here, so
      no producer can store a raw tool input.
    * `tool.approve` / `tool.deny` (operator) - payload `run_id`, `tool_call_id`,
      optional `decided_by`, `reason` (<= 500 chars).
    * `tool.finish` (system) - the decision was delivered; optional `outcome`.
    * `tool.expire` (system) - the request ended undecided; `reason` says why:
      `timeout` (nobody answered), `run_ended` (the run reached a terminal state),
      `client_gone` (the agent's connection closed) or `server_restart` (Foreman
      restarted while the agent waited). An operator decision on an expired call
      is refused with `{:tool_call_expired, reason}`.

  This aggregate decides an AGENT TOOL CALL only. It is not the run's merge gate
  (`merge_approve`, `run.pr.merge`), which lives on the `run:` stream and stays
  operator-only: a `tool.approve` can only ever address a `tool_call:` stream.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Overwatch.WorkerLogPolicy

  @max_summary 500
  @max_reason 500
  @global_run "global"

  defmodule State do
    @moduledoc "Lifecycle state of one tool call."
    @enforce_keys [:exists?, :tool_call_id, :status, :terminal?, :reason]
    defstruct [:exists?, :tool_call_id, :status, :terminal?, :reason]
  end

  @doc "Stream id for a tool call; `:` in either id is escaped so ids stay unambiguous."
  @spec stream_id(String.t(), String.t()) :: String.t()
  def stream_id(run_id, tool_call_id) when is_binary(run_id) and is_binary(tool_call_id),
    do: "tool_call:#{escape(run_id)}:#{escape(tool_call_id)}"

  @impl true
  def initial_state do
    %State{exists?: false, tool_call_id: nil, status: nil, terminal?: false, reason: nil}
  end

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)
    id = Aggregate.get(payload, :tool_call_id)

    case Aggregate.event_type(event) do
      "ToolCallRequested" -> transition(state, id, "requested", false)
      "ToolCallApproved" -> transition(state, id, "approved", false)
      "ToolCallDenied" -> transition(state, id, "denied", true)
      "ToolCallExpired" -> transition(state, id, "expired", true, Aggregate.get(payload, :reason))
      "ToolCallFinished" -> transition(state, id, "finished", true)
      _ -> state
    end
  end

  defp transition(%State{} = state, id, status, terminal?, reason \\ nil),
    do: %State{
      state
      | exists?: true,
        tool_call_id: id,
        status: status,
        terminal?: terminal?,
        reason: reason
    }

  @impl true
  def handle_command(state, %{type: "tool.request", payload: payload}) do
    with {:ok, run_id, tool_call_id} <- ids(payload),
         {:ok, tool_name} <- Aggregate.required_binary(get(payload, :tool_name), :tool_name),
         :ok <- optional(payload, [:project_id, :provider, :requested_by, :delivery]),
         :ok <- require_absent(state) do
      {:ok,
       %{
         stream_id: stream_id(run_id, tool_call_id),
         event_type: "ToolCallRequested",
         payload: %{
           run_id: run_id,
           tool_call_id: tool_call_id,
           tool_name: tool_name,
           input_summary: summarize(get(payload, :input_summary)),
           project_id: get(payload, :project_id),
           provider: get(payload, :provider),
           requested_by: get(payload, :requested_by),
           delivery: get(payload, :delivery),
           requested_at: now(payload, :requested_at)
         }
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in ["tool.approve", "tool.deny"] do
    with {:ok, run_id, tool_call_id} <- ids(payload),
         {:ok, reason} <- validate_reason(get(payload, :reason)),
         :ok <- optional(payload, [:decided_by]),
         :ok <- require_decidable(state) do
      event_type = if type == "tool.approve", do: "ToolCallApproved", else: "ToolCallDenied"

      {:ok,
       %{
         stream_id: stream_id(run_id, tool_call_id),
         event_type: event_type,
         payload: %{
           run_id: run_id,
           tool_call_id: tool_call_id,
           decided_by: get(payload, :decided_by),
           reason: reason,
           decided_at: now(payload, :decided_at)
         }
       }}
    end
  end

  def handle_command(state, %{type: "tool.finish", payload: payload}) do
    with {:ok, run_id, tool_call_id} <- ids(payload),
         :ok <- optional(payload, [:outcome, :worker_id, :tool_name]),
         :ok <- require_status(state, ["requested", "approved"]) do
      {:ok,
       %{
         stream_id: stream_id(run_id, tool_call_id),
         event_type: "ToolCallFinished",
         payload: %{
           worker_id: get(payload, :worker_id) || "approvals",
           run_id: run_id,
           tool_call_id: tool_call_id,
           tool_name: get(payload, :tool_name),
           outcome: get(payload, :outcome)
         }
       }}
    end
  end

  def handle_command(state, %{type: "tool.expire", payload: payload}) do
    with {:ok, run_id, tool_call_id} <- ids(payload),
         :ok <- optional(payload, [:reason]),
         :ok <- require_status(state, ["requested"]) do
      {:ok,
       %{
         stream_id: stream_id(run_id, tool_call_id),
         event_type: "ToolCallExpired",
         payload: %{
           run_id: run_id,
           tool_call_id: tool_call_id,
           reason: get(payload, :reason),
           at: now(payload, :at)
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # -- helpers ---------------------------------------------------------

  defp get(payload, key), do: Aggregate.get(payload, key)

  defp ids(payload) do
    run_id = get(payload, :run_id) || @global_run

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id),
         {:ok, tool_call_id} <-
           Aggregate.required_binary(get(payload, :tool_call_id), :tool_call_id) do
      {:ok, run_id, tool_call_id}
    end
  end

  defp optional(payload, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Aggregate.optional_binary(get(payload, key), key) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_reason(nil), do: {:ok, nil}

  defp validate_reason(reason) when is_binary(reason) do
    if String.length(reason) <= @max_reason,
      do: {:ok, reason},
      else: {:error, {:reason_too_long, String.length(reason)}}
  end

  defp validate_reason(_), do: {:error, {:missing_or_invalid, :reason}}

  defp summarize(summary) when is_binary(summary) do
    summary |> WorkerLogPolicy.redact() |> String.slice(0, @max_summary)
  end

  defp summarize(_), do: nil

  defp now(payload, key) do
    case get(payload, key) do
      at when is_binary(at) and at != "" -> at
      _ -> DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  defp require_absent(%State{exists?: true}), do: {:error, :tool_call_already_requested}
  defp require_absent(_state), do: :ok

  # An operator decision on a request that expired says why it did.
  defp require_decidable(%State{status: "expired", reason: reason}),
    do: {:error, {:tool_call_expired, reason}}

  defp require_decidable(state), do: require_status(state, ["requested"])

  defp require_status(%State{terminal?: true, status: status}, _allowed),
    do: {:error, {:tool_call_terminal, status}}

  defp require_status(%State{exists?: false}, _allowed), do: {:error, :tool_call_not_requested}

  defp require_status(%State{status: status}, allowed) do
    if status in allowed, do: :ok, else: {:error, {:invalid_tool_call_status, status}}
  end

  defp escape(value), do: String.replace(value, ":", "%3A")
end
