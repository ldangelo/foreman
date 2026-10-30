defmodule ForemanServer.Events.QuestionAnswerUndelivered do
  @moduledoc """
  An operator's answer was recorded (`QuestionAnswered`) but can never reach the agent that
  asked: it is longer than the steering message that would carry it
  (`ForemanServer.Aggregates.OperatorQuestion.max_answer_chars/1`). Only an answer recorded
  before `question.answer` refused such text can end here. `reason` says why and what to do
  (steer the run with a shorter message); the answer text stays only in `QuestionAnswered`.
  The question remains `answered`: this event marks that delivery will not happen, so
  `ForemanServer.Questions.Deliverer` stops retrying it and the operator is told.
  """
  @enforce_keys [:run_id, :question_id, :reason, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          question_id: String.t(),
          reason: String.t(),
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :question_id, :reason, :at]
end
