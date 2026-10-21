defmodule ForemanServer.Aggregates.OperatorQuestion do
  @moduledoc """
  An operator question (`question:<run_id|global>:<question_id>`), the first-class
  state behind the agent -> inbox -> operator flow.

  State machine: `open -> answered | expired`; answered and expired are terminal.

  Commands:

    * `question.open` (system) - payload `run_id` (default `"global"`),
      `question_id`, optional `agent_id`, `project_id`, `text` (redacted, <= 500
      chars), `timeout_ms`. Idempotent: opening a question that already exists in
      any state is `{:ok, nil}`.
    * `question.answer` (operator) - payload `run_id`, `question_id`, `text`
      (non-empty, <= 8000), optional `answered_by`. Only an open question can be
      answered: `{:error, {:question_not_open, status}}` otherwise, so a double
      answer and an answer after expiry are rejected.
    * `question.expire` (system) - payload `run_id`, `question_id`, optional
      `reason`. Only an open question expires.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Overwatch.WorkerLogPolicy

  @max_answer 8_000
  @max_text 500
  @global_run "global"

  defmodule State do
    @moduledoc "Lifecycle state of one operator question."
    @enforce_keys [:status]
    defstruct [:status]
  end

  @doc "Stream id for a question; `:` in either id is escaped."
  @spec stream_id(String.t(), String.t()) :: String.t()
  def stream_id(run_id, question_id) when is_binary(run_id) and is_binary(question_id),
    do: "question:#{escape(run_id)}:#{escape(question_id)}"

  @doc "The run id used for a question that belongs to no run."
  @spec global_run() :: String.t()
  def global_run, do: @global_run

  @impl true
  def initial_state, do: %State{status: nil}

  @impl true
  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "QuestionOpened" -> %State{state | status: "open"}
      "QuestionAnswered" -> %State{state | status: "answered"}
      "QuestionExpired" -> %State{state | status: "expired"}
      _ -> state
    end
  end

  @impl true
  def handle_command(%State{status: nil}, %{type: "question.open", payload: payload}) do
    with {:ok, run_id, question_id} <- ids(payload),
         :ok <- optional(payload, [:agent_id, :project_id]),
         {:ok, timeout_ms} <- timeout(Aggregate.get(payload, :timeout_ms)) do
      {:ok,
       %{
         stream_id: stream_id(run_id, question_id),
         event_type: "QuestionOpened",
         payload: %{
           run_id: run_id,
           question_id: question_id,
           agent_id: Aggregate.get(payload, :agent_id),
           project_id: Aggregate.get(payload, :project_id),
           text: summarize(Aggregate.get(payload, :text)),
           timeout_ms: timeout_ms,
           at: now(payload)
         }
       }}
    end
  end

  def handle_command(%State{}, %{type: "question.open"}), do: {:ok, nil}

  def handle_command(%State{} = state, %{type: "question.answer", payload: payload}) do
    with {:ok, run_id, question_id} <- ids(payload),
         {:ok, text} <- answer_text(Aggregate.get(payload, :text)),
         :ok <- optional(payload, [:answered_by]),
         :ok <- require_open(state) do
      {:ok,
       %{
         stream_id: stream_id(run_id, question_id),
         event_type: "QuestionAnswered",
         payload: %{
           run_id: run_id,
           question_id: question_id,
           text: text,
           answered_by: Aggregate.get(payload, :answered_by),
           at: now(payload)
         }
       }}
    end
  end

  def handle_command(%State{} = state, %{type: "question.expire", payload: payload}) do
    with {:ok, run_id, question_id} <- ids(payload),
         :ok <- optional(payload, [:reason]),
         :ok <- require_open(state) do
      {:ok,
       %{
         stream_id: stream_id(run_id, question_id),
         event_type: "QuestionExpired",
         payload: %{
           run_id: run_id,
           question_id: question_id,
           reason: Aggregate.get(payload, :reason),
           at: now(payload)
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp ids(payload) do
    run_id = Aggregate.get(payload, :run_id) || @global_run

    with {:ok, run_id} <- Aggregate.required_binary(run_id, :run_id),
         {:ok, question_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :question_id), :question_id) do
      {:ok, run_id, question_id}
    end
  end

  defp optional(payload, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Aggregate.optional_binary(Aggregate.get(payload, key), key) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp timeout(nil), do: {:ok, nil}
  defp timeout(ms) when is_integer(ms) and ms > 0, do: {:ok, ms}
  defp timeout(_), do: {:error, {:missing_or_invalid, :timeout_ms}}

  defp answer_text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, {:missing_or_invalid, :text}}
      String.length(text) > @max_answer -> {:error, {:text_too_long, String.length(text)}}
      true -> {:ok, text}
    end
  end

  defp answer_text(_), do: {:error, {:missing_or_invalid, :text}}

  defp summarize(text) when is_binary(text),
    do: text |> WorkerLogPolicy.redact() |> String.slice(0, @max_text)

  defp summarize(_), do: nil

  defp now(payload) do
    case Aggregate.get(payload, :at) do
      at when is_binary(at) and at != "" -> at
      _ -> DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  defp require_open(%State{status: "open"}), do: :ok
  defp require_open(%State{status: status}), do: {:error, {:question_not_open, status}}

  defp escape(value), do: String.replace(value, ":", "%3A")
end
