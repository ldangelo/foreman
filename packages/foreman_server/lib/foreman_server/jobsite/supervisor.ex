defmodule ForemanServer.Jobsite.Supervisor do
  @moduledoc """
  DynamicSupervisor that manages one `ForemanServer.Jobsite.Executor` per
  jobsite id. Restart is `:temporary` — a crash is never auto-restarted
  (`:transient` would restart on any abnormal exit, including `:killed`,
  re-running `jobsite.start` against an already-started aggregate, which the
  aggregate's `require_absent` guard would then reject). Recovery is always
  an explicit `resume/1` call: whoever observes the crash (the caller blocked
  on `reply_to` gets no reply and times out, or an operator notices the
  jobsite stuck non-terminal) invokes `resume/1`.
  """

  use DynamicSupervisor

  alias ForemanServer.Jobsite.Executor

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec start_jobsite(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_jobsite(jobsite_id, opts) do
    # An intent left behind by a previous run of this id (an executor that exited
    # between the last check and its clear) would pause or cancel this one the moment
    # it starts. No executor is registered yet, so the controller cannot be adding a
    # fresh intent for this id concurrently.
    ForemanServer.Jobsite.Control.clear(jobsite_id)

    child_spec = %{
      id: Executor,
      start: {Executor, :start_link, [jobsite_id, opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec resume_jobsite(String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def resume_jobsite(jobsite_id, opts) do
    start_jobsite(jobsite_id, Keyword.put(opts, :resume?, true))
  end

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
