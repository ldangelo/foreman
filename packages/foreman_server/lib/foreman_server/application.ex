defmodule ForemanServer.Application do
  @moduledoc false

  use Application

  alias ForemanServer.{
    EventStore,
    Inbox.TriggerPoller,
    Overwatch,
    ProjectionStore,
    PrMonitor,
    ProjectRegistry,
    Recovery,
    Repo,
    RuntimeSafety,
    Scheduler
  }

  @impl true
  def start(_type, _args) do
    RuntimeSafety.validate!()

    boot_started_at = DateTime.utc_now()
    boot_id = boot_id()

    children =
      repo_children() ++
        [
          {Registry, keys: :duplicate, name: ForemanServer.InboxRegistry},
          {Registry, keys: :unique, name: :project_registry}
        ] ++
        [
          {ProjectionStore, []},
          {Overwatch, []},
          {Overwatch.Tracker, :ok},
          {Overwatch.WorkerSupervisor, []},
          {EventStore, []},
          {ForemanServer.StreamGapDetector, []},
          {ForemanServer.ProjectRunLimitSweeper, []}
        ] ++
        debug_children() ++
        [
          {Overwatch.StuckDetector, []},
          {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.RunDynamicSupervisor},
          {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.ProjectDynamicSupervisor},
          {ProjectRegistry, []},
          {Scheduler.Runtime, []},
          {Recovery, [boot_id: boot_id, boot_started_at: boot_started_at]},
          {PrMonitor, []},
          {TriggerPoller, []}
        ] ++ http_children()

    opts = [strategy: :one_for_one, name: ForemanServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp repo_children do
    if postgres_event_store?(), do: [Repo], else: []
  end

  defp debug_children do
    if Application.get_env(:foreman_server, :debug_live_views_enabled, false) do
      [
        {Phoenix.PubSub, name: ForemanServer.PubSub},
        {ForemanServerWeb.Endpoint, []},
        {ForemanServerWeb.Presence, []},
        {ForemanServerWeb.Debug.PresenceBridge, []}
      ]
    else
      []
    end
  end

  defp postgres_event_store? do
    ForemanServer.RuntimeInfo.event_store_adapter() == :postgres
  end

  defp http_children do
    enabled? =
      Application.get_env(:foreman_server, :http_enabled, false) ||
        System.get_env("FOREMAN_SERVER_HTTP_ENABLED") == "true"

    if enabled? do
      [{ForemanServer.Http.Endpoint, []}]
    else
      []
    end
  end

  defp boot_id do
    bytes = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = bytes

    Enum.join(
      [
        Base.encode16(<<a::32>>, case: :lower),
        Base.encode16(<<b::16>>, case: :lower),
        Base.encode16(<<c::16>>, case: :lower),
        Base.encode16(<<d::16>>, case: :lower),
        Base.encode16(<<e::48>>, case: :lower)
      ],
      "-"
    )
  end
end
