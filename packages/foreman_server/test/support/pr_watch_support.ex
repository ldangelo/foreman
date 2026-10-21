defmodule ForemanServer.TestSupport.PrWatchSupport do
  @moduledoc """
  Fixtures for the E9 PR-watch tests: a started (optionally completed) run with
  a PR on its stream, built through the real event store and projection, and a
  `PrStatus` builder. Ids carry a random token because the event store outlives
  the VM and `System.unique_integer/1` restarts on every boot.
  """

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.EventStore, as: FEventStore
  alias ForemanServer.GitHub.PrStatus

  @doc "Start a run (RunStarted on its stream + projection) and return its identifiers."
  @spec start_run!(keyword()) :: %{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t()
        }
  def start_run!(opts \\ []) do
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    run_id = "run-prw-#{token}"
    project_id = Keyword.get(opts, :project_id, "project-prw-#{token}")
    task_id = "task-prw-#{token}"
    pr_url = "https://github.com/acme/repo-#{token}/pull/1"
    started = %{run_id: run_id, project_id: project_id, task_id: task_id, workflow_snapshot: %{}}

    :ok =
      FEventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    if Keyword.get(opts, :complete, false), do: complete_run!(run_id, project_id)

    %{run_id: run_id, project_id: project_id, task_id: task_id, pr_url: pr_url}
  end

  @doc "Append `RunCompleted` to the run's stream and project it."
  @spec complete_run!(String.t(), String.t()) :: :ok
  def complete_run!(run_id, project_id) do
    {:ok, version} = stream_version(run_id)
    data = %{run_id: run_id, project_id: project_id, sequence: 1}

    :ok =
      FEventStore.append_to_stream("run:#{run_id}", version, [
        %EventStore.EventData{event_type: "RunCompleted", data: data, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunCompleted", payload: data}])
  end

  defp stream_version(run_id) do
    {:ok, events} = FEventStore.read_stream_forward("run:#{run_id}", 0, 10_000)
    {:ok, length(events)}
  end

  @doc "A `PrStatus` with sensible open-PR defaults; pass overrides as a keyword."
  @spec status(keyword()) :: PrStatus.t()
  def status(overrides \\ []) do
    struct!(
      %PrStatus{
        status: :open,
        head_sha: "sha-1",
        head_branch: "foreman/run/phase",
        base_branch: "main"
      },
      overrides
    )
  end

  @doc "A failing CheckRun entry as `PrStatus` normalises it."
  @spec failing_check(String.t()) :: PrStatus.check()
  def failing_check(name) do
    %{
      name: name,
      kind: :check_run,
      state: :failing,
      conclusion: "FAILURE",
      url: "https://github.com/acme/repo/actions/runs/1/job/#{name}",
      workflow: "ci"
    }
  end

  @doc "Dispatch a system command, asserting success; returns the event spec."
  @spec dispatch!(map()) :: map() | nil
  def dispatch!(command) do
    {:ok, spec} = CommandGateway.dispatch_system(command)
    spec
  end

  @doc "Read every event of a run's stream."
  @spec run_events(String.t()) :: [struct()]
  def run_events(run_id) do
    {:ok, events} = FEventStore.read_stream_forward("run:#{run_id}", 0, 10_000)
    events
  end

  @doc "Event types of a run's stream, in order."
  @spec run_event_types(String.t()) :: [String.t()]
  def run_event_types(run_id), do: run_id |> run_events() |> Enum.map(& &1.event_type)
end
