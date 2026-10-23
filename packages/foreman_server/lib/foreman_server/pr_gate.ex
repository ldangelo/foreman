defmodule ForemanServer.PrGate do
  @moduledoc """
  Merge gate check interface used by the Run aggregate's `ensure_pr_gate_ok/2`.

  Queries the `ForemanServer.Workflow.MergeGate` GenServer (ETS-backed) and
  returns `:ok` when the run has an approved merge gate, or `{:error, reason}`
  when merge is not yet authorized.

  TRD-2026-4212be7e / MGH-T001 / TRD-071.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run

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
        if ForemanServer.Workflow.MergeGate.pending_for_key?(gate_key(run_id, nil)) do
          {:error, :pr_not_acceptable}
        else
          :ok
        end
    end
  end

  def check(_), do: {:error, :no_pr_association}

  @doc """
  The `ForemanServer.Workflow.MergeGate` requester key of one PR of a run:
  `"run:<id>"` for the primary repository (`repo_id` nil/empty) and
  `"run:<id>:<repo_id>"` for another repository, so two PRs of one run never
  share a key.
  """
  @spec gate_key(String.t(), String.t() | nil) :: String.t()
  def gate_key(run_id, repo_id) when is_binary(run_id) do
    if is_binary(repo_id) and repo_id != "", do: "run:#{run_id}:#{repo_id}", else: "run:#{run_id}"
  end

  @doc """
  Record that a repository's PR has entered the merge gate pending state.
  Called by the Run aggregate after `run.pr.ready` is dispatched.
  """
  @spec record_pending(String.t(), String.t(), String.t() | nil) :: :ok
  def record_pending(run_id, pr_url, repo_id \\ nil)
      when is_binary(run_id) and is_binary(pr_url) do
    ForemanServer.Workflow.MergeGate.request_approval(pr_url, gate_key(run_id, repo_id))
    :ok
  end

  @doc """
  Record that a repository's merge gate has been approved (`repo_id` nil =
  primary). Called by the Run aggregate after `merge_approve` is dispatched;
  approves only that repository's pending entry.
  """
  @spec record_approved(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def record_approved(run_id, approver, approver_identity, repo_id \\ nil)
      when is_binary(run_id) and is_binary(approver) and is_binary(approver_identity) do
    ForemanServer.Workflow.MergeGate.approve_by_key(
      gate_key(run_id, repo_id),
      approver,
      approver_identity
    )

    :ok
  end

  @doc """
  The `run.pr.rehold` system command that voids `repo_id`'s approval because the PR now shows
  `head_sha`, or `:current` when no approval is stale (the gate is not approved, or what it approved
  is still the head). `pr_url` limits the check to an observation of the PR the gate holds; `nil`
  says `head_sha` is that PR's own head (a merge attempt read it from GitHub).

  The decision is `Run.stale_approval/4` on the run's event-sourced state; the aggregate decides
  again when the command arrives, so a stale command is a no-op. The command id is the approval's:
  one approval is voided at most once, and a head that comes round again in a later approval is a
  new command. (An id derived from the heads would repeat across approvals, and the router answers
  a repeated id with the earlier event instead of appending.)
  """
  @spec rehold_command(String.t(), String.t() | nil, String.t(), String.t() | nil) ::
          {:ok, map()} | :current
  def rehold_command(run_id, repo_id, head_sha, pr_url \\ nil)
      when is_binary(run_id) and is_binary(head_sha) do
    {state, _version} = Aggregate.load(Run, "run:#{run_id}")

    case Run.stale_approval(state, repo_id, head_sha, pr_url) do
      {:stale, %{pr_url: url, approved_at: approved_at}} when is_binary(url) ->
        payload = %{run_id: run_id, pr_url: url, head_sha: head_sha}

        {:ok,
         %{
           type: "run.pr.rehold",
           command_id: "pr_rehold:#{run_id}:#{repo_id}:#{approved_at}",
           aggregate_id: "run:#{run_id}",
           payload: if(repo_id, do: Map.put(payload, :repo_id, repo_id), else: payload)
         }}

      :current ->
        :current
    end
  end
end
