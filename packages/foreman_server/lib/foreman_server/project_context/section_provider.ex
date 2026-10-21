defmodule ForemanServer.ProjectContext.SectionProvider do
  @moduledoc """
  Behaviour for optional context sections (memory, library, ...). Providers are
  listed under `config :foreman_server, :project_context, section_providers:`.
  A provider returns `:skip` when it has nothing to say; it never raises on
  missing data.
  """

  alias ForemanServer.ProjectContext.Section

  @callback section(project_id :: String.t()) :: {:ok, Section.t()} | :skip
end
