defmodule ForemanServer.Events.QuestionAnswered do
  @moduledoc """
  An operator answered an open question. `text` is the answer (<= 8000
  characters); it is delivered to the asking agent by
  `ForemanServer.Questions.Deliverer` and is the only event that carries it.
  """
  @enforce_keys [:run_id, :question_id, :text, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          question_id: String.t(),
          text: String.t(),
          answered_by: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :question_id, :text, :answered_by, :at]
end
