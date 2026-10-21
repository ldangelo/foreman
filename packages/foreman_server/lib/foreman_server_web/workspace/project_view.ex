defmodule ForemanServerWeb.Workspace.ProjectView do
  @moduledoc """
  Reads the few project facts the workspace pages display, normalising the
  projection's mixed atom/string config keys ONCE here (a persisted config has
  atom keys when freshly appended and string keys after a replay) so no page
  hedges between the two.
  """

  @type t :: %{name: String.t(), status: String.t() | nil, env_names: [String.t()]}

  @doc "Display facts of a project projection; `fallback_name` is used when it has no name."
  @spec build(map(), String.t()) :: t()
  def build(project, fallback_name) when is_map(project) do
    config = stringify(Map.get(project, :config))
    environment = stringify(config["environment"])

    %{
      name: config["name"] || fallback_name,
      status: Map.get(project, :status),
      env_names: env_names([config["env"], environment["vars"]])
    }
  end

  defp env_names(maps) do
    maps
    |> Enum.flat_map(fn
      %{} = m -> Map.keys(m)
      _ -> []
    end)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}
end
