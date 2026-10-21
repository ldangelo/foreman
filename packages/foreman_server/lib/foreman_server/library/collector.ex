defmodule ForemanServer.Library.Collector do
  @moduledoc """
  Registers thread-produced files into the project library (E5-S5).

  Subscribes to `ProjectionStore` (no replay: a restart must not re-register
  history) and reacts to exactly two event types:

    * `PhaseCompleted` - the phase artifact (`artifact_path`, the artifact contract
      of `phase.complete`) becomes `phase-<index>/<basename>` in the run's
      `produced-<run_id>` entry. Allowed source roots: the run's worktree(s), the
      project checkout and the run's artifact directory under `~/.foreman/runs`.
    * `ReviewRecorded` - the session archive's `analysis.md` and `diff.patch` (when
      present) become `archive/analysis.md` / `archive/diff.patch`. The archive is
      only complete once the review is recorded, which is why this is the trigger
      and not `RunCompleted`. Allowed source root: the archive directory.

  OPT-IN per project: nothing is registered unless the project's
  `library_collect_produced` setting is `true` (default off), because
  auto-registering every run's output clutters the library. All containment,
  idempotency and budget rules live in `ForemanServer.Library.Produced`; a failed
  registration is logged and never affects the run.
  """

  use GenServer

  require Logger

  alias ForemanServer.{Aggregate, Library, ProjectionStore}

  @archive_files ~w(analysis.md diff.patch)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    handle_event(event_type(event), payload(event))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @spec handle_event(term(), map()) :: :ok
  def handle_event("PhaseCompleted", payload) do
    with run_id when is_binary(run_id) <- Aggregate.get(payload, :run_id),
         path when is_binary(path) <- Aggregate.get(payload, :artifact_path),
         %{project_id: project_id} when is_binary(project_id) <- ProjectionStore.run(run_id),
         true <- collecting?(project_id) do
      index = Aggregate.get(payload, :index) || 0
      rel = "phase-#{index}/#{Path.basename(path)}"

      register(
        project_id,
        run_id,
        [%{relative_path: rel, source_path: path}],
        run_roots(project_id, run_id)
      )
    else
      _ -> :ok
    end
  rescue
    exception -> log_crash("PhaseCompleted", exception, __STACKTRACE__)
  end

  def handle_event("ReviewRecorded", payload) do
    kind = Aggregate.get(payload, :subject_kind)
    subject_id = Aggregate.get(payload, :subject_id)
    project_id = Aggregate.get(payload, :project_id)
    archive = Aggregate.get(payload, :archive_path)

    with true <- kind in ["run", "jobsite"],
         true <- is_binary(subject_id) and is_binary(project_id) and is_binary(archive),
         true <- collecting?(project_id) do
      files =
        for name <- @archive_files, File.regular?(Path.join(archive, name)) do
          %{relative_path: "archive/" <> name, source_path: Path.join(archive, name)}
        end

      if files != [], do: register(project_id, subject_id, files, [archive]), else: :ok
    else
      _ -> :ok
    end
  rescue
    exception -> log_crash("ReviewRecorded", exception, __STACKTRACE__)
  end

  def handle_event(_type, _payload), do: :ok

  defp register(project_id, run_id, files, roots) do
    case Library.register_produced(project_id, run_id, files, allowed_roots: roots) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "library collector: could not register produced files for #{run_id}: #{inspect(error)}"
        )
    end
  end

  defp collecting?(project_id) do
    match?(%{library_collect_produced: true}, ProjectionStore.project_settings(project_id))
  end

  defp run_roots(project_id, run_id) do
    worktrees =
      for %{} = wt <- ProjectionStore.worktrees_for_run(run_id),
          path = Map.get(wt, :worktree_path),
          is_binary(path),
          do: path

    project_path =
      case ProjectionStore.project(project_id) do
        %{path: path} when is_binary(path) and path != "" -> [path]
        _ -> []
      end

    worktrees ++
      project_path ++ [Path.join(ForemanServer.Workflow.RunExecutor.artifact_base(), run_id)]
  end

  defp event_type(%{event_type: type}), do: type
  defp event_type(%{"event_type" => type}), do: type
  defp event_type(_), do: nil

  defp payload(%{data: data}) when is_map(data), do: data
  defp payload(%{"data" => data}) when is_map(data), do: data
  defp payload(%{payload: data}) when is_map(data), do: data
  defp payload(_), do: %{}

  defp log_crash(type, exception, stacktrace) do
    Logger.error(
      "library collector: #{type} handling crashed: #{Exception.format(:error, exception, stacktrace)}"
    )
  end
end
