defmodule ForemanServer.MCP.RepoTools do
  @moduledoc """
  Write MCP tools of the multi-repository epic (E12):

    * `foreman_run_request_repo` (S10) - a thread adds a repository to its own
      run (`run.repo.request`): allowlist, cap and audit decide.
    * `foreman_task_fanout` (S11) - goal fan-out, one single-repo task per
      repository (`task.fanout`).

  Both are in `ForemanServer.MCP.Policy`'s write set, so they need
  `allow_workflow_writes`. Both are system-authored commands: neither is in the
  operator allowlist, and the tools run them through `Workflow.RunRepoRequest` /
  `Workflow.TaskFanout` directly (this directory never calls the gateway's
  trusted-automation dispatch, see `MCP.PolicyTest`). There is deliberately no
  PR-gate path here. `ForemanServer.MCP.Tools` advertises `schemas/0` and
  delegates.
  """

  alias ForemanServer.MCP.{Policy, ToolError}
  alias ForemanServer.Telemetry
  alias ForemanServer.Workflow.{RunRepoRequest, TaskFanout}

  @request_tool "foreman_run_request_repo"
  @fanout_tool "foreman_task_fanout"

  @doc "Tool schemas, appended to `ForemanServer.MCP.Tools`'s tool list."
  @spec schemas() :: [map()]
  def schemas do
    [
      %{
        name: @request_tool,
        description:
          "Ask to add a repository to THIS run (a thread widening its own scope). Name a registered " <>
            "repo_id or an absolute repo_path. The operator's project repo_allowlist decides (empty " <>
            "= feature off: every request is denied) and max_repos_per_run caps the run; every " <>
            "request, allowed or denied, is audited. An unregistered path inside the allowlist is " <>
            "registered first. The repository's worktree is created immediately but takes effect in " <>
            "the NEXT phase (effective next phase): the phase already running does not see it " <>
            "(FOREMAN_REPOS is recomputed per phase). An attached repository gets its own PR. " <>
            "Requires allow_workflow_writes.",
        inputSchema: %{
          type: "object",
          required: ["run_id"],
          properties: %{
            run_id: %{type: "string", description: "The run's own ID (must not be finished)"},
            repo_id: %{type: "string", description: "A repository id registered on the project"},
            repo_path: %{
              type: "string",
              description: "Absolute path of a git work tree (used when repo_id is omitted)"
            }
          }
        }
      },
      %{
        name: @fanout_tool,
        description:
          "Fan a goal out as ONE task per repository (independent single-repo runs, one PR each; " <>
            "not one multi-repo run). Task ids are <fanout_id>-<repo_id>, so retrying with the same " <>
            "fanout_id creates no duplicates. Tasks are created open (start them separately); " <>
            "pause/archive/cap rejections are reported per repository and keep the tasks already " <>
            "created. Requires allow_workflow_writes.",
        inputSchema: %{
          type: "object",
          required: ["project_id", "title", "prompt", "workflow", "repo_ids"],
          properties: %{
            project_id: %{type: "string", description: "The project ID"},
            title: %{type: "string", description: "Task title shared by every task"},
            prompt: %{type: "string", description: "The goal prompt every task receives"},
            workflow: %{type: "string", description: "The workflow name"},
            repo_ids: %{
              anyOf: [
                %{type: "array", items: %{type: "string"}},
                %{type: "string", enum: ["all"]}
              ],
              description: "Registered repository ids, or \"all\" for every repository"
            },
            fanout_id: %{
              type: "string",
              description:
                "Label shared by the tasks and the idempotency key. Minted when omitted; pass the same one to retry."
            }
          }
        }
      }
    ]
  end

  @doc "`foreman_run_request_repo`."
  @spec run_request_repo(map()) :: {:ok, map()} | {:error, ToolError.t()}
  def run_request_repo(%{run_id: run_id} = args) do
    with :ok <- authorize(@request_tool) do
      payload =
        %{run_id: run_id, requested_by: "run:" <> run_id}
        |> put_present(:repo_id, Map.get(args, :repo_id))
        |> put_present(:repo_path, Map.get(args, :repo_path))

      run(@request_tool, &RunRepoRequest.execute/1, %{
        command_id: "mcp:#{@request_tool}:#{run_id}:#{System.unique_integer([:positive])}",
        payload: payload
      })
    end
  end

  @doc "`foreman_task_fanout`."
  @spec task_fanout(map()) :: {:ok, map()} | {:error, ToolError.t()}
  def task_fanout(%{project_id: project_id} = args) do
    with :ok <- authorize(@fanout_tool) do
      payload =
        %{
          project_id: project_id,
          title: Map.get(args, :title),
          prompt: Map.get(args, :prompt),
          workflow_name: Map.get(args, :workflow),
          repo_ids: Map.get(args, :repo_ids)
        }
        |> put_present(:fanout_id, Map.get(args, :fanout_id))

      run(@fanout_tool, &TaskFanout.execute/1, %{
        command_id: "mcp:#{@fanout_tool}:#{project_id}:#{System.unique_integer([:positive])}",
        payload: payload
      })
    end
  end

  defp authorize(tool) do
    if Policy.authorized?(tool) do
      :ok
    else
      {:error,
       %ToolError{
         code: "WRITE_NOT_ALLOWED",
         message: "#{tool} requires allow_workflow_writes to be enabled"
       }}
    end
  end

  defp run(tool, fun, command) do
    start_us = System.monotonic_time(:microsecond)
    result = fun.(command)
    duration_us = System.monotonic_time(:microsecond) - start_us

    case result do
      {:ok, body} ->
        Telemetry.mcp_tool_call(duration_us, tool, :ok)
        {:ok, body}

      {:error, reason} ->
        Telemetry.mcp_tool_call(duration_us, tool, :error)
        {:error, tool_error(reason)}

      {:error, reason, _detail} ->
        Telemetry.mcp_tool_call(duration_us, tool, :error)
        {:error, tool_error(reason)}
    end
  end

  defp tool_error({:repo_not_allowed, path}),
    do: %ToolError{
      code: "REPO_NOT_ALLOWED",
      message: "repository #{inspect(path)} is not allowed by the project's repo_allowlist"
    }

  defp tool_error({:max_repos_exceeded, max}),
    do: %ToolError{
      code: "MAX_REPOS_EXCEEDED",
      message: "a run may use at most #{max} repositories (primary included)"
    }

  defp tool_error({:not_found, :run, _id}),
    do: %ToolError{code: "NOT_FOUND", message: "Run not found"}

  defp tool_error({:run_terminal, _run_id}),
    do: %ToolError{code: "RUN_FINISHED", message: "the run has finished"}

  defp tool_error(reason),
    do: %ToolError{code: "DOMAIN_ERROR", message: inspect(reason)}

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
