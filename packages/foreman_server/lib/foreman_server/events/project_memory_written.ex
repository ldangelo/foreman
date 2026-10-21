defmodule ForemanServer.Events.ProjectMemoryWritten do
  @moduledoc """
  Typed event appended to `project_memory:<project_id>` when a memory topic is
  written. It carries metadata only (name, description hook, sha256, bytes,
  redaction count, author). The content is deliberately absent: it lives on
  disk under `.foreman/memory/`, redacted, because the event log is
  append-only and memory must stay deletable. Do not add a `content` field.
  """
  @enforce_keys [:project_id, :name, :sha256, :bytes, :author_kind, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          sha256: String.t(),
          bytes: non_neg_integer(),
          redactions: non_neg_integer(),
          version: pos_integer(),
          author_kind: String.t(),
          author_ref: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :name,
    :description,
    :sha256,
    :bytes,
    :author_kind,
    :author_ref,
    :at,
    redactions: 0,
    version: 1
  ]
end
