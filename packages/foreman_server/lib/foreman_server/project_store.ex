defmodule ForemanServer.ProjectStore do
  @moduledoc """
  TRD-004: ProjectStore.

  Thin façade over the `ProjectionStore` and `CommandRouter`. Persists
  project configuration by appending events through the canonical command
  path; reads from the projection store.
  """

  alias ForemanServer.{CommandGateway, ProjectionStore}

  def save(%{project_id: project_id} = payload) when is_binary(project_id) do
    type =
      case ProjectionStore.project_projection(project_id) do
        nil -> "project.register"
        _ -> "project.update"
      end

    CommandGateway.dispatch_system(%{
      aggregate_id: "project:#{project_id}",
      type: type,
      payload: Map.put(payload, :project_id, project_id)
    })
  end

  def save(%{project_id: nil}), do: {:error, :missing_project_id}
  def save(%{}), do: {:error, :missing_project_id}

  @doc "List all project projections."
  @spec list() :: [map()]
  def list do
    ProjectionStore.list_projects()
  end

  @doc "Get a single project projection."
  @spec get(String.t()) :: map() | nil
  def get(project_id) when is_binary(project_id) do
    ProjectionStore.project_projection(project_id)
  end

  @doc "Archive a project."
  @spec archive(String.t()) :: {:ok, term()} | {:error, term()}
  def archive(project_id) when is_binary(project_id) do
    CommandGateway.dispatch_system(%{
      aggregate_id: "project:#{project_id}",
      type: "project.archive",
      payload: %{project_id: project_id}
    })
  end

  @doc "Reactivate a project."
  @spec reactivate(String.t()) :: {:ok, term()} | {:error, term()}
  def reactivate(project_id) when is_binary(project_id) do
    CommandGateway.dispatch_system(%{
      aggregate_id: "project:#{project_id}",
      type: "project.reactivate",
      payload: %{project_id: project_id}
    })
  end
end
