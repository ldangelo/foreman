defmodule ForemanServer.PrWatch.DTO do
  @moduledoc """
  The one wire shape of a watched PR (E9): `GET /api/runs/:id/prs`, `foreman run prs` and the
  MCP `foreman_pr_status` tool all return `%{run_id, prs: [DTO]}` built by `fetch/1` through
  `from_projection/3`, so the surfaces cannot diverge.

  Fields are fixed snake_case keys with explicit `null`s, except `merge_gate`
  (the `none | pending | approved` merge gate of the PR the run is
  associated with), which is omitted for any other PR. `fixes` carries the per-kind attempt counters
  (`ci`, `comments`, `conflicts`), the in-flight fix (`state` is `requested`
  until its jobsite starts, then `running`), the last outcome per kind and the
  head SHA each kind gave up on.

  ## Evidence (TRD-023)

  The evidence fields are the display of what the approval gate reads. `eligibility` is the
  result of `PrEvidence.evaluate/2` over the same projection record, with the project's
  current policy and `checks_ref: nil` (a display read, freshness is not judged), so the status
  an operator sees is the decision the gate would take on this record: a divergence is a bug
  (the parity test pins it). The gate additionally forces an observation first, so it can
  decide differently only because the world moved.

    * `eligibility` - `%{status, head_sha, reasons, waived, policy_version, evaluated_at}`;
      `status` is `off | eligible | ineligible | waived | unknown`, `reasons` and `waived` are
      `[%{code, subject, detail}]`. `unknown` (never `off`) when the project's policy or the
      record cannot be read; its one reason is `evidence_unreadable`.
    * `checks` - `nil` or `%{head_sha, current, stale, old, observed_at, truncated,
      evidence_digest, items}`, `items` being `%{name, kind, workflow, state, conclusion,
      started_at, completed_at}`.
    * `findings` - `nil` or `%{head_sha, current, stale, status, defect, defect_detail, digest,
      recorded_at, unresolved, total, listed_truncated, items, judgement}`.
    * `risk` - `nil` or `%{head_sha, current, stale, level, rubric_version, digest, seq,
      recorded_at, rationale, instructions}`; `rationale` is `%{rule, level, basis, detail}`.
    * `waiver` - `nil` or `%{head_sha, current, codes, policy_version, reason, waived_by,
      waived_at, applies, ignored_because}`; `applies` and `ignored_because` come from the
      evaluator (`other_head | policy_changed`) and are `null` when the gate is off or `unknown`.
    * `report` - `nil` or `%{head_sha, digest, status, reason, comment_url, superseded,
      recorded_at, current, stale}`; stale also when its digest is not the risk record's.
    * `delivery_issue` - `nil` or `%{stage, reason, failed_at}`.
    * `next_actions` - `PrEvidence.next_actions/2`: `[%{action, command, codes}]`.

  Every evidence block carries its own `head_sha`: `current` is whether it is for the PR's head
  and `stale` is its negation (a stale block is for another head). `old` marks a checks
  observation older than 900 seconds in the display only; age is never a reason.

  Text written by an agent or read from GitHub (a finding's description, path and source, a
  defect detail, a check's name, a rationale detail, a waiver reason) is untrusted: it is
  scrubbed of invalid UTF-8 and control characters and cut at a fixed length here, and a
  consumer that renders it into markdown or HTML must escape it again.

  Read-only and advisory: nothing here can merge, approve or refuse anything.
  """

  alias ForemanServer.PrEvidence
  alias ForemanServer.PrEvidence.{Eligibility, Reason}
  alias ForemanServer.ProjectionStore

  require Logger

  @display_stale_ms 900_000
  @max_listed 20
  @max_checks 100
  @max_rationale 20
  @max_text 300
  @max_short 64
  @max_path 200
  @max_reason 500

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
    :agent_review,
    :eligibility,
    :checks,
    :findings,
    :risk,
    :waiver,
    :report,
    :delivery_issue,
    :next_actions
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
          eligibility: map(),
          checks: map() | nil,
          findings: map() | nil,
          risk: map() | nil,
          waiver: map() | nil,
          report: map() | nil,
          delivery_issue: map() | nil,
          next_actions: [map()],
          merge_gate: String.t() | nil
        }

  @typedoc """
  What the evidence fields are derived under: `policy` is `PrEvidence.project_policy/1`'s
  answer for the PR's project (or an error detail), `now_ms` the display clock and `run_status`
  the run's status string.
  """
  @type context :: %{
          policy: {:ok, map() | nil} | {:error, String.t()},
          now_ms: integer(),
          run_status: String.t() | nil
        }

  @kinds ~w(ci comments conflicts)

  @doc """
  The PRs of a run as `%{run_id: id, prs: [t()]}`, or `{:error, :run_not_found}`
  for an unknown run (a known run with no observed PR yields `prs: []`).

  When `ProjectionStore` does not answer (it is down, restarting after a failed boot read of
  the event log, or the call times out) the answer is `{:error, {:projection_unavailable, reason}}`
  (TRD-031, AC-005-3): the status of the PRs is unknown, never an empty list and never clean.
  """
  @spec fetch(String.t()) ::
          {:ok, %{run_id: String.t(), prs: [t()]}}
          | {:error, :run_not_found}
          | {:error, {:projection_unavailable, String.t()}}
  def fetch(run_id) when is_binary(run_id) and run_id != "" do
    read_projection(run_id)
  catch
    :exit, reason -> {:error, {:projection_unavailable, bounded_inspect(reason)}}
  end

  def fetch(_run_id), do: {:error, :run_not_found}

  defp read_projection(run_id) do
    case ProjectionStore.run(run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        %{pr_url: gated_url, merge_gate: gate} = ProjectionStore.pr_state(run_id)
        now_ms = System.system_time(:millisecond)

        prs =
          run_id
          |> ProjectionStore.pr_watch()
          |> Enum.map(fn record ->
            context = %{
              policy: policy_source(record),
              now_ms: now_ms,
              run_status: Map.get(run, :status)
            }

            from_projection(record, if(record.pr_url == gated_url, do: gate), context)
          end)

        {:ok, %{run_id: run_id, prs: prs}}
    end
  end

  # The one place the policy of a PR is read. A policy that cannot be read is an error with its
  # reason, shown as `unknown`, never as `off`. A store that does not answer at all never gets
  # this far: `fetch/1` answers `{:error, {:projection_unavailable, reason}}` for the whole run.
  @spec policy_source(map()) :: {:ok, map() | nil} | {:error, String.t()}
  defp policy_source(record) do
    case PrEvidence.project_policy(Map.get(record, :project_id)) do
      {:ok, policy} -> {:ok, policy}
      {:error, {:policy_unavailable, reason}} -> {:error, bounded_inspect(reason)}
    end
  end

  @doc """
  Build the DTO from one `ProjectionStore.pr_watch/1` record, the run's merge gate and the
  `t:context/0` the evidence fields are derived under.
  """
  @spec from_projection(map(), atom() | String.t() | nil, context()) :: t()
  def from_projection(record, merge_gate, %{policy: _, now_ms: _, run_status: _} = context)
      when is_map(record) do
    eligibility = eligibility(record, context)
    evidence = evidence_of(record)

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
      eligibility: eligibility_view(eligibility),
      checks: checks(evidence.checks, record, context),
      findings: findings(evidence.findings, record),
      risk: risk(evidence.risk, record),
      waiver: waiver(evidence.waiver, eligibility, record),
      report: report(evidence.report, evidence.risk, record),
      delivery_issue: delivery_issue(evidence.delivery_issue),
      next_actions:
        record
        |> PrEvidence.next_actions(%{
          eligibility: eligibility,
          merge_gate: gate(merge_gate),
          run_status: context.run_status
        }),
      merge_gate: gate(merge_gate)
    }
  end

  # -- eligibility ----------------------------------------------------------------

  # `PrEvidence.evaluate/2` with the project's current policy and no `checks_ref`: the function
  # the aggregate decides with. A policy that cannot be read, or an evaluation that raises, is
  # `unknown` with the one reason `evidence_unreadable`.
  defp eligibility(record, %{policy: {:ok, policy}, now_ms: now_ms}) do
    PrEvidence.evaluate(record, %{
      head_sha: record.head_sha,
      policy: policy,
      now_ms: now_ms,
      checks_ref: nil
    })
  rescue
    exception ->
      Logger.error(
        "PrWatch.DTO: evaluating #{inspect(record.pr_url)} raised #{inspect(exception.__struct__)}"
      )

      unknown(record, now_ms, "the evidence could not be evaluated")
  end

  defp eligibility(record, %{policy: {:error, detail}, now_ms: now_ms}),
    do: unknown(record, now_ms, "the project policy cannot be read: " <> detail)

  defp unknown(record, now_ms, detail) do
    %Eligibility{
      head_sha: record.head_sha,
      status: :unknown,
      reasons: [%Reason{code: :evidence_unreadable, subject: nil, detail: detail}],
      waived: [],
      waiver: nil,
      policy_version: nil,
      inputs: %{},
      evaluated_at: now_ms
    }
  end

  defp eligibility_view(%Eligibility{} = eligibility) do
    %{
      status: Atom.to_string(eligibility.status),
      head_sha: eligibility.head_sha,
      reasons: Enum.map(eligibility.reasons, &reason/1),
      waived: Enum.map(eligibility.waived, &reason/1),
      policy_version: eligibility.policy_version,
      evaluated_at: eligibility.evaluated_at
    }
  end

  defp reason(%Reason{code: code, subject: subject, detail: detail}),
    do: %{
      code: Atom.to_string(code),
      subject: text(subject, @max_path),
      detail: text(detail, @max_text)
    }

  # -- evidence blocks ------------------------------------------------------------

  defp evidence_of(%{evidence: %{} = evidence}),
    do: Map.merge(PrEvidence.empty(), evidence)

  defp evidence_of(_record), do: PrEvidence.empty()

  defp checks(nil, _record, _context), do: nil

  defp checks(%{} = checks, record, %{now_ms: now_ms}) do
    observed_at = get(checks, :observed_at)

    Map.merge(head_labels(get(checks, :head_sha), record), %{
      old:
        is_integer(observed_at) and is_integer(now_ms) and
          now_ms - observed_at > @display_stale_ms,
      observed_at: integer_or_nil(observed_at),
      truncated: get(checks, :truncated) == true,
      evidence_digest: text(get(checks, :evidence_digest), @max_short),
      items: checks |> get(:items) |> list() |> Enum.take(@max_checks) |> Enum.map(&check_item/1)
    })
  end

  defp checks(_other, _record, _context), do: nil

  defp check_item(item) do
    %{
      name: text(get(item, :name), @max_path),
      kind: text(get(item, :kind), @max_short),
      workflow: text(get(item, :workflow), @max_path),
      state: item |> get(:state) |> atom_text() |> text(@max_short),
      conclusion: text(get(item, :conclusion), @max_short),
      started_at: text(get(item, :started_at), @max_short),
      completed_at: text(get(item, :completed_at), @max_short)
    }
  end

  defp findings(nil, _record), do: nil

  defp findings(%{} = findings, record) do
    items = findings |> get(:findings) |> list() |> Enum.filter(&is_map/1)
    unresolved = unresolved(items)

    listed =
      items
      |> Enum.sort_by(&{severity_rank(get(&1, :severity)), unresolved?(&1) == false})
      |> Enum.take(@max_listed)

    Map.merge(head_labels(get(findings, :head_sha), record), %{
      status: text(get(findings, :status), @max_short),
      defect: text(get(findings, :defect), @max_short),
      defect_detail: text(get(findings, :defect_detail), @max_text),
      digest: text(get(findings, :digest), @max_short),
      recorded_at: integer_or_nil(get(findings, :recorded_at)),
      unresolved: unresolved,
      total: length(items),
      listed_truncated: length(items) > @max_listed,
      items: Enum.map(listed, &finding_item/1),
      judgement: judgement(get(findings, :judgement))
    })
  end

  defp findings(_other, _record), do: nil

  defp finding_item(item) do
    %{
      severity: text(get(item, :severity), @max_short),
      disposition: text(get(item, :disposition), @max_short),
      description: text(get(item, :description), @max_text),
      path: text(get(item, :path), @max_path),
      line: positive_or_nil(get(item, :line)),
      source: text(get(item, :source), @max_short)
    }
  end

  # The judgement's level and status only: its rationale is free text of the review agent and
  # is not part of the status read.
  defp judgement(%{} = judgement),
    do: %{
      status: text(get(judgement, :status), @max_short),
      level: text(get(judgement, :level), @max_short),
      defect: text(get(judgement, :defect), @max_short)
    }

  defp judgement(_other), do: nil

  @severities ~w(critical major minor nitpick)

  # Every open finding and every declined critical or major one, as `Workflow.ReviewFindings.unresolved/1`.
  defp unresolved(items) do
    Map.new(@severities, fn severity ->
      {severity, Enum.count(items, &(get(&1, :severity) == severity and unresolved?(&1)))}
    end)
  end

  defp unresolved?(item) do
    case get(item, :disposition) do
      "open" -> true
      "declined" -> get(item, :severity) in ["critical", "major"]
      _other -> false
    end
  end

  defp severity_rank(severity), do: Enum.find_index(@severities, &(&1 == severity)) || 4

  defp risk(nil, _record), do: nil

  defp risk(%{} = risk, record) do
    Map.merge(head_labels(get(risk, :head_sha), record), %{
      level: text(get(risk, :level), @max_short),
      rubric_version: text(get(risk, :rubric_version), @max_short),
      digest: text(get(risk, :digest), @max_short),
      seq: positive_or_nil(get(risk, :seq)),
      recorded_at: integer_or_nil(get(risk, :recorded_at)),
      rationale:
        risk
        |> get(:rationale)
        |> list()
        |> Enum.take(@max_rationale)
        |> Enum.map(&rationale_item/1),
      instructions:
        risk
        |> get(:instructions)
        |> list()
        |> Enum.take(@max_rationale)
        |> Enum.map(&text(&1, @max_text))
    })
  end

  defp risk(_other, _record), do: nil

  defp rationale_item(item) do
    %{
      rule: text(get(item, :rule), @max_short),
      level: text(get(item, :level), @max_short),
      basis: text(get(item, :basis), @max_short),
      detail: text(get(item, :detail), @max_text)
    }
  end

  defp waiver(nil, _eligibility, _record), do: nil

  defp waiver(%{} = waiver, %Eligibility{waiver: evaluated}, record) do
    {applies, ignored_because} =
      case evaluated do
        %{} = evaluated ->
          {get(evaluated, :applies) == true, evaluated |> get(:ignored_because) |> atom_text()}

        _not_evaluated ->
          {nil, nil}
      end

    %{
      head_sha: text(get(waiver, :head_sha), @max_short),
      current: get(waiver, :head_sha) == record.head_sha,
      codes: waiver |> get(:codes) |> list() |> Enum.map(&text(&1, @max_short)),
      policy_version: text(get(waiver, :policy_version), @max_short),
      reason: text(get(waiver, :reason), @max_reason),
      waived_by: text(get(waiver, :waived_by), @max_path),
      waived_at: integer_or_nil(get(waiver, :waived_at)),
      applies: applies,
      ignored_because: ignored_because
    }
  end

  defp waiver(_other, _eligibility, _record), do: nil

  defp report(nil, _risk, _record), do: nil

  defp report(%{} = report, risk, record) do
    head = get(report, :head_sha)
    current? = head == record.head_sha

    risk_digest = if is_map(risk), do: get(risk, :digest)

    %{
      head_sha: text(head, @max_short),
      digest: text(get(report, :digest), @max_short),
      status: text(get(report, :status), @max_short),
      reason: text(get(report, :reason), @max_short),
      comment_url: text(get(report, :comment_url), @max_reason),
      superseded: text(get(report, :superseded), @max_short),
      recorded_at: integer_or_nil(get(report, :recorded_at)),
      current: current?,
      stale: not current? or get(report, :digest) != risk_digest
    }
  end

  defp report(_other, _risk, _record), do: nil

  defp delivery_issue(%{} = issue),
    do: %{
      stage: text(get(issue, :stage), @max_short),
      reason: text(get(issue, :reason), @max_text),
      failed_at: integer_or_nil(get(issue, :failed_at))
    }

  defp delivery_issue(_other), do: nil

  # `current` is whether the block is for the PR's head; `stale` is its negation.
  defp head_labels(head, record) do
    current? = is_binary(head) and head == record.head_sha
    %{head_sha: text(head, @max_short), current: current?, stale: not current?}
  end

  # -- run fixes and agent review (E9) -----------------------------------------------

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

  # -- bounded, scrubbed values -----------------------------------------------------

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_other), do: []

  defp atom_text(nil), do: nil
  defp atom_text(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_text(value), do: value

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_other), do: nil

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_other), do: nil

  # Untrusted text: invalid UTF-8 and C0/C1 control characters (newline and tab included) are
  # replaced by a space, the result is trimmed and cut at `max` characters. `nil` for anything
  # that is not text or is empty after the scrub.
  @spec text(term(), pos_integer()) :: String.t() | nil
  defp text(value, max) when is_binary(value) do
    scrubbed =
      for(<<char::utf8 <- String.replace_invalid(value, " ")>>, into: "") do
        if char < 0x20 or (char >= 0x7F and char <= 0x9F), do: " ", else: <<char::utf8>>
      end

    case scrubbed |> String.trim() |> String.slice(0, max) do
      "" -> nil
      cut -> cut
    end
  end

  defp text(_other, _max), do: nil

  defp bounded_inspect(term),
    do: term |> inspect(limit: 5, printable_limit: 80) |> text(@max_text)

  defimpl Jason.Encoder do
    def encode(dto, opts) do
      dto
      |> Map.from_struct()
      |> Map.reject(fn {key, value} -> key == :merge_gate and is_nil(value) end)
      |> Jason.Encode.map(opts)
    end
  end
end
