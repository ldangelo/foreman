defmodule ForemanServer.TaskProviders.ConcurrencyLimiter do
  @moduledoc """
  Per-project concurrency limiter for task providers.

  The limiter enforces `:max_in_flight` concurrent operations per project,
  queueing additional callers until a slot becomes available or their
  configured timeout elapses.
  """

  use GenServer

  @app :foreman_server
  @default_max_in_flight 4
  @default_timeout_ms 30_000

  @type project_id :: term()
  @type waiter :: {project_id(), GenServer.from(), reference(), reference()}
  @type state :: %{
          in_flight: %{optional(project_id()) => non_neg_integer()},
          waiters: :queue.queue(waiter()),
          max_in_flight: pos_integer(),
          timeout_ms: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Acquire a project-scoped slot.

  Returns `:ok` when a slot is available immediately or after waiting in the
  queue. Returns `{:error, :timeout}` when the per-call timeout elapses before
  a slot becomes available.
  """
  @spec acquire(project_id(), non_neg_integer() | nil) :: :ok | {:error, :timeout}
  def acquire(project_id, timeout_ms \\ nil) do
    GenServer.call(__MODULE__, {:acquire, project_id, timeout_ms}, :infinity)
  end

  @doc """
  Release a project-scoped slot.
  """
  @spec release(project_id()) :: :ok
  def release(project_id) do
    GenServer.call(__MODULE__, {:release, project_id})
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(@app, :task_provider, [])

    state = %{
      in_flight: %{},
      waiters: :queue.new(),
      max_in_flight: Keyword.get(config, :max_in_flight, @default_max_in_flight),
      timeout_ms: Keyword.get(config, :timeout_ms, @default_timeout_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, project_id, timeout_ms}, from, state) do
    current_in_flight = Map.get(state.in_flight, project_id, 0)

    if current_in_flight < state.max_in_flight do
      next_state = %{
        state
        | in_flight: put_in_flight(state.in_flight, project_id, current_in_flight + 1)
      }

      {:reply, :ok, next_state}
    else
      waiter_ref = make_ref()

      timeout_ref =
        Process.send_after(self(), {:waiter_timeout, waiter_ref}, timeout_ms || state.timeout_ms)

      next_waiters = :queue.in({project_id, from, waiter_ref, timeout_ref}, state.waiters)
      {:noreply, %{state | waiters: next_waiters}}
    end
  end

  def handle_call({:release, project_id}, _from, state) do
    current_in_flight = Map.get(state.in_flight, project_id, 0)

    case current_in_flight do
      count when count <= 0 ->
        {:reply, :ok, state}

      count ->
        decremented = put_in_flight(state.in_flight, project_id, count - 1)
        base_state = %{state | in_flight: decremented}

        case dequeue_waiter(base_state.waiters, project_id) do
          {:ok, {_project_id, waiter_from, _waiter_ref, timeout_ref}, remaining_waiters} ->
            Process.cancel_timer(timeout_ref, async: false, info: false)
            GenServer.reply(waiter_from, :ok)

            granted_state = %{
              base_state
              | waiters: remaining_waiters,
                in_flight:
                  put_in_flight(
                    base_state.in_flight,
                    project_id,
                    Map.get(base_state.in_flight, project_id, 0) + 1
                  )
            }

            {:reply, :ok, granted_state}

          :error ->
            {:reply, :ok, base_state}
        end
    end
  end

  @impl true
  def handle_info({:waiter_timeout, waiter_ref}, state) do
    case drop_waiter(state.waiters, waiter_ref) do
      {:ok, {_project_id, from, ^waiter_ref, _timeout_ref}, remaining_waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: remaining_waiters}}

      :error ->
        {:noreply, state}
    end
  end

  defp put_in_flight(in_flight, project_id, 0), do: Map.delete(in_flight, project_id)
  defp put_in_flight(in_flight, project_id, count), do: Map.put(in_flight, project_id, count)

  defp dequeue_waiter(waiters, project_id) do
    take_waiter(waiters, fn {queued_project_id, _from, _waiter_ref, _timeout_ref} ->
      queued_project_id == project_id
    end)
  end

  defp drop_waiter(waiters, waiter_ref) do
    take_waiter(waiters, fn {_project_id, _from, queued_waiter_ref, _timeout_ref} ->
      queued_waiter_ref == waiter_ref
    end)
  end

  defp take_waiter(waiters, matcher) do
    {matched_waiter, remaining_waiters} =
      waiters
      |> :queue.to_list()
      |> Enum.reduce({nil, []}, fn waiter, {matched, remaining} ->
        if is_nil(matched) and matcher.(waiter) do
          {waiter, remaining}
        else
          {matched, [waiter | remaining]}
        end
      end)

    case matched_waiter do
      nil ->
        :error

      waiter ->
        {:ok, waiter, :queue.from_list(Enum.reverse(remaining_waiters))}
    end
  end
end
