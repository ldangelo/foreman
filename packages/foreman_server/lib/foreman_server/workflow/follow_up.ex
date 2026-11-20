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

  @doc "The `resume_session` start option of a request, or `[]`."
  @spec resume_opts(map()) :: keyword()
  def resume_opts(%{resume_session_provider: provider, resume_session_id: id})
      when is_binary(provider) and is_binary(id),
      do: [resume_session: {provider, id}]

  def resume_opts(_request), do: []

  defp followup(request) do
    Map.take(request, [:kind, :parent_run_id, :pr_url, :fix_kind, :attach_branch, :push, :prompt, :note])
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
