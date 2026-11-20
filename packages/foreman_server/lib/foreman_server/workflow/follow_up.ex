defmodule ForemanServer.Workflow.FollowUp do
  @moduledoc """
  Turns a recorded `RunFollowUpRequested` (`ProjectionStore.followup_request/1`) into what the
  Dispatcher hands to `RunAdmission.start/2` and `RunExecutor`: a TASK-LESS run payload and a
  task-shaped map for the executor.

  A follow-up run has no task, mints no Bead and touches no task provider (`provider_tracked:
  false`). Its workflow is one phase, `fix`, whose prompt is the request's already-redacted prompt
  (`followup.prompt`, read by `RunExecutor` instead of a catalog file). The attach-branch and push
  settings travel in the executor's task map under `:followup`; they are not workflow manifest keys.
  """

  alias ForemanServer.Work.RunPayload

  @workflow_name "pr-fix"

  @spec workflow_name() :: String.t()
  def workflow_name, do: @workflow_name

  @doc "The admission payload of a recorded request."
  @spec run_payload(map()) :: RunPayload.t()
  def run_payload(%{run_id: run_id, project_id: project_id} = request) do
    snapshot = workflow_snapshot(request)

    %RunPayload{
      run_id: run_id,
      task_id: nil,
      project_id: project_id,
      approval_id: nil,
      workflow_snapshot: snapshot,
      phase_specs: Map.fetch!(snapshot, "phases"),
      source: :followup
    }
  end

  @doc "The task-shaped map `RunExecutor` runs against (no task id, no provider tracking)."
  @spec task_projection(map()) :: map()
  def task_projection(%{run_id: run_id, project_id: project_id} = request) do
    %{
      run_id: run_id,
      project_id: project_id,
      workflow_name: @workflow_name,
      workflow_snapshot: workflow_snapshot(request),
      provider_tracked: false,
      followup: followup(request)
    }
  end

  @doc """
  The run id of the follow-up that fixes one PR attempt: deterministic from the parent run, the PR,
  the fix kind and the attempt, so a re-delivered request names the same run (`run-` + 32 hex, the
  shape of every run id).
  """
  @spec run_id(String.t(), String.t(), String.t(), term()) :: String.t()
  def run_id(parent_run_id, pr_url, kind, attempt) do
    digest =
      :crypto.hash(:sha256, Enum.join([parent_run_id, pr_url, kind, to_string(attempt)], "\0"))

    "run-" <> binary_part(Base.encode16(digest, case: :lower), 0, 32)
  end

  @doc """
  Records the request (`run.followup.request`, system-only). The Dispatcher admits the run when the
  event arrives. Returns `{:ok, run_id}`; a request already recorded for the id is `{:ok, run_id}`
  too (the id is deterministic, so that is a re-delivery).
  """
  @spec request(map()) :: {:ok, String.t()} | {:error, term()}
  def request(%{run_id: run_id} = request) when is_binary(run_id) do
    command = %{
      type: "run.followup.request",
      command_id: "followup:" <> run_id,
      aggregate_id: ForemanServer.Aggregates.RunFollowUp.stream_id(run_id),
      payload: request
    }

    case ForemanServer.CommandGateway.dispatch_system(command) do
      {:ok, _} -> {:ok, run_id}
      {:error, {:already_exists, :run_followup, ^run_id}} -> {:ok, run_id}
      {:error, _} = error -> error
    end
  end

  @doc "The `resume_session` start option of a request, or `[]`."
  @spec resume_opts(map()) :: keyword()
  def resume_opts(%{resume_session_provider: provider, resume_session_id: id})
      when is_binary(provider) and is_binary(id),
      do: [resume_session: {provider, id}]

  def resume_opts(_request), do: []

  defp followup(request) do
    Map.take(request, [
      :kind,
      :parent_run_id,
      :pr_url,
      :fix_kind,
      :attach_branch,
      :push,
      :prompt,
      :note,
      :repo_path,
      :worktree_path
    ])
  end

  defp workflow_snapshot(request) do
    %{
      "workflow_name" => @workflow_name,
      "phases" => [phase(request)],
      "worktree" => %{"enabled" => true, "path" => "workspace", "cleanup" => "never"}
    }
    |> put_if("sandbox", request[:sandbox])
  end

  defp phase(request) do
    %{"name" => "fix", "commit" => true}
    |> put_if("provider", request[:provider])
    |> put_if("models", request[:model] && %{"default" => request[:model]})
    |> put_if("approval_mode", request[:approval_mode])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
