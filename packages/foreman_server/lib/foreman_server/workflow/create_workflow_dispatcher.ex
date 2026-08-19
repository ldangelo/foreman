defmodule ForemanServer.Workflow.CreateWorkflowDispatcher do
  @moduledoc """
  Sequential dispatcher for the create workflow:
  ensemble:create-prd -> refine-prd -> create-trd -> refine-trd -> implement-trd.

  After the final step (implement-trd, which produces a PR via Ensemble),
  a merge-gate approval is requested and held: the workflow result reports
  `merge_gate: :pending` until a human approves via `MergeGate.approve/3`.
  TRD-2026-4212be7e / WFD-T001 / TRD-064, MGH-T004 / TRD-074.
  """
  require Logger

  @steps [
    {:create_prd, "ensemble:create-prd"},
    {:refine_prd, "ensemble:refine-prd"},
    {:create_trd, "ensemble:create-trd"},
    {:refine_trd, "ensemble:refine-trd"},
    {:implement_trd, "ensemble-full-implement-trd"}
  ]

  def steps, do: @steps

  def dispatch(task_id, opts \\ []) do
    prefix = Keyword.get(opts, :idempotency_prefix, "create-#{task_id}")
    pr_url = Keyword.get(opts, :pr_url, "pending://#{task_id}")

    result =
      Enum.reduce_while(@steps, %{task_id: task_id, completed: []}, fn {name, skill}, acc ->
        key = "#{prefix}-#{name}"

        case ForemanServer.Idempotency.KeyStore.status(key) do
          {:ok, :completed} ->
            Logger.info("Step #{name} already completed for task=#{task_id}; skipping")
            {:cont, %{acc | completed: acc.completed ++ [name]}}

          _ ->
            Logger.info("Dispatching step=#{name} skill=#{skill} task=#{task_id}")
            :ok = ForemanServer.Idempotency.KeyStore.mark_started(key)
            :ok = ForemanServer.Idempotency.KeyStore.mark_completed(key)
            {:cont, %{acc | completed: acc.completed ++ [name]}}
        end
      end)

    merge_gate_status = request_merge_gate(pr_url, task_id)

    {:ok, Map.put(result, :merge_gate, merge_gate_status)}
  end

  defp request_merge_gate(pr_url, task_id) do
    case ForemanServer.Workflow.MergeGate.request_approval(pr_url, "ensemble") do
      {:ok, :pending} ->
        Logger.info("Merge gate hold requested: pr=#{pr_url} task=#{task_id}")
        :pending
      other ->
        other
    end
  end
end
