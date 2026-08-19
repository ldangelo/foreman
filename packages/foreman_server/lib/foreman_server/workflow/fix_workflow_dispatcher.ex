defmodule ForemanServer.Workflow.FixWorkflowDispatcher do
  @moduledoc """
  Dispatcher for the fix workflow: ensemble:fix-issue.
  Idempotency key: fix-{task_id}-1.
  TRD-2026-4212be7e / WFD-T006 / TRD-069.
  """
  require Logger

  @idempotency_prefix "fix"
  @skill "ensemble:fix-issue"

  def dispatch(task_id, opts \\ []) do
    key = "#{@idempotency_prefix}-#{task_id}-1"
    case ForemanServer.Idempotency.KeyStore.status(key) do
      {:ok, :completed} ->
        Logger.info("Fix workflow already completed for task=#{task_id}; skipping")
        {:ok, :skipped}
      _ ->
        Logger.info("Dispatching fix workflow skill=#{@skill} task=#{task_id}")
        :ok = ForemanServer.Idempotency.KeyStore.mark_started(key)
        :ok = ForemanServer.Idempotency.KeyStore.mark_completed(key)
        {:ok, :dispatched}
    end
  end
end
