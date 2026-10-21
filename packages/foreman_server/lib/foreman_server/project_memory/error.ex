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
end
