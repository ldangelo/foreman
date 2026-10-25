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

  @invalid_input [
    :name_invalid,
    :description_invalid,
    :content_too_large,
    :index_full,
    :too_many_topics,
    :content_not_durable
  ]

  @doc """
  Coarse class of an error code, shared by the HTTP and MCP surfaces so their
  status/code mappings cannot drift: `:invalid_input`, `:not_found`,
  `:conflict` (archived project / no path) or `:internal`.
  """
  @spec category(atom()) :: :invalid_input | :not_found | :conflict | :internal
  def category(code) when code in @invalid_input, do: :invalid_input
  def category(code) when code in [:not_found, :project_not_found], do: :not_found
  def category(code) when code in [:project_archived, :project_path_unknown], do: :conflict
  def category(code) when is_atom(code), do: :internal
end
