defmodule ForemanServer.Workflow.ImplementWorkflowDispatcher do
  @moduledoc """
  Dispatcher for the implement workflow: ensemble-full-implement-trd.
  Idempotency key: implement-{task_id}-1.
  TRD-2026-4212be7e / WFD-T005 / TRD-068.
  """
  require Logger

  @idempotency_prefix "implement"
  @skill "ensemble-full-implement-trd"

  def dispatch(task_id, opts \\ []) do
    key = "#{@idempotency_prefix}-#{task_id}-1"
    case ForemanServer.Idempotency.KeyStore.status(key) do
      {:ok, :completed} ->
        Logger.info("Implement workflow already completed for task=#{task_id}; skipping")
        {:ok, :skipped}
      _ ->
        Logger.info("Dispatching implement workflow skill=#{@skill} task=#{task_id}")
        :ok = ForemanServer.Idempotency.KeyStore.mark_started(key)
        :ok = ForemanServer.Idempotency.KeyStore.mark_completed(key)
        {:ok, :dispatched}
    end
  end
end
