defmodule ForemanServer.Application do
  @moduledoc """
  Top-level Foreman application.

  Boots the Phoenix endpoint, the CQRS event-sourced spine, the
  task-provider registry, the workflow supervision tree, and a
  collection of opt-in subsystems (Jido AgentRuntime, Jido signal
  bus + adapter, jido_ecto checkpoint repo, Overwatch, MCP) gated
  on configuration keys.

  See `start/2` for the children list and the gating config keys.
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
        ForemanServer.Aggregator
      ] ++
        maybe_json_schema_cache_child() ++
        [
          # JsonSchemaCache owns the cached `br schema ... --json` payload
          # schemas used by every BeadsAdapter parser (claim, list_ready,
          # complete, fail, reopen, etc.). It MUST start before any code
          # path that resolves a Beads provider, including the
          # TaskProvider.Registry snapshot and BootReconciliation's lazy
          # orphan-reopen pass.
          # TaskProvider.Registry owns configured task provider routing and must
          # start before dispatch paths resolve a provider snapshot.
          ForemanServer.TaskProvider.Registry
        ] ++
        maybe_beads_watcher_child() ++
        maybe_beads_orphan_janitor_child() ++
        maybe_project_provider_projector_child() ++
        [
          # BootReconciliation runs once after the projector has rebuilt
          # per-project routing so orphaned upstream in-progress issues can be
          # reopened before any dispatcher/executor work resumes.
          ForemanServer.Workflow.BootReconciliation,
          # RunExecutorRegistry must exist before RunExecutor children start;
          # RunSupervisor and Dispatcher both rely on it for via-tuple lookup.
          {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
          # RunExecutorLiveness owns the active-phase deadline table; reads
          # from StuckDetector must avoid calling a blocked RunExecutor, so
          # the deadline is published here via ETS BEFORE the executor blocks
          # into AgentRuntime and cleared after.
          ForemanServer.RunExecutorLiveness,
          # Workflow.Catalog owns the in-memory workflow + prompt snapshots,
          # auto-installs the bundled templates on first boot, and reloads
          # files when the directory changes. Must start before any code path
          # that resolves a workflow (CommandRouter, Dispatcher, RunExecutor).
          ForemanServer.Workflow.Catalog,
          ForemanServer.Workflow.RunSupervisor,
          # Dispatcher subscribes to ProjectionStore and reacts to TaskDispatched
          # AND terminal run events (RunCancelled, RunFlaggedStuck, RunCompleted,
          # RunFailed), forwarding the latter to BootReconciliation.run_terminated/2
          # so orphan-task scans during normal operation mirror the boot path.
          ForemanServer.Workflow.Dispatcher,
          # CommandRouter handles all append requests.
          ForemanServer.CommandRouter
        ]
        ++ maybe_lifecycle_reconciler_child()
        ++ maybe_agent_runtime_child()
        ++ maybe_jido_checkpoint_repo_child()
        ++ maybe_mcp_child()
        ++ maybe_overwatch_child()
        ++ maybe_stuck_detector_child()
        ++
        [
          # Endpoint exposes dev-only debug LiveViews.
          ForemanServerWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # TRD-004: register the Jido.Harness backend adapter when the rollout
    # switch is on (PRD-2026-016 §3.4). PiAdapter continues to be seeded
    # via the `:agent_runtime, :adapters` config; this block is the
    # in-code counterpart to FOREMAN_USE_JIDO_HARNESS and must run AFTER
    # Supervisor.start_link so the AgentRuntime.AdapterCatalog GenServer
    # is already alive.
    _ = register_jido_harness_adapter()

    {:ok, pid}
  end

  @doc """
  TRD-004 — Registers `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`
  with the supervised `ForemanServer.AgentRuntime.AdapterCatalog` when
  `:jido_harness, :enabled` is true.

  This is the runtime counterpart to the static `:adapters` keyword list
  that `ForemanServer.AgentRuntime.Supervisor.init/1` reads at boot to
  pre-seed the catalog (currently carrying `PiAdapter`). Operators flip
  the JidoHarnessAdapter on independently of the static list by setting
  `config :foreman_server, :jido_harness, enabled: true` (or
  `FOREMAN_USE_JIDO_HARNESS=true` once Phase-2 rollout wiring lands).

  Returns `{:ok, capability_map}` if registered, or `nil` if the gate
  is closed (the flag is false or unset). The AgentRuntime catalog must
  be running for registration to succeed; callers from `start/2` are
  guaranteed that because the supervisor tree has already started.
  """
  @spec register_jido_harness_adapter() ::
          {:ok, ForemanServer.AgentRuntime.capability_map()} | nil
  def register_jido_harness_adapter do
    if jido_harness_enabled?() do
      case ForemanServer.AgentRuntime.register(
             ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
           ) do
        {:ok, _} = ok -> ok
        {:error, _} -> nil
      end
    else
      nil
    end
  end

  defp jido_harness_enabled? do
    Application.get_env(:foreman_server, :jido_harness, [])
    |> Keyword.get(:enabled, false) == true
  end

  defp maybe_agent_runtime_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [
          {ForemanServer.AgentRuntime.Supervisor, []}
        ] ++
          maybe_signal_to_command_child()

      _ ->
        []
    end
  end

  # The Jido checkpoint store is the persistent backend for Jido
  # agent state. We start a dedicated Ecto.Repo (so jido's tables live
  # in their own namespace) gated on
  # `config :foreman_server, :jido_ecto, enabled: true`. The wrapper
  # is a no-op (just forwards to Jido.Ecto.Storage) so it does not
  # need to be a supervisor child; only the Repo does.
  defp maybe_jido_checkpoint_repo_child do
    if Application.get_env(:foreman_server, :jido_ecto, [])[:enabled] in [true, "true"] do
      [{ForemanServer.Agents.JidoCheckpointStore.Repo, []}]
    else
      []
    end
  end

  # The signal-to-command bridge is the Jido signal-side counterpart
  # to the existing Jido AgentRuntime supervision: Jido agents publish
  # CloudEvents on the `com.foreman.command.*` topic pattern; the
  # adapter subscribes and routes each event to
  # `ForemanServer.CommandGateway.dispatch_system/2` (TRD-014
  # Integration Ingestion). The bus is started before the adapter so
  # the adapter's deferred auto-subscribe lands on a live bus.
  # Disabled by default (no separate flag): opt in by setting
  # `config :foreman_server, :agent_runtime, signal_bridge_enabled: true`.
  def maybe_signal_to_command_child do
    opts = Application.get_env(:foreman_server, :agent_runtime, [])
    enabled? = is_list(opts) and Keyword.get(opts, :enabled, false) in [true, "true"]
    bridge? = enabled? and Keyword.get(opts, :signal_bridge_enabled, false)

    if bridge? do
      bus_name = :foreman_jido_signal_bus
      adapter_name = :foreman_signal_to_command_adapter

      [
        {Jido.Signal.Bus, [name: bus_name]},
        {ForemanServer.Agents.SignalToCommandAdapter, [name: adapter_name, bus: bus_name]}
      ]
    else
      []
    end
  end

  defp maybe_mcp_child do
    case Application.get_env(:foreman_server, :mcp, [])[:enabled] do
      true ->
        [{ForemanServer.MCP, []}]

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

  defp maybe_project_provider_projector_child do
    if Application.get_env(:foreman_server, :start_project_provider_projector?, true) do
      [
        # ProjectProviderProjector subscribes to ProjectionStore and maintains
        # per-project task provider routing inside the Registry.
        ForemanServer.TaskProvider.ProjectProviderProjector
      ]
    else
      []
    end
  end

  def maybe_beads_watcher_child do
    if Application.get_env(:foreman_server, :start_beads_watcher?, false) do
      [ForemanServer.TaskProviders.BeadsWatcherSupervisor]
    else
      []
    end
  end

  def maybe_beads_orphan_janitor_child do
    if Application.get_env(:foreman_server, :start_beads_orphan_janitor?, false) do
      [ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor]
    else
      []
    end
  end

  defp maybe_json_schema_cache_child do
    if Application.get_env(:foreman_server, :start_json_schema_cache?, true) do
      [ForemanServer.TaskProviders.JsonSchemaCache]
    else
      []
    end
  end

  defp maybe_stuck_detector_child do
    seconds =
      Application.get_env(:foreman_server, :stuck_run_check_interval_seconds, 60)

    [{ForemanServer.StuckDetector, [interval_ms: seconds * 1000]}]
  end

  # Gated on :start_lifecycle_reconciler? config so the test suite
  # can opt out of it (avoids cross-test state pollution on the
  # shared `run_slots:global` aggregate).
  def maybe_lifecycle_reconciler_child do
    if Application.get_env(:foreman_server, :start_lifecycle_reconciler?, true) do
      [ForemanServer.RunLifecycleReconciler]
    else
      []
    end
  end

  def config_change(changed, _new, removed) do
    ForemanServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
