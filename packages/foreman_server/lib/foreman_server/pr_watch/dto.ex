defmodule ForemanServer.PrWatch.DTO do
  @moduledoc """
  The one wire shape of a watched PR (E9): `GET /api/runs/:id/prs` and the MCP
  `foreman_pr_status` tool both return `%{run_id, prs: [DTO]}` built by
  `fetch/1` through `from_projection/2`, so the two surfaces cannot diverge.

  Fields are fixed snake_case keys with explicit `null`s, except `merge_gate`
  (the `none | pending | approved` merge gate of the PR the run is
  associated with), which is omitted for any other PR. `fixes` carries the per-kind attempt counters
  (`ci`, `comments`, `conflicts`), the in-flight fix (`state` is `requested`
  until its jobsite starts, then `running`), the last outcome per kind and the
  head SHA each kind gave up on. Read-only: nothing here can merge a PR.
  """

  alias ForemanServer.ProjectionStore

  @enforce_keys [
    :pr_url,
    :repo_id,
    :status,
    :head_sha,
    :base_branch,
    :branch_name,
    :checks_state,
    :failing,
    :review_decision,
    :comment_count,
    :watching,
    :stop_reason,
    :fixes,
    :agent_review
  ]
  defstruct @enforce_keys ++ [merge_gate: nil]

  @type t :: %__MODULE__{
          pr_url: String.t(),
          repo_id: String.t() | nil,
          status: String.t() | nil,
          head_sha: String.t() | nil,
          base_branch: String.t() | nil,
          branch_name: String.t() | nil,
          checks_state: String.t() | nil,
          failing: [String.t()],
          review_decision: String.t() | nil,
          comment_count: non_neg_integer(),
          watching: boolean(),
          stop_reason: String.t() | nil,
          fixes: map(),
          agent_review: map() | nil,
          merge_gate: String.t() | nil
        }

  @kinds ~w(ci comments conflicts)

  @doc """
  The PRs of a run as `%{run_id: id, prs: [t()]}`, or `{:error, :run_not_found}`
  for an unknown run (a known run with no observed PR yields `prs: []`).
  """
  @spec fetch(String.t()) :: {:ok, %{run_id: String.t(), prs: [t()]}} | {:error, :run_not_found}
  def fetch(run_id) when is_binary(run_id) and run_id != "" do
    case ProjectionStore.run(run_id) do
      nil ->
        {:error, :run_not_found}

      _run ->
        %{pr_url: gated_url, merge_gate: gate} = ProjectionStore.pr_state(run_id)

        prs =
          run_id
          |> ProjectionStore.pr_watch()
          |> Enum.map(&from_projection(&1, if(&1.pr_url == gated_url, do: gate)))

        {:ok, %{run_id: run_id, prs: prs}}
    end
  end

  def fetch(_run_id), do: {:error, :run_not_found}

  @doc "Build the DTO from one `ProjectionStore.pr_watch/1` record and the run's merge gate."
  @spec from_projection(map(), atom() | nil) :: t()
  def from_projection(record, merge_gate) when is_map(record) do
    %__MODULE__{
      pr_url: record.pr_url,
      repo_id: record.repo_id,
      status: record.status,
      head_sha: record.head_sha,
      base_branch: record.base_branch,
      branch_name: record.branch_name,
      checks_state: record.checks_state,
      failing: record.failing,
      review_decision: record.review_decision,
      comment_count: length(record.comment_ids),
      watching: record.watching,
      stop_reason: record.stop_reason,
      fixes: fixes(record.fix),
      agent_review: agent_review(Map.get(record, :agent_review)),
      merge_gate: gate(merge_gate)
    }
  end

  defp fixes(fix) do
    %{
      attempts: Map.new(@kinds, &{&1, Map.get(fix.attempts, &1, 0)}),
      in_flight: in_flight(fix),
      last_outcome: fix.last_outcome,
      exhausted: fix.exhausted
    }
  end

  defp in_flight(%{in_flight: nil}), do: nil

  defp in_flight(%{in_flight: :requested} = fix),
    do: %{
      state: "requested",
      kind: fix.in_flight_kind,
      attempt: fix.in_flight_attempt,
      jobsite_id: nil
    }

  defp in_flight(%{in_flight: jobsite_id} = fix),
    do: %{
      state: "running",
      kind: fix.in_flight_kind,
      attempt: fix.in_flight_attempt,
      jobsite_id: jobsite_id
    }

  defp agent_review(nil), do: nil

  defp agent_review(review),
    do: %{verdict: review.verdict, gap_bead_ids: review.gap_bead_ids, at: review.at}

  defp gate(nil), do: nil
  defp gate(gate) when is_atom(gate), do: Atom.to_string(gate)
  defp gate(gate) when is_binary(gate), do: gate

  defimpl Jason.Encoder do
    def encode(dto, opts) do
      dto
      |> Map.from_struct()
      |> Map.reject(fn {key, value} -> key == :merge_gate and is_nil(value) end)
      |> Jason.Encode.map(opts)
    end
  end
end
