defmodule ForemanServer.Events.QuestionExpired do
  @moduledoc """
  An open question was not answered before its timeout. It can no longer be
  answered; the operator steers the run instead.
  """
  @enforce_keys [:run_id, :question_id, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          question_id: String.t(),
          reason: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :question_id, :reason, :at]
end
