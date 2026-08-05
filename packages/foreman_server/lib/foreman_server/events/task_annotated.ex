defmodule ForemanServer.Events.TaskAnnotated do
  @moduledoc "Typed event emitted when a task is annotated."
  @enforce_keys [:task_id, :body, :author]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          body: String.t(),
          author: String.t(),
          metadata: map() | nil
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, :body, :author, :metadata]
end