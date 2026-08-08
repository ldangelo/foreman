defmodule ForemanServer.AgentRuntime.Supervisor do
  @moduledoc """
  Top-level supervisor for the agent runtime subsystem.

  Manages:
  - `ForemanServer.AgentRuntime.AdapterCatalog` — GenServer + Registry for
    backend adapter registration and snapshots.
  - `ForemanServer.AgentRuntime.InvocationSupervisor` — DynamicSupervisor for
    per-execution invocation processes.

  Started as a child of `ForemanServer.Application` when
  `config :foreman_server, :agent_runtime, enabled: true`.
  """

  use Supervisor

  alias ForemanServer.AgentRuntime.{AdapterCatalog, InvocationSupervisor}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    catalog_name = Keyword.get(opts, :adapter_catalog_name, AdapterCatalog)
    invocation_name = Keyword.get(opts, :invocation_supervisor_name, InvocationSupervisor)

    # Get adapters from config or opts
    adapters =
      Keyword.get(
        opts,
        :adapters,
        Application.get_env(:foreman_server, :agent_runtime, [])[:adapters] || []
      )

    children = [
      {AdapterCatalog, [name: catalog_name, adapters: adapters]},
      {InvocationSupervisor, [name: invocation_name]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
