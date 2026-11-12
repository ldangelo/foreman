defmodule ForemanServer.Workflow.PhasePR do
  @moduledoc """
  Creates or reconciles a phase-scoped GitHub PR for a completed workflow phase.

  The request is typed and explicit: base branch is the recorded run base branch,
  head branch is the Foreman run branch, and no defaults are invented. Results
  are phase records, not final run PR associations.

  Phase PR reconciliation must publish the head branch before it reuses a
  matching open PR. Otherwise a reused PR record can look successful while the
  provider still shows an older remote head and a stale cumulative diff.

  The push and the PR create are keyed effects (`ForemanServer.Idempotency.Effect`,
  TRD-013): a crash around either is reconciled at boot against the remote branch
  (`Reconcilers.BranchPush`) or GitHub (`Reconcilers.PrCreate`) instead of the call
  being repeated. An effect whose intent cannot be recorded does not run and
  returns `%Error{reason: :intent_not_recorded}` (the effect and the recorder's
  reason in `details`). A key recovery left unresolved is not repeated: the result is
  `%Error{reason: :effect_unresolved}` (the effect and key in `details`) until the run
  is reset; a refusal check that cannot be made is `%Error{reason: :effect_check_failed}`; a malformed marker
  is `%Error{reason: :effect_marker_malformed}` (an operator repairs the stored key). A key
  nobody has decided (`started`, or `ambiguous` with no recorded decision) is
  `%Error{reason: :effect_undecided}` (the effect and key in `details`): the effect is not
  run and is not retried here, and the boot sweep decides the key.
  The PR-create key is checked before the push, so a refusal stops the push too.

  The PR that already exists is asked of GitHub through `ForemanServer.GitHub.PrLookup`
  (TRD-038): an open PR of this repository whose head is the tip just pushed is reused
  (`existing`); an open PR of this repository with another head is
  `%Error{reason: :pr_lookup_mismatch}` (url, `expected_head`, `actual_head` in `details`);
  a fork's PR of the same branch name is not this run's and is ignored; a closed or merged
  PR of this repository is `%Error{reason: :matching_pr_closed}` (the `PrLookup.Pr` in
  `details`); an answer that cannot be read is `:unexpected_pr_list_payload` or
  `:unparsable_pr_list`; a lookup `gh` did not answer lets creation go ahead.
  """

  alias ForemanServer.GitHub.PrLookup
  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.Reconcilers.BranchPush
  alias ForemanServer.Idempotency.Reconcilers.PrCreate, as: PrCreateEffect

  require Logger

  defmodule Request do
    @moduledoc "Typed phase PR request."
    @enforce_keys [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :base_branch,
      :head_branch,
      :cwd
    ]
    defstruct [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :base_branch,
      :head_branch,
      :cwd,
      :artifact_path,
      :now,
      :command_runner,
      existing_records: []
    ]
  end

  defmodule Record do
    @moduledoc "Typed phase PR outcome."
    @enforce_keys [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :status,
      :base_branch,
      :head_branch,
      :provider,
      :recorded_at
    ]
    defstruct [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :status,
      :pr_url,
      :pr_number,
      :base_branch,
      :head_branch,
      :provider,
      :reason,
      :recorded_at
    ]
  end

  defmodule Error do
    @moduledoc "Typed phase PR error."
    @enforce_keys [:reason, :phase_id, :base_branch, :head_branch, :details]
    defstruct [:reason, :phase_id, :base_branch, :head_branch, :details]
  end

  @type result :: {:ok, %Record{}} | {:error, %Error{}}

  @doc """
  Creates or reconciles a phase PR record for this phase.

  Publishes the run head branch, then finds or creates a GitHub PR targeting
  the recorded run base branch from the same head. Each phase in a run records
  its own outcome; the underlying PR is shared across all phases in the run
  because they share the same base/head pair.

  Returns `{:ok, record}` on success, `{:error, error}` on any failure.
  A `:noop` record (no commits ahead) does not suppress final AutoPR.
  A `:created` or `:existing` record suppresses final AutoPR.
  """
  @spec maybe_create(%Request{}) :: result()
  def maybe_create(%Request{} = request) do
    with :ok <- validate_request(request),
         :not_recorded <- existing_record(request),
         {:ok, ahead} <- commits_ahead(request) do
      cond do
        ahead == 0 ->
          {:ok, record(request, :noop, reason: :no_commits_ahead)}

        true ->
          create_or_reuse(request)
      end
    else
      {:ok, %Record{} = record} -> {:ok, record}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def maybe_create(other) do
    {:error,
     %Error{
       reason: :invalid_request,
       phase_id: nil,
       base_branch: nil,
       head_branch: nil,
       details: other
     }}
  end

  defp validate_request(%Request{} = request) do
    cond do
      blank?(request.base_branch) ->
        typed_error(request, :phase_pr_base_branch_unresolved, request)

      blank?(request.head_branch) ->
        typed_error(request, :phase_pr_head_branch_unresolved, request)

      blank?(request.cwd) ->
        typed_error(request, :phase_pr_worktree_unresolved, request)

      true ->
        :ok
    end
  end

  defp existing_record(%Request{} = request) do
    request.existing_records
    |> Enum.find(fn record ->
      Map.get(record, :phase_id) == request.phase_id and
        Map.get(record, :status) in ["created", "existing", :created, :existing]
    end)
    |> case do
      nil -> :not_recorded
      record -> {:ok, record_from_existing(request, record)}
    end
  end

  defp commits_ahead(request) do
    case run(request, "git", [
           "rev-list",
           "--count",
           request.base_branch <> ".." <> request.head_branch
         ]) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {count, _} -> {:ok, count}
          :error -> typed_error(request, :unparsable_rev_list, output)
        end

      {output, exit_code} ->
        typed_error(request, :rev_list_failed, %{
          exit_code: exit_code,
          output: String.trim(output)
        })
    end
  end

  defp create_or_reuse(request) do
    with :ok <- preflight_open_pr(request),
         {:ok, tip} <- push_head(request),
         :none <- find_pr(request, :open, tip),
         :none <- find_pr(request, :closed, nil) do
      open_pr(request)
    else
      {:ok, %PrLookup.Pr{state: :open} = pr} ->
        {:ok, record(request, :existing, pr_url: pr.url, pr_number: pr.number)}

      {:ok, %PrLookup.Pr{state: state} = pr} when state in [:closed, :merged] ->
        typed_error(request, :matching_pr_closed, pr)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # A PR-create key recovery left unresolved refuses the whole sequence BEFORE
  # the push: a push that ran anyway could publish commits the remote lacks.
  defp preflight_open_pr(request) do
    Effect.preflight(
      :pr_create,
      PrCreateEffect.key(request.run_id, request.head_branch, request.base_branch),
      %{"run_id" => request.run_id}
    )
    |> effect_result(request, :pr_create)
  end

  # The push is a keyed effect (`Idempotency.Effect`, TRD-013): the remote head
  # and the local tip are read BEFORE the push and recorded in the `started`
  # key, so a crash around the push is reconciled against the remote at boot
  # (`Reconcilers.BranchPush`) instead of the push being repeated blind. An
  # intent that cannot be recorded means the push did not run. The pushed tip
  # (`pushed_local_sha` of the intent) is returned: it is the head the run's open
  # PR must have.
  defp push_head(request) do
    with {:ok, meta} <-
           BranchPush.intent(runner(request), request.run_id, request.head_branch, request.cwd) do
      Effect.run(
        :branch_push,
        BranchPush.key(request.run_id, request.head_branch),
        fn -> git_push(request) end,
        meta
      )
      |> pushed_tip(meta.pushed_local_sha)
    end
    |> effect_result(request, :branch_push)
  end

  defp pushed_tip(:ok, tip), do: {:ok, tip}
  defp pushed_tip(other, _tip), do: other

  defp git_push(request) do
    Logger.info("PhasePR.run_id=#{request.run_id} git push -u origin #{request.head_branch}")

    case run(request, "git", ["push", "-u", "origin", request.head_branch]) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        typed_error(request, :git_push_failed, %{
          exit_code: exit_code,
          output: String.trim(output)
        })
    end
  end

  # `gh pr create` is a keyed effect too (`Reconcilers.PrCreate`): a crash after
  # GitHub made the PR is found by asking GitHub at boot, never by creating a
  # second PR.
  defp open_pr(request) do
    Effect.run(
      :pr_create,
      PrCreateEffect.key(request.run_id, request.head_branch, request.base_branch),
      fn -> gh_pr_create(request) end,
      PrCreateEffect.intent(request.run_id, request.head_branch, request.base_branch, request.cwd)
    )
    |> effect_result(request, :pr_create)
  end

  defp gh_pr_create(request) do
    title = "feat(phase): #{request.phase_name}"

    body =
      "Foreman run `#{request.run_id}` phase `#{request.phase_name}` complete.\n" <>
        if(request.artifact_path, do: "\nArtifact: #{request.artifact_path}\n", else: "") <>
        findings_section(request.artifact_path)

    args = [
      "pr",
      "create",
      "--base",
      request.base_branch,
      "--head",
      request.head_branch,
      "--title",
      title,
      "--body",
      body
    ]

    case run(request, "gh", args) do
      {output, 0} ->
        url = pr_url_from_output(output) || String.trim(output)
        {:ok, record(request, :created, pr_url: url, pr_number: pr_number_from_url(url))}

      {output, exit_code} ->
        typed_error(request, :gh_pr_create_failed, %{
          exit_code: exit_code,
          output: String.trim(output)
        })
    end
  end

  # An effect whose intent was not recorded did not run. This module returns
  # typed errors only, so it becomes one (`:intent_not_recorded`, the effect and
  # `Effect.run/4`'s reason in `details`).
  defp effect_result({:error, {:intent_not_recorded, reason}}, request, effect) do
    Logger.error(
      "PhasePR.run_id=#{request.run_id} #{effect} NOT run: its intent could not be recorded: #{inspect(reason)}"
    )

    typed_error(request, :intent_not_recorded, %{effect: effect, reason: reason})
  end

  # An unresolved key (recovery could not tell whether the effect happened) is
  # never repeated until the run is reset (only a failed, stuck, blocked or paused
  # run can be): `%Error{reason: :effect_unresolved}`. A check that could not be
  # made is `%Error{reason: :effect_check_failed}`.
  defp effect_result({:error, {:effect_unresolved, key}}, request, effect) do
    Logger.error(
      "PhasePR.run_id=#{request.run_id} #{effect} NOT run: #{inspect(key)} is unresolved (see foreman_doctor, Unresolved effect keys). " <>
        "run.reset lifts this only for a failed, stuck, blocked or paused run, and only when the reset run resumes and reaches the effect again; for any other run check GitHub and the doctor list"
    )

    typed_error(request, :effect_unresolved, %{effect: effect, key: key})
  end

  # A key nobody has decided (`started`, or `ambiguous` with no recorded decision): an
  # earlier attempt may be in flight or may have happened, so the effect is not run and not
  # repeated here: `%Error{reason: :effect_undecided}`. The boot sweep decides the key.
  defp effect_result({:error, {:effect_undecided, key}}, request, effect) do
    Logger.error(
      "PhasePR.run_id=#{request.run_id} #{effect} NOT run: #{inspect(key)} is undecided: an earlier attempt may still be in flight or may already have happened, and nothing has said which, so it is not repeated. " <>
        "The boot sweep is asked to decide it; check GitHub and foreman_doctor, Unresolved effect keys"
    )

    typed_error(request, :effect_undecided, %{effect: effect, key: key})
  end

  defp effect_result({:error, {:effect_marker_malformed, key}}, request, effect) do
    Logger.error(
      "PhasePR.run_id=#{request.run_id} #{effect} NOT run: the unresolved marker of #{inspect(key)} is malformed; no reset clears it, the stored key needs an operator's repair (see foreman_doctor, Unresolved effect keys)"
    )

    typed_error(request, :effect_marker_malformed, %{effect: effect, key: key})
  end

  defp effect_result({:error, {:effect_check_failed, reason}}, request, effect) do
    Logger.error(
      "PhasePR.run_id=#{request.run_id} #{effect} NOT run: could not check whether its key is unresolved: #{inspect(reason)}"
    )

    typed_error(request, :effect_check_failed, %{effect: effect, reason: reason})
  end

  defp effect_result(result, _request, _effect), do: result

  # The PR GitHub already has for the head and base, asked through `GitHub.PrLookup`
  # (TRD-038, precondition P-2): this repository's PR only (a fork's PR of the same branch
  # name is dropped there). The open lookup passes the tip just pushed, so an open PR is
  # reused only when its head is that tip; a PR of this repository with another head is
  # `:pr_lookup_mismatch`, never reused and never created over. The closed lookup (merged
  # PRs included) passes none: any closed or merged PR of this repository is
  # `:matching_pr_closed`. An answer that cannot be read stays a typed error. A lookup
  # `gh` did not answer (a non-zero exit, `gh` not run) is best-effort reconciliation:
  # creation remains the loud authority and will surface provider failures with command
  # output.
  defp find_pr(request, state, expected_head) do
    opts =
      [cwd: request.cwd, command_runner: runner(request)] ++
        if(expected_head, do: [expected_head: expected_head], else: [])

    case PrLookup.find(state, request.head_branch, request.base_branch, opts) do
      {:ok, %PrLookup.Pr{}} = found ->
        found

      :none ->
        :none

      {:error, {:pr_lookup_mismatch, url, expected, actual}} ->
        typed_error(request, :pr_lookup_mismatch, %{
          url: url,
          expected_head: expected,
          actual_head: actual
        })

      {:error, {:unexpected_pr_list_payload, payload}} ->
        typed_error(request, :unexpected_pr_list_payload, payload)

      {:error, {:unparsable_pr_list, text}} ->
        typed_error(request, :unparsable_pr_list, text)

      {:error, reason} ->
        Logger.warning(
          "PhasePR.run_id=#{request.run_id} no #{state} PR found for #{request.head_branch} into #{request.base_branch} (#{inspect(reason)}); going on"
        )

        :none
    end
  end

  defp record(request, status, opts) do
    %Record{
      run_id: request.run_id,
      phase_id: request.phase_id,
      phase_index: request.phase_index,
      phase_name: request.phase_name,
      status: Atom.to_string(status),
      pr_url: Keyword.get(opts, :pr_url),
      pr_number: Keyword.get(opts, :pr_number),
      base_branch: request.base_branch,
      head_branch: request.head_branch,
      provider: "github",
      reason: keyword_reason(opts),
      recorded_at: recorded_at(request)
    }
  end

  defp record_from_existing(request, existing) do
    %Record{
      run_id: request.run_id,
      phase_id: request.phase_id,
      phase_index: request.phase_index,
      phase_name: request.phase_name,
      status: to_string(Map.get(existing, :status)),
      pr_url: Map.get(existing, :pr_url),
      pr_number: Map.get(existing, :pr_number),
      base_branch: Map.get(existing, :base_branch) || request.base_branch,
      head_branch: Map.get(existing, :head_branch) || request.head_branch,
      provider: Map.get(existing, :provider) || "github",
      reason: Map.get(existing, :reason),
      recorded_at: Map.get(existing, :recorded_at) || recorded_at(request)
    }
  end

  defp run(request, executable, args) do
    opts = [cd: request.cwd, stderr_to_stdout: true]
    runner(request).(executable, args, opts)
  end

  defp runner(request), do: request.command_runner || (&System.cmd/3)

  defp typed_error(request, reason, details) do
    {:error,
     %Error{
       reason: reason,
       phase_id: request.phase_id,
       base_branch: request.base_branch,
       head_branch: request.head_branch,
       details: details
     }}
  end

  defp keyword_reason(opts) do
    case Keyword.get(opts, :reason) do
      nil -> nil
      reason -> to_string(reason)
    end
  end

  defp recorded_at(%{now: %DateTime{} = now}), do: DateTime.to_iso8601(now)
  defp recorded_at(_request), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+", output) do
      [url | _] -> String.trim(url)
      nil -> nil
    end
  end

  defp pr_number_from_url(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)(?:\D|$)}, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp pr_number_from_url(_url), do: nil

  defp blank?(value), do: not is_binary(value) or value == ""

  defp findings_section(artifact_path) do
    case ForemanServer.Workflow.ReviewFindings.extract(artifact_path) do
      {:ok, block} -> "\n## Unresolved review findings\n\n" <> block <> "\n"
      :none -> ""
      {:error, :unterminated_block} -> unterminated_findings_section(artifact_path)
    end
  end

  defp unterminated_findings_section(artifact_path) do
    Logger.warning(
      "PhasePR could not read unresolved review findings: unterminated block in #{artifact_path}"
    )

    ForemanServer.Workflow.ReviewFindings.unterminated_section(artifact_path)
  end
end
