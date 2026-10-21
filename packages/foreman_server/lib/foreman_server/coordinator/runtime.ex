defmodule ForemanServer.Coordinator.Runtime do
  @moduledoc """
  Resolved configuration and process names of one coordinator runtime
  (`Coordinator.Supervisor`). Everything a turn needs is passed explicitly, so
  tests run independent runtimes with their own scripted agent and gateway spy
  without touching global application env.
  """

  alias ForemanServer.Coordinator.Context.Sources.Live

  @enforce_keys [:name, :registry, :worker_sup, :task_sup, :agent]
  defstruct [
    :name,
    :registry,
    :worker_sup,
    :task_sup,
    :agent,
    agent_opts: [],
    only: nil,
    gateway: ForemanServer.CommandGateway,
    sources: Live,
    threads: ForemanServer.Threads,
    thread_actions: ForemanServer.Threads.Actions,
    retry_backoff_ms: 5_000,
    turn_timeout_ms: 300_000,
    agent_timeout_ms: 180_000,
    unhealthy_after: 3,
    max_actions: 10,
    max_threads_per_turn: 5,
    default_provider: :pi,
    default_model: nil,
    default_effort: nil
  ]

  @type t :: %__MODULE__{}

  @doc "True when this runtime serves `project_id` (`:only` restricts it; tests use that to isolate)."
  @spec serves?(t(), String.t()) :: boolean()
  def serves?(%__MODULE__{only: nil}, _project_id), do: true
  def serves?(%__MODULE__{only: only}, project_id), do: project_id in only

  @doc "Build a runtime named `name`; `opts` override `config :foreman_server, :coordinator`."
  @spec new(atom(), keyword()) :: t()
  def new(name, opts \\ []) when is_atom(name) do
    config = Application.get_env(:foreman_server, :coordinator, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(config, key, default)) end

    %__MODULE__{
      name: name,
      registry: Module.concat(name, Registry),
      worker_sup: Module.concat(name, WorkerSupervisor),
      task_sup: Module.concat(name, TaskSupervisor),
      agent: get.(:agent, ForemanServer.Coordinator.Agent.Harness),
      agent_opts: Keyword.get(opts, :agent_opts, []),
      only: Keyword.get(opts, :only),
      gateway: get.(:gateway, ForemanServer.CommandGateway),
      sources: get.(:sources, Live),
      threads: get.(:threads, ForemanServer.Threads),
      thread_actions: get.(:thread_actions, ForemanServer.Threads.Actions),
      retry_backoff_ms: get.(:retry_backoff_ms, 5_000),
      turn_timeout_ms: get.(:turn_timeout_ms, 300_000),
      agent_timeout_ms: get.(:agent_timeout_ms, 180_000),
      unhealthy_after: get.(:unhealthy_after, 3),
      max_actions: get.(:max_actions_per_turn, 10),
      max_threads_per_turn: get.(:max_threads_per_turn, 5),
      default_provider: get.(:default_provider, :pi),
      default_model: get.(:default_model, nil),
      default_effort: get.(:default_effort, nil)
    }
  end
end
