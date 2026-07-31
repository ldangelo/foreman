defmodule ForemanServer.Inbox.TriggerPoller do
  @moduledoc """
  Periodic external-trigger polling GenServer.

  When `external_trigger_endpoint_url` is configured (non-nil, non-empty) and
  `external_trigger_poll_enabled` is `true`, this GenServer polls that endpoint
  every `external_trigger_poll_interval_seconds` seconds (default: 60) and
  submits each pending trigger through `SharedInbox.ingest/2` for deduplication
  and normal inbox routing.

  If the endpoint URL is not configured, the GenServer starts and immediately
  idles — no timers, no HTTP calls, no noise in tests or default deployments.
  """

  use GenServer

  require Logger

  alias ForemanServer.Inbox.SharedInbox
  alias ForemanServer.Inbox.ExternalTriggerCorrelationId

  # ─── Client API ───────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ─── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    endpoint_url = Application.get_env(:foreman_server, :external_trigger_endpoint_url)
    enabled? = Application.get_env(:foreman_server, :external_trigger_poll_enabled, false)
    interval_seconds = Application.get_env(:foreman_server, :external_trigger_poll_interval_seconds, 60)

    if enabled? and is_binary(endpoint_url) and endpoint_url != "" do
      interval_ms = interval_seconds * 1000
      schedule_poll(interval_ms)
      {:ok, %{endpointurl: endpoint_url, interval_ms: interval_ms}}
    else
      {:ok, %{endpointurl: nil, interval_ms: 0}, :hibernate}
    end
  end

  @impl true
  def handle_info(:poll, %{endpointurl: url} = state) do
    fetch_and_submit_triggers(url)
    schedule_poll(state.interval_ms)
    {:noreply, state}
  end

  # ─── Polling ──────────────────────────────────────────────────────────────

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp fetch_and_submit_triggers(endpoint_url) when is_binary(endpoint_url) do
    # :httpc expects URL as charlist, headers as charlist list, body_format in Options.
    url_charlist = String.to_charlist(endpoint_url)
    headers = [] |> Enum.map(&String.to_charlist/1)

    case :httpc.request(:get, {url_charlist, headers}, [], [{:body_format, :binary}]) do
      {:ok, {{_version, 200, _phrase}, _headers, body}} ->
        parse_and_submit(body)

      {:ok, {{_version, status, phrase}, _headers, _body}} ->
        Logger.warning("[TriggerPoller] endpoint returned #{status} #{phrase}: #{endpoint_url}")

      {:error, reason} ->
        Logger.warning("[TriggerPoller] failed to fetch triggers: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[TriggerPoller] HTTP error: #{inspect(e)}")
  end

  defp parse_and_submit(body) do
    case Jason.decode(body) do
      {:ok, %{"triggers" => triggers}} when is_list(triggers) ->
        Enum.each(triggers, &submit_trigger/1)

      {:ok, triggers} when is_list(triggers) ->
        Enum.each(triggers, &submit_trigger/1)

      {:ok, _other} ->
        Logger.warning("[TriggerPoller] unexpected response shape from trigger endpoint")

      {:error, reason} ->
        Logger.warning("[TriggerPoller] failed to parse trigger response: #{inspect(reason)}")
    end
  end

  defp submit_trigger(trigger) when is_map(trigger) do
    case SharedInbox.ingest(ExternalTriggerCorrelationId, trigger) do
      {:ok, %{event: event}} ->
        Logger.info("[TriggerPoller] submitted trigger: #{event.event_type}")

      {:error, reason} ->
        Logger.debug("[TriggerPoller] trigger rejected: #{inspect(reason)}")
    end
  end
end
