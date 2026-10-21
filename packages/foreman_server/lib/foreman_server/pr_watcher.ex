defmodule ForemanServer.PrWatcher do
  @moduledoc """
  Watches the pull requests of runs (E9): turns what GitHub reports into typed
  events on the owning run's stream and, in later stories, starts fix threads.

  Shape: a `ProjectionStore` subscriber like `Messaging.Dispatcher` and
  `Review.Analyzer`. `init/1` subscribes with `replay_existing: false` - a
  restart must not re-observe history - and a failed subscribe crashes the
  process (it is not swallowed). It reacts to:

    * `PrAssociated`, `PrReady`, `PrWatchStarted` - observe the PR immediately
      instead of waiting for the next poll;
    * every other event - ignored, state unchanged (so the observations the
      watcher itself causes can never feed back into it).

  Observation is `ForemanServer.PrWatcher.Observer` (one fetch, deterministic
  commands, so a poll, a webhook and this subscriber converge on one event).
  Work runs in a task under a private `Task.Supervisor`, never in the
  subscription callback, so a slow `gh` cannot back up the projection broadcast.
  Refreshes of one PR are single-flight: concurrent `refresh_now/2` callers
  share one fetch. Delivery from the projection is at-least-once, which is safe
  because observation is idempotent by digest.

  Public API: `refresh/2` (async, used by webhooks), `refresh_now/2` (sync, used
  by tests and the poller), `stats/1`, `running?/1`.

  Configuration (`config :foreman_server, :pr_watcher, enabled: boolean`;
  env `FOREMAN_PR_WATCHER_ENABLED=false` turns it off). `gh` missing is
  reported in `stats/1` as `last_error: :gh_not_installed`; the process stays up.
  Polling is owned by `ForemanServer.PrMonitor` (`FOREMAN_PR_MONITOR_ENABLED`).
  """

  use GenServer

  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.ProjectionStore

  require Logger

  @refresh_timeout 120_000
  @observe_events ~w(PrAssociated PrReady PrWatchStarted)

  @type server :: GenServer.server()
  @type refresh_result :: {:ok, Observer.result()} | {:error, Observer.error()}

  # -- public API ------------------------------------------------------------

  @doc "Whether the watcher is enabled in configuration (default true)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:foreman_server, :pr_watcher, [])[:enabled] != false
  end

  @doc """
  Start the watcher. Options: `:name` (default `#{inspect(__MODULE__)}`),
  `:fetch_fun` (`pr_url -> {:ok, PrStatus.t()} | {:error, term()}`, defaults to
  `Observer.default_fetch/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether a watcher process is registered under `server`."
  @spec running?(server()) :: boolean()
  def running?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  @doc "Observe `pr_url` in the background. Returns `:ok` immediately."
  @spec refresh(String.t(), server()) :: :ok
  def refresh(pr_url, server \\ __MODULE__) when is_binary(pr_url),
    do: GenServer.cast(server, {:refresh, pr_url})

  @doc """
  Observe `pr_url` and wait for the result. Concurrent callers for one PR share
  a single fetch.
  """
  @spec refresh_now(String.t(), server()) :: refresh_result()
  def refresh_now(pr_url, server \\ __MODULE__) when is_binary(pr_url),
    do: GenServer.call(server, {:refresh_now, pr_url}, @refresh_timeout)

  @doc "Counters and the last error."
  @spec stats(server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    case ProjectionStore.subscribe(replay_existing: false) do
      :ok ->
        {:ok,
         %{
           supervisor: supervisor,
           fetch_fun: Keyword.get(opts, :fetch_fun, &Observer.default_fetch/1),
           inflight: %{},
           observations: 0,
           errors: 0,
           last_error: nil
         }}

      {:error, reason} ->
        {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info({:projection_event, %{event_type: type, data: payload}}, state)
      when type in @observe_events and is_map(payload) do
    case pr_url(payload) do
      nil -> {:noreply, state}
      url -> {:noreply, start_refresh(state, url, nil)}
    end
  end

  def handle_info({:projection_event, _other}, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_refresh(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, finish_refresh(state, ref, {:error, {:refresh_crashed, reason}})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:refresh, pr_url}, state), do: {:noreply, start_refresh(state, pr_url, nil)}

  @impl true
  def handle_call({:refresh_now, pr_url}, from, state),
    do: {:noreply, start_refresh(state, pr_url, from)}

  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:observations, :errors, :last_error]), state}
  end

  # -- internals -------------------------------------------------------------

  # Single-flight per PR: a refresh already running for `pr_url` absorbs this
  # request, and a waiting caller is answered with that run's result.
  defp start_refresh(state, pr_url, waiter) do
    case Enum.find(state.inflight, fn {_ref, {url, _waiters}} -> url == pr_url end) do
      {ref, {url, waiters}} ->
        put_in(state.inflight[ref], {url, add_waiter(waiters, waiter)})

      nil ->
        fetch = state.fetch_fun

        task =
          Task.Supervisor.async_nolink(state.supervisor, fn ->
            Observer.observe(pr_url, fetch_fun: fetch)
          end)

        put_in(state.inflight[task.ref], {pr_url, add_waiter([], waiter)})
    end
  end

  defp add_waiter(waiters, nil), do: waiters
  defp add_waiter(waiters, from), do: [from | waiters]

  defp finish_refresh(state, ref, result) do
    {{_url, waiters}, inflight} = Map.pop(state.inflight, ref, {nil, []})
    Enum.each(waiters, &GenServer.reply(&1, result))
    state = %{state | inflight: inflight}

    case result do
      {:ok, _} ->
        %{state | observations: state.observations + 1}

      {:error, :not_watched} ->
        state

      {:error, reason} ->
        Logger.warning("PrWatcher refresh failed: #{inspect(reason)}")
        %{state | errors: state.errors + 1, last_error: reason}
    end
  end

  defp pr_url(payload) do
    case Map.get(payload, :pr_url) || Map.get(payload, "pr_url") do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
