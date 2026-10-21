defmodule ForemanServer.Approvals.Sweeper do
  @moduledoc """
  Durable expiry of unanswered tool-call requests and operator questions.

  The projection is the source of truth, not a timer: every sweep (at startup, so a
  restart recovers, and then every `:interval_ms`) reads the pending requests and
  open questions of ALL projects and applies
  `ForemanServer.Approvals.TimeoutPolicy` to those past their deadline:

    * a tool call is overdue `:tool_call_timeout_ms` after `requested_at`
      (`Config.tool_call_timeout_ms/0`, default 30 minutes);
    * a question is overdue its own recorded `timeout_ms` after `opened_at` (the
      workflow manifest's `operator_timeout_ms` resolved when it was asked).

  The boundary is inclusive (`age >= timeout`). Deterministic command ids and the
  aggregates' status guards make a repeated sweep, or one racing the
  `OperatorTimeout` fast path, record each expiry exactly once.
  """

  use GenServer

  require Logger

  alias ForemanServer.Approvals.{Config, TimeoutPolicy}
  alias ForemanServer.ProjectionStore

  @doc """
  Start the sweeper. Options: `:name`, `:now_fun` (ms clock, injectable),
  `:interval_ms` (`:manual` disables the timer), `:tool_call_timeout_ms`,
  `:on_timeout`, `:gateway`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Sweep now and wait: `%{tool_calls: n, questions: n}` counts the requests the
  policy was applied to (including ones already decided elsewhere).
  """
  @spec sweep(GenServer.server()) :: %{
          tool_calls: non_neg_integer(),
          questions: non_neg_integer()
        }
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep, 30_000)

  @impl true
  def init(opts) do
    state = %{
      now_fun: Keyword.get(opts, :now_fun, fn -> System.system_time(:millisecond) end),
      interval_ms: Keyword.get_lazy(opts, :interval_ms, &Config.sweep_interval_ms/0),
      tool_call_timeout_ms:
        Keyword.get_lazy(opts, :tool_call_timeout_ms, &Config.tool_call_timeout_ms/0),
      policy_opts: Keyword.take(opts, [:on_timeout, :gateway])
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    _ = do_sweep(state)
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, do_sweep(state), state}

  @impl true
  def handle_info(:sweep, state) do
    _ = do_sweep(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{interval_ms: interval} = state) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
    state
  end

  defp schedule(state), do: state

  defp do_sweep(state) do
    now = state.now_fun.()
    %{tool_calls: calls, questions: questions} = ProjectionStore.pending_needs_you()

    overdue_calls =
      Enum.filter(calls, &overdue?(&1.requested_at_ms, state.tool_call_timeout_ms, now))

    overdue_questions = Enum.filter(questions, &overdue?(&1.opened_at_ms, &1.timeout_ms, now))

    Enum.each(overdue_calls, &apply_policy(:tool_call, &1, state))
    Enum.each(overdue_questions, &apply_policy(:question, &1, state))

    %{tool_calls: length(overdue_calls), questions: length(overdue_questions)}
  end

  defp overdue?(at_ms, timeout_ms, now)
       when is_integer(at_ms) and is_integer(timeout_ms) and timeout_ms > 0,
       do: now - at_ms >= timeout_ms

  defp overdue?(_at_ms, _timeout_ms, _now), do: false

  defp apply_policy(kind, subject, state) do
    case TimeoutPolicy.apply(kind, subject, state.policy_opts) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "approvals sweeper: could not time out #{kind} #{inspect(subject_id(subject))}: #{inspect(reason)}"
        )
    end
  end

  defp subject_id(%{tool_call_id: id, run_id: run_id}), do: {run_id, id}
  defp subject_id(%{question_id: id, run_id: run_id}), do: {run_id, id}
end
