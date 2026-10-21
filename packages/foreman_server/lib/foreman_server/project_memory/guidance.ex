defmodule ForemanServer.ProjectMemory.Guidance do
  @moduledoc """
  The single standing instruction telling agents how to use project memory.

  `text/0` is embedded verbatim by prompt injection (E3) and `tool_description/1`
  builds the MCP tool descriptions from the same wording, so neither can drift.
  """

  @text """
  - Save only durable facts future threads need: decisions, conventions, environment gotchas, project-wide user preferences.
  - Never save task progress, logs, secrets or anything derivable from the repo.
  - Call foreman_project_memory_list before writing; update an existing topic instead of duplicating it.
  - Keep each entry under ~2 KB.
  - Use foreman_project_memory_forget for facts that became false.
  """

  @doc "The standing guidance block (<= 1200 bytes)."
  @spec text() :: String.t()
  def text, do: @text

  @doc "Description for one MCP tool, built from the shared guidance."
  @spec tool_description(:list | :read | :write | :forget) :: String.t()
  def tool_description(:list),
    do:
      "List this project's memory: the MEMORY.md index plus one entry per topic. " <>
        "Call it before writing so you update rather than duplicate."

  def tool_description(:read),
    do: "Read one project-memory topic (already redacted) by name."

  def tool_description(:write),
    do:
      "Create or replace one durable project-memory topic (secrets are redacted). " <>
        "Guidance:\n" <> @text

  def tool_description(:forget),
    do: "Delete a project-memory topic whose fact became false. Guidance:\n" <> @text
end
