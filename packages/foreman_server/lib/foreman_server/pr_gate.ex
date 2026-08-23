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
  Pure PR-status → merge-acceptability check.

  `:open` and `:merged` are acceptable (a merged PR is already past the
  gate; an open PR still needs review but is not actively rejected).
  `:closed`, `:conflicted`, and any unknown status are not acceptable.
  """
  @spec evaluate(:open | :merged | :closed | :conflicted | term()) ::
          :ok | {:error, :pr_not_acceptable}
  def evaluate(:open), do: :ok
  def evaluate(:merged), do: :ok
  def evaluate(_), do: {:error, :pr_not_acceptable}

  @doc """
  Check whether `run_id` is authorized to merge.

  Returns `{:error, :no_pr_association}` when no PR association has ever
  been recorded for `run_id`; `{:error, :pr_not_acceptable}` when the
  recorded gate is still pending; `:ok` when the recorded gate is
  approved (or when no pending entry exists for a known association).
  """
  @spec check(String.t() | term()) :: :ok | {:error, :pr_not_acceptable | :no_pr_association}
  def check(run_id) when is_binary(run_id) do
    key = "run:#{run_id}"

    cond do
      ForemanServer.Workflow.MergeGate.pending_for_key?(key) ->
        {:error, :pr_not_acceptable}

      ForemanServer.Workflow.MergeGate.approved?(key) ->
        :ok

      true ->
        {:error, :no_pr_association}
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
