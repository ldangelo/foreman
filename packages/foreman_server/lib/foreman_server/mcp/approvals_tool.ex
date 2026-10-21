defmodule ForemanServer.MCP.ApprovalsTool do
  @moduledoc """
  Implementation of the read-only `foreman_approvals_list` MCP tool: a project's
  (or one run's) tool-call permission requests as `ForemanServer.Approvals.DTO`
  maps. There is deliberately no MCP tool that decides a request: deciding is the
  operator's `tool.approve` / `tool.deny` command over `POST /api/commands` or the
  CLI.
  """

  alias ForemanServer.Approvals.DTO
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.{ProjectStore, ProjectionStore}

  @doc "Run the tool for `args` (atom keys: `project_id` or `run_id`, optional `status`)."
  @spec call(map()) :: {:ok, map()} | {:error, ToolError.t()}
  def call(args) when is_map(args) do
    with {:ok, status} <- status(Map.get(args, :status)),
         {:ok, calls} <- read(args, status) do
      {:ok, %{"approvals" => DTO.list(calls)}}
    end
  end

  defp read(%{project_id: project_id} = args, status) when is_binary(project_id) do
    cond do
      Map.has_key?(args, :run_id) ->
        invalid("pass project_id or run_id, not both")

      ProjectStore.get(project_id) == nil ->
        {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}

      true ->
        {:ok, ProjectionStore.project_approvals(project_id, status: status)}
    end
  end

  defp read(%{run_id: run_id}, status) when is_binary(run_id) do
    if ProjectionStore.run(run_id) != nil or ProjectionStore.jobsite(run_id) != nil do
      {:ok, ProjectionStore.run_approvals(run_id, status: status)}
    else
      {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
    end
  end

  defp read(_args, _status), do: invalid("project_id or run_id is required")

  defp status(nil), do: {:ok, :pending}
  defp status("pending"), do: {:ok, :pending}
  defp status("all"), do: {:ok, :all}
  defp status(_), do: invalid("status must be pending or all")

  defp invalid(message), do: {:error, %ToolError{code: "INVALID_PARAMS", message: message}}
end
