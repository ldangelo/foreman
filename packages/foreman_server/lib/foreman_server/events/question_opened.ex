defmodule ForemanServer.Events.QuestionOpened do
  @moduledoc """
  An agent asked the operator a question (`question:<run_id>:<question_id>`).

  `run_id` is `"global"` when the question is not tied to a run. `text` is the
  question, redacted and cut to 500 characters; `timeout_ms` is the per-question
  timeout resolved when it was asked (the workflow manifest's
  `operator_timeout_ms`), which the sweeper uses without a manifest lookup.
  """
  @enforce_keys [:run_id, :question_id, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          question_id: String.t(),
          agent_id: String.t() | nil,
          project_id: String.t() | nil,
          text: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :question_id, :agent_id, :project_id, :text, :timeout_ms, :at]
end
