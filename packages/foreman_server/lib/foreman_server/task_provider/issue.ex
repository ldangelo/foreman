defmodule ForemanServer.TaskProvider.Issue do
  @moduledoc """
  Normalized task-provider issue record with 11 first-class fields:
  `id`, `title`, `status`, `priority`, `dependencies`, `assignee`,
  `description`, `notes`, `design`, `labels`, and `metadata`.

  AC-019-5 requires the sensitive fields (`assignee`, `description`, `notes`,
  and `design`) to remain explicit struct fields rather than being aliased into
  `metadata`.
  """

  @enforce_keys [
    :id,
    :title,
    :status,
    :priority,
    :dependencies,
    :assignee,
    :description,
    :notes,
    :design,
    :labels,
    :metadata
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          status: String.t(),
          priority: non_neg_integer(),
          dependencies: [String.t()],
          assignee: String.t() | nil,
          description: String.t() | nil,
          notes: String.t() | nil,
          design: String.t() | nil,
          labels: [String.t()],
          metadata: map()
        }

  @derive Jason.Encoder
  defstruct [
    :id,
    :title,
    :status,
    :priority,
    dependencies: [],
    assignee: nil,
    description: nil,
    notes: nil,
    design: nil,
    labels: [],
    metadata: %{}
  ]
end
