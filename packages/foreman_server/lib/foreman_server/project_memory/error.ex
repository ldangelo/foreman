defmodule ForemanServer.ProjectMemory.Error do
  @moduledoc """
  Typed failure of project memory (AGENTS.md §5.1): never a bare map.

  `code` vocabulary:

    * `:name_invalid` - topic name fails `^[a-z0-9][a-z0-9_-]{0,63}$` (or is reserved)
    * `:content_too_large` - redacted content exceeds the per-topic cap
    * `:index_full` - the generated `MEMORY.md` would exceed its line/byte cap
    * `:too_many_topics` - the project already has the maximum number of topics
    * `:content_not_durable` - content is a log/env dump (`details.reason` is
      `:repeated_lines` or `:mostly_secrets`)
    * `:not_found` - unknown topic
    * `:project_path_unknown` - the project has no usable path on disk
    * `:project_not_found` / `:project_archived` - facade project guards
    * `:write_failed` - filesystem failure
    * `:audit_failed` - the audit command was rejected; disk was rolled back
    * `:description_invalid` - description is not a string
  """
  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defstruct [:code, :message, details: %{}]

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details),
      do: %__MODULE__{code: code, message: message, details: details}

  # Every code `ProjectMemory` can produce, with the coarse class both the HTTP
  # and MCP surfaces derive their responses from. A code missing here makes
  # `category/1` raise (and `error_test.exs` fails for any `Error.new(:code, ...)`
  # in the project-memory sources that is not listed), so a new code cannot
  # silently fall into the wrong class on one surface.
  @categories %{
    name_invalid: :invalid_input,
    description_invalid: :invalid_input,
    content_too_large: :invalid_input,
    index_full: :invalid_input,
    too_many_topics: :invalid_input,
    content_not_durable: :invalid_input,
    not_found: :not_found,
    project_not_found: :not_found,
    project_archived: :conflict,
    project_path_unknown: :conflict,
    write_failed: :internal,
    audit_failed: :internal
  }

  @type category :: :invalid_input | :not_found | :conflict | :internal

  @doc "Every known error code."
  @spec codes() :: [atom()]
  def codes, do: Map.keys(@categories)

  @doc """
  Coarse class of an error code, shared by the HTTP and MCP surfaces so their
  status/code mappings cannot drift: `:invalid_input`, `:not_found`,
  `:conflict` (archived project / no path) or `:internal`. Raises on a code
  that is not in the table.
  """
  @spec category(atom()) :: category()
  def category(code) when is_atom(code), do: Map.fetch!(@categories, code)
end
