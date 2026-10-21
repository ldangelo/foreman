defmodule ForemanServer.PrMonitor do
  @moduledoc """
  TRD-017: Polling fallback for PR state when webhooks are missed or
  reordered. Periodically reads the current PR state from GitHub
  (`ForemanServer.GitHub.PrStatus`) for every associated run and dispatches a
  `run.pr.update` command, which appends `PrUpdated` to the run's stream. A
  repeated poll that observes the same status and head SHA reuses one
  deterministic `command_id`, so the router deduplicates it instead of
  appending an event per poll.

  ## Configuration

    * `:pr_monitor_interval_ms` — poll cadence (default 5 minutes).
    * `:pr_monitor_enabled` — when false, the GenServer starts but does
      not schedule the recurring poll (useful for tests / dev).

  The fetch function is not a config key: tests inject one with
  `set_fetch_fun/1`; it receives a `pr_url` and returns
  `{:ok, %ForemanServer.GitHub.PrStatus{}}` or `{:error, reason}`.

  ## Example

      Application.put_env(:foreman_server, :pr_monitor_interval_ms, 60_000)
      Application.put_env(:foreman_server, :pr_monitor_enabled, true)
      {:ok, _} = PrMonitor.start_link([])
  """

  use GenServer

  alias ForemanServer.ProjectionStore
  alias ForemanServer.PrAssociate
  alias ForemanServer.CommandGateway
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrUpdate

  require Logger

  @default_interval_ms 5 * 60 * 1000

  # -- public API ----------------------------------------------------------

  @doc """
  Returns the configured poll interval in milliseconds.
  """
  def interval_ms do
    Application.get_env(:foreman_server, :pr_monitor_interval_ms, @default_interval_ms)
  end

  @doc """
  Whether polling is enabled.
  """
  def enabled? do
    Application.get_env(:foreman_server, :pr_monitor_enabled, false)
  end

  @doc """
  Inject the fetch function used by the poller. Must accept a single
  `pr_url` argument and return `{:ok, %ForemanServer.GitHub.PrStatus{}}`
  or `{:error, reason}`.
  """
  def set_fetch_fun(fun) when is_function(fun, 1) do
    :persistent_term.put({__MODULE__, :fetch_fun}, fun)
  end

  def fetch_fun do
    case :persistent_term.get({__MODULE__, :fetch_fun}, :unset) do
      :unset -> &default_fetch/1
      fun -> fun
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronous barrier: collect all PR associations, run fetch, and
  return the number of `run.pr.update` commands dispatched.
  """
  def poll_now do
    GenServer.call(__MODULE__, :poll_now)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # -- GenServer callbacks --------------------------------------------------

  @impl true
  def init(_opts) do
    if enabled?() do
      schedule_poll(interval_ms())
    end

    {:ok, %{last_run_at: nil, last_count: 0, last_errors: 0}}
  end

  @impl true
  def handle_info(:poll, _state) do
    new_state = do_poll()
    schedule_poll(interval_ms())
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:poll_now, _from, _state) do
    new_state = do_poll()
    {:reply, new_state.last_count, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  # -- private -------------------------------------------------------------

  defp do_poll do
    fun = fetch_fun()
    associations = collect_associations()

    {count, errors} =
      Enum.reduce(associations, {0, 0}, fn assoc, {ok, err} ->
        case safe_fetch(fun, assoc.pr_url) do
          {:ok, %PrStatus{} = pr} ->
            case dispatch_update(assoc, pr) do
              :ok -> {ok + 1, err}
              {:error, _} -> {ok, err + 1}
            end

          {:error, reason} ->
            Logger.warning(
              "PrMonitor.fetch failed run_id=#{assoc.run_id} url=#{assoc.pr_url}: " <>
                inspect(reason)
            )

            {ok, err + 1}
        end
      end)

    %{
      last_run_at: System.system_time(:millisecond),
      last_count: count,
      last_errors: errors
    }
  end

  defp collect_associations do
    case ProjectionStore.list_runs() do
      runs when is_list(runs) ->
        for run <- runs, run_id = Map.get(run, :run_id) do
          case PrAssociate.lookup(run_id) do
            {:ok, assoc} -> assoc
            _ -> nil
          end
        end
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp safe_fetch(fun, url) do
    fun.(url)
  rescue
    e ->
      Logger.warning("PrMonitor.fetch failed: #{inspect(e)}")
      {:error, :fetch_crashed}
  end

  # The payload contract and the deduplicating command id live in
  # `ForemanServer.PrUpdate`, shared with the webhook. A rejected dispatch was
  # once swallowed and counted as a success; it is now an error in the poll's tally.
  defp dispatch_update(assoc, %PrStatus{} = pr) do
    run_id = assoc.run_id

    with {:ok, command} <- PrUpdate.command(run_id, assoc.pr_url, pr) do
      case CommandGateway.dispatch_system(command) do
        {:ok, _event_spec} -> :ok
        {:error, reason} -> report_dispatch_failure(run_id, reason)
        {:error, reason, _detail} -> report_dispatch_failure(run_id, reason)
      end
    else
      {:error, reason} -> report_dispatch_failure(run_id, reason)
    end
  end

  defp report_dispatch_failure(run_id, reason) do
    Logger.error("PrMonitor run.pr.update rejected run_id=#{run_id}: #{inspect(reason)}")
    {:error, reason}
  end

  defp schedule_poll(interval) when interval > 0 do
    Process.send_after(self(), :poll, interval)
  end

  defp default_fetch(url), do: PrStatus.fetch(url)
end
