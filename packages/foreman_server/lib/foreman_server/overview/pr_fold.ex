defmodule ForemanServer.Overview.PrFold do
  @moduledoc """
  Pure fold of the Run-stream PR / merge-gate events into per-run PR state.

  `ProjectionStore` keeps one entry per run id (`state.pr_states`) and delegates
  every PR event here. The Overview classifier reads the result through
  `ProjectionStore.pr_state/1` and `ProjectionStore.pr_states_for_project/1`.

  PR events are emitted on a run's stream and may arrive after the run is
  terminal (`allow_pr_lifecycle_on_terminal_runs`), so a fold never consults
  the run's own status.

  | event | effect |
  |---|---|
  | `PrAssociated` | seeds `pr_url`/`pr_number`; `pr_state` becomes `:open` unless already set |
  | `PrReady` | `pr_state :open`, `pr_url`, `head_sha`, `merge_gate :pending` (the Run aggregate treats `PrReady` itself as the gate hold) |
  | `MergeGatePending` | `merge_gate :pending` |
  | `MergeGateApproved` | `merge_gate :approved` |
  | `PrUpdated` | `pr_state` from `pr_status` (`open`/`merged`/`closed`/`conflicted`), `head_sha`, `base_branch`; a merged PR stays merged |
  | `PrMerged` | `pr_state :merged` |
  | `PrRetargeted` | `base_branch` only |
  | `PrReset` | `merge_gate :none`, `pr_state :open` |

  A run that opened a PR in several repositories (E12) has one entry per PR: the
  primary's in `state.pr_states` and each non-primary repository's in
  `state.repo_pr_states` (`fold_repo/3`). The Overview classifies a thread by all of
  them through `rollup/2`, never by the primary's alone.

  Entries are atom-keyed maps; payloads are read with string or atom keys
  (events are JSON round-tripped by the event store). A payload without a
  usable `run_id`, or a `PrUpdated` with an unknown status, is logged at
  `:warning` and skipped: a fold must never crash `ProjectionStore.init/1`'s
  replay.

  Merging is operator-only (`merge_approve` -> `run.pr.merge`). This module only
  *observes* those events; it dispatches nothing.
  """

  require Logger

  @type pr_state :: :open | :merged | :closed | :conflicted
  @type merge_gate :: :none | :pending | :approved
  @type entry :: %{
          pr_url: String.t() | nil,
          pr_number: non_neg_integer() | nil,
          pr_state: pr_state() | nil,
          head_sha: String.t() | nil,
          base_branch: String.t() | nil,
          merge_gate: merge_gate(),
          merge_gate_at: integer() | nil,
          pr_updated_at: integer() | nil
        }
  @type t :: %{String.t() => entry()}

  @events ~w(PrAssociated PrReady MergeGatePending MergeGateApproved PrUpdated PrMerged
             PrRetargeted PrReset)

  @doc "Event types this fold consumes."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The entry of a run that has no PR event yet."
  @spec default_entry() :: entry()
  def default_entry do
    %{
      pr_url: nil,
      pr_number: nil,
      pr_state: nil,
      head_sha: nil,
      base_branch: nil,
      merge_gate: :none,
      merge_gate_at: nil,
      pr_updated_at: nil
    }
  end

  @doc "Fold one event into the per-run map. Unusable payloads leave it unchanged."
  @spec fold(t(), String.t(), map()) :: t()
  def fold(pr_states, event_type, payload)
      when is_map(pr_states) and event_type in @events and is_map(payload) do
    if non_primary?(payload), do: pr_states, else: fold_primary(pr_states, event_type, payload)
  end

  @typedoc "Per-repository PR state of non-primary repositories: `%{run_id => %{repo_id => entry}}`."
  @type repo_states :: %{String.t() => %{String.t() => entry()}}

  @doc """
  Fold one event of a NON-primary repository's PR (payload `repo_id` present)
  into `%{run_id => %{repo_id => entry}}` - one gate and PR state per PR. An
  event without a `repo_id` is the primary's and leaves this map unchanged
  (see `fold/3`); so does an unusable payload.
  """
  @spec fold_repo(repo_states(), String.t(), map()) :: repo_states()
  def fold_repo(repo_states, event_type, payload)
      when is_map(repo_states) and event_type in @events and is_map(payload) do
    run_id = binary(payload, :run_id)
    repo_id = binary(payload, :repo_id)

    with true <- is_binary(run_id) and is_binary(repo_id),
         entry = repo_states |> Map.get(run_id, %{}) |> Map.get(repo_id, default_entry()),
         {:ok, new_entry} <- apply_event(entry, event_type, payload) do
      Map.update(repo_states, run_id, %{repo_id => new_entry}, &Map.put(&1, repo_id, new_entry))
    else
      _ -> repo_states
    end
  end

  def fold_repo(repo_states, _event_type, _payload), do: repo_states

  @typedoc """
  One PR as the Overview reads it: the primary's `ProjectionStore.pr_state/1` view or a
  non-primary repository's `ProjectionStore.repo_pr_states/1` view (an `entry` plus ids).
  """
  @type view :: %{
          required(:pr_state) => pr_state() | nil,
          required(:merge_gate) => merge_gate(),
          required(:pr_updated_at) => integer() | nil,
          optional(atom()) => term()
        }

  @live [:open, :conflicted]

  @doc """
  The single view a thread is classified by, over every PR its head run opened: the
  primary's `primary` view and the views `others` of the other repositories' PRs.

  A run with no other PR reads exactly what it read before: `primary` is returned
  untouched. With several PRs the result is `primary` with three fields rolled up:

    * `pr_state` - `:conflicted` while any PR is conflicted, else `:open` while any PR is
      open; once none is live, `:merged` when any PR merged, else `:closed`; `nil` when no
      PR has a state. So a thread only reads merged (resolved) when no PR is left to wait
      on, and a live PR keeps it open whatever the primary's PR did;
    * `merge_gate` - the strongest gate of the LIVE PRs (`:approved`, else `:pending`,
      else `:none`): a merged PR's gate says nothing about the PR still open. When no PR
      is live, the strongest gate of all of them;
    * `pr_updated_at` - the newest observation of any PR, so a merge only counts after an
      operator's reopen when the LAST PR to settle is newer than it.

  `nil` (a thread with no run view, e.g. a jobsite) stays `nil`.
  """
  @spec rollup(view() | nil, [view()]) :: view() | nil
  def rollup(nil, _others), do: nil
  def rollup(%{} = primary, []), do: primary

  def rollup(%{} = primary, [_ | _] = others) do
    prs = [primary | others]
    live = Enum.filter(prs, &(&1.pr_state in @live))

    %{
      primary
      | pr_state: rolled_state(prs, live),
        merge_gate: rolled_gate(if(live == [], do: prs, else: live)),
        pr_updated_at: latest_update(prs)
    }
  end

  defp rolled_state(prs, live) do
    cond do
      Enum.any?(live, &(&1.pr_state == :conflicted)) -> :conflicted
      live != [] -> :open
      Enum.any?(prs, &(&1.pr_state == :merged)) -> :merged
      Enum.any?(prs, &(&1.pr_state == :closed)) -> :closed
      true -> nil
    end
  end

  defp rolled_gate(prs) do
    gates = Enum.map(prs, & &1.merge_gate)

    cond do
      :approved in gates -> :approved
      :pending in gates -> :pending
      true -> :none
    end
  end

  defp latest_update(prs) do
    prs |> Enum.map(& &1.pr_updated_at) |> Enum.filter(&is_integer/1) |> Enum.max(fn -> nil end)
  end

  # E12: an event carrying `repo_id` belongs to a non-primary repository's PR.
  # The per-run entry is the primary's, so it must not be overwritten by a
  # sibling PR (per-PR gate state is S6).
  defp non_primary?(payload), do: binary(payload, :repo_id) not in [nil, ""]

  defp fold_primary(pr_states, event_type, payload) do
    case get(payload, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        entry = Map.get(pr_states, run_id, default_entry())

        case apply_event(entry, event_type, payload) do
          {:ok, new_entry} ->
            Map.put(pr_states, run_id, new_entry)

          :skip ->
            Logger.warning("Overview.PrFold skipped malformed #{event_type}: #{inspect(payload)}")

            pr_states
        end

      _ ->
        Logger.warning("Overview.PrFold skipped #{event_type} without a run_id")
        pr_states
    end
  end

  defp apply_event(entry, "PrAssociated", payload) do
    {:ok,
     entry
     |> put_present(:pr_url, binary(payload, :pr_url))
     |> put_present(:pr_number, integer(payload, :pr_number))
     |> Map.update!(:pr_state, &(&1 || :open))}
  end

  defp apply_event(entry, "PrReady", payload) do
    {:ok,
     entry
     |> put_present(:pr_url, binary(payload, :pr_url))
     |> put_present(:pr_number, integer(payload, :pr_number))
     |> put_present(:head_sha, binary(payload, :head_sha))
     |> Map.merge(%{pr_state: :open, merge_gate: :pending})}
  end

  defp apply_event(entry, "MergeGatePending", payload) do
    {:ok,
     entry
     |> put_present(:pr_url, binary(payload, :pr_url))
     |> put_present(:pr_number, integer(payload, :pr_number))
     |> Map.merge(%{merge_gate: :pending, merge_gate_at: integer(payload, :paused_at)})}
  end

  defp apply_event(entry, "MergeGateApproved", payload) do
    {:ok,
     Map.merge(entry, %{merge_gate: :approved, merge_gate_at: integer(payload, :approved_at)})}
  end

  defp apply_event(entry, "PrUpdated", payload) do
    case status(get(payload, :pr_status) || get(payload, :status)) do
      nil ->
        :skip

      status ->
        {:ok,
         entry
         |> put_present(:pr_url, binary(payload, :pr_url))
         |> put_present(:head_sha, binary(payload, :head_sha))
         |> put_present(:base_branch, binary(payload, :base_branch))
         |> put_present(:pr_updated_at, integer(payload, :observed_at))
         |> Map.update!(:pr_state, &next_state(&1, status))}
    end
  end

  defp apply_event(entry, "PrMerged", _payload), do: {:ok, %{entry | pr_state: :merged}}

  defp apply_event(entry, "PrRetargeted", payload) do
    {:ok, put_present(entry, :base_branch, binary(payload, :base_branch))}
  end

  defp apply_event(entry, "PrReset", _payload) do
    {:ok, %{entry | merge_gate: :none, pr_state: :open}}
  end

  # A merged PR cannot reopen: a stale poll or an out-of-order webhook that still
  # reports `open` must not move a merged PR back. `PrReset` is the only way out.
  defp next_state(:merged, _status), do: :merged
  defp next_state(_current, status), do: status

  defp status(value) when value in [:open, :merged, :closed, :conflicted], do: value

  defp status(value) when value in ["open", "merged", "closed", "conflicted"],
    do: String.to_existing_atom(value)

  defp status(_), do: nil

  defp put_present(entry, _key, nil), do: entry
  defp put_present(entry, key, value), do: Map.put(entry, key, value)

  defp binary(payload, key) do
    case get(payload, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp integer(payload, key) do
    case get(payload, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp get(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
