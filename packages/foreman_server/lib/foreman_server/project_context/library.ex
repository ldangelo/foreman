defmodule ForemanServer.ProjectContext.Library do
  @moduledoc """
  Section provider for the project library (E5). Renders `ForemanServer.Library.index/1`
  under a "Project library" heading. Library files are operator/agent supplied
  data, so they are listed, never inlined; the agent reads them from
  `$FOREMAN_LIBRARY_PATH`. A project with an empty library gets no section.
  """

  @behaviour ForemanServer.ProjectContext.SectionProvider

  alias ForemanServer.Library
  alias ForemanServer.ProjectContext.Section

  require Logger

  @impl true
  def section(project_id) do
    case Library.index(project_id) do
      {:ok, ""} ->
        :skip

      {:ok, index} ->
        {:ok,
         Section.new(:library, "Project library", String.trim_trailing(index),
           hint:
             "call foreman_project_library_list for the full list and " <>
               "foreman_project_library_read to read a file"
         )}

      {:error, error} ->
        Logger.warning("project library index unavailable for #{project_id}: #{inspect(error)}")
        :skip
    end
  end
end
