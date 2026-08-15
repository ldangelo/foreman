defmodule ForemanServer.Work.Submission do
  @moduledoc """
  Pure submission preparation: resolves a `work.submit` payload into the
  deterministic run identity plus a frozen workflow snapshot.

  `prepare/1` is a pure function so the HTTP boundary and the supervised
  dispatcher compute the same `run_id` from the same `(work_id,
  submission_id)` pair.
  """

  alias ForemanServer.Identity
  alias ForemanServer.Workflow.Catalog

  @spec prepare(map()) ::
          {:ok, map()}
          | {:error, {:workflow_load_failed, String.t(), term()}}
          | {:error, {:invalid_submission, :missing_required_fields}}

  @doc """
  Prepare a work submission.

  ## Inputs
    - `work_id`     — the work item identifier
    - `project_id`  — the project identifier
    - `workflow`    — the workflow name (e.g. `"implement"`)
    - `prompt`      — the user prompt

  ## Returns
    - `{:ok, %{submission_id, run_id, workflow_snapshot, work_id, project_id, workflow}}`
    - `{:error, {:workflow_load_failed, name, reason}}` if the manifest cannot be loaded
    - `{:error, {:invalid_submission, :missing_required_fields}}` if required fields are absent
  """
  def prepare(
        %{
          work_id: work_id,
          project_id: project_id,
          workflow: workflow_name,
          prompt: prompt
        } = input
      )
      when is_map(input) and
             is_binary(work_id) and work_id != "" and
             is_binary(project_id) and is_binary(workflow_name) and is_binary(prompt) do
    with {:ok, manifest} <- load_manifest(workflow_name),
         {:ok, submission_id} <- derive_submission_id(),
         run_id = Identity.run_id(work_id, submission_id),
         {:ok, workflow_snapshot} <- build_snapshot(manifest, prompt, run_id, workflow_name) do
      {:ok,
       %{
         submission_id: submission_id,
         run_id: run_id,
         workflow_snapshot: workflow_snapshot,
         work_id: work_id,
         project_id: project_id,
         workflow: workflow_name
       }}
    end
  end

  def prepare(_) do
    {:error, {:invalid_submission, :missing_required_fields}}
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp load_manifest(workflow_name) do
    case Catalog.load(workflow_name <> ".yaml") do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, reason} ->
        {:error, {:workflow_load_failed, workflow_name, reason}}
    end
  end

  defp derive_submission_id do
    {:ok, EventStore.UUID.uuid4()}
  end

  defp build_snapshot(manifest, prompt, run_id, workflow_name) do
    phases =
      manifest.phases
      |> Enum.with_index(1)
      |> Enum.map(fn {phase, index} ->
        Map.merge(phase, %{
          index: index,
          phase_id: Identity.phase_id(run_id, index)
        })
      end)

    workflow_snapshot = %{
      phases: phases,
      workflow: workflow_name,
      input: %{
        "prompt" => prompt,
        "prompt_argument" => Jason.encode!(prompt)
      }
    }

    {:ok, workflow_snapshot}
  end
end
