defmodule ForemanServer.PrMonitor do
  @moduledoc """
  TRD-017 / E9: the polling tier of PR watching. Spike S4 decided polling is the
  primary signal source (Foreman is usually not reachable by GitHub webhooks),
  so this process sweeps `ProjectionStore.watched_prs/0` - watched PRs that are
  neither merged, closed nor stopped - and observes each through
  `ForemanServer.PrWatcher.Observer`. That is the same code path the webhook
  accelerator and the `PrWatcher` subscriber use, so all three produce one
  deterministic command id per distinct observation and the router deduplicates.

  ## Adaptive schedule (spike S4)

  Each PR has its own next-due time, chosen from its last observed state by the
  pure `next_interval/3`:

    * any check still running, or `UNKNOWN` merge state: `:pr_monitor_pending_interval_ms` (30 s);
    * a change within the last 10 minutes: 60 s;
    * idle for more than 24 h: 15 minutes;
    * otherwise `:pr_monitor_interval_ms` (5 minutes).

  All intervals get +/-10% jitter. A failing PR backs off 2x per consecutive
  failure up to 15 minutes; a rate-limited `gh` pauses the whole sweep (the
  `Retry-After` seconds when `gh` printed them, else 60 s). A scheduled tick
  observes at most `:pr_monitor_max_per_tick` (default 25) due PRs, longest
  unobserved first, to bound `gh` usage.

  ## Configuration

    * `:pr_monitor_enabled` - when false the GenServer does not schedule ticks
      (default false; env `FOREMAN_PR_MONITOR_ENABLED=true` turns it on).
    * `:pr_monitor_interval_ms` - the stable interval (default 5 minutes).
    * `:pr_monitor_pending_interval_ms` - default 30 seconds.
    * `:pr_monitor_max_per_tick` - default 25.

  The fetch function is not a config key: tests inject one with
  `set_fetch_fun/1`; it receives a `pr_url` and returns
  `{:ok, %ForemanServer.GitHub.PrStatus{}}` or `{:error, reason}`.
  """

  use GenServer

  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.ProjectionStore

  require Logger

  @default_interval_ms 5 * 60 * 1000
  @default_pending_interval_ms 30_000
  @default_max_per_tick 25
  @recent_change_ms 10 * 60 * 1000
  @recent_interval_ms 60_000
  @idle_after_ms 24 * 60 * 60 * 1000
  @idle_interval_ms 15 * 60 * 1000
  @max_backoff_ms 15 * 60 * 1000
  @default_rate_limit_pause_ms 60_000
  @jitter 0.1

  # -- public API ----------------------------------------------------------

  @doc "Returns the configured stable poll interval in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Application.get_env(:foreman_server, :pr_monitor_interval_ms, @default_interval_ms)
  end

  @doc "Interval used while any check of the PR is still running."
  @spec pending_interval_ms() :: pos_integer()
  def pending_interval_ms do
    Application.get_env(
      :foreman_server,
      :pr_monitor_pending_interval_ms,
      @default_pending_interval_ms
    )
  end

  @doc "Maximum PRs observed by one scheduled tick."
  @spec max_per_tick() :: pos_integer()
  def max_per_tick do
    Application.get_env(:foreman_server, :pr_monitor_max_per_tick, @default_max_per_tick)
  end

  @doc "Whether polling is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:foreman_server, :pr_monitor_enabled, false)
  end

  @doc """
  Inject the fetch function used by the poller. Must accept a single
  `pr_url` argument and return `{:ok, %ForemanServer.GitHub.PrStatus{}}`
  or `{:error, reason}`.
  """
  @spec set_fetch_fun((String.t() -> {:ok, struct()} | {:error, term()})) :: :ok
  def set_fetch_fun(fun) when is_function(fun, 1) do
    :persistent_term.put({__MODULE__, :fetch_fun}, fun)
  end

  @doc "The fetch function in effect (the injected one, else `Observer.default_fetch/1`)."
  @spec fetch_fun() :: (String.t() -> {:ok, struct()} | {:error, term()})
  def fetch_fun do
    case :persistent_term.get({__MODULE__, :fetch_fun}, :unset) do
      :unset -> &Observer.default_fetch/1
      fun -> fun
    end
  end

  @doc "Start the monitor, registered under its module name (a second start returns the first)."
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronous barrier: observe every watched PR (ignoring due times and the
  per-tick cap) and return how many observations succeeded.
  """
  @spec poll_now() :: non_neg_integer()
  def poll_now do
    GenServer.call(__MODULE__, :poll_now, 120_000)
  end

  @doc "Counters of the last sweep."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Milliseconds until the next observation of a PR whose watch record is
  `record`, at time `now_ms`. Pure. `opts[:jitter]` is a fixed jitter fraction
  (default: random within +/-10%).
  """
  @spec next_interval(map(), integer(), keyword()) :: pos_integer()
  def next_interval(record, now_ms, opts \\ []) do
    base =
      cond do
        record.checks_state == "pending" -> pending_interval_ms()
        recent?(record, now_ms) -> @recent_interval_ms
        idle?(record, now_ms) -> @idle_interval_ms
        true -> interval_ms()
      end

    jitter = Keyword.get_lazy(opts, :jitter, fn -> (:rand.uniform() * 2 - 1) * @jitter end)
    max(1, round(base * (1 + jitter)))
  end

  defp recent?(%{updated_at: at}, now_ms) when is_integer(at), do: now_ms - at < @recent_change_ms
  defp recent?(_record, _now_ms), do: false

  defp idle?(%{updated_at: at}, now_ms) when is_integer(at), do: now_ms - at > @idle_after_ms
  defp idle?(_record, _now_ms), do: false

  # -- GenServer callbacks --------------------------------------------------

  @impl true
  def init(_opts) do
    if enabled?() do
      schedule_poll(interval_ms())
    end

    {:ok,
     %{
       last_run_at: nil,
       last_count: 0,
       last_errors: 0,
       due: %{},
       failures: %{},
       backlog: 0,
       paused_until: nil
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    now = now_ms()

    state =
      if paused?(state, now), do: state, else: sweep(state, :due, now)

    schedule_poll(next_delay(state, now_ms()))
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    new_state = sweep(state, :all, now_ms())
    {:reply, new_state.last_count, new_state}
  end

  def handle_call(:stats, _from, state), do: {:reply, state, state}

  # -- sweep ---------------------------------------------------------------

  defp sweep(state, mode, now) do
    fun = fetch_fun()

    watched = ProjectionStore.watched_prs() |> Enum.uniq_by(& &1.pr_url)
    {batch, backlog} = due_batch(watched, state, mode, now)

    {state, count, errors} =
      Enum.reduce_while(batch, {state, 0, 0}, fn record, {acc, ok, err} ->
        case Observer.observe(record.pr_url, fetch_fun: fun) do
          {:ok, _result} ->
            {:cont, {schedule_after_success(acc, record, now), ok + 1, err}}

          # No run owns the PR any more, or its watch ended: nothing to observe.
          {:error, :not_watched} ->
            {:cont, {acc, ok, err}}

          {:error, reason} ->
            Logger.warning("PrMonitor observe failed url=#{record.pr_url}: #{inspect(reason)}")
            acc = schedule_after_failure(acc, record, reason, now)
            # A rate limit pauses the whole sweep: stop instead of hitting `gh`
            # again for every remaining PR in the batch.
            if paused?(acc, now),
              do: {:halt, {acc, ok, err + 1}},
              else: {:cont, {acc, ok, err + 1}}
        end
      end)

    # Entries of PRs no longer watched (merged, closed, stopped, not_watched)
    # would otherwise stay in `due` and pin `next_delay/2` to its 1 s floor.
    live = MapSet.new(watched, & &1.pr_url)

    %{
      state
      | due: Map.filter(state.due, fn {url, _} -> MapSet.member?(live, url) end),
        failures: Map.filter(state.failures, fn {url, _} -> MapSet.member?(live, url) end),
        backlog: backlog,
        last_run_at: System.system_time(:millisecond),
        last_count: count,
        last_errors: errors
    }
  end

  # A scheduled tick takes only the due PRs, capped. `poll_now/0` is a barrier: it
  # observes every watched PR (ignoring due times and the cap).
  # Returns `{batch, backlog}`: `backlog` is how many due PRs the cap left for the
  # next tick.
  defp due_batch(records, _state, :all, _now), do: {records, 0}

  defp due_batch(records, state, :due, now) do
    due = Enum.filter(records, &(Map.get(state.due, &1.pr_url, 0) <= now))
    batch = Enum.take(due, max_per_tick())
    {batch, length(due) - length(batch)}
  end

  defp schedule_after_success(state, record, now) do
    fresh = fresh_record(record)
    due = now + next_interval(fresh, now)

    %{
      state
      | due: Map.put(state.due, record.pr_url, due),
        failures: Map.delete(state.failures, record.pr_url)
    }
  end

  defp schedule_after_failure(state, record, reason, now) do
    failures = Map.get(state.failures, record.pr_url, 0) + 1
    backoff = min(@max_backoff_ms, pending_interval_ms() * Integer.pow(2, failures))

    state = %{
      state
      | due: Map.put(state.due, record.pr_url, now + backoff),
        failures: Map.put(state.failures, record.pr_url, failures)
    }

    case rate_limit_pause(reason) do
      nil -> state
      pause_ms -> %{state | paused_until: now + pause_ms}
    end
  end

  # The record as it is after the observation's own events were applied.
  defp fresh_record(record) do
    Enum.find(ProjectionStore.pr_watch(record.run_id), record, &(&1.pr_url == record.pr_url))
  end

  # `gh` reports a rate limit as an HTTP 403/429 in its output; honour a
  # `Retry-After: <seconds>` it printed, else pause a minute.
  defp rate_limit_pause({:gh_failed, _code, output}) when is_binary(output) do
    # A bare 403 (revoked token, repo the token cannot read) is not a rate limit;
    # GitHub's rate-limit 403 says so in its message.
    if Regex.match?(~r/rate limit|HTTP 429/i, output) do
      case Regex.run(~r/retry-after:?\s*(\d+)/i, output) do
        [_, seconds] -> String.to_integer(seconds) * 1000
        nil -> @default_rate_limit_pause_ms
      end
    end
  end

  defp rate_limit_pause(_reason), do: nil

  defp paused?(%{paused_until: nil}, _now), do: false
  defp paused?(%{paused_until: until}, now), do: until > now

  defp next_delay(state, now) do
    soonest =
      cond do
        state.backlog > 0 -> 1_000
        state.due == %{} -> interval_ms()
        true -> max(Enum.min(Map.values(state.due)) - now, 1_000)
      end

    pause = if paused?(state, now), do: state.paused_until - now, else: 0
    min(interval_ms(), max(soonest, pause))
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp schedule_poll(interval) when interval > 0 do
    Process.send_after(self(), :poll, interval)
  end
end
