defmodule ForemanServer.AgentRuntime.JidoSupervisor do
  @moduledoc """
  Foreman-side DynamicSupervisor that hosts `Jido.AgentServer` GenServer
  instances for Foreman workflow runs (TRD-2026-4212be7e, JCR-T002).

  This module is the slot inside `ForemanServer.AgentRuntime.Supervisor`
  where Jido agents (one per workflow run) are spawned. Each Jido agent
  is implemented in the upstream `Jido.AgentServer` GenServer (defined
  in the `jido` package). Foreman's role here is purely structural: it
  provides a supervised child slot for Jido agent processes.

  ## Why a DynamicSupervisor

  Foreman runs many workflows in parallel; a static Supervisor with all
  agents as children would require restart-on-startup coordination and
  would not match the per-run lifecycle Foreman already uses for
  `ForemanServer.Workflow.RunSupervisor`. A DynamicSupervisor matches
  the pattern already used by
  `ForemanServer.AgentRuntime.InvocationSupervisor` (sibling in the
  same AgentRuntime tree) and by `Jido.AgentSupervisor` itself upstream.

  ## Heartbeat integration

  Lifecycle forwarding to `ForemanServer.Overwatch.Tracker` is a separate
  concern (tracked under LGC-T002 and the existing JHA-T002 work) and is
  not wired in this module. JCR-T002 establishes the supervisor slot
  only; the heartbeat contract is a follow-up.

  ## Public API

    - `start_link/1` — start the supervisor with an optional `:name`.
    - `start_agent/1` — start a `Jido.AgentServer` under a target supervisor.
    - `child_spec/1` — standard DynamicSupervisor child spec.

  See also: `Jido.AgentServer.start_link/1`, `Jido.AgentServer.start/1`.
  """

  use DynamicSupervisor

  @doc """
  Start the JidoSupervisor with an optional name.

  ## Options

    - `:name` — process name (default: `ForemanServer.AgentRuntime.JidoSupervisor`).
  """
  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a `Jido.AgentServer` under a target supervisor for a Foreman run.

  ## Options

    - `:supervisor` — required. The DynamicSupervisor pid or registered
      name under which to start the Jido agent. Pass the supervisor's pid
      (returned from `start_link/1`) so uniquely-named supervisors work
      as well as the default name.
    - `:run_id` — required. The Foreman run_id this agent belongs to.
      Used as the Jido agent id.
    - `:agent` — required. The Jido agent module (e.g. `MyApp.MyAgent`).
    - `:id` — optional. Override the Jido agent id (defaults to `run_id`).

  Returns the standard `DynamicSupervisor.start_child/2` result.
  """
  @spec start_agent(keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(opts) do
    sup = Keyword.fetch!(opts, :supervisor)
    run_id = Keyword.fetch!(opts, :run_id)
    agent_module = Keyword.fetch!(opts, :agent)
    jido_id = Keyword.get(opts, :id, run_id)

    # Foreman-side keys consumed above; everything else is forwarded to
    # `Jido.AgentServer.start_link/1` (e.g. `:register_global`, `:registry`,
    # `:partition`, `:persistence`, `:storage`, ...).
    jido_opts =
      opts
      |> Keyword.drop([:supervisor, :run_id, :agent, :id])
      |> Keyword.put(:agent, agent_module)
      |> Keyword.put(:id, jido_id)

    DynamicSupervisor.start_child(sup, {Jido.AgentServer, jido_opts})
  end

  @doc """
  Returns a child_spec for supervision.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
