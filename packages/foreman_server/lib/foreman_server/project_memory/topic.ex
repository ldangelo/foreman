defmodule ForemanServer.ProjectMemory.Topic do
  @moduledoc """
  One memory topic as exposed by `ForemanServer.ProjectMemory`: on-disk
  metadata merged with the audit-index fields (author, version, updated_at).
  `on_disk?` is false for a topic the audit index knows but whose file is gone.
  """
  alias ForemanServer.ProjectMemory.Store.Entry

  @enforce_keys [:name, :sha256, :bytes]
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          sha256: String.t(),
          bytes: non_neg_integer(),
          redactions: non_neg_integer(),
          version: pos_integer() | nil,
          author_kind: String.t() | nil,
          author_ref: String.t() | nil,
          updated_at: String.t() | nil,
          on_disk?: boolean()
        }
  defstruct [
    :name,
    :sha256,
    :bytes,
    :version,
    :author_kind,
    :author_ref,
    :updated_at,
    description: "",
    redactions: 0,
    on_disk?: true
  ]

  @doc "Merge a disk entry with its (optional) audit projection map."
  @spec build(Entry.t(), map() | nil, boolean()) :: t()
  def build(%Entry{} = entry, audit, on_disk?) do
    %__MODULE__{
      name: entry.name,
      description: entry.description,
      sha256: entry.sha256,
      bytes: entry.bytes,
      redactions: entry.redactions,
      on_disk?: on_disk?
    }
    |> put_audit(audit)
  end

  @doc "Topic known only from the audit index."
  @spec from_audit(map()) :: t()
  def from_audit(audit) do
    %__MODULE__{
      name: audit.name,
      description: audit.description || "",
      sha256: audit.sha256,
      bytes: audit.bytes,
      on_disk?: false
    }
    |> put_audit(audit)
  end

  defp put_audit(topic, nil), do: topic

  defp put_audit(topic, audit) do
    %{
      topic
      | version: audit.version,
        author_kind: audit.author_kind,
        author_ref: audit.author_ref,
        updated_at: audit.updated_at,
        redactions: audit.redactions || topic.redactions
    }
  end
end
