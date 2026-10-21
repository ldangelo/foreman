defmodule ForemanServer.ProjectEnvironmentDTO do
  @moduledoc """
  The one wire shape of a project's environment read (`GET /api/projects/:id/environment`
  and the MCP `foreman_project_environment_get` tool). Fixed string keys; NEVER a
  secret value.

      %{
        "project_id" => "...",
        "vars" => %{"NAME" => "value" | "[redacted]"},
        "setup_script" => nil | "...",
        "network" => %{"mode" => "default", "hosts" => []},
        "network_enforced_on" => ["docker_jobsite"],
        "legacy_env" => false,
        "secrets" => [%{"name" => "API_TOKEN", "version" => 2, "updated_at" => "..."}]
      }

  `vars` values are shown only for the record form (secret-looking names are
  rejected at write time). A project still on legacy flat `config.env` may hold
  secrets there, so its values are `"[redacted]"` and `legacy_env` is `true`.
  `names_only/1` is the MCP view: variable and secret NAMES, no values at all.
  """

  alias ForemanServer.{ProjectEnvironment, ProjectionStore}
  alias ForemanServer.Jobsite.NetworkPolicy

  @redacted "[redacted]"

  @spec fetch(String.t()) :: {:ok, map()} | :not_found
  def fetch(project_id) when is_binary(project_id) do
    case ProjectionStore.project(project_id) do
      nil ->
        :not_found

      project ->
        config = Map.get(project, :config, %{})
        record = ProjectEnvironment.from_config(config)
        legacy? = not ProjectEnvironment.record_form?(config)

        {:ok,
         %{
           "project_id" => project_id,
           "vars" =>
             if(legacy?,
               do: Map.new(record["vars"], fn {name, _} -> {name, @redacted} end),
               else: record["vars"]
             ),
           "setup_script" => record["setup_script"],
           "network" => record["network"],
           "network_enforced_on" =>
             Enum.map(NetworkPolicy.network_enforced_on(), &Atom.to_string/1),
           "legacy_env" => legacy?,
           "secrets" =>
             project_id
             |> ProjectionStore.project_secret_names()
             |> Enum.map(&Map.new(&1, fn {key, value} -> {Atom.to_string(key), value} end))
         }}
    end
  end

  @doc "MCP view of `fetch/1`: variable and secret names only, no values anywhere."
  @spec names_only(map()) :: map()
  def names_only(dto) do
    dto
    |> Map.update!("vars", &(&1 |> Map.keys() |> Enum.sort()))
    |> Map.update!("secrets", fn secrets ->
      Enum.map(secrets, &Map.take(&1, ["name", "version", "updated_at"]))
    end)
  end
end
