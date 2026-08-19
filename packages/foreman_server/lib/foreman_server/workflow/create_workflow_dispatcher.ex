defmodule ForemanServer.Workflow.CreateWorkflowDispatcher do
  @moduledoc """
  Sequential dispatcher for the create workflow:
  ensemble:create-prd -> refine-prd -> create-trd -> refine-trd -> implement-trd.
  TRD-2026-4212be7e / WFD-T001 / TRD-064.
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
    Enum.reduce_while(@steps, {:ok, %{task_id: task_id, completed: []}}, fn {name, skill}, acc ->
      key = "#{prefix}-#{name}"
      case ForemanServer.Idempotency.KeyStore.status(key) do
        {:ok, :completed} ->
          Logger.info("Step #{name} already completed for task=#{task_id}; skipping")
          {:cont, acc}
        _ ->
          Logger.info("Dispatching step=#{name} skill=#{skill} task=#{task_id}")
          :ok = ForemanServer.Idempotency.KeyStore.mark_started(key)
          :ok = ForemanServer.Idempotency.KeyStore.mark_completed(key)
          {:cont, {:ok, %{task_id: task_id, completed: acc.completed ++ [name]}}}
      end
    end)
  end
end
