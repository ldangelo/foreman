defmodule ForemanServer.Questions.Deliverer do
  @moduledoc """
  Delivers an operator's answer to the agent that asked, exactly once.

  Subscribes to `ForemanServer.ProjectionStore` (no replay) and reacts to
  `QuestionAnswered` only:

    * a question tied to a live workflow run is delivered as an E6 steering
      message (`run.steer`, `message_id` `question:<question_id>`, text
      `"Answer to your question <id>: ..."`); the run is then resumed if it is
      paused. The steer's idempotent message id makes a repeated delivery a no-op.
    * any other question (no run) is published on the operator reply topic
      (`JidoSignalTopics.foreman_operator_reply/0`) for signal-bus agents.

  A failed delivery is logged at `:error` with the question id (the
  `QuestionAnswered` event stays the durable record); it is never reported as
  delivered. Commands go through `ForemanServer.Approvals.Dispatch`, a closed list.
  """

  use GenServer

  require Logger

  alias ForemanServer.Agents.JidoSignalTopics
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
      :ok -> {:ok, %{opts: opts}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
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
  Deliver one answer (public so tests and recovery can drive it without a
  subscription). `:delivered` or `{:failed, reason}`.
  """
  @spec deliver(String.t(), String.t(), String.t(), keyword()) :: :delivered | {:failed, term()}
  def deliver(run_id, question_id, text, opts \\ []),
    do: deliver(run_id, question_id, text, nil, opts)

  defp deliver(run_id, question_id, text, answered_by, opts) do
    result =
      if ProjectionStore.run(run_id) do
        steer_run(
          run_id,
          question_id,
          text,
          Keyword.get(opts, :gateway, ForemanServer.CommandGateway)
        )
      else
        publish_reply(run_id, question_id, text, answered_by, opts)
      end

    case result do
      :ok ->
        :delivered

      {:error, reason} ->
        Logger.error("questions: answer to #{question_id} was not delivered: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  defp steer_run(run_id, question_id, text, gateway) do
    steer = %{
      type: "run.steer",
      command_id: "question-steer:#{run_id}:#{question_id}",
      aggregate_id: "run:" <> run_id,
      payload: %{
        run_id: run_id,
        message_id: "question:" <> question_id,
        text: "Answer to your question #{question_id}: #{text}",
        steered_by: "question",
        resume: true
      }
    }

    with {:ok, _} <- unwrap(Dispatch.system(steer, gateway)) do
      resume_if_paused(run_id, question_id, gateway)
    end
  end

  defp resume_if_paused(run_id, question_id, gateway) do
    case ProjectionStore.run(run_id) do
      %{status: "paused"} ->
        resume = %{
          type: "run.resume",
          command_id: "question-resume:#{run_id}:#{question_id}",
          aggregate_id: "run:" <> run_id,
          payload: %{run_id: run_id, reason: "question_answered"}
        }

        with {:ok, _} <- unwrap(Dispatch.system(resume, gateway)), do: :ok

      _running_or_gone ->
        :ok
    end
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
