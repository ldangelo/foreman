defmodule ForemanServer.Questions.DTO do
  @moduledoc """
  String-keyed, whitelisted view of a projected operator question, shared by
  `GET /api/projects/:id/questions` and the `foreman_questions_list` MCP tool.

  `actions` is `["question.answer"]` only while the question is `open`;
  `command_hints` carries the payload skeleton (the `text` is the operator's to
  fill in) for `POST /api/commands`. Answering is never an MCP tool.
  """

  alias ForemanServer.ProjectionStore

  @type t :: %{String.t() => term()}

  @doc "DTO for one projected question."
  @spec to_map(ProjectionStore.question()) :: t()
  def to_map(question) do
    open? = question.status == "open"

    %{
      "question_id" => question.question_id,
      "run_id" => question.run_id,
      "project_id" => question.project_id,
      "agent_id" => question.agent_id,
      "text" => question.text,
      "status" => question.status,
      "opened_at" => question.opened_at,
      "decided_at" => question.decided_at,
      "answered_by" => question.answered_by,
      "reason" => question.reason,
      "actions" => if(open?, do: ["question.answer"], else: []),
      "command_hints" => if(open?, do: hints(question), else: %{})
    }
  end

  @doc "DTO list."
  @spec list([ProjectionStore.question()]) :: [t()]
  def list(questions), do: Enum.map(questions, &to_map/1)

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
