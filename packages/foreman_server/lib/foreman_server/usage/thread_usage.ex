defmodule ForemanServer.Usage.ThreadUsage do
  @moduledoc "One thread's (run or jobsite) bucket, its last activity and its most recent events."

  alias ForemanServer.Usage
  alias ForemanServer.Usage.Bucket

  @type recent :: %{at: String.t(), usage: Usage.t()}
  @type t :: %__MODULE__{
          thread_kind: String.t(),
          thread_id: String.t(),
          role: String.t(),
          provider: String.t() | nil,
          last_at: String.t(),
          bucket: Bucket.t(),
          recent: [recent()]
        }
  @enforce_keys [:thread_kind, :thread_id, :role, :last_at]
  defstruct [
    :thread_kind,
    :thread_id,
    :role,
    :last_at,
    provider: nil,
    bucket: %Bucket{},
    recent: []
  ]
end
