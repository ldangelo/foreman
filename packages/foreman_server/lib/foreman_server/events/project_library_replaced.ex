defmodule ForemanServer.Events.ProjectLibraryReplaced do
  @moduledoc """
  Typed event appended to `project_library:<project_id>` when a library entry's
  files are replaced. Same metadata as `ProjectLibraryAdded` plus the
  `previous_manifest_sha256` it superseded. Never carries file bytes.
  """
  @enforce_keys [
    :project_id,
    :entry_id,
    :name,
    :kind,
    :manifest_sha256,
    :previous_manifest_sha256,
    :author_kind,
    :at
  ]
  @type t :: %__MODULE__{
          project_id: String.t(),
          entry_id: String.t(),
          name: String.t(),
          kind: String.t(),
          file_count: non_neg_integer(),
          bytes: non_neg_integer(),
          manifest_sha256: String.t(),
          previous_manifest_sha256: String.t(),
          source: map() | nil,
          skipped_summary: map(),
          author_kind: String.t(),
          author_ref: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :entry_id,
    :name,
    :kind,
    :manifest_sha256,
    :previous_manifest_sha256,
    :source,
    :author_kind,
    :author_ref,
    :at,
    file_count: 0,
    bytes: 0,
    skipped_summary: %{}
  ]
end
