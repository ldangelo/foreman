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
        ForemanServer.Aggregator,
        # Idempotency store — durable idempotency key records (TRD-075) and
        # heartbeat lease with expiry detection (TRD-076). ETS fallback when
        # JidoCheckpointStore.Repo is unavailable so it starts regardless of
        # repo configuration.
        ForemanServer.Idempotency.KeyStore,
        ForemanServer.Idempotency.HeartbeatLease,
        # Foreman Actions Registry — the tool-catalog layer that
        # RunExecutor, the agent runtime toolset sync, and the prompt
        # template loader all consult to find available Jido.Actions.
        # Started here (in the unconditional block, alongside the
        # Aggregator) so the catalog is ready when the first
        # RunExecutor looks up its agent's tools. The default action
        # set is [GitStatusAction, DiffReadAction, TaskGetAction,
        # ReadPromptAction]; operators add more via config
        # :foreman_server, ForemanServer.Actions.Registry, :actions.
        {ForemanServer.Actions.Registry,
         actions:
           Application.get_env(:foreman_server, ForemanServer.Actions.Registry, [])
           |> Keyword.get(:actions, [
             ForemanServer.Actions.GitStatusAction,
             ForemanServer.Actions.DiffReadAction,
             ForemanServer.Actions.TaskGetAction,
             ForemanServer.Actions.ReadPromptAction
           ])}
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
        maybe_boot_reconciliation_child() ++
        [
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
          # Merge gate: pauses a run after PR creation pending explicit
          # human approval (TRD-014). Previously never supervised anywhere
          # (dev/prod/test) — every call site and every test file started
          # it ad hoc via `MergeGate.start_link()`, which only worked by
          # accident when nothing else had already started it under the
          # same registered name in the same test run.
          ForemanServer.Workflow.MergeGate,
          # CommandRouter handles all append requests.
          ForemanServer.CommandRouter
        ] ++
        maybe_stuck_detector_child() ++
        maybe_lifecycle_reconciler_child() ++
        maybe_jido_signal_bus_child() ++
        maybe_signal_journal_child() ++
        maybe_directive_queue_child() ++
        maybe_signal_to_command_child() ++
        maybe_task_metadata_query_subscriber_child() ++
        maybe_agent_runtime_child() ++
        maybe_jido_checkpoint_repo_child() ++
        maybe_operator_question_subscriber_child() ++
        maybe_operator_directive_projector_child() ++
        maybe_jido_shell_runner_child() ++
        maybe_operator_timeout_child() ++
        maybe_overwatch_child() ++
        maybe_vfs_isolation_child() ++
        maybe_mcp_allowlist_child() ++
        maybe_mcp_child() ++
        [
          # Endpoint exposes dev-only debug LiveViews.
          ForemanServerWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # TRD-004: register the Jido.Harness backend adapter with the
    # AgentRuntime.AdapterCatalog after the supervisor tree is alive.
    _ = register_jido_harness_adapter()

    # Seed MCP allowlist with read-only tools after supervisor starts.
    _ = seed_mcp_allowlist()

    {:ok, pid}
  end

  @doc """
  TRD-004 — Registers `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`
  with the supervised `ForemanServer.AgentRuntime.AdapterCatalog`.
  """
  @spec register_jido_harness_adapter() ::
          {:ok, ForemanServer.AgentRuntime.capability_map()} | nil
  def register_jido_harness_adapter do
    if ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter in Application.get_env(
         :foreman_server,
         :agent_runtime,
         []
       )[:adapters] do
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

  defp maybe_agent_runtime_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        # `maybe_signal_to_command_child/0` is called separately below
        # so the bus startup (always-on when agent_runtime is enabled)
        # and the adapter startup (opt-in via :signal_bridge_enabled)
        # can be controlled independently.
        [
          {ForemanServer.AgentRuntime.Supervisor, []}
        ] ++
          []

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
  # The signal-to-command bridge is split into two opt-in steps:
  # the bus follows the same :agent_runtime, :enabled flag as the
  # rest of the Jido AgentRuntime (so the production directive
  # publisher always has a bus to write to), and the
  # SignalToCommandAdapter is opt-in via :signal_bridge_enabled.
  # The directive publisher (JSI-T011) and the agent-directive
  # subscriber both depend on the bus, NOT on the adapter.
  def maybe_jido_signal_bus_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{Jido.Signal.Bus, [name: :foreman_jido_signal_bus]}]

      _ ->
        []
    end
  end

  # TRD-022 (JSI-T004) / TRD-056 (JLD-T002): Persistent signal journal for
  # replay on restart. Referenced by SignalDirectivePublisher (enqueue/dispatch
  # hooks) and LiveDashboard (replay view). Gated on agent_runtime :enabled
  # so it starts whenever the Jido signal infrastructure is live.
  def maybe_signal_journal_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{ForemanServer.Agents.SignalJournal, [name: ForemanServer.Agents.SignalJournal]}]

      _ ->
        []
    end
  end

  # TRD-056 (JLD-T002): Tracks pending directives for Jido agents.
  # Referenced by SignalDirectivePublisher (enqueue/mark_dispatched) and
  # LiveDashboard (queued view). Same gate as SignalJournal.
  def maybe_directive_queue_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{ForemanServer.Agents.DirectiveQueue, [name: ForemanServer.Agents.DirectiveQueue]}]

      _ ->
        []
    end
  end

  def maybe_signal_to_command_child do
    opts = Application.get_env(:foreman_server, :agent_runtime, [])
    enabled? = is_list(opts) and Keyword.get(opts, :enabled, false) in [true, "true"]
    bridge? = enabled? and Keyword.get(opts, :signal_bridge_enabled, false)

    if bridge? do
      adapter_name = :foreman_signal_to_command_adapter

      [
        {ForemanServer.Agents.SignalToCommandAdapter,
         [name: adapter_name, bus: :foreman_jido_signal_bus]}
      ]
    else
      []
    end
  end

  # The task-metadata query subscriber consumes the
  # `com.foreman.query.task_metadata.*` topic pattern (JSI-T012).
  # The subscriber auto-subscribes its pid to that topic on
  # :foreman_jido_signal_bus at init, so this child is gated on
  # the bus being up. We gate on the same always-on flag as the
  # bus itself (agent_runtime, :enabled), not on :signal_bridge_enabled
  # (the command-adapter flag) — the subscriber only needs the bus,
  # not the SignalToCommandAdapter. Operators who want neither the
  # command bridge nor the query subscriber can leave
  # agent_runtime, :enabled off and the bus (and the subscriber)
  # won't be started.
  def maybe_task_metadata_query_subscriber_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [
          {ForemanServer.Agents.TaskMetadataQuerySubscriber,
           [name: :foreman_task_metadata_query_subscriber, bus: :foreman_jido_signal_bus]}
        ]

      _ ->
        []
    end
  end

  def maybe_jido_shell_runner_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{ForemanServer.Agents.JidoShellRunner, [name: ForemanServer.Agents.JidoShellRunner]}]

      _ ->
        []
    end
  end

  # TRD-2026-4212be7e JSH-T003: VFS isolation per worktree.
  # VfsIsolation is always-on when agent_runtime is enabled so that
  # every shell session is bound to a sandboxed worktree root.
  def maybe_vfs_isolation_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{ForemanServer.Agents.VfsIsolation, [name: ForemanServer.Agents.VfsIsolation]}]

      _ ->
        []
    end
  end

  def maybe_operator_question_subscriber_child do
    # The operator-question subscriber consumes the
    # `com.foreman.operator.*` topic pattern (JSI-T006). The
    # subscriber auto-subscribes its pid to that topic on
    # :foreman_jido_signal_bus at init, so this child is gated on
    # the bus being up — same gate as the task-metadata query
    # subscriber (agent_runtime, :enabled). The dispatcher that the
    # subscriber hands each signal to (JSI-T007) writes the operator
    # question into the Foreman inbox pipeline.
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [
          {ForemanServer.Agents.OperatorQuestionSubscriber,
           [name: :foreman_operator_question_subscriber, bus: :foreman_jido_signal_bus]}
        ]

      _ ->
        []
    end
  end

  # TRD-005 / AC-005-2: The operator-directive projector consumes
  # InboxItemStarted events from the OperatorQuestionSource and publishes
  # Jido directive signals to the agent's directive topic, completing the
  # operator-response → agent flow. Gated on :agent_runtime, :enabled.
  def maybe_operator_directive_projector_child do
    case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [
          {ForemanServer.Agents.OperatorDirectiveProjector,
           [name: :foreman_operator_directive_projector]}
        ]

      _ ->
        []
    end
  end

  def maybe_operator_timeout_child do
    case Application.get_env(:foreman_server, :operator_timeout, [])[:enabled] do
      enabled when enabled in [true, "true"] ->
        [{ForemanServer.Agents.OperatorTimeout, [name: ForemanServer.Agents.OperatorTimeout]}]

      _ ->
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

  # Seeds the MCP allowlist with read-only Foreman tools. Write tools
  # (work_submit, workflow_put, etc.) are controlled by the Policy layer
  # based on allow_workflow_writes config, not the allowlist.
  defp maybe_mcp_allowlist_child do
    if Application.get_env(:foreman_server, :mcp, [])[:enabled] do
      [{ForemanServer.Agents.McpAllowlist, []}]
    else
      []
    end
  end

  # Seeds the MCP allowlist after supervisor starts so McpAllowlist is alive.
  # Safe tools = all tools minus write tools (controlled by Policy instead).
  defp seed_mcp_allowlist do
    if Application.get_env(:foreman_server, :mcp, [])[:enabled] do
      write_tools = [
        "foreman_work_submit",
        "foreman_work_cancel",
        "foreman_workflow_put",
        "foreman_workflow_delete",
        "foreman_prompt_put"
      ]

      safe_tools =
        ForemanServer.MCP.Tools.list_tools()
        |> Enum.reject(fn %{name: name} -> name in write_tools end)
        |> Enum.map(fn %{name: name} -> name end)

      Enum.each(safe_tools, &ForemanServer.Agents.McpAllowlist.add/1)
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

    stuck = [{ForemanServer.StuckDetector, [interval_ms: seconds * 1000]}]

    if ForemanServer.Workflow.StallPolicy.enabled?() do
      stall_seconds =
        Application.get_env(:foreman_server, :stall_detection_check_interval_seconds, 60)

      stuck ++ [{ForemanServer.StallDetector, [interval_ms: stall_seconds * 1000]}]
    else
      stuck
    end
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

  # Gated on :start_boot_reconciliation? config so the test suite can
  # opt out of the always-on GenServer (each test file that needs it
  # starts its own supervised instance via `ensure_started/2`, avoiding
  # cross-test pollution of the ambiguous-key / run-slot-orphan scans
  # this process drives).
  def maybe_boot_reconciliation_child do
    if Application.get_env(:foreman_server, :start_boot_reconciliation?, true) do
      [ForemanServer.Workflow.BootReconciliation]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ForemanServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
