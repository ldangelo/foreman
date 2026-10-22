defmodule ForemanServer.Workflow.RunRepoSet do
  @moduledoc """
  Resolves which repositories a run works in, from the task/run request.

  A request names the run's PRIMARY repository (`repo_id`, default: the
  project's primary) and optionally extra repositories (`repo_ids`). A request
  that names neither is the single-repository run and resolves to `:single`
  without reading any repository data, so single-repo runs are untouched.

  Resolution order (S3 §4.1, open follow-ups 2 and 5):

    1. `repo_ids` must not contain duplicates nor the effective primary;
    2. every named repository must be registered on the project
       (`ProjectionStore.project_repositories/1`);
    3. the primary plus the extras must not exceed the cap
       (`max_repos_per_run`, default 4, counting the primary).

  `gate/2` is the run-start gate: until multi-repo runs are released
  (`config :foreman_server, :multi_repo, runs: true`) a resolved set larger
  than one repository, or a run primary that is not the project primary,
  is refused with `{:error, :multi_repo_runs_disabled}`.
  """

  alias ForemanServer.ProjectionStore

  @type repo :: map()
  @type resolved :: %{primary: repo(), extras: [repo()], project_primary_id: String.t()}

  @type error ::
          {:unknown_repo, term()}
          | {:duplicate_repo_ids, [String.t()]}
          | {:repo_id_is_primary, String.t()}
          | {:invalid_repo_ids, term()}
          | {:max_repos_exceeded, pos_integer()}
          | {:project_not_found, String.t()}

  @doc """
  Resolves `request` (`%{repo_id: id | nil, repo_ids: [id] | nil}`, atom or
  string keys) against the project's registered repositories.
  """
  @spec resolve(String.t(), map(), pos_integer()) ::
          {:ok, :single | resolved()} | {:error, error()}
  def resolve(project_id, request, max_repos) when is_map(request) do
    repo_id = field(request, :repo_id)
    repo_ids = field(request, :repo_ids)

    if repo_id in [nil, ""] and repo_ids in [nil, []] do
      {:ok, :single}
    else
      resolve_named(project_id, repo_id, repo_ids || [], max_repos)
    end
  end

  @doc """
  The project's `max_repos_per_run` (default 4) read from its current settings.
  """
  @spec cap(String.t()) :: pos_integer()
  def cap(project_id) do
    case ProjectionStore.project_settings(project_id) do
      %ForemanServer.ProjectSettings{max_repos_per_run: max} when is_integer(max) -> max
      _ -> ForemanServer.Aggregates.Project.Settings.default_max_repos_per_run()
    end
  end

  defp resolve_named(project_id, repo_id, repo_ids, max_repos) do
    case ProjectionStore.project_repositories(project_id) do
      nil ->
        {:error, {:project_not_found, project_id}}

      repos ->
        project_primary_id = primary_id(repos)
        primary_id = if repo_id in [nil, ""], do: project_primary_id, else: repo_id

        with :ok <- validate_repo_ids(repo_ids, primary_id),
             {:ok, primary} <- fetch(repos, primary_id),
             {:ok, extras} <- fetch_all(repos, repo_ids),
             :ok <- check_cap(1 + length(extras), max_repos) do
          {:ok, %{primary: primary, extras: extras, project_primary_id: project_primary_id}}
        end
    end
  end

  @doc """
  The run-start multi-repo gate. `:ok` for a single-repository run, or when
  `config :foreman_server, :multi_repo, runs: true`.
  """
  @spec gate(:single | resolved()) :: :ok | {:error, :multi_repo_runs_disabled}
  def gate(:single), do: :ok

  def gate(%{primary: %{id: primary_id}, extras: extras, project_primary_id: project_primary_id}) do
    multi? = extras != [] or primary_id != project_primary_id

    if multi? and not runs_enabled?(), do: {:error, :multi_repo_runs_disabled}, else: :ok
  end

  @doc "Whether multi-repository runs are released (`:multi_repo, runs: true`)."
  @spec runs_enabled?() :: boolean()
  def runs_enabled? do
    :foreman_server |> Application.get_env(:multi_repo, []) |> Keyword.get(:runs, false) == true
  end

  defp validate_repo_ids(repo_ids, _primary_id) when not is_list(repo_ids),
    do: {:error, {:invalid_repo_ids, repo_ids}}

  defp validate_repo_ids(repo_ids, primary_id) do
    cond do
      not Enum.all?(repo_ids, &is_binary/1) ->
        {:error, {:invalid_repo_ids, repo_ids}}

      (duplicates = repo_ids -- Enum.uniq(repo_ids)) != [] ->
        {:error, {:duplicate_repo_ids, Enum.uniq(duplicates)}}

      primary_id in repo_ids ->
        {:error, {:repo_id_is_primary, primary_id}}

      true ->
        :ok
    end
  end

  defp fetch(repos, id) do
    case Enum.find(repos, &(&1.id == id)) do
      nil -> {:error, {:unknown_repo, id}}
      repo -> {:ok, repo}
    end
  end

  defp fetch_all(repos, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case fetch(repos, id) do
        {:ok, repo} -> {:cont, {:ok, acc ++ [repo]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_cap(count, max) when count <= max, do: :ok
  defp check_cap(_count, max), do: {:error, {:max_repos_exceeded, max}}

  defp primary_id(repos) do
    case Enum.find(repos, & &1.primary) do
      %{id: id} -> id
      nil -> ForemanServer.Projects.RepoValidation.primary_id()
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
