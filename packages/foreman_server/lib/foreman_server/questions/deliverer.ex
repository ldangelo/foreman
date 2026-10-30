defmodule ForemanServer.Questions.Deliverer do
  @moduledoc """
  Delivers an operator's answer to the agent that asked, exactly once.

  Subscribes to `ForemanServer.ProjectionStore` (no replay) and reacts to
  `QuestionAnswered` only:

    * a question tied to a live workflow run is delivered as an E6 steering
      message (`run.steer`, `message_id` `question:<question_id>`, text
      `OperatorQuestion.steer_text/2`: `"Answer to your question <id>: ..."`, which
      `question.answer` guarantees fits the steer cap). A run that was paused when the answer
      arrived is then resumed, while it still holds the message; a running run is
      left to the dispatcher, which pauses and resumes it for the steer. The steer's
      idempotent message id makes a repeated delivery a no-op.
    * any other question (no run) is published on the operator reply topic
      (`JidoSignalTopics.foreman_operator_reply/0`) for signal-bus agents.

  A failed delivery is logged at `:error` with the question id (the
  `QuestionAnswered` event stays the durable record); it is never reported as
  delivered. Commands go through `ForemanServer.Approvals.Dispatch`, a closed list.

  An answer longer than `OperatorQuestion.max_answer_chars/1` (only an answer recorded before
  `question.answer` enforced that limit can be) is refused by the steer aggregate on every
  attempt, so retrying it only repeats the failure at every start. Its outcome is
  `{:undeliverable, {:answer_too_long, length, max}}`: logged at `:error` and MARKED undelivered
  (`question.answer.undeliver`: `QuestionAnswerUndelivered`, listed as `undelivered_reason` and
  notified), once. Startup recovery then skips it. The answer text stays in the
  `QuestionAnswered` event; the operator steers the run with a shorter message.
  """

  use GenServer

  require Logger

  alias ForemanServer.Agents.JidoSignalTopics
  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.Approvals.Dispatch
  alias ForemanServer.ProjectionStore

  @doc "Start the deliverer. Options: `:name`, `:gateway`, `:bus` (signal bus, default the supervised one)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{opts: opts}, {:continue, :recover}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    recover(state.opts)
    {:noreply, state}
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    if event_type(event) == "QuestionAnswered" do
      case data(event) do
        %{run_id: run_id, question_id: id, text: text} when is_binary(text) ->
          _ = deliver(run_id, id, text, answered_by(event), state.opts)

        _malformed ->
          Logger.error("questions: malformed QuestionAnswered event dropped")
      end
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Re-deliver the answers of questions whose run has not ended (running or paused): the
  answer may have been recorded while the deliverer was down (or it died while delivering).
  The answer text is read back from the `QuestionAnswered` event. The steer and resume
  commands have deterministic ids, so an answer that did arrive is a no-op, and a run is
  resumed only while it still holds this answer's message (`resume_if_paused/3`). Answers
  to a run that ended cannot be delivered and are not retried; a question of no run is not
  republished (the bus reply has no durable delivery marker, so a replay would re-publish
  history to agents that already got their answer). An answer already marked undelivered is
  skipped; one found too long now is marked (see `deliver/4`). Returns the number attempted.
  """
  @spec recover(keyword()) :: non_neg_integer()
  def recover(opts \\ []) do
    pending =
      for %{run_id: run_id, question_id: id, undelivered_reason: nil} <-
            ProjectionStore.answered_questions(),
          match?(%{terminal?: false}, ProjectionStore.run(run_id)),
          text = answer_text(run_id, id),
          is_binary(text),
          do: {run_id, id, text}

    for {run_id, id, text} <- pending, do: deliver(run_id, id, text, opts)
    length(pending)
  end

  defp answer_text(run_id, question_id) do
    stream = OperatorQuestion.stream_id(run_id, question_id)

    with {:ok, events} <- ForemanServer.EventStore.read_stream_forward(stream, 0, 100) do
      Enum.find_value(events, fn
        %{event_type: "QuestionAnswered", data: data} ->
          Map.get(data, :text) || Map.get(data, "text")

        _ ->
          nil
      end)
    else
      _ -> nil
    end
  end

  @typedoc """
  The outcome of one delivery. `{:undeliverable, ...}` is final (no retry can deliver the answer);
  `{:failed, reason}` may succeed on a later attempt.
  """
  @type outcome ::
          :delivered
          | {:failed, term()}
          | {:undeliverable, {:answer_too_long, pos_integer(), non_neg_integer()}}

  @doc """
  Deliver one answer (public so tests and recovery can drive it without a
  subscription). `:delivered`, `{:failed, reason}` or `{:undeliverable, reason}`.
  """
  @spec deliver(String.t(), String.t(), String.t(), keyword()) :: outcome()
  def deliver(run_id, question_id, text, opts \\ []),
    do: deliver(run_id, question_id, text, nil, opts)

  defp deliver(run_id, question_id, text, answered_by, opts) do
    gateway = Keyword.get(opts, :gateway, ForemanServer.CommandGateway)

    result =
      if ProjectionStore.run(run_id) do
        steer_run(run_id, question_id, text, gateway)
      else
        publish_reply(run_id, question_id, text, answered_by, opts)
      end

    case result do
      :ok ->
        :delivered

      {:error, {:answer_too_long, _length, _max} = reason} ->
        mark_undelivered(run_id, question_id, reason, gateway)

      {:error, reason} ->
        Logger.error("questions: answer to #{question_id} was not delivered: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  # No retry can deliver an answer longer than any steering message may be: say so once, where
  # the operator looks (a durable `QuestionAnswerUndelivered`), not at every start in a log
  # line. A marker that cannot be recorded is logged, and the next start tries again.
  defp mark_undelivered(run_id, question_id, {:answer_too_long, length, max} = reason, gateway) do
    detail =
      "answer too long to deliver: #{length} characters, the limit is #{max}; " <>
        "the agent never received it, so send the run a shorter message instead"

    Logger.error(
      "questions: answer to #{question_id} (run #{run_id}) is undeliverable: #{detail}"
    )

    marker = %{
      type: "question.answer.undeliver",
      command_id: "question-undeliver:#{run_id}:#{question_id}",
      aggregate_id: OperatorQuestion.stream_id(run_id, question_id),
      payload: %{run_id: run_id, question_id: question_id, reason: detail}
    }

    case Dispatch.system(marker, gateway) do
      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "questions: could not record that the answer to #{question_id} is undeliverable: " <>
            inspect(other)
        )
    end

    {:undeliverable, reason}
  end

  # A run that was RUNNING when the answer arrived is the dispatcher's: it pauses the run
  # for the steer and resumes it by itself, so a resume sent here would race that cycle (and
  # report a delivered answer as failed). Only a run that was already paused is resumed here.
  defp steer_run(run_id, question_id, text, gateway) do
    paused_before? = paused?(run_id)

    steer = %{
      type: "run.steer",
      command_id: "question-steer:#{run_id}:#{question_id}",
      aggregate_id: "run:" <> run_id,
      payload: %{
        run_id: run_id,
        message_id: steer_message_id(question_id),
        text: OperatorQuestion.steer_text(question_id, text),
        steered_by: "question",
        resume: true
      }
    }

    with :ok <- fits_steer(question_id, text),
         {:ok, _} <- unwrap(Dispatch.system(steer, gateway)) do
      if paused_before?, do: resume_if_paused(run_id, question_id, gateway), else: :ok
    end
  end

  # The same limit `question.answer` enforces (derived from the steer cap, never a second
  # number): an answer over it would be refused by the steer aggregate, whatever the attempt.
  defp fits_steer(question_id, text) do
    length = String.length(text)
    max = OperatorQuestion.max_answer_chars(question_id)

    if length > max, do: {:error, {:answer_too_long, length, max}}, else: :ok
  end

  # A paused run is resumed only while it still holds this answer's steer message. Once the
  # run took it (a recovery pass over an old answer) the pause is for some other reason (an
  # operator's, an approval's) and is not this answer's to undo.
  defp resume_if_paused(run_id, question_id, gateway) do
    if paused?(run_id) and steer_pending?(run_id, question_id),
      do: resume(run_id, question_id, gateway),
      else: :ok
  end

  defp paused?(run_id), do: match?(%{status: "paused"}, ProjectionStore.run(run_id))

  defp resume(run_id, question_id, gateway) do
    resume = %{
      type: "run.resume",
      command_id: "question-resume:#{run_id}:#{question_id}",
      aggregate_id: "run:" <> run_id,
      payload: %{run_id: run_id, reason: "question_answered"}
    }

    with {:ok, _} <- unwrap(Dispatch.system(resume, gateway)), do: :ok
  end

  defp steer_message_id(question_id), do: "question:" <> question_id

  defp steer_pending?(run_id, question_id) do
    message_id = steer_message_id(question_id)
    Enum.any?(ProjectionStore.pending_steering(run_id), &(&1.message_id == message_id))
  end

  defp publish_reply(run_id, question_id, text, answered_by, opts) do
    bus = Keyword.get(opts, :bus, :foreman_jido_signal_bus)
    agent_id = agent_id(run_id, question_id)

    payload = %{
      "question_id" => question_id,
      "agent_id" => agent_id,
      "answer" => text,
      "answered_by" => answered_by
    }

    with {:ok, signal} <-
           Jido.Signal.new(JidoSignalTopics.foreman_operator_reply(), payload,
             source: "foreman.questions.deliverer"
           ),
         {:ok, _recorded} <- Jido.Signal.Bus.publish(bus, [signal]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_id(run_id, question_id) do
    case ProjectionStore.question(run_id, question_id) do
      %{agent_id: agent_id} -> agent_id
      nil -> nil
    end
  end

  defp unwrap({:ok, _} = ok), do: ok
  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap({:error, reason, _detail}), do: {:error, reason}

  defp event_type(event), do: Map.get(event, :event_type) || Map.get(event, "event_type")

  defp data(event) do
    data = Map.get(event, :data) || Map.get(event, "data") || Map.get(event, :payload) || %{}
    data = if is_struct(data), do: Map.from_struct(data), else: data

    %{
      run_id: Map.get(data, :run_id) || Map.get(data, "run_id"),
      question_id: Map.get(data, :question_id) || Map.get(data, "question_id"),
      text: Map.get(data, :text) || Map.get(data, "text")
    }
  end

  defp answered_by(event) do
    data = Map.get(event, :data) || Map.get(event, "data") || %{}
    data = if is_struct(data), do: Map.from_struct(data), else: data
    Map.get(data, :answered_by) || Map.get(data, "answered_by")
  end
end
