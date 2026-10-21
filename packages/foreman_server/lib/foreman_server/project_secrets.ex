defmodule ForemanServer.ProjectSecrets do
  @moduledoc """
  Write path for project secrets: the value goes straight into
  `ForemanServer.SecretStore`, then only `name` + `version` is recorded by
  dispatching `project.secret.set` / `project.secret.unset` (system-only; not
  in the operator allowlist). The value is never part of any command, event,
  log line or return value.
  """

  alias ForemanServer.Aggregates.ProjectSecret
  alias ForemanServer.{CommandGateway, ProjectionStore, SecretStore}

  @type error :: {:error, SecretStore.Error.t() | term()}

  @doc """
  Store (or rotate) `name` for `project_id`. `author_ref` identifies the
  surface that wrote it (e.g. `"http"`). Returns `{:ok, %{name:, version:}}`.
  If the store write succeeds but the event dispatch fails the error is
  returned and the stored value stays (a retry re-dispatches).
  """
  @spec set(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, %{name: String.t(), version: pos_integer()}} | error()
  def set(project_id, name, value, author_ref \\ nil) do
    with :ok <- require_project(project_id),
         {:ok, :stored} <- SecretStore.put(project_id, name, value) do
      next = current_version(project_id, name) + 1

      case dispatch("project.secret.set", project_id, name, next, author_ref) do
        {:ok, _} -> {:ok, %{name: name, version: next}}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Delete `name` for `project_id`. Returns `{:ok, %{name:}}`."
  @spec unset(String.t(), String.t(), String.t() | nil) :: {:ok, %{name: String.t()}} | error()
  def unset(project_id, name, author_ref \\ nil) do
    with :ok <- require_project(project_id),
         {:ok, :deleted} <- SecretStore.delete(project_id, name) do
      next = current_version(project_id, name) + 1

      case dispatch("project.secret.unset", project_id, name, next, author_ref) do
        {:ok, _} -> {:ok, %{name: name}}
        {:error, _} = error -> error
      end
    end
  end

  defp require_project(project_id) when is_binary(project_id) and project_id != "" do
    case ProjectionStore.project(project_id) do
      nil -> {:error, {:not_found, :project, project_id}}
      _ -> :ok
    end
  end

  defp require_project(_), do: {:error, {:missing_or_invalid, :project_id}}

  # Latest projected version (set OR unset) for the name, 0 when never seen.
  defp current_version(project_id, name) do
    project_id
    |> ProjectionStore.project_secret_versions()
    |> Map.get(name, 0)
  end

  defp dispatch(type, project_id, name, version, author_ref) do
    stream = ProjectSecret.stream_id(project_id)

    CommandGateway.dispatch_system(%{
      type: type,
      command_id: "project_secret:#{project_id}:#{name}:#{version}",
      aggregate_id: stream,
      payload: %{project_id: project_id, name: name, author_ref: author_ref}
    })
  end
end
