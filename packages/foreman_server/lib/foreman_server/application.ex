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
        # Aggregator starts the Registry and supervises Actor children.
        ForemanServer.Aggregator,
        # CommandRouter handles all append requests.
        ForemanServer.CommandRouter,
        # Endpoint exposes dev-only debug LiveViews.
        ForemanServerWeb.Endpoint
      ] ++ maybe_overwatch_child() ++ maybe_stuck_detector_child()

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end

  defp maybe_overwatch_child do
    case Application.get_env(:foreman_server, ForemanServer.Overwatch, []) do
      opts when is_list(opts) ->
        if Keyword.get(opts, :enabled, false) do
          [{ForemanServer.Overwatch, opts}]
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
