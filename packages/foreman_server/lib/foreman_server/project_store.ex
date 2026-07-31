defmodule ForemanServer.ProjectStore do
  @moduledoc """
  Event-sourced project persistence via CommandRouter + ProjectionStore.

  - `save/2` appends `ProjectRegistered` or `ProjectUpdated` through
    CommandRouter; projected via ProjectionStore.
  - `get/1` and `list/0` read from ProjectionStore.

  `load_projects/0` and `save_projects/1` are the legacy boot-loading path
  backed by a durable term file; they are orthogonal to the CQRS APIs above.
  """

  alias ForemanServer.Project

  @type project_source :: :file | :application_env

  @spec load_projects() :: {:ok, [Project.t()], project_source()} | {:error, term()}
  def load_projects do
    path = store_path()

    cond do
      is_binary(path) and File.exists?(path) -> load_file(path)
      true -> load_application_env()
    end
  end

  @spec save_projects([Project.t()]) :: :ok | {:error, term()}
  def save_projects(projects) when is_list(projects) do
    path = store_path(required?: true)
    File.mkdir_p!(Path.dirname(path))
    binary = :erlang.term_to_binary(projects)
    File.write(path, binary)
  end

  defp load_file(path) do
    with {:ok, binary} <- File.read(path),
         projects when is_list(projects) <- :erlang.binary_to_term(binary),
         {:ok, normalized} <- normalize_projects(projects) do
      {:ok, normalized, :file}
    else
      error -> {:error, {:invalid_project_store, error}}
    end
  end

  defp load_application_env do
    projects = Application.get_env(:foreman_server, :projects, [])

    with {:ok, normalized} <- normalize_projects(projects) do
      {:ok, normalized, :application_env}
    end
  end

  defp normalize_projects(projects) do
    projects
    |> Enum.reduce_while({:ok, []}, fn project, {:ok, acc} ->
      case Project.new(project) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_path(opts \\ []) do
    ForemanServer.RuntimeInfo.project_store_path(opts)
  end

  alias ForemanServer.CommandRouter
  alias ForemanServer.ProjectionStore

  @doc """
  Saves a project by appending a `ProjectRegistered` or `ProjectUpdated` event
  through CommandRouter.  The event is projected via ProjectionStore.

  Dispatches `"project.register"` for new projects or `"project.update"` when
  the project already exists (checked via ProjectionStore).
  """
  @spec save(Project.t(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def save(%Project{} = project, opts \\ []) do
    command_id =
      Keyword.get(
        opts,
        :command_id,
        "project-store-#{project.id}-#{System.unique_integer([:positive])}"
      )

    existing = ProjectionStore.project(project.id)
    command_type = if existing, do: "project.update", else: "project.register"

    payload = %{
      project_id: project.id,
      path: project.path,
      status: Atom.to_string(project.status),
      default_branch: project.default_branch,
      config: project.config,
      health: project.health
    }

    CommandRouter.handle(%{
      command_id: command_id,
      command_type: command_type,
      payload: payload,
      metadata: %{source: "project_store"}
    })
  end

  @doc "Reads a single project projection by id."
  @spec get(String.t()) :: map() | nil
  def get(project_id), do: ProjectionStore.project(project_id)

  @doc "Lists all project projections sorted by project_id."
  @spec list() :: [map()]
  def list, do: ProjectionStore.project_list()
end
