defmodule ForemanServer.Agents.OperatorTimeout do
  @moduledoc """
  Fast-path expiry timer for operator questions.

  `schedule/3` starts an in-memory timer when a question is opened
  (`OperatorQuestionDispatcher`). When it fires, the question is expired through
  `ForemanServer.Approvals.TimeoutPolicy` (`question.expire`, a durable
  `QuestionExpired`): it is no longer a log line that does nothing.

  The timer is only the fast path. It is lost on restart (and on `cancel/2`), so
  correctness never depends on it: `ForemanServer.Approvals.Sweeper` expires every
  overdue open question from the projection, at startup and periodically. Both
  use deterministic command ids, so whichever fires first wins and the other is a
  no-op.
  """

  use GenServer

  require Logger

  alias ForemanServer.Approvals.TimeoutPolicy
  alias ForemanServer.ProjectionStore

  @table :operator_timeout_registry
  # 5 minutes
  @default_timeout_ms 5 * 60 * 1000

  @doc "Start the timer manager (registered under its module name by default)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{policy_opts: Keyword.take(opts, [:gateway, :on_timeout])}}
  end

  @doc "Schedule expiry of `question_id` (asked by `agent_id`) after `timeout_ms`."
  @spec schedule(String.t(), String.t(), pos_integer()) :: :ok
  def schedule(question_id, agent_id, timeout_ms \\ @default_timeout_ms) do
    GenServer.call(__MODULE__, {:schedule, question_id, agent_id, timeout_ms})
  end

  @doc "Cancel a scheduled expiry; a no-op when none is scheduled."
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(question_id, agent_id) do
    GenServer.call(__MODULE__, {:cancel, question_id, agent_id})
  end

  @impl true
  def handle_call({:schedule, question_id, agent_id, timeout_ms}, _from, state) do
    {:ok, ref} = :timer.send_after(timeout_ms, self(), {:expire, question_id, agent_id})
    :ets.insert(@table, {{question_id, agent_id}, ref})
    {:reply, :ok, state}
  end

  def handle_call({:cancel, question_id, agent_id}, _from, state) do
    case :ets.lookup(@table, {question_id, agent_id}) do
      [{_, ref}] ->
        :timer.cancel(ref)
        :ets.delete(@table, {question_id, agent_id})

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:expire, question_id, agent_id}, state) do
    :ets.delete(@table, {question_id, agent_id})

    case ProjectionStore.open_question_by_id(question_id) do
      nil ->
        # Already answered/expired (or never opened): nothing left to time out.
        :ok

      question ->
        case TimeoutPolicy.apply(:question, question, state.policy_opts) do
          {:ok, _outcome} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Operator timeout for question=#{question_id} agent=#{agent_id} could not expire it: #{inspect(reason)}"
            )
        end
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
