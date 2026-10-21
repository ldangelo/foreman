defmodule ForemanServer.WorkerEnvironment do
  @moduledoc """
  Builds immutable worker environment snapshots from the registered project.

  Env derivation lives in `ForemanServer.ProjectEnvironment.resolve/2`; this
  module is the stable facade (`build/2`, `build_env_map/1`,
  `refresh_on_relaunch/2`) plus `extract_secrets/1`, the pure key-name matcher
  that resolution and log redaction share.
  """

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.ProjectEnvironment

  @type env_map :: %{optional(String.t()) => String.t()}

  @spec build(String.t(), keyword()) :: env_map()
  def build(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    case ProjectEnvironment.resolve(project_id, opts) do
      {:ok, %{env: env}} ->
        env

      {:error, reason} ->
        raise ArgumentError,
              "project #{inspect(project_id)} environment is invalid: #{inspect(reason)}"
    end
  end

  @spec build_env_map(String.t()) :: env_map()
  def build_env_map(project_id) when is_binary(project_id), do: build(project_id, [])

  @spec refresh_on_relaunch(String.t(), env_map()) :: env_map()
  def refresh_on_relaunch(project_id, _current_env) when is_binary(project_id) do
    build_env_map(project_id)
  end

  @doc """
  Extract secret values from an env map for log redaction.

  Values whose keys match the known secret-name pattern
  (`Environment.secret_name?/1`) are returned as a list. An empty list is
  returned when no matching keys are present.
  """
  @spec extract_secrets(env_map()) :: [String.t()]
  def extract_secrets(env) when is_map(env) do
    env
    |> Enum.reject(fn {k, _v} -> is_atom(k) end)
    |> Enum.flat_map(fn
      {k, v} when is_binary(v) and v != "" ->
        if Environment.secret_name?(k), do: [v], else: []

      _ ->
        []
    end)
  end

  def extract_secrets(_), do: []
end
