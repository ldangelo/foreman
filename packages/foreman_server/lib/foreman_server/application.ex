defmodule ForemanServer.Application do
  @moduledoc """
  OTP application for ForemanServer.

  Starts:
  - EventStore (Postgrex-backed event log — single source of truth)
  - Aggregator supervisor (Registry + aggregate Actor children, `:permanent` restart)
  - CommandRouter (GenServer — sole append point)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # PubSub backs LiveView debug subscriptions.
        {Phoenix.PubSub, name: ForemanServer.PubSub},
        # Phoenix Presence tracks live aggregate actors for debug pages.
        ForemanServerWeb.Presence,
        # EventStore must be started first (ProjectionStore subscribes to it).
        ForemanServer.EventStore,
        # ProjectionStore subscribes to EventStore and maintains read model.
        ForemanServer.ProjectionStore,
        # DedupeTable owns the dedupe ETS table; started before Inbox.Poller
        # so the long-lived owner outlives any transient caller that may have
        # lazily created the table before Poller subscribed.
        ForemanServer.Inbox.DedupeTable,
        # Inbox.Poller consumes InboxItemStarted/Deduped events emitted by SharedInbox.
        ForemanServer.Inbox.Poller,
        # Aggregator starts the Registry and supervises Actor children.
        ForemanServer.Aggregator,

        # RunExecutorRegistry must exist before RunExecutor children start;
        # RunSupervisor and Dispatcher both rely on it for via-tuple lookup.
        {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
        # Workflow.Catalog owns the in-memory workflow + prompt snapshots,
        # auto-installs the bundled templates on first boot, and reloads
        # files when the directory changes. Must start before any code path
        # that resolves a workflow (CommandRouter, Dispatcher, RunExecutor).
        ForemanServer.Workflow.Catalog,
        ForemanServer.Workflow.RunSupervisor,
        # Dispatcher subscribes to ProjectionStore and reacts to TaskDispatched.
        ForemanServer.Workflow.Dispatcher,
        # CommandRouter handles all append requests.
        ForemanServer.CommandRouter
      ] ++
        maybe_agent_runtime_child() ++
        maybe_overwatch_child() ++
        maybe_stuck_detector_child() ++
        [
          # Endpoint exposes dev-only debug LiveViews.
          ForemanServerWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end

  defp maybe_agent_runtime_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{ForemanServer.AgentRuntime.Supervisor, []}]

      _ ->
        []
    end
  end

  defp maybe_overwatch_child do
    case Application.get_env(:foreman_server, ForemanServer.Overwatch, []) do
      opts when is_list(opts) ->
        if Keyword.get(opts, :enabled, false) do
          merged =
            opts
            |> Keyword.put_new(:crash_loop_detector_enabled, true)
            |> Keyword.put_new(:crash_loop_window_ms, 5 * 60 * 1000)
            |> Keyword.put_new(:crash_loop_threshold, 3)

          [{ForemanServer.Overwatch, merged}]
        else
          []
        end

      _ ->
        []
    end
  end

  defp maybe_stuck_detector_child do
    seconds =
      Application.get_env(:foreman_server, :stuck_run_check_interval_seconds, 60)

    [{ForemanServer.StuckDetector, [interval_ms: seconds * 1000]}]
  end

  @impl true
  def config_change(changed, _new, removed) do
    ForemanServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
