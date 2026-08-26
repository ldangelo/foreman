defmodule ForemanServer.PrMonitor do
  @moduledoc """
  TRD-017: Polling fallback for PR state when webhooks are missed or
  reordered. Periodically fetches the current PR status for every
  associated run and emits `run.pr.update` commands through the
  `CommandRouter` so the run projection reflects the canonical state.

  ## Configuration

    * `:pr_monitor_interval_ms` — poll cadence (default 5 minutes).
    * `:pr_monitor_enabled` — when false, the GenServer starts but does
      not schedule the recurring poll (useful for tests / dev).
    * `:pr_monitor_fetch_fun` — a 1-arity `fetch_fun(pr_url)` returning
      one of `{:ok, status}`, `{:error, :not_found}`, or
      `{:error, :transient}`.

  ## Example

      Application.put_env(:foreman_server, :pr_monitor_interval_ms, 60_000)
      Application.put_env(:foreman_server, :pr_monitor_enabled, true)
      {:ok, _} = PrMonitor.start_link([])
  """

  use GenServer

  alias ForemanServer.ProjectionStore
  alias ForemanServer.PrAssociate
  alias ForemanServer.CommandGateway

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
  `pr_url` argument and return `{:ok, status}` where status is an
  atom (`:open`, `:merged`, `:closed`, `:conflicted`, `:reopened`).
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
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
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
          {:ok, status} ->
            dispatch_update(assoc, status)
            {ok + 1, err}

          {:error, _} ->
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

  defp dispatch_update(assoc, status) do
    {:ok, run_id} = Map.fetch(assoc, :run_id)
    {:ok, pr_url} = Map.fetch(assoc, :pr_url)

    command = %{
      type: "run.pr.update",
      aggregate_id: "run:#{run_id}",
      payload: %{
        run_id: run_id,
        pr_url: pr_url,
        pr_status: status,
        head_sha: Map.get(assoc, :head_sha),
        base_branch: Map.get(assoc, :base_branch),
        phase: status_to_phase(status),
        last_polled_at: System.system_time(:millisecond)
      }
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _event_spec} -> :ok
      {:error, _} -> :error
    end
  end

  defp status_to_phase(:merged), do: "merge_pending"
  defp status_to_phase(:open), do: "pr_open"
  defp status_to_phase(:closed), do: "pr_closed"
  defp status_to_phase(:conflicted), do: "pr_conflict"
  defp status_to_phase(:reopened), do: "pr_open"
  defp status_to_phase(_), do: "pr_open"

  defp schedule_poll(interval) when interval > 0 do
    Process.send_after(self(), :poll, interval)
  end

  defp default_fetch(_url), do: {:error, :not_configured}
end
