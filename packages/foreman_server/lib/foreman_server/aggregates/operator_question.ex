defmodule ForemanServer.Aggregates.OperatorQuestion do
  @moduledoc """
  An operator question (`question:<run_id|global>:<question_id>`), the first-class
  state behind the agent -> inbox -> operator flow.

  State machine: `open -> answered | expired`; answered and expired are terminal.

  Commands:

    * `question.open` (system) - payload `run_id` (default `"global"`),
      `question_id` (at most `max_question_id_chars/0` characters, else
      `{:error, {:question_id_too_long, length, max}}` and nothing is recorded), optional
      `agent_id`, `project_id`, `text` (redacted, <= 500 chars), `timeout_ms`. Idempotent:
      opening a question that already exists in any state is `{:ok, nil}`.
    * `question.answer` (operator) - payload `run_id`, `question_id`, `text`
      (non-blank, at most `max_answer_chars/1` characters), optional `answered_by`.
      Only an open question can be answered: `{:error, {:question_not_open, status}}`
      otherwise, so a double answer and an answer after expiry are rejected. An answer
      too long to be delivered is refused: `{:error, {:answer_too_long, length, max}}`.
    * `question.expire` (system) - payload `run_id`, `question_id`, optional
      `reason`. Only an open question expires.

  ## The answer limit

  An answer reaches the run that asked as a `run.steer` message (`steer_text/2`: the answer
  behind a prefix naming the question), and a steer is capped (`Run.steer_text_max_chars/0`).
  The limit on an answer is what that cap leaves after the prefix (`max_answer_chars/1`):
  derived from the steer cap and the prefix, never a second number, so an answer this
  aggregate accepts is never too long to be delivered, and one that would be is refused here
  instead of being recorded and dropped. The prefix carries the asker's own question id, so
  the limit is per question; the id is bounded where it is minted (`question.open`), so the
  prefix can never fill the steer cap and leave an answer of zero characters. Only open
  checks the bound: answer and expire act on a stream that already exists, and a question
  recorded before the bound existed must stay answerable. A question of no run is answered
  on the signal bus, a path with no cap of its own; it gets the same limit, so one rule holds
  for every question.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.Overwatch.WorkerLogPolicy

  @max_text 500
  @max_question_id_chars 200
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

  @doc "The longest `question_id` (characters) `question.open` accepts."
  @spec max_question_id_chars() :: pos_integer()
  def max_question_id_chars, do: @max_question_id_chars

  @doc "The run id used for a question that belongs to no run."
  @spec global_run() :: String.t()
  def global_run, do: @global_run

  @doc """
  The `run.steer` text that carries `answer` to the run that asked `question_id`.
  `ForemanServer.Questions.Deliverer` sends exactly this, and `max_answer_chars/1` is
  measured on it, so the delivered message and its limit cannot disagree.
  """
  @spec steer_text(String.t(), String.t()) :: String.t()
  def steer_text(question_id, answer) when is_binary(question_id) and is_binary(answer),
    do: "Answer to your question #{question_id}: #{answer}"

  @doc """
  The longest answer, in characters, question `question_id` accepts: what is left of the steer
  cap once `steer_text/2`'s prefix is in front (`0` when the prefix alone fills it). Counting
  the answer and the prefix apart is safe: the length of a concatenation never exceeds the sum
  of the lengths of its parts.
  """
  @spec max_answer_chars(String.t()) :: non_neg_integer()
  def max_answer_chars(question_id) when is_binary(question_id),
    do: max(Run.steer_text_max_chars() - String.length(steer_text(question_id, "")), 0)

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
         :ok <- question_id_length(question_id),
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
         {:ok, text} <- answer_text(Aggregate.get(payload, :text), question_id),
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

  defp question_id_length(question_id) do
    length = String.length(question_id)

    if length > @max_question_id_chars,
      do: {:error, {:question_id_too_long, length, @max_question_id_chars}},
      else: :ok
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

  defp answer_text(text, question_id) when is_binary(text) do
    chars = String.length(text)
    max = max_answer_chars(question_id)

    cond do
      String.trim(text) == "" -> {:error, {:missing_or_invalid, :text}}
      chars > max -> {:error, {:answer_too_long, chars, max}}
      true -> {:ok, text}
    end
  end

  defp answer_text(_text, _question_id), do: {:error, {:missing_or_invalid, :text}}

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
