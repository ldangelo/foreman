defmodule ForemanServer.MCP.QuestionsTool do
  @moduledoc """
  Implementation of the read-only `foreman_questions_list` MCP tool: a project's
  operator questions as a `ForemanServer.Questions.Listing` (the same typed payload
  `GET /api/projects/:id/questions` returns). Answering a question is the operator's
  `question.answer` command, never an MCP tool.
  """

  alias ForemanServer.MCP.ToolError
  alias ForemanServer.Questions.Listing
  alias ForemanServer.{ProjectStore, ProjectionStore}

  @doc "Run the tool for `args` (atom keys: `project_id`, optional `status`)."
  @spec call(map()) :: {:ok, Listing.t()} | {:error, ToolError.t()}
  def call(%{project_id: project_id} = args) when is_binary(project_id) do
    with {:ok, status} <- status(Map.get(args, :status)) do
      if ProjectStore.get(project_id) do
        {:ok, Listing.build(ProjectionStore.project_questions(project_id, status: status))}
      else
        {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}
      end
    end
  end

  def call(_args), do: invalid("project_id is required")

  defp status(nil), do: {:ok, :pending}
  defp status("pending"), do: {:ok, :pending}
  defp status("all"), do: {:ok, :all}
  defp status(_), do: invalid("status must be pending or all")

  defp invalid(message), do: {:error, %ToolError{code: "INVALID_PARAMS", message: message}}
end
