defmodule ForemanServer.PrObservation do
  @moduledoc """
  Turns one `ForemanServer.GitHub.PrStatus` reading into the `Run`-aggregate
  commands that record what changed (E9-S1). Pure: the only outside read is
  `ProjectionStore.run/1` (through `PrUpdate.command/3`).

  A reading yields zero to four commands:

    * `run.pr.update` - when the PR status, head SHA or base branch differs from the
      previous record (the same builder the webhook uses, so a webhook and a poll converge
      on one deterministic `command_id`);
    * `run.pr.checks` - when the *checks digest* differs;
    * `run.pr.review` - when the *review digest* differs;
    * `run.pr.risk` (TRD-018) - last, when the batch carries `run.pr.update` or
      `run.pr.checks`, or the stored risk is missing, for another head, from another findings
      record or from another rubric version.

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
  alias ForemanServer.PrReport
  alias ForemanServer.PrRisk.Rubric
  alias ForemanServer.PrUpdate

  @type previous :: map() | nil

  @type error ::
          {:run_not_found, String.t()}
          | {:run_projection_missing_ids, String.t()}
          | {:invalid_force, term()}

  @max_failing 50
  @max_text 200

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
  Digest of the evidence side of `status`: the head, whether the check list was cut, the
  policy version (`nil` until a policy supplies one) and EVERY check as
  `{name, kind, workflow, state, conclusion, completed_at}` in sorted order. Unlike
  `checks_digest/1` it moves when a passing check is added, removed or re-run; the Notifier
  never sees it, so it cannot make a notification repeat.
  """
  @spec evidence_digest(PrStatus.t(), term()) :: String.t()
  def evidence_digest(%PrStatus{} = status, policy_version \\ nil) do
    checks =
      status.checks
      |> Enum.map(&{&1.name, &1.kind, &1.workflow, &1.state, &1.conclusion, &1.completed_at})
      |> Enum.sort()

    digest({:evidence, status.head_sha, status.checks_truncated, policy_version, checks})
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

  @doc """
  The sorted ids of the PR's conversation comments that a person wrote.

  A comment GitHub reports as written by a Bot (`bot: true`: a review bot's walkthrough, a
  coverage report) is not feedback anyone can address, and counting it would enable "Address
  comments" on every PR of an account that has a review bot (foreman-v9y3x). A comment whose
  author type is unknown (`bot: nil`: the fetch did not read it) counts, as every comment did
  before. A comment that is Foreman's own report (TRD-030) is not feedback either: its body
  starts with `PrReport.marker_prefix/0` AND the token's own user wrote it
  (`viewer_did_author`, read from `gh pr view`). Without that guard the publisher's comment would
  reach the watcher through the `issue_comment` webhook and move the review digest. A comment
  by another user that starts with the marker proves nothing and is counted.
  """
  @spec comment_ids(PrStatus.t()) :: [String.t()]
  def comment_ids(%PrStatus{comments: comments}) do
    for(%{id: id} = comment <- comments, feedback?(comment), do: id)
    |> Enum.sort()
  end

  defp feedback?(%{bot: true}), do: false

  defp feedback?(%{viewer_did_author: true, body: body}) when is_binary(body),
    do: not String.starts_with?(body, PrReport.marker_prefix())

  defp feedback?(_comment), do: true

  @doc "The sorted ids of the PR's unresolved review threads (`[]` when threads were not read)."
  @spec thread_ids(PrStatus.t()) :: [String.t()]
  def thread_ids(%PrStatus{threads: nil}), do: []

  def thread_ids(%PrStatus{threads: threads}),
    do: for(%{resolved: false, id: id} <- threads, do: id) |> Enum.sort()

  @doc """
  Commands to dispatch for `status` observed on `run_id`'s PR `pr_url`.
  `previous` is the stored watch record (or `nil`). `repo_id` is the effective id of
  the repository that opened the PR (E12; `nil` == the run's primary); every command
  of a non-primary PR carries it, a primary's carry `repo_id: nil` as before.

  `opts`: `force: %{nonce: binary, now_ms: integer}` makes a forced observation for the
  approval gate: the `run.pr.update` is always in the batch (its deterministic id makes it a
  no-op for an unchanged PR), followed by exactly one `run.pr.checks` whatever the digests
  say, with id `pr_checks:<run_id>:<url_hash>:forced:<nonce>`, `observed_at: now_ms`,
  `observation_ref: nonce` and `source: "gate"`, and no `run.pr.review`. Every other
  `run.pr.checks` is stamped `source: "watch"`.

  `opts` `policy: %{required, version} | nil` (`PrEvidence.project_policy/1`, default `nil`
  = gate off): every `run.pr.checks` records `required` and `policy_version` on its payload
  (display only; a decision reads the policy itself), and the version is part of the evidence
  digest, so a policy change with no new check still emits one `run.pr.checks`.
  """
  @spec commands(
          String.t(),
          String.t(),
          PrStatus.t(),
          previous(),
          String.t() | nil,
          keyword()
        ) :: {:ok, [map()]} | {:error, error()}
  def commands(run_id, pr_url, %PrStatus{} = status, previous, repo_id \\ nil, opts \\ [])
      when is_binary(run_id) and is_binary(pr_url) and is_list(opts) do
    force = Keyword.get(opts, :force)
    policy = policy_opt(Keyword.get(opts, :policy))

    with :ok <- check_force(force),
         {:ok, update} <- update_command(run_id, pr_url, status, repo_id) do
      base = base_payload(update.payload, status)

      case force do
        nil ->
          batch =
            update_commands(update, status, previous) ++
              checks_commands(run_id, pr_url, status, previous, base, policy) ++
              review_commands(run_id, pr_url, status, previous, base)

          {:ok, batch ++ risk_commands(run_id, pr_url, status, previous, base, policy, batch)}

        %{nonce: nonce, now_ms: now_ms}
        when is_binary(nonce) and nonce != "" and is_integer(now_ms) ->
          batch = [
            update,
            forced_checks_command(run_id, pr_url, status, previous, base, nonce, now_ms, policy)
          ]

          {:ok,
           batch ++
             risk_commands(
               run_id,
               pr_url,
               status,
               previous,
               %{base | observed_at: now_ms},
               policy,
               batch
             )}
      end
    end
  end

  defp policy_opt(%{} = policy),
    do: %{required: policy_get(policy, :required), version: policy_get(policy, :version)}

  defp policy_opt(_none), do: %{required: nil, version: nil}

  defp policy_get(policy, key), do: Map.get(policy, key, Map.get(policy, Atom.to_string(key)))

  defp check_force(nil), do: :ok

  defp check_force(%{nonce: nonce, now_ms: now_ms})
       when is_binary(nonce) and nonce != "" and is_integer(now_ms),
       do: :ok

  defp check_force(other), do: {:error, {:invalid_force, other}}

  defp update_command(run_id, pr_url, status, repo_id),
    do: PrUpdate.command(run_id, pr_url, status, repo_id)

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
      repo_id: Map.get(update_payload, :repo_id),
      base_branch: status.base_branch,
      head_sha: status.head_sha,
      pr_status: Atom.to_string(status.status),
      observed_at: System.system_time(:millisecond)
    }
  end

  defp checks_commands(run_id, pr_url, status, previous, base, policy) do
    digest = checks_digest(status)
    baseline = previous_value(previous, :checks_digest) || empty_checks_digest(status)
    evidence = evidence_digest(status, policy.version)

    evidence_baseline =
      stored_evidence_digest(previous) || empty_evidence_digest(status, policy.version)

    if digest == baseline and evidence == evidence_baseline do
      []
    else
      seq = next_checks_seq(previous)

      [
        checks_command(
          "pr_checks:#{run_id}:#{url_hash(pr_url)}:#{digest}:#{seq}",
          run_id,
          pr_url,
          status,
          base,
          digest,
          evidence,
          seq,
          nil,
          "watch",
          if(digest == baseline, do: "evidence", else: "digest"),
          policy
        )
      ]
    end
  end

  # `change` says what moved: `digest` (the notification digest: a new failing set, state or
  # head, the one the Notifier dedupes on) or `evidence` (only the passing checks or a time
  # moved, or a forced observation). Only a `digest` change may notify: an evidence-only event
  # carries the same failing set and digest, and after the dedupe window it would send "CI
  # failed" a second time for the same failure.
  #
  # A forced observation is built whatever the digests say: an unchanged PR returns nothing from
  # `checks_commands/5`, so its `observed_at` and `observation_ref` would stay old. It carries
  # the unchanged notification `digest` and `source: "gate"`, so the Notifier ignores it.
  defp forced_checks_command(run_id, pr_url, status, previous, base, nonce, now_ms, policy) do
    checks_command(
      "pr_checks:#{run_id}:#{url_hash(pr_url)}:forced:#{nonce}",
      run_id,
      pr_url,
      status,
      %{base | observed_at: now_ms},
      checks_digest(status),
      evidence_digest(status, policy.version),
      next_checks_seq(previous),
      nonce,
      "gate",
      "evidence",
      policy
    )
  end

  # -- risk (TRD-018) -------------------------------------------------------------------------

  # `run.pr.risk` ends the batch when the batch carries `run.pr.update` or `run.pr.checks` (the
  # head moved, the PR changed, or the checks did), or when the stored risk record is missing,
  # is for another head, was computed from another findings record (its `findings_digest`
  # differs from `evidence.findings.digest`) or under another rubric version. A batch with none
  # of these and a current record carries none. A forced batch always has a `run.pr.checks`.
  #
  # The command is the facts of the one `PrStatus` and the policy snapshot; it carries no level:
  # the aggregate classifies. `checks_ref` is the `observation_ref` of the batch's own checks
  # command (the forced nonce, `nil` for an observer's batch), else the stored checks record's.
  defp risk_commands(run_id, pr_url, status, previous, base, policy, batch) do
    checks = Enum.find(batch, &(&1.type == "run.pr.checks"))

    if risk_due?(status, previous, base, batch) do
      seq = (stored_risk(previous) |> Map.get(:seq) || 0) + 1

      [
        %{
          type: "run.pr.risk",
          command_id: "pr_risk:#{run_id}:#{url_hash(pr_url)}:#{status.head_sha}:#{seq}",
          aggregate_id: "run:#{run_id}",
          payload: %{
            run_id: run_id,
            pr_url: pr_url,
            project_id: base.project_id,
            task_id: base.task_id,
            repo_id: base.repo_id,
            head_sha: status.head_sha,
            base_branch: status.base_branch,
            files: status.files,
            changed_files: status.changed_files,
            additions: status.additions,
            deletions: status.deletions,
            required: policy.required,
            policy_version: policy.version,
            checks_ref: risk_checks_ref(checks, previous),
            observed_at: base.observed_at
          }
        }
      ]
    else
      []
    end
  end

  defp risk_due?(status, previous, base, batch) do
    risk = stored_risk(previous)

    Enum.any?(batch, &(&1.type in ["run.pr.update", "run.pr.checks"])) or
      risk == %{} or Map.get(risk, :head_sha) != status.head_sha or
      Map.get(risk, :rubric_version) != Rubric.version() or
      Map.get(risk, :findings_digest) != stored_findings_digest(previous, base.repo_id)
  end

  defp risk_checks_ref(%{payload: %{observation_ref: ref}}, _previous), do: ref

  defp risk_checks_ref(nil, previous) do
    case stored_evidence(previous, :checks) do
      %{} = checks -> Map.get(checks, :observation_ref)
      _none -> nil
    end
  end

  defp stored_risk(previous), do: stored_evidence(previous, :risk) || %{}

  # A secondary repository's PR is classified without a findings record (the handler's rule), so
  # its stored findings digest is read as `nil` here too.
  defp stored_findings_digest(_previous, repo_id) when is_binary(repo_id), do: nil

  defp stored_findings_digest(previous, nil) do
    case stored_evidence(previous, :findings) do
      %{} = findings -> Map.get(findings, :digest)
      _none -> nil
    end
  end

  defp stored_evidence(previous, key) do
    with %{} = record <- previous,
         %{} = evidence <- Map.get(record, :evidence) do
      Map.get(evidence, key)
    else
      _ -> nil
    end
  end

  defp next_checks_seq(previous), do: (previous_value(previous, :checks_seq) || 0) + 1

  defp checks_command(
         command_id,
         run_id,
         pr_url,
         status,
         base,
         digest,
         evidence,
         seq,
         observation_ref,
         source,
         change,
         policy
       ) do
    %{
      type: "run.pr.checks",
      command_id: command_id,
      aggregate_id: "run:#{run_id}",
      payload:
        Map.merge(base, %{
          run_id: run_id,
          pr_url: pr_url,
          checks_state: Atom.to_string(status.checks_state),
          failing: failing(status),
          checks: evidence_checks(status),
          checks_truncated: status.checks_truncated,
          digest: digest,
          evidence_digest: evidence,
          observation_ref: observation_ref,
          source: source,
          change: change,
          required: policy.required,
          policy_version: policy.version,
          observation_seq: seq
        })
    }
  end

  defp stored_evidence_digest(previous) do
    with %{} = record <- previous,
         %{} = evidence <- Map.get(record, :evidence),
         %{} = checks <- Map.get(evidence, :checks) do
      Map.get(checks, :evidence_digest)
    else
      _ -> nil
    end
  end

  defp empty_evidence_digest(status, policy_version),
    do: evidence_digest(%{status | checks: [], checks_truncated: false}, policy_version)

  defp evidence_checks(status) do
    status.checks
    |> Enum.take(-PrStatus.max_list())
    |> Enum.map(fn check ->
      %{
        name: cut(check.name),
        kind: check.kind,
        state: check.state,
        conclusion: cut(check.conclusion),
        workflow: cut(check.workflow),
        started_at: check.started_at,
        completed_at: check.completed_at
      }
    end)
  end

  defp cut(nil), do: nil
  defp cut(text), do: String.slice(text, 0, @max_text)

  defp review_commands(run_id, pr_url, status, previous, base) do
    digest = review_digest(status)
    # A head move resets the stored review observation (`PrEvidence`), so the baseline this
    # batch must differ from is the reset one: an unchanged review is re-recorded in the same
    # batch instead of reading as nothing until the next poll.
    baseline =
      if head_moved?(previous, status),
        do: empty_review_digest(status),
        else: previous_value(previous, :review_digest) || empty_review_digest(status)

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

  defp head_moved?(previous, status) do
    head = previous_value(previous, :head_sha)
    is_binary(head) and head != "" and head != status.head_sha
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
