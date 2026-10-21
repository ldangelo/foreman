defmodule ForemanServer.PrObservation do
  @moduledoc """
  Turns one `ForemanServer.GitHub.PrStatus` reading into the `Run`-aggregate
  commands that record what changed (E9-S1). Pure: the only outside read is
  `ProjectionStore.run/1` (through `PrUpdate.command/3`).

  A reading yields zero to three commands:

    * `run.pr.update` - when the PR status, head SHA or base branch differs from the
      previous record (the same builder the webhook uses, so a webhook and a
      poll converge on one deterministic `command_id`);
    * `run.pr.checks` - when the *checks digest* differs;
    * `run.pr.review` - when the *review digest* differs.

  Each digest is a short hash of exactly what that event records, so an edited
  comment elsewhere never re-fires the checks event. The two digests are
  computed from a canonical (sorted) term, hence stable across polls.

  `previous` is the `ProjectionStore.pr_watch/1` record for the PR (or `nil`).
  A first sighting with nothing to report (no checks, no review state) emits
  nothing: the baseline is "no checks, no comments".

  `command_id` carries the digest AND a monotonically increasing
  `observation_seq` taken from `previous`: a state that returns to an earlier
  digest after a different one (fail -> fixed -> fail) must still append, so a
  digest alone would let `CommandRouter`'s deterministic event id swallow the
  flip. Two concurrent observers that read the same `previous` compute the same
  id and therefore collapse into one event.
  """

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrUpdate

  @type previous :: map() | nil

  @type error ::
          {:run_not_found, String.t()} | {:run_projection_missing_ids, String.t()}

  @max_failing 50

  @doc "Content digest of the checks side of `status` (16 hex characters)."
  @spec checks_digest(PrStatus.t()) :: String.t()
  def checks_digest(%PrStatus{} = status) do
    failing =
      status.checks
      |> Enum.filter(&(&1.state == :failing))
      |> Enum.map(&{&1.name, &1.conclusion})
      |> Enum.sort()

    digest({:checks, status.head_sha, status.checks_state, failing})
  end

  @doc """
  Content digest of the review side of `status`: review decision, sorted
  conversation-comment ids, sorted unresolved review-thread ids, and review
  `{id, state}` pairs. Comment bodies are deliberately not part of it.
  """
  @spec review_digest(PrStatus.t()) :: String.t()
  def review_digest(%PrStatus{} = status) do
    digest(
      {:review, status.review_decision, comment_ids(status), thread_ids(status),
       status.reviews |> Enum.map(&{&1.id, &1.state}) |> Enum.sort()}
    )
  end

  @doc "The sorted ids of the PR's conversation comments."
  @spec comment_ids(PrStatus.t()) :: [String.t()]
  def comment_ids(%PrStatus{comments: comments}), do: comments |> Enum.map(& &1.id) |> Enum.sort()

  @doc "The sorted ids of the PR's unresolved review threads (`[]` when threads were not read)."
  @spec thread_ids(PrStatus.t()) :: [String.t()]
  def thread_ids(%PrStatus{threads: nil}), do: []

  def thread_ids(%PrStatus{threads: threads}),
    do: for(%{resolved: false, id: id} <- threads, do: id) |> Enum.sort()

  @doc """
  Commands to dispatch for `status` observed on `run_id`'s PR `pr_url`.
  `previous` is the stored watch record (or `nil`).
  """
  @spec commands(String.t(), String.t(), PrStatus.t(), previous()) ::
          {:ok, [map()]} | {:error, error()}
  def commands(run_id, pr_url, %PrStatus{} = status, previous)
      when is_binary(run_id) and is_binary(pr_url) do
    with {:ok, update} <- update_command(run_id, pr_url, status, previous) do
      base = base_payload(update.payload, status)

      {:ok,
       update_commands(update, status, previous) ++
         checks_commands(run_id, pr_url, status, previous, base) ++
         review_commands(run_id, pr_url, status, previous, base)}
    end
  end

  defp update_command(run_id, pr_url, status, _previous),
    do: PrUpdate.command(run_id, pr_url, status)

  defp update_commands(update, _status, nil), do: [update]

  defp update_commands(update, status, previous) do
    if previous_value(previous, :status) == Atom.to_string(status.status) and
         previous_value(previous, :head_sha) == status.head_sha and
         previous_value(previous, :base_branch) == status.base_branch,
       do: [],
       else: [update]
  end

  defp base_payload(update_payload, status) do
    %{
      project_id: update_payload.project_id,
      task_id: update_payload.task_id,
      branch_name: update_payload.branch_name,
      base_branch: status.base_branch,
      head_sha: status.head_sha,
      pr_status: Atom.to_string(status.status),
      observed_at: System.system_time(:millisecond)
    }
  end

  defp checks_commands(run_id, pr_url, status, previous, base) do
    digest = checks_digest(status)
    baseline = previous_value(previous, :checks_digest) || empty_checks_digest(status)

    if digest == baseline do
      []
    else
      seq = (previous_value(previous, :checks_seq) || 0) + 1

      [
        %{
          type: "run.pr.checks",
          command_id: "pr_checks:#{run_id}:#{url_hash(pr_url)}:#{digest}:#{seq}",
          aggregate_id: "run:#{run_id}",
          payload:
            Map.merge(base, %{
              run_id: run_id,
              pr_url: pr_url,
              repo_id: nil,
              checks_state: Atom.to_string(status.checks_state),
              failing: failing(status),
              digest: digest,
              observation_seq: seq
            })
        }
      ]
    end
  end

  defp review_commands(run_id, pr_url, status, previous, base) do
    digest = review_digest(status)
    baseline = previous_value(previous, :review_digest) || empty_review_digest(status)

    if digest == baseline do
      []
    else
      seq = (previous_value(previous, :review_seq) || 0) + 1

      [
        %{
          type: "run.pr.review",
          command_id: "pr_review:#{run_id}:#{url_hash(pr_url)}:#{digest}:#{seq}",
          aggregate_id: "run:#{run_id}",
          payload:
            base
            |> Map.drop([:branch_name, :base_branch])
            |> Map.merge(%{
              run_id: run_id,
              pr_url: pr_url,
              repo_id: nil,
              review_decision: decision(status.review_decision),
              comment_ids: comment_ids(status),
              thread_ids: thread_ids(status),
              new_comment_count: new_comment_count(status, previous),
              digest: digest,
              observation_seq: seq
            })
        }
      ]
    end
  end

  defp empty_checks_digest(status),
    do: digest({:checks, status.head_sha, :none, []})

  defp empty_review_digest(_status), do: digest({:review, nil, [], [], []})

  defp failing(status) do
    status.checks
    |> Enum.filter(&(&1.state == :failing))
    |> Enum.take(@max_failing)
    |> Enum.map(&%{name: &1.name, conclusion: &1.conclusion, url: &1.url})
  end

  defp decision(nil), do: nil
  defp decision(decision), do: Atom.to_string(decision)

  defp new_comment_count(status, previous) do
    seen = previous_value(previous, :comment_ids) || []

    length(comment_ids(status) -- seen) +
      length(thread_ids(status) -- (previous_value(previous, :thread_ids) || []))
  end

  defp previous_value(nil, _key), do: nil
  defp previous_value(previous, key), do: Map.get(previous, key)

  defp digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Stable short hash of a PR URL, used in command ids."
  @spec url_hash(String.t()) :: String.t()
  def url_hash(pr_url) do
    :crypto.hash(:sha, pr_url) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end
end
