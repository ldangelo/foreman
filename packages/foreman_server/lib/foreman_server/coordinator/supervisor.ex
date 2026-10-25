defmodule ForemanServer.Coordinator.Supervisor do
  @moduledoc """
  Supervision tree of one coordinator runtime: a Registry of per-project workers,
  the DynamicSupervisor that owns them, the TaskSupervisor their turns run under,
  and the `Runner`. Started from `application.ex` behind
  `config :foreman_server, :coordinator, enabled: true`; tests start their own
  with a scripted agent.

  Options: `:name` (default `ForemanServer.Coordinator.Runtime`-style singleton
  `ForemanServer.Coordinator`) and anything `Coordinator.Runtime.new/2` accepts.

  `:setup_proposals` (default `config :foreman_server, :coordinator,
  setup_proposals:`, true) starts `Coordinator.SetupProposer`, the first-turn
  setup proposal; `:setup_catch_up?` (default true) lets it scan for projects
  that missed theirs at startup. The test environment turns the proposer off so
  only its own tests run it.
  """
  use Supervisor

  alias ForemanServer.Coordinator.{Reporter, Runner, Runtime, SetupProposer}

  def start_link(opts) do
    name = Keyword.get(opts, :name, ForemanServer.Coordinator)
    Supervisor.start_link(__MODULE__, {name, opts}, name: Module.concat(name, Supervisor))
  end

  @doc "The runtime struct this supervisor was started with."
  @spec runtime(atom(), keyword()) :: Runtime.t()
  def runtime(name, opts \\ []), do: Runtime.new(name, opts)

  @impl true
  def init({name, opts}) do
    rt = Runtime.new(name, opts)

    children =
      [
        {Registry, keys: :unique, name: rt.registry},
        {DynamicSupervisor, strategy: :one_for_one, name: rt.worker_sup},
        {Task.Supervisor, name: rt.task_sup},
        {Runner, runtime: rt},
        {Reporter, runtime: rt, backfill?: Keyword.get(opts, :backfill?, true)}
      ] ++ setup_proposer(rt, opts)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp setup_proposer(rt, opts) do
    config = Application.get_env(:foreman_server, :coordinator, [])

    if Keyword.get(opts, :setup_proposals, Keyword.get(config, :setup_proposals, true)),
      do: [{SetupProposer, runtime: rt, catch_up?: Keyword.get(opts, :setup_catch_up?, true)}],
      else: []
  end
end
