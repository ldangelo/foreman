defmodule ForemanServer.Agents.DirectiveQueue do
  @moduledoc """
  Tracks pending directives awaiting dispatch to Jido agents.

  TRD-2026-4212be7e / JLD-T002 / TRD-056.

  This GenServer maintains an in-memory ETS table of queued directives
  keyed by directive id. Callers enqueue directives via `enqueue/1`
  and mark them dispatched via `dispatched/1`. The LiveDashboard
  queries the queue via `queued/0` to display pending items.

  ## Data shape

  Each entry in the ETS table is:
      {directive_id, %{id, agent_id, payload, enqueued_at, status: :pending | :dispatched}}

  The `:pending` entries are what the dashboard surfaces.
  """

  use GenServer
  require Logger

  @table :foreman_directive_queue

  # ─────────────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a directive for tracking.

  ## Arguments

    - `agent_id` — the target Jido agent id (binary)
    - `payload` — the directive body (map)
    - `opts` — optional keyword list. Pass `id:` to override the
      generated directive id.

  ## Returns

    `{:ok, directive_id :: String.t()}`
  """
  @spec enqueue(String.t(), map(), keyword()) :: {:ok, String.t()}
  def enqueue(agent_id, payload, opts \\ []) when is_binary(agent_id) and is_map(payload) do
    GenServer.call(__MODULE__, {:enqueue, agent_id, payload, opts})
  end

  @doc """
  Mark a directive as dispatched.

  ## Returns

    `:ok` on success, `{:error, :not_found}` if the directive id
    was not in the queue.
  """
  @spec dispatched(String.t()) :: :ok | {:error, :not_found}
  def dispatched(directive_id) when is_binary(directive_id) do
    GenServer.call(__MODULE__, {:dispatched, directive_id})
  end

  @doc """
  Return all queued (`:pending`) directives, oldest first.
  """
  @spec queued() :: [map()]
  def queued do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, entry} -> entry.status == :pending end)
    |> Enum.sort_by(fn {_id, entry} -> entry.enqueued_at end)
    |> Enum.map(fn {_id, entry} -> entry end)
  end

  @doc """
  Return the count of pending directives.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.tab2list(@table)
    |> Enum.count(fn {_id, entry} -> entry.status == :pending end)
  end

  @doc """
  Clear all entries from the queue. Primarily intended for testing.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ─────────────────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────────────────

  def init(_opts) do
    table_opts =
      case :ets.info(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _ ->
          @table
      end

    {:ok, %{}}
  end

  def handle_call({:enqueue, agent_id, payload, opts}, _from, state) do
    id =
      case Keyword.get(opts, :id) do
        nil -> "dir-#{System.unique_integer([:positive])}"
        custom -> custom
      end

    entry = %{
      id: id,
      agent_id: agent_id,
      payload: payload,
      enqueued_at: System.system_time(:millisecond),
      status: :pending
    }

    :ets.insert(@table, {id, entry})
    Logger.debug("Directive enqueued: id=#{id} agent=#{agent_id}")
    {:reply, {:ok, id}, state}
  end

  def handle_call({:dispatched, directive_id}, _from, state) do
    case :ets.lookup(@table, directive_id) do
      [{^directive_id, entry}] ->
        updated = %{entry | status: :dispatched}
        :ets.insert(@table, {directive_id, updated})
        Logger.debug("Directive dispatched: id=#{directive_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
