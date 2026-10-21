defmodule ForemanServer.Aggregates.Thread do
  @moduledoc """
  Operator disposition of a thread (`thread:<thread_id>`, where the thread id is
  `run:<id>` or `jobsite:<id>`; see `ForemanServer.Threads`).

  Commands:

    * `thread.resolve` - payload `thread_id`, `project_id`, optional `reason`
      (<= 500 chars), `resolved_by`, `source`. Resolving an already resolved
      thread is an idempotent no-op (`{:ok, nil}`, nothing appended).
    * `thread.reopen` - payload `thread_id`, `project_id`, optional
      `reopened_by`, `source`. Reopening a thread that is not resolved is
      `{:error, {:thread_not_resolved, thread_id}}`.

  Resolving is a disposition flag only: it never cancels or stops a run.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{ThreadReopened, ThreadResolved}

  @max_reason 500

  @doc "Stream id for a thread."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(thread_id), do: "thread:" <> thread_id

  defmodule State do
    @moduledoc "Whether the thread is currently resolved, when, and why."
    @type t :: %__MODULE__{
            resolved: boolean(),
            resolved_at: String.t() | nil,
            reason: String.t() | nil
          }
    defstruct resolved: false, resolved_at: nil, reason: nil
  end

  @impl true
  def initial_state, do: %State{}

  # apply_event/2 must tolerate unknown event types (no crash on replay)
  @impl true
  def apply_event(%State{} = state, %ThreadResolved{at: at, reason: reason}),
    do: %State{state | resolved: true, resolved_at: at, reason: reason}

  def apply_event(%State{} = state, %ThreadReopened{}),
    do: %State{state | resolved: false, resolved_at: nil, reason: nil}

  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      type when type in ["ThreadResolved", "ThreadReopened"] ->
        payload = event |> Aggregate.event_payload() |> Map.delete("event_type")
        apply_event(state, EventCodec.decode!(type, payload))

      _ ->
        state
    end
  end

  @impl true
  def handle_command(%State{resolved: true}, %{type: "thread.resolve", payload: payload}) do
    with {:ok, _} <- Aggregate.required_binary(Aggregate.get(payload, :thread_id), :thread_id),
         {:ok, _} <- Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, _} <- validate_reason(Aggregate.get(payload, :reason)) do
      {:ok, nil}
    end
  end

  def handle_command(%State{}, %{type: "thread.resolve", payload: payload}) do
    with {:ok, thread_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :thread_id), :thread_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, reason} <- validate_reason(Aggregate.get(payload, :reason)),
         :ok <- optional_binary(payload, :resolved_by),
         :ok <- optional_binary(payload, :source) do
      {:ok,
       %{
         stream_id: stream_id(thread_id),
         event_type: "ThreadResolved",
         payload: %{
           thread_id: thread_id,
           project_id: project_id,
           reason: reason,
           resolved_by: Aggregate.get(payload, :resolved_by),
           source: Aggregate.get(payload, :source),
           at: Aggregate.get(payload, :at) || DateTime.to_iso8601(DateTime.utc_now())
         }
       }}
    end
  end

  def handle_command(%State{} = state, %{type: "thread.reopen", payload: payload}) do
    with {:ok, thread_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :thread_id), :thread_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- optional_binary(payload, :reopened_by),
         :ok <- optional_binary(payload, :source),
         :ok <- ensure_resolved(state, thread_id) do
      {:ok,
       %{
         stream_id: stream_id(thread_id),
         event_type: "ThreadReopened",
         payload: %{
           thread_id: thread_id,
           project_id: project_id,
           reopened_by: Aggregate.get(payload, :reopened_by),
           source: Aggregate.get(payload, :source),
           at: Aggregate.get(payload, :at) || DateTime.to_iso8601(DateTime.utc_now())
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp validate_reason(nil), do: {:ok, nil}

  defp validate_reason(reason) when is_binary(reason) do
    if String.length(reason) <= @max_reason,
      do: {:ok, reason},
      else: {:error, {:reason_too_long, String.length(reason)}}
  end

  defp validate_reason(_), do: {:error, {:missing_or_invalid, :reason}}

  defp optional_binary(payload, key),
    do: Aggregate.optional_binary(Aggregate.get(payload, key), key)

  defp ensure_resolved(%State{resolved: true}, _thread_id), do: :ok
  defp ensure_resolved(%State{}, thread_id), do: {:error, {:thread_not_resolved, thread_id}}
end
