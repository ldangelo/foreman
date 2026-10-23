defmodule ForemanServer.RunPrMerge do
  @moduledoc """
  The two GitHub-facing steps of the operator merge gate: reading back the head an operator
  approves (`verify_head/3`, behind `merge_approve`) and performing the real merge (`execute/2`,
  behind `run.pr.merge`).

  The `Run` aggregate's `run.pr.merge` handler only *records* a merge (`PrMerged`)
  once the merge gate is approved. It must stay pure — the actor re-runs
  `handle_command/2` on a version conflict, which would repeat a real merge — so
  the side effect lives here and `CommandGateway.dispatch_operator/2` runs it
  *before* dispatching the command. `merge_approve` gets the same treatment for its (read-only)
  GitHub call.

  `verify_head/3` refuses an approval unless the head the operator names is the PR's head on GitHub
  right now. That head is what the approval pins, so the commit that gets merged is one the
  operator named while it was the head. The PR watch's recorded head is deliberately not the
  authority: it lags a push by up to a poll interval (and polling is opt-in).

  `execute/2` refuses unless every one of these holds:

    * the run's merge gate is `:approved`, read from the event-sourced aggregate
      (not the ETS-backed `MergeGate`, which does not survive a restart);
    * the PR is still open and unconflicted, or already merged;
    * the PR head is still the commit that was approved - the head the operator named in
      `merge_approve`, pinned by the aggregate when the gate was approved - so commits pushed after
      approval cannot be merged unreviewed. `gh` is also told `--match-head-commit`, so the pin
      holds against a push that lands between the check and the merge. A head that moved is
      refused (`head_moved_since_approval`) and never adopted as the new pin: only a fresh
      approval naming the new head reopens the merge (`CommandGateway` re-holds the gate).

  An already-merged PR is not merged again: a retry after `gh` succeeded but the
  event append failed records the merge instead of failing.

  On success it returns the `run.pr.merge` payload, built entirely from the stored
  `PrReady` event and the approval's pin. The caller's payload is discarded, so a client can
  neither retarget the merge nor skip the head pin.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventStore
  alias ForemanServer.GitHub.PrMerge
  alias ForemanServer.GitHub.PrStatus

  @runner_key {__MODULE__, :command_runner}
  @payload_keys [:project_id, :task_id, :pr_url, :branch_name, :head_sha, :base_branch]

  @doc """
  Test seam: route the `gh` calls of this module through `fun`, a 3-arity
  `(cmd, args, opts)` returning `{output, exit_code}`. Without it the installed
  `gh` runs.
  """
  @spec set_command_runner((String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          :ok
  def set_command_runner(fun) when is_function(fun, 3) do
    :persistent_term.put(@runner_key, fun)
  end

  @doc "Remove the runner installed by `set_command_runner/1`."
  @spec clear_command_runner() :: boolean()
  def clear_command_runner, do: :persistent_term.erase(@runner_key)

  @doc """
  Check the head an operator names in `merge_approve` against GitHub: `:ok` when it is the head of
  the PR that `repo_id`'s gate (`nil` = the run's primary) holds, `{:error, {:missing_or_invalid,
  :head_sha}}` when none was named, `{:error, {:head_sha_mismatch, named, live}}` when the PR head
  is another commit, and the `gh` failure (`PrStatus.error()`) when GitHub cannot be read - an
  approval that cannot be checked is refused, never assumed.

  Only a gate that is waiting for approval is checked. For any other gate (no PR readied, already
  approved) `:ok` just means there is nothing to compare: the `Run` aggregate refuses those with
  their own typed errors.
  """
  @spec verify_head(String.t(), String.t() | nil, term()) :: :ok | {:error, term()}
  def verify_head(run_id, repo_id, head_sha)
      when is_binary(run_id) and run_id != "" and (is_nil(repo_id) or is_binary(repo_id)) do
    with {:ok, named} <- Aggregate.required_binary(head_sha, :head_sha) do
      repo_key = if repo_id == "", do: nil, else: repo_id
      {state, _version} = Aggregate.load(Run, "run:#{run_id}")

      case Run.merge_gate(state, repo_key) do
        :pending ->
          %Run.MergePin{pr_url: pr_url} = Run.merge_pin(state, repo_key)
          compare_live(pr_url, named)

        _approved_or_not_readied ->
          :ok
      end
    end
  end

  defp compare_live(pr_url, named) do
    case PrStatus.fetch(pr_url, runner_opts()) do
      {:ok, %PrStatus{head_sha: ^named}} -> :ok
      {:ok, %PrStatus{head_sha: live}} -> {:error, {:head_sha_mismatch, named, live}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Merge the PR of `run_id` (of its repository `repo_id`; `nil` = the run's
  primary) on GitHub and return the `run.pr.merge` payload to record.
  Concurrent calls for one PR are serialized, so the second observes the
  first's merge instead of racing it; different repositories of one run merge
  independently, each pinned to its own approved head.
  """
  @spec execute(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def execute(run_id, repo_id \\ nil)
      when is_binary(run_id) and run_id != "" and (is_nil(repo_id) or is_binary(repo_id)) do
    repo_key = if repo_id == "", do: nil, else: repo_id
    :global.trans({{__MODULE__, run_id, repo_key}, self()}, fn -> merge(run_id, repo_key) end)
  end

  defp merge(run_id, repo_key) do
    with {:ok, pin} <- require_gate_approved(run_id, repo_key),
         {:ok, ready} <- approved_ready_payload(run_id, repo_key),
         ready = pin_head(ready, pin),
         {:ok, current} <- PrStatus.fetch(ready.pr_url, runner_opts()),
         :ok <- merge_unless_done(current, ready) do
      {:ok, ready |> put_repo_id(repo_key) |> Map.put(:run_id, run_id)}
    end
  end

  defp put_repo_id(payload, nil), do: payload
  defp put_repo_id(payload, repo_key), do: Map.put(payload, :repo_id, repo_key)

  # The approval's pin is what the merge is held to: the head the operator named (or, for an
  # approval recorded before heads were pinned, the head the PR watch had recorded by then).
  defp require_gate_approved(run_id, repo_key) do
    {state, _version} = Aggregate.load(Run, "run:#{run_id}")

    cond do
      not state.exists? -> {:error, {:run_not_found, run_id}}
      Run.merge_gate(state, repo_key) == :approved -> {:ok, Run.merge_pin(state, repo_key)}
      true -> {:error, :pr_not_acceptable}
    end
  end

  # The most recent `PrReady` OF THIS REPOSITORY is the one its gate was opened
  # (and approved) for; another repository's PrReady is never considered.
  defp approved_ready_payload(run_id, repo_key) do
    case EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.event_type == "PrReady" and ready_repo_key(&1.data) == repo_key))
        |> List.last()
        |> ready_payload(run_id)

      {:error, :stream_not_found} ->
        {:error, {:run_not_found, run_id}}

      {:error, reason} ->
        {:error, {:pr_ready_read_failed, reason}}
    end
  end

  # `PrReady` is recorded once, when the PR is opened. A Fix CI / Address comments /
  # Resolve conflicts push (or a force-push) moves the head afterwards, and approving
  # that PR must pin the head the operator approved, not the stale one from PrReady - or no
  # PR that ever needed a fix could be merged (foreman-axmni). The pin is that approved head
  # (`Run.merge_pin/2`); a push after approval moves the live head off it, the merge refuses it
  # (`head_moved_since_approval`) and the pin is never moved. The `PrReady` head is only the
  # fallback for an approval that pinned nothing.
  defp pin_head(ready, %Run.MergePin{head_sha: head}),
    do: Map.put(ready, :head_sha, head || ready.head_sha)

  defp ready_repo_key(data) do
    case Aggregate.get(data, :repo_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp ready_payload(nil, run_id), do: {:error, {:pr_ready_event_missing, run_id}}

  defp ready_payload(%{data: data}, _run_id) do
    Enum.reduce_while(@payload_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Aggregate.required_binary(Aggregate.get(data, key), key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # A PR already merged is recorded only if what landed is what was approved: a
  # merge of some other head must not be attributed to this approval.
  defp merge_unless_done(%PrStatus{status: :merged, head_sha: head}, %{head_sha: approved}) do
    if head == approved, do: :ok, else: {:error, {:head_moved_since_approval, approved, head}}
  end

  defp merge_unless_done(%PrStatus{status: :open, head_sha: head}, %{head_sha: approved} = ready) do
    if head == approved do
      PrMerge.merge(ready.pr_url, approved, runner_opts())
    else
      {:error, {:head_moved_since_approval, approved, head}}
    end
  end

  defp merge_unless_done(%PrStatus{status: :closed}, ready),
    do: {:error, {:pr_closed, ready.pr_url}}

  defp merge_unless_done(%PrStatus{status: :conflicted}, ready),
    do: {:error, {:pr_conflicted, ready.pr_url}}

  defp runner_opts do
    case :persistent_term.get(@runner_key, :unset) do
      :unset -> []
      fun -> [command_runner: fun]
    end
  end
end
