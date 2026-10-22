defmodule ForemanServer.PrWatcher.AutoFix do
  @moduledoc """
  The opt-in policy that turns an observation of a PR into at most ONE fix request
  (E9-S4). Off unless the project sets `pr_auto_fix` (`ForemanServer.ProjectSettings`):

      %{"kinds" => ["ci", "comments", "conflicts"], "max_attempts" => 2, "cooldown_seconds" => 0}

  What triggers which kind (checked in this priority, one at a time because one fix may
  be in flight per PR and a conflicted branch cannot be tested):

    * `conflicts` - the PR is `:conflicted`;
    * `ci` - the checks state is `:failing`;
    * `comments` - the review decision is `changes_requested`, or review threads are unresolved.

  The policy itself is only a trigger. Every bound lives in the `Run` aggregate
  (`ForemanServer.Aggregates.Run.PrWatch`): per-PR, per-kind attempt caps, one fix in
  flight, no automatic retry of a fix that changed nothing on the same head, a cooldown,
  and `PrFixExhausted` when it gives up. This module reports a refusal for the two
  "gave up" reasons as a `run.pr.fix_exhausted` command, so the operator sees *auto-fix
  gave up* instead of silence; any other refusal (in flight, cooling down, already
  exhausted) is expected and quiet.

  Operator-requested fixes never come through here and bypass the settings (but not the
  aggregate's hard cap).
  """

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.{PrObservation, ProjectionStore, ProjectSettings}

  @type settings :: %{String.t() => term()}

  @command_types %{
    "ci" => "run.pr.fix_ci",
    "comments" => "run.pr.address_comments",
    "conflicts" => "run.pr.resolve_conflicts"
  }

  @doc "The auto-fix settings of `project_id`, or `nil` when off."
  @spec settings(String.t() | nil) :: settings() | nil
  def settings(project_id) when is_binary(project_id) do
    case ProjectionStore.project_projection(project_id) do
      %{config: config} -> config |> ProjectSettings.from_config() |> Map.get(:pr_auto_fix)
      _ -> nil
    end
  end

  def settings(_project_id), do: nil

  @doc """
  The fix command to request for `status`, if any: `{:request, command}`,
  or `:none`. `record` is the run's current watch record for the PR (fix bookkeeping).
  Pure.
  """
  @spec decide(String.t(), String.t(), PrStatus.t(), map() | nil, settings() | nil, integer()) ::
          {:request, map()} | :none
  def decide(_run_id, _pr_url, _status, _record, nil, _now), do: :none
  def decide(_run_id, _pr_url, _status, nil, _settings, _now), do: :none

  def decide(run_id, pr_url, %PrStatus{} = status, record, settings, now) do
    enabled = Map.get(settings, "kinds", [])

    with true <- record.watching and status.status in [:open, :conflicted],
         nil <- record.fix.in_flight,
         kind when not is_nil(kind) <- wanted_kind(status, enabled),
         false <- Map.get(record.fix.exhausted, kind) == status.head_sha do
      {:request, request(run_id, pr_url, kind, record, settings, now)}
    else
      _ -> :none
    end
  end

  defp wanted_kind(status, enabled) do
    Enum.find(["conflicts", "ci", "comments"], fn kind ->
      kind in enabled and applies?(kind, status)
    end)
  end

  defp applies?("conflicts", status), do: status.status == :conflicted
  defp applies?("ci", status), do: status.checks_state == :failing

  defp applies?("comments", status),
    do: status.review_decision == :changes_requested or PrObservation.thread_ids(status) != []

  defp request(run_id, pr_url, kind, record, settings, now) do
    attempt = Map.get(record.fix.attempts, kind, 0) + 1

    %{
      type: Map.fetch!(@command_types, kind),
      command_id: "pr_fix:#{run_id}:#{PrObservation.url_hash(pr_url)}:#{kind}:#{attempt}",
      aggregate_id: "run:#{run_id}",
      payload:
        %{
          run_id: run_id,
          pr_url: pr_url,
          trigger: "auto",
          max_attempts: Map.get(settings, "max_attempts", 2),
          cooldown_seconds: Map.get(settings, "cooldown_seconds", 0),
          requested_at: now
        }
        |> put_repo(Map.get(record, :repo_id))
    }
  end

  @doc """
  When the aggregate refused an automatic request because the PR keeps failing
  (`fix_attempts_exhausted`) or the last fix changed nothing (`fix_no_progress`), the
  `run.pr.fix_exhausted` command that records the give-up; `:none` for every other reason.
  """
  @spec exhausted_command(String.t(), String.t(), map(), term(), String.t()) ::
          {:ok, map()} | :none
  def exhausted_command(run_id, pr_url, request, reason, head_sha) do
    kind = request.type |> kind_of()

    case reason do
      {:fix_attempts_exhausted, ^kind, _cap} ->
        {:ok, exhausted(run_id, pr_url, kind, "max_attempts", head_sha, request)}

      {:fix_no_progress, ^kind} ->
        {:ok, exhausted(run_id, pr_url, kind, "no_progress", head_sha, request)}

      _other ->
        :none
    end
  end

  defp kind_of(type), do: Enum.find_value(@command_types, fn {kind, t} -> t == type && kind end)

  defp exhausted(run_id, pr_url, kind, reason, head_sha, request) do
    %{
      type: "run.pr.fix_exhausted",
      command_id:
        "pr_fix_exhausted:#{run_id}:#{PrObservation.url_hash(pr_url)}:#{kind}:#{head_sha}",
      aggregate_id: "run:#{run_id}",
      payload:
        %{run_id: run_id, pr_url: pr_url, kind: kind, reason: reason, head_sha: head_sha}
        |> put_repo(request.payload[:repo_id])
    }
  end

  # Absent == the run's primary repository (E12): only a non-primary PR names its repo.
  defp put_repo(payload, nil), do: payload
  defp put_repo(payload, repo_id), do: Map.put(payload, :repo_id, repo_id)
end
