defmodule ForemanServer.PrGate do
  @moduledoc """
  Merge gate check interface used by the Run aggregate's `ensure_pr_gate_ok/2`.

  Queries the `ForemanServer.Workflow.MergeGate` GenServer (ETS-backed) and
  returns `:ok` when the run has an approved merge gate, or `{:error, reason}`
  when merge is not yet authorized.

  TRD-2026-4212be7e / MGH-T001 / TRD-071.
  """
  require Logger

  @doc """
  Evaluate a raw PR status atom (as reported by GitHub webhooks or
  `ForemanServer.PrMonitor` polling) for merge acceptability.

  Returns `:ok` for statuses that permit merge (`:open`, `:merged`), or
  `{:error, :pr_not_acceptable}` for any other status (`:closed`,
  `:conflicted`, unknown atoms, or `nil`).
  """
  @spec evaluate(atom() | nil) :: :ok | {:error, :pr_not_acceptable}
  def evaluate(:open), do: :ok
  def evaluate(:merged), do: :ok
  def evaluate(_), do: {:error, :pr_not_acceptable}

  @doc """
  Check whether `run_id` is authorized to merge.

  Returns `{:error, :no_pr_association}` when `run_id` is not a binary, or
  when the `ForemanServer.ProjectionStore` has no PR association recorded
  for it (i.e. `run.pr.ready`/webhook association never happened). Returns
  `:ok` when the gate is not pending, or `{:error, :pr_not_acceptable}` when
  the gate is still pending.
  """
  @spec check(String.t()) :: :ok | {:error, :pr_not_acceptable | :no_pr_association}
  def check(run_id) when is_binary(run_id) do
    case ForemanServer.ProjectionStore.pr_association(run_id) do
      {:error, :not_found} ->
        {:error, :no_pr_association}

      {:ok, _association} ->
        key = "run:#{run_id}"

        if ForemanServer.Workflow.MergeGate.pending_for_key?(key) do
          {:error, :pr_not_acceptable}
        else
          :ok
        end
    end
  end

  def check(_), do: {:error, :no_pr_association}

  @doc """
  Record that a run has entered the merge gate pending state.
  Called by the Run aggregate after `run.pr.ready` is dispatched.
  """
  @spec record_pending(String.t(), String.t()) :: :ok
  def record_pending(run_id, pr_url) when is_binary(run_id) and is_binary(pr_url) do
    key = "run:#{run_id}"
    ForemanServer.Workflow.MergeGate.request_approval(pr_url, key)
    :ok
  end

  @doc """
  Record that a run's merge gate has been approved.
  Called by the Run aggregate after `merge_approve` is dispatched.
  """
  @spec record_approved(String.t(), String.t(), String.t()) :: :ok
  def record_approved(run_id, approver, approver_identity)
      when is_binary(run_id) and is_binary(approver) and is_binary(approver_identity) do
    key = "run:#{run_id}"
    ForemanServer.Workflow.MergeGate.approve_by_key(key, approver, approver_identity)
    :ok
  end
end
