defmodule ForemanServerWeb.Workspace.ProjectView do
  @moduledoc """
  Reads the few project facts the workspace pages display, normalising the
  projection's mixed atom/string config keys ONCE here (a persisted config has
  atom keys when freshly appended and string keys after a replay) so no page
  hedges between the two.
  """

  @type t :: %{name: String.t(), status: String.t() | nil}

  @doc "Display facts of a project projection; `fallback_name` is used when it has no name."
  @spec build(map(), String.t()) :: t()
  def build(project, fallback_name) when is_map(project) do
    config = stringify(Map.get(project, :config))

    %{name: config["name"] || fallback_name, status: Map.get(project, :status)}
  end

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}
end
