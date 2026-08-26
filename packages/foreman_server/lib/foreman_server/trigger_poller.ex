defmodule ForemanServer.TriggerPoller do
  @moduledoc """
  TRD-015: External trigger polling fallback.

  Pulls pending triggers from an external system when push-based
  webhooks are unavailable. Fetches are delegated to an injected
  `fetch_fun/0` (defaults to a no-op stub); each fetched trigger is
  routed through `SharedInbox.ingest/2` so dedup and delivery status
  share the canonical path.

  ## Configuration

    * `:trigger_poll_interval_ms` — poll cadence (default 60_000)
    * `:trigger_poll_enabled` — when false, the GenServer is started
      but does not poll (useful for tests / dev).
    * `:trigger_poll_source_module` — module implementing
      `InboxItemCorrelationId` that drives the dedupe key.
    * `:trigger_webhook_source_module` — same, for the webhook
      controller path.

  ## Example

      Application.put_env(:foreman_server, :trigger_poll_interval_ms, 30_000)
      Application.put_env(:foreman_server, :trigger_poll_enabled, true)
      {:ok, _} = TriggerPoller.start_link([])
  """

  use GenServer

  alias ForemanServer.Inbox.SharedInbox

  require Logger

  @default_interval_ms 60_000
  @default_source_module ForemanServer.TriggerPoller.StubSource

  # -- public API ----------------------------------------------------------

  @doc """
  Returns the configured poll interval in milliseconds.
  """
  def interval_ms do
    Application.get_env(:foreman_server, :trigger_poll_interval_ms, @default_interval_ms)
  end

  @doc """
  Returns the configured source module implementing
  `InboxItemCorrelationId`. Falls back to the default when the env is
  unset or explicitly nil.
  """
  def source_module do
    case Application.get_env(:foreman_server, :trigger_poll_source_module, :unset) do
      :unset -> @default_source_module
      nil -> @default_source_module
      mod -> mod
    end
  end

  @doc """
  Whether polling is enabled. When false, the GenServer still starts but
  will not schedule the recurring poll.
  """
  def enabled? do
    Application.get_env(:foreman_server, :trigger_poll_enabled, false)
  end

  @doc """
  Inject the fetch function used by the poller. Must return a list of
  raw trigger payloads (maps). Defaults to `&default_fetch/0`.
  """
  def set_fetch_fun(fun) when is_function(fun, 0) do
    :persistent_term.put({__MODULE__, :fetch_fun}, fun)
  end

  def fetch_fun do
    case :persistent_term.get({__MODULE__, :fetch_fun}, :unset) do
      :unset -> &default_fetch/0
      fun -> fun
    end
  end

  @doc """
  Start the poller. Idempotent — returns `{:ok, pid}` even if already
  started under the registered name.
  """
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Synchronous barrier for tests: triggers an immediate fetch and returns
  the number of triggers ingested.
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

    {:ok, %{last_run_at: nil, last_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    schedule_poll(interval_ms())
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    new_state = do_poll(state)
    {:reply, new_state.last_count, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  # -- private -------------------------------------------------------------

  defp do_poll(state) do
    count =
      try do
        ingest_fetched(source_module())
      rescue
        e ->
          Logger.warning("TriggerPoller.fetch failed: #{inspect(e)}")
          0
      end

    %{state | last_run_at: System.system_time(:millisecond), last_count: count}
  end

  defp ingest_fetched(source_module) do
    fetch_fun().()
    |> Enum.reduce(0, fn payload, acc ->
      case SharedInbox.ingest(source_module, payload) do
        {:ok, _, _} -> acc + 1
        {:error, _} -> acc
      end
    end)
  end

  defp schedule_poll(interval) when interval > 0 do
    Process.send_after(self(), :poll, interval)
  end

  defp default_fetch, do: []
end
