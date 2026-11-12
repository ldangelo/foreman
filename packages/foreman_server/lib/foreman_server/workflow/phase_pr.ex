defmodule ForemanServer.Workflow.PhasePR do
  @moduledoc """
  Creates or reconciles a phase-scoped GitHub PR for a completed workflow phase.

  The request is typed and explicit: base branch is the recorded run base branch,
  head branch is the Foreman run branch, and no defaults are invented. Results
  are phase records, not final run PR associations.

  A matching open PR is reused only when its head is the commit the run has: a PR that
  GitHub shows at an older head is reused only after the push moved it. Otherwise a
  reused PR record can look successful while the provider still shows an older remote head
  and a stale cumulative diff.

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
  (TRD-038), first of all as `AutoPR` does (before any key is consulted: an open PR with
  the local tip is reused without a push, and settles the PR-create key an earlier attempt
  left undecided), then again after the push: an open PR of this repository whose head is
  the tip just pushed is reused (`existing`); GitHub updates a PR's head asynchronously, so
  a head that is not the tip yet is looked up again (three tries, `lookup_retry_sleep_ms`
  apart); an open PR of this repository with another head after that is
  `%Error{reason: :pr_lookup_mismatch}` (url, `expected_head`, `actual_head` in `details`);
  a fork's PR of the same branch name is not this run's and is ignored; a closed or merged
  PR of this repository is `%Error{reason: :matching_pr_closed}` (the `PrLookup.Pr` in
  `details`); an answer that cannot be read is `:unexpected_pr_list_payload` or
  `:unparsable_pr_list`; any other failed lookup (a non-zero exit, a timeout after
  `lookup_timeout_ms`, `gh` not run) is `%Error{reason: :pr_lookup_failed}` (`state` and
  `reason` in `details`): only the answer "no PR" lets creation go ahead. A `gh pr create`
  that fails is followed by one more open-PR lookup, as in `AutoPR` (it too reads a lagging head
  again, three tries): the PR with the tip is adopted.
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
      existing_records: [],
      lookup_timeout_ms: ForemanServer.Idempotency.Reconcilers.Command.default_timeout_ms(),
      lookup_retry_sleep_ms: 700
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

  # GitHub is asked first, before any effect key is consulted, as `AutoPR` does: the open PR of
  # this repository whose head is the local tip IS the run's PR however the keys stand, so
  # nothing is pushed or created and the PR-create key an earlier attempt left undecided is
  # settled. Every other answer goes on into the keyed sequence, whose own lookups judge it.
  defp create_or_reuse(request) do
    intent = BranchPush.intent(runner(request), request.run_id, request.head_branch, request.cwd)

    case adopt_open_pr(request, intent) do
      {:ok, _record} = adopted -> adopted
      :continue -> push_and_open(request, intent)
    end
  end

  # An unreadable tip has nothing to compare a PR's head with: the sequence reports it at the push.
  defp adopt_open_pr(request, {:ok, %{pushed_local_sha: tip}}) do
    case lookup(request, :open, tip) do
      {:ok, %PrLookup.Pr{state: :open} = pr} ->
        {:ok, reuse(request, pr)}

      :none ->
        :continue

      # Not adopted, and said so: the keyed sequence below looks the PR up again after the push
      # and surfaces a lookup that still fails as its typed error.
      {:error, reason} ->
        Logger.warning(
          "PhasePR.run_id=#{request.run_id} no PR adopted for #{request.head_branch} into #{request.base_branch} (#{inspect(reason)}); going on to the keyed sequence",
          run_id: request.run_id,
          base_branch: request.base_branch,
          head_branch: request.head_branch,
          operation: "phase_pr.lookup",
          outcome: "not_adopted",
          reason: inspect(reason)
        )

        :continue
    end
  end

  defp adopt_open_pr(_request, {:error, _reason}), do: :continue

  defp push_and_open(request, intent) do
    with :ok <- preflight_open_pr(request),
         {:ok, tip} <- push_head(request, intent),
         :none <- find_open_pr(request, tip),
         :none <- find_pr(request, :closed, nil) do
      open_pr(request, tip)
    else
      {:ok, %PrLookup.Pr{state: :open} = pr} ->
        {:ok, reuse(request, pr)}

      {:ok, %PrLookup.Pr{state: state} = pr} when state in [:closed, :merged] ->
        typed_error(request, :matching_pr_closed, pr)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # The open PR is the run's: the PR-create key an earlier attempt left `started` or
  # `ambiguous` is settled (GitHub has answered for it), and the phase records the PR.
  defp reuse(request, %PrLookup.Pr{} = pr) do
    case PrCreateEffect.settle_adopted(request.run_id, request.head_branch, request.base_branch) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "PhasePR.run_id=#{request.run_id} could not settle the PR-create key after reusing #{pr.url}: #{inspect(reason)}"
        )
    end

    record(request, :existing, pr_url: pr.url, pr_number: pr.number)
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
  defp push_head(request, intent) do
    with {:ok, meta} <- intent do
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
  defp open_pr(request, tip) do
    Effect.run(
      :pr_create,
      PrCreateEffect.key(request.run_id, request.head_branch, request.base_branch),
      fn -> gh_pr_create(request, tip) end,
      PrCreateEffect.intent(request.run_id, request.head_branch, request.base_branch, request.cwd)
    )
    |> effect_result(request, :pr_create)
  end

  defp gh_pr_create(request, tip) do
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
        after_failed_create(request, tip, %{exit_code: exit_code, output: String.trim(output)})
    end
  end

  # A non-zero exit does not say the PR does not exist: GitHub may have made it, or a concurrent
  # caller opened it between the lookups (it refuses a duplicate open PR). Ask once more before
  # the key settles `failed`, as `AutoPR` does: the open PR with the tip is the run's (the key
  # settles `completed`); a PR of this repository with another head is the typed mismatch; none,
  # or a lookup that failed, keeps the create's own error. The lookup is `find_open_pr/2`, which
  # reads a head that lags behind the push again (up to three tries, `lookup_retry_sleep_ms`
  # apart) while the key is still `started`: deliberate, because a create that failed right
  # after the push meets the same asynchronous head update as the lookup after the push.
  defp after_failed_create(request, tip, failure) do
    case find_open_pr(request, tip) do
      {:ok, %PrLookup.Pr{} = pr} ->
        Logger.info(
          "PhasePR.run_id=#{request.run_id} adopted #{pr.url} after gh pr create failed: it is this run's PR for #{request.head_branch} into #{request.base_branch}"
        )

        {:ok, record(request, :existing, pr_url: pr.url, pr_number: pr.number)}

      {:error, %Error{reason: :pr_lookup_mismatch}} = mismatch ->
        mismatch

      _none_or_unreadable ->
        typed_error(request, :gh_pr_create_failed, failure)
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
  # `:matching_pr_closed`. Only the documented "no PR" answer (`:none`) lets creation go
  # ahead; every other answer is a typed error, because creating over a PR that could not be
  # looked up is how a second PR would be opened over a closed one an operator closed.
  defp find_pr(request, state, expected_head) do
    case lookup(request, state, expected_head) do
      {:ok, %PrLookup.Pr{}} = found -> found
      :none -> :none
      {:error, reason} -> lookup_error(request, state, reason)
    end
  end

  defp lookup(request, state, expected_head) do
    opts =
      [
        cwd: request.cwd,
        command_runner: runner(request),
        timeout_ms: request.lookup_timeout_ms
      ] ++ if(expected_head, do: [expected_head: expected_head], else: [])

    PrLookup.find(state, request.head_branch, request.base_branch, opts)
  end

  # GitHub updates a PR's `headRefOid` asynchronously after a push, so an open PR whose head
  # is not yet the tip just pushed is read again (three tries, `lookup_retry_sleep_ms`
  # apart) before it is the mismatch.
  @head_tries 3
  defp find_open_pr(request, tip), do: find_open_pr(request, tip, @head_tries)

  defp find_open_pr(request, tip, tries_left) do
    case lookup(request, :open, tip) do
      {:ok, %PrLookup.Pr{}} = found ->
        found

      :none ->
        :none

      {:error, {:pr_lookup_mismatch, _url, _expected, _actual}} when tries_left > 1 ->
        Process.sleep(request.lookup_retry_sleep_ms)
        find_open_pr(request, tip, tries_left - 1)

      {:error, reason} ->
        lookup_error(request, :open, reason)
    end
  end

  defp lookup_error(request, _state, {:pr_lookup_mismatch, url, expected, actual}) do
    typed_error(request, :pr_lookup_mismatch, %{
      url: url,
      expected_head: expected,
      actual_head: actual
    })
  end

  defp lookup_error(request, _state, {:unexpected_pr_list_payload, payload}),
    do: typed_error(request, :unexpected_pr_list_payload, payload)

  defp lookup_error(request, _state, {:unparsable_pr_list, text}),
    do: typed_error(request, :unparsable_pr_list, text)

  defp lookup_error(request, state, reason) do
    Logger.error(
      "PhasePR.run_id=#{request.run_id} could not look up the #{state} PR for #{request.head_branch} into #{request.base_branch} (#{inspect(reason)}): nothing is created over a PR that cannot be looked up"
    )

    typed_error(request, :pr_lookup_failed, %{state: state, reason: reason})
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
