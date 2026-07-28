defmodule ForemanServer.Events.TaskAnnotated do
  @enforce_keys [:task_id, :body]
  @type t :: %__MODULE__{
    task_id: String.t(),
    body: String.t(),
    author: String.t() | nil,
    created_at: String.t() | nil,
    metadata: map() | nil
  }
  @derive Jason.Encoder
  defstruct [:task_id, :body, :author, :created_at, :metadata]
end
