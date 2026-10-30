defmodule ForemanServer.Questions.DTO do
  @moduledoc """
  Whitelisted struct view of a projected operator question, shared by
  `GET /api/projects/:id/questions` and the `foreman_questions_list` MCP tool.

  `actions` is `["question.answer"]` only while the question is `open`;
  `command_hints` carries the payload skeleton (the `text` is the operator's to
  fill in) for `POST /api/commands`. Answering is never an MCP tool.
  `undelivered_reason` is set only on an `answered` question whose answer can never reach the
  agent (it was recorded before the answer limit and is too long to steer the run with): the
  operator steers the run with a shorter message instead.
  """

  alias ForemanServer.ProjectionStore

  @enforce_keys [:question_id, :run_id, :status, :opened_at, :actions, :command_hints]
  @type t :: %__MODULE__{
          question_id: String.t(),
          run_id: String.t(),
          project_id: String.t() | nil,
          agent_id: String.t() | nil,
          text: String.t() | nil,
          status: String.t(),
          opened_at: String.t(),
          decided_at: String.t() | nil,
          answered_by: String.t() | nil,
          reason: String.t() | nil,
          undelivered_reason: String.t() | nil,
          actions: [String.t()],
          command_hints: %{String.t() => map()}
        }
  # The struct field names ARE the wire names (`Jason.Encoder` emits them as-is).
  @derive Jason.Encoder
  defstruct [
    :question_id,
    :run_id,
    :project_id,
    :agent_id,
    :text,
    :status,
    :opened_at,
    :decided_at,
    :answered_by,
    :reason,
    :undelivered_reason,
    :actions,
    :command_hints
  ]

  @doc "DTO for one projected question."
  @spec build(ProjectionStore.question()) :: t()
  def build(question) do
    open? = question.status == "open"

    %__MODULE__{
      question_id: question.question_id,
      run_id: question.run_id,
      project_id: question.project_id,
      agent_id: question.agent_id,
      text: question.text,
      status: question.status,
      opened_at: question.opened_at,
      decided_at: question.decided_at,
      answered_by: question.answered_by,
      reason: question.reason,
      undelivered_reason: question.undelivered_reason,
      actions: if(open?, do: ["question.answer"], else: []),
      command_hints: if(open?, do: hints(question), else: %{})
    }
  end

  @doc "DTO list."
  @spec list([ProjectionStore.question()]) :: [t()]
  def list(questions), do: Enum.map(questions, &build/1)

  defp hints(question) do
    %{
      "question.answer" => %{
        "type" => "question.answer",
        "payload" => %{
          "run_id" => question.run_id,
          "question_id" => question.question_id,
          "text" => ""
        }
      }
    }
  end
end
