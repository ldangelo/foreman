defmodule ForemanServer.RunControl do
  @moduledoc """
  Off-process stop-intent registry and agent-cancellation surface for
  `RunExecutor`.

  `RunExecutor`'s phase loop blocks synchronously inside
  `handle_info(:kickoff)`/`handle_info({:start_at, _})` while a phase's
  agent subprocess is running. A `GenServer.call/2` to the executor
  would deadlock while that block is in flight, so an operator's
  `run.pause`/`run.cancel` command reaches the executor through this
  ETS table instead: `ForemanServer.Workflow.Dispatcher` records an
  intent here and cancels the in-flight harness run; the executor's own
  agent-failure path — unblocked by that cancellation — consults the
  table to decide how to fold the resulting error (fold as a pause, a
  cancel, or an ordinary failure).

  The table is owned by this supervised GenServer, mirroring
  `ForemanServer.RunExecutorLiveness`, so its lifetime is bound to the
  application supervisor rather than to whichever transient caller
  triggered lazy initialization.

  Table key: `run_id`. Table value: `{intent, harness_run_id | nil}`
  where `intent` is `:pause | :cancel | nil`. Steering messages (E6-S4)
  live under the key `{:messages, run_id}` as an ordered list of
  `%{message_id, text}`; that mailbox is a cache of the projection.
  """

  use GenServer

  alias Jido.Harness.Run

  @table __MODULE__

  ## -- GenServer ---------------------------------------------------------

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # This is the only path that creates the ETS table. Public functions
    # do not call ensure_table/0 — that would let a transient caller
    # steal ownership during a GenServer restart. If the GenServer is
    # down, public functions hit :undefined and fail; the supervisor
    # restarts us quickly under :permanent.
    ensure_table()
    {:ok, %{}}
  end

  ## -- public API --------------------------------------------------------

  @doc """
  Records a stop `intent` for `run_id`, preserving any harness run id
  already registered via `register_agent/2`.
  """
  @spec request(String.t(), :pause | :cancel) :: :ok
  def request(run_id, intent)
      when is_binary(run_id) and intent in [:pause, :cancel] do
    {_intent, harness_run_id} = lookup(run_id)
    :ets.insert(@table, {run_id, {intent, harness_run_id}})
    :ok
  end

  @doc """
  Returns the recorded stop intent for `run_id`, or `nil` when none is
  recorded.
  """
  @spec intent(String.t()) :: :pause | :cancel | nil
  def intent(run_id) when is_binary(run_id) do
    {intent, _harness_run_id} = lookup(run_id)
    intent
  end

  @doc """
  Records the harness run id backing `run_id`'s currently-executing
  agent, preserving any intent already recorded by `request/2`. Called
  by the worker when a harness run starts.
  """
  @spec register_agent(String.t(), String.t()) :: :ok
  def register_agent(run_id, harness_run_id)
      when is_binary(run_id) and is_binary(harness_run_id) do
    {intent, _harness_run_id} = lookup(run_id)
    :ets.insert(@table, {run_id, {intent, harness_run_id}})
    :ok
  end

  @doc "The harness run id currently registered for `run_id`'s agent, if any."
  @spec agent_run_id(String.t()) :: {:ok, String.t()} | {:error, :no_agent}
  def agent_run_id(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      {_intent, nil} -> {:error, :no_agent}
      {_intent, harness_run_id} -> {:ok, harness_run_id}
    end
  end

  @doc """
  Cancels the harness run registered for `run_id`, if any.

  `{:error, :no_agent}` covers both "no harness run has ever registered
  for this run" and "the harness could not cancel it" (e.g. it already
  reached a terminal state) — from a caller's perspective both mean
  there is nothing left to stop.
  """
  @spec cancel_agent(String.t()) :: :ok | {:error, :no_agent}
  def cancel_agent(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      {_intent, nil} ->
        {:error, :no_agent}

      {_intent, harness_run_id} ->
        case Run.cancel(harness_run_id) do
          :ok -> :ok
          {:error, _reason} -> {:error, :no_agent}
        end
    end
  end

  @doc """
  Appends a steering `message` (`%{message_id, text}`) to `run_id`'s
  mailbox. A message whose `message_id` is already queued is ignored.

  The mailbox is only a CACHE of the durable queue
  (`ProjectionStore.pending_steering/1`): `clear/1` wipes it on every
  executor terminate and every resume, so nothing may rely on it surviving.
  """
  @spec push_message(String.t(), %{message_id: String.t(), text: String.t()}) :: :ok
  def push_message(run_id, %{message_id: message_id, text: text} = message)
      when is_binary(run_id) and is_binary(message_id) and is_binary(text) do
    messages = peek_messages(run_id)

    unless Enum.any?(messages, &(&1.message_id == message_id)) do
      :ets.insert(@table, {{:messages, run_id}, messages ++ [message]})
    end

    :ok
  end

  @doc "Returns `run_id`'s cached steering messages in queue order, without removing them."
  @spec peek_messages(String.t()) :: [
          %{
            required(:message_id) => String.t(),
            required(:text) => String.t(),
            optional(:approval_mode_override) => String.t() | nil
          }
        ]
  def peek_messages(run_id) when is_binary(run_id) do
    case :ets.lookup(@table, {:messages, run_id}) do
      [{_key, messages}] -> messages
      [] -> []
    end
  end

  @doc "Removes the cached messages whose ids are in `message_ids`; others stay queued."
  @spec drain_messages(String.t(), [String.t()]) :: :ok
  def drain_messages(run_id, message_ids) when is_binary(run_id) and is_list(message_ids) do
    case Enum.reject(peek_messages(run_id), &(&1.message_id in message_ids)) do
      [] -> :ets.delete(@table, {:messages, run_id})
      rest -> :ets.insert(@table, {{:messages, run_id}, rest})
    end

    :ok
  end

  @doc "Drops the recorded intent/harness run id and cached steering messages for `run_id`. No-op when absent."
  @spec clear(String.t()) :: :ok
  def clear(run_id) when is_binary(run_id) do
    :ets.delete(@table, run_id)
    :ets.delete(@table, {:messages, run_id})
    :ok
  end

  ## -- private -----------------------------------------------------------

  defp lookup(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, {intent, harness_run_id}}] -> {intent, harness_run_id}
      [] -> {nil, nil}
    end
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
