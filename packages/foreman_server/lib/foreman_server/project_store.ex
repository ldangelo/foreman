defmodule ForemanServer.ProjectStore do
  @moduledoc """
  Loads configured projects from a durable term file or application config.

  The file format uses `:erlang.term_to_binary/1` so this shell can stay
  dependency-free until the Postgres-backed store lands in TRD-003.
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
    required? = Keyword.get(opts, :required?, false)

    Application.get_env(:foreman_server, :project_store_path) ||
      System.get_env("FOREMAN_SERVER_PROJECT_STORE") ||
      if(required?, do: Path.expand("var/foreman_server/projects.term"), else: nil)
  end
end
