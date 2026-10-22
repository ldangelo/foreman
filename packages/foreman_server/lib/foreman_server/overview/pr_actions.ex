defmodule ForemanServer.Overview.PrActions do
  @moduledoc """
  Which PR actions a workflow thread's card offers, and why a disabled one is
  disabled. Pure: it reads the thread, its `pr_state` view and the E9 PR-watch
  records of its head run (all already loaded by `ForemanServer.Overview`).

  The four actions are exactly the operator commands the CLI
  (`foreman run fix-ci|address-comments|resolve-conflicts|create-pr`), the HTTP
  `/api/commands` route and the MCP `foreman_pr_fix` tool already dispatch:
  `run.pr.fix_ci`, `run.pr.address_comments`, `run.pr.resolve_conflicts` and
  `run.pr.create`. There is deliberately no merge or approve action here: the
  merge gate stays operator-only (CLI/HTTP), never a button.

  Applicability is advisory UI state. The Run aggregate stays the authority and
  rejects what the watch fold cannot support (not watched, fix in flight, caps).

  Jobsite threads offer none (`[]`): they have no run to attach a PR to.
  `ThreadCard` also drops them for the Resolved group.
  """

  alias ForemanServer.Threads.Thread

  @type kind :: :fix_ci | :address_comments | :resolve_conflicts | :create_pr
  @type t :: %{
          kind: kind(),
          label: String.t(),
          enabled: boolean(),
          reason: String.t() | nil,
          pr_url: String.t() | nil
        }

  @doc "The command type each action dispatches (the same ones the CLI and MCP use)."
  @spec command_type(kind()) :: String.t()
  def command_type(:fix_ci), do: "run.pr.fix_ci"
  def command_type(:address_comments), do: "run.pr.address_comments"
  def command_type(:resolve_conflicts), do: "run.pr.resolve_conflicts"
  def command_type(:create_pr), do: "run.pr.create"

  @doc "Action kinds in display order."
  @spec kinds() :: [kind()]
  def kinds, do: [:fix_ci, :address_comments, :resolve_conflicts, :create_pr]

  @doc "The actions of a card; `watch` is `ProjectionStore.pr_watch/1` of the head run (or `[]`)."
  @spec build(Thread.t(), map() | nil, [map()]) :: [t()]
  def build(%Thread{door: :workflow, run_ids: [_ | _]} = thread, pr, watch) do
    live = Enum.reject(watch, &(&1.status in ["merged", "closed"]))
    Enum.map(kinds(), &action(&1, thread, pr, live))
  end

  def build(_thread, _pr, _watch), do: []

  defp action(:create_pr = kind, thread, pr, _live) do
    cond do
      thread.pr_url != nil or (pr && pr.pr_url != nil) ->
        off(kind, "A pull request already exists for this thread.")

      thread.status != "completed" ->
        off(kind, "The run has not completed.")

      true ->
        on(kind, nil)
    end
  end

  defp action(kind, _thread, pr, []) do
    off(kind, no_live_pr_reason(pr))
  end

  defp action(:resolve_conflicts = kind, _thread, pr, live) do
    case Enum.find(live, &(&1.status == "conflicted")) do
      %{pr_url: url} = rec -> guard_in_flight(kind, rec, url)
      nil when pr != nil and pr.pr_state == :conflicted -> on(kind, first_url(live))
      nil -> off(kind, "The pull request has no merge conflicts.")
    end
  end

  defp action(:fix_ci = kind, _thread, _pr, live) do
    case Enum.find(live, &(&1.checks_state == "failing")) do
      %{pr_url: url} = rec -> guard_in_flight(kind, rec, url)
      nil -> off(kind, "CI is not failing.")
    end
  end

  defp action(:address_comments = kind, _thread, _pr, live) do
    case Enum.find(live, &commented?/1) do
      %{pr_url: url} = rec -> guard_in_flight(kind, rec, url)
      nil -> off(kind, "There are no unresolved review comments.")
    end
  end

  defp commented?(rec) do
    rec.review_decision == "changes_requested" or rec.comment_ids != [] or rec.thread_ids != []
  end

  defp guard_in_flight(kind, %{fix: %{in_flight: in_flight}}, _url) when not is_nil(in_flight),
    do: off(kind, "A fix is already running for this pull request.")

  defp guard_in_flight(kind, _rec, url), do: on(kind, url)

  defp no_live_pr_reason(%{pr_state: state}) when state in [:merged, :closed],
    do: "The pull request is #{state}."

  defp no_live_pr_reason(_pr), do: "No pull request is being watched for this thread."

  defp first_url([%{pr_url: url} | _]), do: url

  defp on(kind, url),
    do: %{kind: kind, label: label(kind), enabled: true, reason: nil, pr_url: url}

  defp off(kind, reason),
    do: %{kind: kind, label: label(kind), enabled: false, reason: reason, pr_url: nil}

  defp label(:fix_ci), do: "Fix CI"
  defp label(:address_comments), do: "Address comments"
  defp label(:resolve_conflicts), do: "Resolve conflicts"
  defp label(:create_pr), do: "Create PR"
end
