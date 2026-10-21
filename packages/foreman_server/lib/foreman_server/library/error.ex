defmodule ForemanServer.Library.Error do
  @moduledoc """
  Typed failure of the project library (AGENTS.md §5.1): never a bare map.

  `code` vocabulary:

    * `:name_invalid` - entry name fails `^[A-Za-z0-9][A-Za-z0-9_ -]{0,127}$`
    * `:path_invalid` - a relative path is empty, absolute, has `..`/NUL, escapes
      its root, or duplicates another path in the same add
    * `:source_missing` - a source file/folder does not exist or is not the right type
    * `:too_many_files` - a file add lists more than `max_files_per_add` files
    * `:file_too_large` - a file exceeds `max_file_bytes` (`details.path`)
    * `:folder_empty` - a folder add selected no files (`details.skipped` says why)
    * `:too_many_folders` - the project already holds the maximum folder entries
    * `:duplicate_name` - another entry already has the name
    * `:not_found` - unknown entry id, or file missing from an entry
    * `:too_large` - a read exceeds the per-read byte cap
    * `:produced_over_budget` - a thread-produced registration would exceed the
      per-run file/byte budget
    * `:server_path_disabled` - server-path folder adds are not enabled
    * `:project_not_found` / `:project_archived` / `:project_path_unknown` - facade project guards
    * `:write_failed` - filesystem failure
    * `:dispatch_failed` - the metadata command was rejected; disk was rolled back
  """
  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defstruct [:code, :message, details: %{}]

  @doc "Builds an error."
  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details),
      do: %__MODULE__{code: code, message: message, details: details}
end
