defmodule ForemanServer.Workflow.Approval do
  @moduledoc """
  Pure approval preparation: resolve a `task.approve` payload into the
  deterministic run/approval identity plus a frozen workflow snapshot.

  Approval preparation is a pure function so the HTTP boundary and the
  supervised dispatcher compute the same `run_id` from the same `(task_id,
  approval_id)` pair. Both paths must agree; otherwise the dispatch claim
  command would route to a different stream than the operator event.

  When the caller does not supply an `approval_id`, one is derived
  deterministically from the `task_id` so retries produce the same run.
  """

  alias ForemanServer.Identity
  alias ForemanServer.Workflow.Catalog

  @type prepare_input :: %{
          :task_id => String.t(),
          optional(:approval_id) => String.t() | nil,
          optional(:task_type) => String.t() | nil,
          optional(:workflow_type) => String.t() | nil,
          optional(atom()) => any()
        }

  @type prepare_result :: %{
          :task_id => String.t(),
          :approval_id => String.t(),
          :run_id => String.t(),
          :workflow_name => String.t() | nil,
          :workflow_digest => String.t() | nil,
          :workflow_snapshot => map() | nil
        }

  @spec prepare(map() | prepare_input(), keyword()) ::
          {:ok, prepare_result()} | {:error, term()}
  def prepare(%{task_id: task_id} = payload, opts \\ [])
      when is_binary(task_id) and task_id != "" do
    with {:ok, approval_id} <- ensure_approval_id(payload, opts),
         run_id = Identity.run_id(task_id, approval_id),
         {:ok, workflow_name, workflow_digest, snapshot} <-
           resolve_workflow_snapshot(payload, run_id) do
      {:ok,
       %{
         task_id: task_id,
         approval_id: approval_id,
         run_id: run_id,
         workflow_name: workflow_name,
         workflow_digest: workflow_digest,
         workflow_snapshot: snapshot
       }}
    end
  end

  def prepare(payload, _opts),
    do: {:error, {:invalid_payload, :task_id_missing, Map.keys(payload || %{})}}

  @doc "Return the approval_id used for a given payload (or `:error` if invalid)."
  @spec approval_id_for(map() | prepare_input(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def approval_id_for(payload, opts \\ []) do
    ensure_approval_id(payload || %{}, opts)
  end

  defp ensure_approval_id(%{approval_id: id}, _opts) when is_binary(id) and id != "",
    do: {:ok, id}

  defp ensure_approval_id(%{approval_id: id}, _opts) when is_binary(id) and id == "",
    do: {:error, :approval_id_blank}

  defp ensure_approval_id(payload, opts) do
    case Keyword.get(opts, :approval_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> deterministic_approval_id(payload)
    end
  end

  defp deterministic_approval_id(%{task_id: task_id})
       when is_binary(task_id) and task_id != "" do
    digest =
      :crypto.hash(:sha256, "foreman.approval\0" <> task_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    {:ok, "approval-" <> digest}
  end

  defp deterministic_approval_id(_payload), do: {:error, :task_id_required}

  defp resolve_workflow_snapshot(payload, run_id) do
    task_type =
      payload[:workflow_type] ||
        payload[:task_type] ||
        Application.get_env(:foreman_server, :default_task_type, "implement")

    case Catalog.load(task_type <> ".yaml") do
      {:ok, workflow} ->
        base_snapshot = %{
          run_id: run_id,
          workflow_name: workflow.name,
          manifest_digest: workflow.digest,
          manifest_path: workflow.manifest_path,
          phases:
            workflow.phases
            |> Enum.with_index(1)
            |> Enum.map(fn {phase, index} ->
              Map.merge(phase, %{
                index: index,
                phase_id: Identity.phase_id(run_id, index)
              })
            end)
        }

        snapshot =
          base_snapshot
          |> maybe_put_worktree(workflow)
          |> maybe_put_prompt(payload[:prompt])

        {:ok, workflow.name, workflow.digest, snapshot}

      {:error, reason} ->
        {:error, {:workflow_load_failed, task_type, reason}}
    end
  end

  # The workflow's `worktree:` block travels on the snapshot beside `phases`,
  # because the run it describes has exactly one worktree. Absent when the
  # manifest declares none, so `WorktreeSpec.normalize/1` can still tell
  # "declared nothing" (every default applies) from "declared disabled".
  defp maybe_put_worktree(snapshot, workflow) do
    case Map.get(workflow, :worktree) do
      block when is_map(block) -> Map.put(snapshot, :worktree, block)
      _ -> snapshot
    end
  end

  defp maybe_put_prompt(snapshot, prompt) when is_binary(prompt) and prompt != "" do
    Map.put(snapshot, "input", %{"prompt" => prompt})
  end

  defp maybe_put_prompt(snapshot, _prompt), do: snapshot
end
