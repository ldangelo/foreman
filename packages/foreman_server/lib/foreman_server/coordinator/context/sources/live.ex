defmodule ForemanServer.Coordinator.Context.Sources.Live do
  @moduledoc "Production `Coordinator.Context.Sources`: the real projections, memory and catalog."
  @behaviour ForemanServer.Coordinator.Context.Sources

  alias ForemanServer.Coordinator.Tuning
  alias ForemanServer.ProjectContext
  alias ForemanServer.ProjectContext.Section
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Workflow.LoadError

  @impl true
  def conversation(project_id), do: ProjectionStore.coordinator_state(project_id)

  @impl true
  def project(project_id) do
    with %{} = project <- ProjectionStore.project(project_id),
         {:ok, bundle} <- ProjectContext.build(project_id) do
      settings = ProjectionStore.project_settings(project_id)

      {:ok,
       %{
         name: get_in(project, [:config, :name]) || project_id,
         goal: settings && settings.goal,
         instructions: body(bundle.sections, :instructions),
         memory_index: body(bundle.sections, :memory),
         repositories: bundle.sections |> body(:repositories) |> lines()
       }}
    else
      _ -> {:error, :project_not_found}
    end
  end

  @impl true
  def threads(project_id), do: Threads.list(project_id, limit: 200)

  @impl true
  def workflows do
    Enum.flat_map(Catalog.manifests(), fn filename ->
      case Catalog.load(filename) do
        {:ok, workflow} ->
          [
            %{
              name: Map.get(workflow, :name) || Path.rootname(filename),
              description: Map.get(workflow, :description)
            }
          ]

        {:error, _} ->
          []
      end
    end)
  end

  # Manifests the catalog refused. Named by file (`lvclaude.yaml` -> `lvclaude`),
  # the only name a refused file has: its own `name:` was never trusted.
  @impl true
  def invalid_workflows do
    Enum.map(Catalog.invalid(), fn error ->
      %{name: Path.rootname(error.filename), reason: LoadError.describe(error)}
    end)
  end

  @impl true
  def tuning(project_id), do: Tuning.read(project_id)

  # The Overview's own group counts, so the coordinator is told exactly what the
  # operator's Overview shows (the card states below are an approximation).
  @impl true
  def status_counts(project_id), do: ForemanServer.Overview.summary(project_id).counts

  @impl true
  def limits(project_id) do
    case ProjectionStore.project_limits(project_id) do
      nil ->
        %{}

      limits ->
        Map.take(limits, [:max_concurrent_runs, :active_runs, :daily_thread_cap, :remaining_today])
    end
  end

  defp body(sections, id) do
    case Enum.find(sections, &match?(%Section{id: ^id}, &1)) do
      %Section{body: body} -> body
      nil -> nil
    end
  end

  defp lines(nil), do: []

  defp lines(text),
    do: text |> String.split("\n", trim: true) |> Enum.map(&String.trim_leading(&1, "- "))
end
