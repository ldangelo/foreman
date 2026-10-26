defmodule ForemanServer.Questions.Listing do
  @moduledoc """
  The result of listing operator questions: the ONE payload that
  `GET /api/projects/:id/questions` and the `foreman_questions_list` MCP tool return,
  built here from the projection so both transports share one shape (AGENTS.md 5.1,
  5.7).

  The struct field is the wire name: `Jason.Encoder` emits `{"questions": [...]}`,
  each entry a `ForemanServer.Questions.DTO`.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Questions.DTO

  @enforce_keys [:questions]
  @type t :: %__MODULE__{questions: [DTO.t()]}
  @derive Jason.Encoder
  defstruct [:questions]

  @doc "The listing of projected questions."
  @spec build([ProjectionStore.question()]) :: t()
  def build(questions) when is_list(questions), do: %__MODULE__{questions: DTO.list(questions)}
end
