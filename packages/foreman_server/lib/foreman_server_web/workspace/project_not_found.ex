defmodule ForemanServerWeb.Workspace.ProjectNotFound do
  @moduledoc """
  Raised by the workspace LiveViews for an unknown project id. Carries
  `plug_status: 404` so the dead render answers 404 instead of an empty page.
  """

  defexception [:project_id, plug_status: 404]

  @impl true
  def message(%{project_id: project_id}), do: "project not found: #{inspect(project_id)}"
end
