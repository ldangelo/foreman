defmodule ForemanServer.PrEvidence.Reason do
  @moduledoc """
  One reason a PR is not eligible: `code` (one closed set: `no_checks_configured`, `missing`,
  `failing`, `pending`, `stale`, `skipped`, `other_sha`, `checks_truncated`, `findings_absent`,
  `findings_malformed`, `findings_legacy_format`, `findings_other_sha`, `risk_missing`,
  `risk_other_sha`, `evidence_unreadable`), `subject` (the check it is about or `nil`) and
  `detail` (a string or `nil`).
  """

  @derive Jason.Encoder
  defstruct [:code, :subject, :detail]

  @type t :: %__MODULE__{
          code: atom(),
          subject: String.t() | nil,
          detail: String.t() | nil
        }
end

defmodule ForemanServer.PrEvidence.Eligibility do
  @moduledoc """
  The result of `ForemanServer.PrEvidence.evaluate/2`. `inputs` has eight keys
  (`checks_head_sha`, `checks_observed_at`, `evidence_digest`, `checks_ref`, `findings_head_sha`,
  `findings_digest`, `risk_head_sha`, `risk_digest`); `evaluated_at` is the `now_ms` of the
  decision and no reason depends on it.
  """

  alias ForemanServer.PrEvidence.Reason

  @derive Jason.Encoder
  defstruct [
    :head_sha,
    :status,
    :policy_version,
    :inputs,
    :evaluated_at,
    :waiver,
    reasons: [],
    waived: []
  ]

  @type status :: :off | :eligible | :ineligible | :waived | :unknown
  @type t :: %__MODULE__{
          head_sha: String.t() | nil,
          status: status(),
          reasons: [Reason.t()],
          waived: [Reason.t()],
          waiver: map() | nil,
          policy_version: String.t() | nil,
          inputs: %{atom() => term()},
          evaluated_at: integer() | nil
        }
end

defmodule ForemanServer.PrEvidence do
  @moduledoc """
  The `evidence` sub-record of a watched PR and the one fold that maintains it.

  `Aggregates.Run.PrWatch.apply_event/3` (the aggregate) and `ForemanServer.PrWatchFold`
  (the projection) both call `apply_event/3` first, so the two records cannot disagree.
  The record is a map with the keys `checks`, `waiver`, `delivery_issue`, `findings`, `risk`
  and `report`.

    * `checks` - `%{head_sha, items, truncated, observed_at, digest, evidence_digest,
      observation_ref, required, policy_version}`, stored for a `PrChecksChanged` whose `checks`
      is a list and left as it was for one that has none or a non-list.
    * `waiver` - `%{head_sha, codes, policy_version, reason, waived_by, waived_at}`, `codes` a
      sorted, de-duplicated list of strings; set by `PrEvidenceWaived` and replacing any earlier one.
    * `risk` - `%{head_sha, level, rubric_version, digest, findings_digest, seq, recorded_at}`,
      set by `PrRiskRecorded` (TRD-018) with the head it was classified for; a head move keeps it.
    * `report` - `%{head_sha, digest, status, reason, detail, comment_id, comment_url,
      superseded, recorded_at}`, set by `PrCommentPublished` (TRD-021) with the head and digest
      of the risk record the report was rendered from; a head move keeps it, so after a push the
      old report reads as for another head until the new one is published. Nothing in the
      evaluation reads it: the merge gate does not depend on the comment.

  Head reset: of the PR events only `PrUpdated`, `PrReady`, `PrChecksChanged` and
  `PrReviewChanged` carry a head. When one brings a `head_sha` different from the record's
  non-nil one, the current-head observation (`checks_state`, `checks_digest`, `review_decision`,
  `review_digest`, and `failing` where the record has it) is reset first, and the waiver is
  voided unless it is for the head the event brings. The evidence records stay, each with the
  `head_sha` it was recorded for: readers compare that head with the head being decided.

  Never raises: this runs inside `ProjectionStore.init/1`'s replay. Payload keys are read as
  atoms (live) or strings (replayed).
  """

  alias ForemanServer.PrEvidence.{Eligibility, Reason}
  alias ForemanServer.{ProjectionStore, ProjectSettings}

  @head_events ~w(PrUpdated PrReady PrChecksChanged PrReviewChanged)
  @events @head_events ++
            [
              "PrEvidenceWaived",
              "PrReadyFailed",
              "ReviewFindingsRecorded",
              "PrRiskRecorded",
              "PrCommentPublished"
            ]

  @max_checks 100
  @max_required 20
  @max_text 200

  @kinds ~w(check_run status_context)
  @states ~w(passing failing pending)

  @observation_resets [
    checks_state: nil,
    checks_digest: nil,
    review_decision: nil,
    review_digest: nil,
    failing: []
  ]

  @type t :: %{
          checks: map() | nil,
          waiver: map() | nil,
          delivery_issue: map() | nil,
          findings: map() | nil,
          risk: map() | nil,
          report: map() | nil
        }

  @doc "Event types this fold consumes."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The empty evidence record."
  @spec empty() :: t()
  def empty,
    do: %{checks: nil, waiver: nil, delivery_issue: nil, findings: nil, risk: nil, report: nil}

  @doc """
  Fold one event into a watch `record` (aggregate or projection): the head reset, then the
  evidence the event carries. Any other event, or a malformed payload, returns `record`
  with at least an `evidence` key.
  """
  @spec apply_event(map(), String.t(), term()) :: map()
  def apply_event(record, type, payload) when is_map(record) and is_map(payload) do
    record = Map.put(record, :evidence, Map.merge(empty(), evidence_of(record)))

    record
    |> reset_on_head_move(type, payload)
    |> apply_evidence(type, payload)
  end

  def apply_event(record, _type, _payload) when is_map(record),
    do: Map.put(record, :evidence, Map.merge(empty(), evidence_of(record)))

  defp evidence_of(%{evidence: %{} = evidence}), do: evidence
  defp evidence_of(_record), do: %{}

  # -- head reset --------------------------------------------------------------

  defp reset_on_head_move(record, type, payload) when type in @head_events do
    head = get(payload, :head_sha)
    current = Map.get(record, :head_sha)

    if present?(head) and present?(current) and head != current do
      record
      |> reset_observation()
      |> void_waiver_unless_for(head)
    else
      record
    end
  end

  defp reset_on_head_move(record, _type, _payload), do: record

  defp reset_observation(record) do
    Enum.reduce(@observation_resets, record, fn {key, empty}, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, empty), else: acc
    end)
  end

  defp void_waiver_unless_for(record, head) do
    case record.evidence.waiver do
      %{head_sha: ^head} -> record
      _other -> put_evidence(record, :waiver, nil)
    end
  end

  # -- evidence ----------------------------------------------------------------

  defp apply_evidence(record, "PrChecksChanged", payload) do
    case get(payload, :checks) do
      items when is_list(items) ->
        put_evidence(record, :checks, %{
          head_sha: get(payload, :head_sha),
          items: items,
          truncated: get(payload, :checks_truncated) == true,
          observed_at: get(payload, :observed_at),
          digest: get(payload, :digest),
          evidence_digest: get(payload, :evidence_digest),
          observation_ref: get(payload, :observation_ref),
          required: get(payload, :required),
          policy_version: get(payload, :policy_version)
        })

      _none_or_not_a_list ->
        record
    end
  end

  defp apply_evidence(record, "PrEvidenceWaived", payload) do
    put_evidence(record, :waiver, %{
      head_sha: get(payload, :head_sha),
      codes: codes(get(payload, :reasons)),
      policy_version: get(payload, :policy_version),
      reason: get(payload, :reason),
      waived_by: get(payload, :approver_identity),
      waived_at: get(payload, :waived_at)
    })
  end

  # A failed ready signal is a recorded condition (TRD-033); the next successful `PrReady`
  # for the PR clears it.
  defp apply_evidence(record, "PrReadyFailed", payload) do
    put_evidence(record, :delivery_issue, %{
      stage: get(payload, :stage),
      reason: get(payload, :reason),
      failed_at: get(payload, :failed_at)
    })
  end

  defp apply_evidence(record, "PrReady", _payload), do: put_evidence(record, :delivery_issue, nil)

  # TRD-015: the review findings recorded for the reviewed head. Kept with ITS OWN head, so a
  # head move neither voids it nor changes what an absent or malformed record reads as.
  defp apply_evidence(record, "ReviewFindingsRecorded", payload) do
    put_evidence(record, :findings, %{
      head_sha: get(payload, :head_sha),
      status: get(payload, :status),
      findings: list_or_empty(get(payload, :findings)),
      defect: get(payload, :defect),
      defect_detail: get(payload, :defect_detail),
      judgement: normalise_judgement(get(payload, :judgement)),
      artifact_path: get(payload, :artifact_path),
      artifact_sha256: get(payload, :artifact_sha256),
      digest: get(payload, :digest),
      recorded_at: get(payload, :recorded_at)
    })
  end

  # TRD-018: the risk record of the head it was classified for. Kept with ITS OWN head, like the
  # findings, so a head move neither voids it nor lets it read as the new head's. Only what a
  # reader compares is kept (the head, the two digests, the version, the level); the full
  # record is in the event.
  defp apply_evidence(record, "PrRiskRecorded", payload) do
    put_evidence(record, :risk, %{
      head_sha: get(payload, :head_sha),
      level: get(payload, :level),
      rubric_version: get(payload, :rubric_version),
      digest: get(payload, :digest),
      findings_digest: get(payload, :findings_digest),
      seq: get(payload, :seq),
      recorded_at: get(payload, :recorded_at)
    })
  end

  # TRD-021: the outcome of publishing the report of one risk record. Kept with ITS OWN head
  # and digest, like the risk record, and replaced by each later outcome (a refused attempt
  # after a published one for the same head shows the refusal).
  defp apply_evidence(record, "PrCommentPublished", payload) do
    put_evidence(record, :report, %{
      head_sha: get(payload, :head_sha),
      digest: get(payload, :digest),
      status: get(payload, :status),
      reason: get(payload, :reason),
      detail: get(payload, :detail),
      comment_id: get(payload, :comment_id),
      comment_url: get(payload, :comment_url),
      superseded: get(payload, :superseded),
      recorded_at: get(payload, :recorded_at)
    })
  end

  defp apply_evidence(record, _type, _payload), do: record

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_other), do: []

  defp put_evidence(record, key, value),
    do: %{record | evidence: Map.put(record.evidence, key, value)}

  defp codes(reasons) when is_list(reasons),
    do: reasons |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp codes(_other), do: []

  # -- evaluation ---------------------------------------------------------------

  @input_keys ~w(checks_head_sha checks_observed_at evidence_digest checks_ref findings_head_sha
                 findings_digest risk_head_sha risk_digest)a

  @waivable ~w(no_checks_configured missing skipped findings_absent findings_legacy_format
               findings_other_sha)a

  @doc """
  The reason codes an operator may waive (§11), as the strings the `PrEvidenceWaived` event
  carries. Every other code (a failure, a pending or stale check, a check of another head, a
  truncated list, a malformed findings block, risk, an unreadable record) is never waivable.
  """
  @spec waivable_codes() :: [String.t()]
  def waivable_codes, do: Enum.map(@waivable, &Atom.to_string/1)

  @type ctx :: %{
          head_sha: String.t() | nil,
          policy: %{required: [map()], version: String.t() | nil} | nil,
          now_ms: integer() | nil,
          checks_ref: String.t() | nil
        }

  @doc """
  The eligibility of the PR `record` for the decision `ctx`
  (`%{head_sha, policy: %{required, version} | nil, now_ms, checks_ref}`). Pure: it reads
  neither the clock, the store nor the application environment, so the gateway, the status
  read and the tests call the same code.

  `status` is `:off` when `ctx.policy` is `nil` (decided before anything is read), `:unknown`
  when the record cannot be read (the one reason `evidence_unreadable`, never waivable),
  `:eligible` when no reason remains, `:waived` when every reason is waivable and covered by
  an applying waiver, else `:ineligible` with the uncovered reasons in `reasons` and the
  covered ones in `waived`.

  A waiver applies only when its `head_sha` equals `ctx.head_sha` and its `policy_version`
  equals the version of `ctx.policy`; `waiver` in the result names it as
  `%{head_sha, codes, policy_version, applies, ignored_because}` (`ignored_because` is
  `:other_head` or `:policy_changed`), `nil` when there is none or the status is `:off` or
  `:unknown`. A `nil` `checks_ref` is a display read: freshness is not judged and age is never
  a reason.

  With a non-nil policy and no `checks` record at all, a decision (`checks_ref` non-nil)
  reads as the one reason `stale` (no observation is recorded for it) and a display read
  (`checks_ref: nil`) as one `missing` per required entry. `stale` is never waivable; the gate
  forces an observation before it decides (TRD-022), so a decision normally finds a record.
  """
  @spec evaluate(map() | nil, ctx()) :: Eligibility.t()
  def evaluate(record, ctx) do
    ctx = normalise_ctx(ctx)

    case evaluate_checks(record, ctx) do
      {:off, _reasons} ->
        eligibility(ctx, :off, [], [], nil, inputs_for(nil, ctx))

      {:unknown, reasons} ->
        eligibility(ctx, :unknown, reasons, [], nil, inputs_for(record, ctx))

      {_status, reasons} ->
        reasons = reasons ++ findings_reasons(record, ctx) ++ risk_reasons(record, ctx)
        waiver = waiver_state(record, ctx)
        {status, uncovered, covered} = apply_waiver(reasons, waiver)
        eligibility(ctx, status, uncovered, covered, waiver, inputs_for(record, ctx))
    end
  end

  @doc """
  The check part of `evaluate/2` alone: no waiver is read. Returns the status
  (`:off | :eligible | :ineligible | :unknown`) with its reasons.
  """
  @spec evaluate_checks(map() | nil, ctx()) ::
          {:off | :eligible | :ineligible | :unknown, [Reason.t()]}
  def evaluate_checks(record, ctx) do
    ctx = normalise_ctx(ctx)

    case ctx.policy do
      nil ->
        {:off, []}

      policy ->
        case readable(record, policy) do
          {:ok, checks} ->
            case check_reasons(checks, policy, ctx) do
              [] -> {:eligible, []}
              reasons -> {:ineligible, reasons}
            end

          {:error, detail} ->
            {:unknown, [%Reason{code: :evidence_unreadable, subject: nil, detail: detail}]}
        end
    end
  end

  @doc """
  The policy version for a `required` list: the first 16 hex characters of the SHA-256 of the
  entries in a canonical (normalised, sorted) form; `nil` only when the gate is off.
  """
  @spec policy_version([map()] | nil) :: String.t() | nil
  def policy_version(nil), do: nil

  def policy_version(required) when is_list(required) do
    canonical =
      required
      |> Enum.map(fn entry ->
        {text_or_nil(get(entry, :name)), text_or_nil(get(entry, :kind)),
         text_or_nil(get(entry, :workflow)), get(entry, :allow_skipped) == true}
      end)
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({:required_checks, canonical}, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  The policy of `project_id` as it stands now, read from the projection like
  `PrWatcher.AutoFix.settings/1`: `{:ok, %{required, version}}` (`required: []` is the gate
  on with no checks), `{:ok, nil}` when the setting is `nil` (gate off), and
  `{:error, {:policy_unavailable, reason}}` for a project the projection does not know or a
  projection that does not answer. Callers must not read the error as gate off.

  `reader` is the projection read (`project_id -> map() | nil`); the default is the real
  `ProjectionStore.project_projection/1`. An exit of the reader (a call that times out, a
  store that is down) is the `{:exit, reason}` error.
  """
  @spec project_policy(String.t() | nil, (String.t() -> map() | nil)) ::
          {:ok, %{required: [map()], version: String.t()} | nil}
          | {:error, {:policy_unavailable, term()}}
  def project_policy(project_id, reader \\ &ProjectionStore.project_projection/1)

  def project_policy(project_id, reader)
      when is_binary(project_id) and project_id != "" and is_function(reader, 1) do
    case reader.(project_id) do
      nil ->
        {:error, {:policy_unavailable, :project_not_found}}

      %{} = project ->
        case ProjectSettings.from_config(Map.get(project, :config)).required_checks do
          nil ->
            {:ok, nil}

          required when is_list(required) ->
            {:ok, %{required: required, version: policy_version(required)}}

          other ->
            {:error, {:policy_unavailable, {:invalid_required_checks, other}}}
        end

      other ->
        {:error, {:policy_unavailable, {:invalid_projection, other}}}
    end
  catch
    :exit, reason -> {:error, {:policy_unavailable, {:exit, reason}}}
  end

  def project_policy(project_id, _reader),
    do: {:error, {:policy_unavailable, {:invalid_project_id, project_id}}}

  defp normalise_ctx(%{} = ctx) do
    %{
      head_sha: get(ctx, :head_sha),
      policy: get(ctx, :policy),
      now_ms: get(ctx, :now_ms),
      checks_ref: get(ctx, :checks_ref)
    }
  end

  defp normalise_ctx(_other), do: %{head_sha: nil, policy: nil, now_ms: nil, checks_ref: nil}

  defp eligibility(ctx, status, reasons, waived, waiver, inputs) do
    %Eligibility{
      head_sha: ctx.head_sha,
      status: status,
      reasons: reasons,
      waived: waived,
      waiver: waiver,
      policy_version: if(is_map(ctx.policy), do: get(ctx.policy, :version)),
      inputs: inputs,
      evaluated_at: ctx.now_ms
    }
  end

  # -- risk reasons (TRD-018) -----------------------------------------------------

  # No risk record is `risk_missing`; a record for another head than the one decided is
  # `risk_other_sha`. Neither is waivable: a waiver covers a check or a review gap, never the
  # absence of the classification the approver reads.
  defp risk_reasons(record, ctx) do
    case record |> evidence_of() |> Map.get(:risk) do
      nil ->
        [%Reason{code: :risk_missing, subject: nil, detail: "no risk record for the PR"}]

      %{} = risk ->
        head = get(risk, :head_sha)

        if head == ctx.head_sha,
          do: [],
          else: [
            %Reason{
              code: :risk_other_sha,
              subject: nil,
              detail: "risk recorded for #{inspect(head)}, decided #{inspect(ctx.head_sha)}"
            }
          ]
    end
  end

  # -- findings reasons (TRD-015) ---------------------------------------------------

  # No record or `absent` is `findings_absent`; `malformed` is `findings_legacy_format` for the
  # defect `legacy_format` and `findings_malformed` otherwise, whatever head it was made for;
  # `recorded` for another head than the one decided is `findings_other_sha`.
  defp findings_reasons(record, ctx) do
    findings = record |> evidence_of() |> Map.get(:findings)

    case findings do
      nil ->
        [%Reason{code: :findings_absent, subject: nil, detail: "no review findings recorded"}]

      %{} = findings ->
        findings_reasons_for(get(findings, :status), findings, ctx)
    end
  end

  defp findings_reasons_for("absent", findings, _ctx),
    do: [
      %Reason{
        code: :findings_absent,
        subject: nil,
        detail: text_or_nil(get(findings, :defect_detail)) || "no review findings block"
      }
    ]

  defp findings_reasons_for("malformed", findings, _ctx) do
    code =
      if get(findings, :defect) == "legacy_format",
        do: :findings_legacy_format,
        else: :findings_malformed

    [%Reason{code: code, subject: nil, detail: text_or_nil(get(findings, :defect_detail))}]
  end

  defp findings_reasons_for("recorded", findings, ctx) do
    head = get(findings, :head_sha)

    if head == ctx.head_sha,
      do: [],
      else: [
        %Reason{
          code: :findings_other_sha,
          subject: nil,
          detail: "findings recorded for #{inspect(head)}, decided #{inspect(ctx.head_sha)}"
        }
      ]
  end

  # A status outside the closed set cannot be trusted as a clean review.
  defp findings_reasons_for(_status, _findings, _ctx),
    do: [
      %Reason{
        code: :findings_malformed,
        subject: nil,
        detail: "the findings record has no usable status"
      }
    ]

  # -- reading the record --------------------------------------------------------

  defp readable(record, policy) do
    with {:ok, evidence} <- evidence_map(record),
         :ok <- readable_required(get(policy, :required)),
         {:ok, checks} <- readable_checks(Map.get(evidence, :checks)),
         :ok <- readable_optional(Map.get(evidence, :findings), "findings"),
         :ok <- readable_optional(Map.get(evidence, :risk), "risk"),
         :ok <- readable_optional(Map.get(evidence, :waiver), "waiver") do
      {:ok, checks}
    end
  end

  defp evidence_map(%{evidence: %{} = evidence}), do: {:ok, evidence}
  defp evidence_map(%{evidence: nil}), do: {:ok, %{}}
  defp evidence_map(%{evidence: _other}), do: {:error, "evidence is not a map"}
  defp evidence_map(%{}), do: {:ok, %{}}
  defp evidence_map(_other), do: {:error, "record is not a map"}

  defp readable_required(required) when is_list(required) do
    if Enum.all?(
         required,
         &(is_map(&1) and is_binary(get(&1, :name)) and is_binary(get(&1, :kind)))
       ),
       do: :ok,
       else: {:error, "required entry has no name or kind"}
  end

  defp readable_required(_other), do: {:error, "required is not a list"}

  defp readable_checks(nil), do: {:ok, nil}

  defp readable_checks(%{} = checks) do
    case Map.get(checks, :items) do
      items when is_list(items) ->
        if Enum.all?(items, &(is_map(&1) and is_binary(get(&1, :name)))),
          do: {:ok, checks},
          else: {:error, "a check has no name"}

      _other ->
        {:error, "checks.items is not a list"}
    end
  end

  defp readable_checks(_other), do: {:error, "checks is not a map"}

  defp readable_optional(nil, _name), do: :ok
  defp readable_optional(%{}, _name), do: :ok
  defp readable_optional(_other, name), do: {:error, "#{name} is not a map"}

  # -- check reasons -------------------------------------------------------------

  defp check_reasons(checks, policy, ctx) do
    case get(policy, :required) do
      [] -> [%Reason{code: :no_checks_configured, subject: nil, detail: nil}]
      required -> required_reasons(checks, required, ctx)
    end
  end

  defp required_reasons(checks, required, ctx) do
    cond do
      is_nil(checks) and not is_nil(ctx.checks_ref) ->
        [stale_reason("no observation is recorded for the decision")]

      is_nil(checks) ->
        Enum.map(required, &missing_reason/1)

      get(checks, :head_sha) != ctx.head_sha ->
        [
          %Reason{
            code: :other_sha,
            subject: nil,
            detail:
              "checks recorded for #{inspect(get(checks, :head_sha))}, decided #{inspect(ctx.head_sha)}"
          }
        ]

      not is_nil(ctx.checks_ref) and get(checks, :observation_ref) != ctx.checks_ref ->
        [stale_reason("the decision observation is not the recorded one")]

      true ->
        Enum.flat_map(required, &entry_reasons(&1, checks))
    end
  end

  defp entry_reasons(entry, checks) do
    name = get(entry, :name)
    matches = Enum.filter(get(checks, :items), &matches?(&1, entry))

    cond do
      matches == [] and get(checks, :truncated) == true ->
        [
          %Reason{
            code: :checks_truncated,
            subject: name,
            detail: "the rollup was cut and the check is not among the kept items"
          }
        ]

      matches == [] ->
        [missing_reason(entry)]

      true ->
        entry_state(name, matches, get(entry, :allow_skipped) == true)
    end
  end

  defp entry_state(name, matches, allow_skipped) do
    cond do
      Enum.any?(matches, &(conclusion(&1) == "STALE")) ->
        [%Reason{code: :stale, subject: name, detail: "conclusion STALE"}]

      Enum.any?(matches, &(get(&1, :state) in ["failing", :failing])) ->
        [%Reason{code: :failing, subject: name, detail: failing_detail(matches)}]

      Enum.any?(matches, &(get(&1, :state) in ["pending", :pending])) ->
        [%Reason{code: :pending, subject: name, detail: nil}]

      not allow_skipped and Enum.any?(matches, &skipped?/1) ->
        [%Reason{code: :skipped, subject: name, detail: skipped_detail(matches)}]

      true ->
        []
    end
  end

  defp matches?(item, entry) do
    get(item, :name) == get(entry, :name) and get(item, :kind) == get(entry, :kind) and
      (not is_binary(get(entry, :workflow)) or get(item, :workflow) == get(entry, :workflow))
  end

  defp skipped?(item),
    do: get(item, :kind) == "check_run" and conclusion(item) in ["SKIPPED", "NEUTRAL"]

  defp conclusion(item) do
    case get(item, :conclusion) do
      value when is_binary(value) -> String.upcase(value)
      _other -> nil
    end
  end

  defp failing_detail(matches) do
    matches
    |> Enum.find(&(get(&1, :state) in ["failing", :failing]))
    |> get(:conclusion)
    |> text_or_nil()
  end

  defp skipped_detail(matches),
    do: matches |> Enum.find(&skipped?/1) |> get(:conclusion) |> text_or_nil()

  defp missing_reason(entry), do: %Reason{code: :missing, subject: get(entry, :name), detail: nil}

  defp stale_reason(detail), do: %Reason{code: :stale, subject: nil, detail: detail}

  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_other), do: nil

  # -- waiver --------------------------------------------------------------------

  defp waiver_state(record, ctx) do
    case record |> evidence_of() |> Map.get(:waiver) do
      %{} = waiver ->
        head = get(waiver, :head_sha)
        version = get(waiver, :policy_version)
        codes = waiver |> get(:codes) |> List.wrap() |> Enum.filter(&is_binary/1)

        ignored =
          cond do
            head != ctx.head_sha -> :other_head
            version != get(ctx.policy, :version) -> :policy_changed
            true -> nil
          end

        %{
          head_sha: head,
          codes: codes,
          policy_version: version,
          applies: is_nil(ignored),
          ignored_because: ignored
        }

      _none ->
        nil
    end
  end

  defp apply_waiver(reasons, %{applies: true, codes: codes}) do
    {covered, uncovered} =
      Enum.split_with(reasons, &(&1.code in @waivable and Atom.to_string(&1.code) in codes))

    status =
      if uncovered == [], do: if(covered == [], do: :eligible, else: :waived), else: :ineligible

    {status, uncovered, covered}
  end

  defp apply_waiver(reasons, _waiver),
    do: {if(reasons == [], do: :eligible, else: :ineligible), reasons, []}

  # -- inputs --------------------------------------------------------------------

  defp inputs_for(_record, %{policy: nil}), do: Map.new(@input_keys, &{&1, nil})

  defp inputs_for(record, ctx) do
    evidence = evidence_of(record)
    checks = Map.get(evidence, :checks)
    findings = Map.get(evidence, :findings)
    risk = Map.get(evidence, :risk)

    %{
      checks_head_sha: get(checks, :head_sha),
      checks_observed_at: get(checks, :observed_at),
      evidence_digest: get(checks, :evidence_digest),
      checks_ref: ctx.checks_ref,
      findings_head_sha: get(findings, :head_sha),
      findings_digest: get(findings, :digest),
      risk_head_sha: get(risk, :head_sha),
      risk_digest: get(risk, :digest)
    }
  end

  # -- command validation (shared with the handlers that record evidence) -------

  @doc """
  Validate and normalise the `checks` of a `run.pr.checks` command: a list of at most 100
  items, each a string-keyed map with `name`, `kind` (`check_run | status_context`), `state`
  (`passing | failing | pending`), `conclusion`, `workflow`, `started_at`, `completed_at`, text
  bounded. Atom or string keys and atom or string `kind`/`state` are accepted; the result is
  one string-keyed form, so the live and the replayed fold read identical values.
  """
  @spec validate_checks(term()) :: {:ok, [map()]} | :error
  def validate_checks(checks) when is_list(checks) and length(checks) <= @max_checks do
    each_ok(checks, &check/1)
  end

  def validate_checks(_other), do: :error

  @doc """
  Validate `required`: `nil` or a list of at most 20 entries, each a map with a `name` and a
  `kind`; returned string-keyed with the text bounded.
  """
  @spec validate_required(term()) :: {:ok, [map()] | nil} | :error
  def validate_required(nil), do: {:ok, nil}

  def validate_required(required) when is_list(required) and length(required) <= @max_required do
    each_ok(required, fn entry ->
      with true <- is_map(entry),
           {:ok, name} <- text(get(entry, :name), required: true),
           {:ok, kind} <- text(get(entry, :kind), required: true) do
        {:ok, %{"name" => name, "kind" => kind}}
      else
        _ -> :error
      end
    end)
  end

  def validate_required(_other), do: :error

  @doc """
  Validate the `required` list of the policy snapshot a `run.pr.risk` carries: the same bounds
  as `validate_required/1`, but each entry keeps its `workflow` and a true `allow_skipped`,
  because `evaluate_checks/2` reads them (the `required` of `PrChecksChanged` is display only
  and drops both, which would make a check of another workflow satisfy an entry). `nil` is the
  gate off. String-keyed result.
  """
  @spec validate_policy_required(term()) :: {:ok, [map()] | nil} | :error
  def validate_policy_required(nil), do: {:ok, nil}

  def validate_policy_required(required)
      when is_list(required) and length(required) <= @max_required do
    each_ok(required, fn entry ->
      with true <- is_map(entry),
           {:ok, name} <- text(get(entry, :name), required: true),
           {:ok, kind} <- text(get(entry, :kind), required: true),
           {:ok, workflow} <- text(get(entry, :workflow), required: false),
           true <- get(entry, :allow_skipped) in [nil, true, false] do
        {:ok,
         %{"name" => name, "kind" => kind}
         |> put_if("workflow", workflow)
         |> put_if("allow_skipped", if(get(entry, :allow_skipped) == true, do: true))}
      else
        _ -> :error
      end
    end)
  end

  def validate_policy_required(_other), do: :error

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @findings_statuses ~w(recorded absent malformed)
  @findings_defects ~w(unterminated_block multiple_blocks legacy_format invalid_json unknown_schema
                       invalid_field too_large too_many_findings unreadable)
  @findings_severities ~w(critical major minor nitpick)
  @findings_dispositions ~w(fixed declined open)
  @max_findings 100
  @max_finding_description 1000
  @max_finding_path 1024
  @max_finding_source 64
  @max_defect_detail 500

  @doc "The closed `status` set of a findings record."
  @spec findings_statuses() :: [String.t()]
  def findings_statuses, do: @findings_statuses

  @doc "The closed `defect` set of a malformed findings record (TRD-013's reasons and `unreadable`)."
  @spec findings_defects() :: [String.t()]
  def findings_defects, do: @findings_defects

  @doc """
  Validate and normalise one findings record: `status` one of `findings_statuses/0` (atom or
  string), `findings` a list of at most 100 findings for `recorded` and empty (or `nil`) for the
  others, `defect` `nil` unless `malformed` (then one of `findings_defects/0`) and
  `defect_detail` at most 500 characters. Every finding is returned as one string-keyed map
  (`severity`, `path`, `line`, `description`, `disposition`, `source`) so the live and the
  replayed fold read identical values. Values over their bound are refused, never cut.
  """
  @spec validate_findings(term(), term(), term(), term()) ::
          {:ok,
           %{
             status: String.t(),
             findings: [map()],
             defect: String.t() | nil,
             defect_detail: String.t() | nil
           }}
          | {:error, atom()}
  def validate_findings(status, findings, defect, defect_detail) do
    with {:ok, status} <- string_enum(status, @findings_statuses, :status),
         {:ok, findings} <- findings_list(status, findings),
         {:ok, defect} <- findings_defect(status, defect),
         {:ok, detail} <- findings_detail(status, defect_detail) do
      {:ok, %{status: status, findings: findings, defect: defect, defect_detail: detail}}
    end
  end

  # A clean review has nothing to explain; `absent` and `malformed` carry the text the operator
  # reads (TRD-015: "an absent or malformed record carries its defect text").
  defp findings_detail("recorded", nil), do: {:ok, nil}
  defp findings_detail("recorded", _detail), do: {:error, :defect_detail}

  defp findings_detail(_status, detail),
    do: optional_bounded(detail, @max_defect_detail, :defect_detail)

  @doc """
  The digest of a findings record: the first 16 hex characters of the SHA-256 of the normalised
  `status`, `defect`, `findings` and `judgement` (TRD-041; an absent judgement is `nil` in the
  digest, so a record with no judgement keeps the digest it had before the field existed).
  Derived by the handler,
  never read from a payload.
  """
  @spec findings_digest(map()) :: String.t()
  def findings_digest(%{} = normalised) do
    term = {
      :review_findings,
      get(normalised, :status),
      get(normalised, :defect),
      get(normalised, :findings),
      digest_judgement(get(normalised, :judgement))
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp digest_judgement(nil), do: nil

  defp digest_judgement(judgement) do
    case normalise_judgement(judgement) do
      %{status: "absent"} -> nil
      normalised -> normalised
    end
  end

  @judgement_levels ~w(LOW MEDIUM HIGH)
  @max_rationale 1000
  @judgement_keys ~w(status level rationale defect defect_detail)a

  @doc """
  Validate and normalise the review agent's risk judgement (TRD-041) carried by a findings
  record. `nil` is the absent judgement. Otherwise one map (atom or string keys, no other key)
  with `status` one of `findings_statuses/0`: `recorded` needs a `level` (`LOW`, `MEDIUM` or
  `HIGH`) and a non-empty `rationale` of at most 1000 characters; `malformed` needs a `defect`
  (one of `findings_defects/0`) and may carry a `defect_detail` of at most 500 characters;
  `absent` carries nothing else. The result is always the atom-keyed map `status`, `level`,
  `rationale`, `defect`, `defect_detail`, so the live and the replayed fold read identical
  values. Values over their bound are refused, never cut.
  """
  @spec validate_judgement(term()) :: {:ok, map()} | {:error, :judgement}
  def validate_judgement(nil), do: {:ok, absent_judgement()}

  def validate_judgement(%{} = raw) do
    known = @judgement_keys ++ Enum.map(@judgement_keys, &Atom.to_string/1)

    with true <- Enum.all?(Map.keys(raw), &(&1 in known)),
         {:ok, status} <- string_enum(get(raw, :status), @findings_statuses, :judgement),
         {:ok, normalised} <- judgement_for(status, raw) do
      {:ok, normalised}
    else
      _ -> {:error, :judgement}
    end
  end

  def validate_judgement(_other), do: {:error, :judgement}

  @doc """
  The judgement of a findings record as the fold stores it: `validate_judgement/1`'s result, or
  the absent judgement when there is none or it does not validate (an event written before
  TRD-041 has no judgement and reads as absent).
  """
  @spec normalise_judgement(term()) :: map()
  def normalise_judgement(raw) do
    case validate_judgement(raw) do
      {:ok, normalised} -> normalised
      {:error, _} -> absent_judgement()
    end
  end

  defp absent_judgement,
    do: %{status: "absent", level: nil, rationale: nil, defect: nil, defect_detail: nil}

  defp judgement_for("absent", raw) do
    if Enum.all?([:level, :rationale, :defect, :defect_detail], &is_nil(get(raw, &1))),
      do: {:ok, absent_judgement()},
      else: {:error, :judgement}
  end

  defp judgement_for("recorded", raw) do
    level = get(raw, :level)
    rationale = get(raw, :rationale)

    if level in @judgement_levels and is_binary(rationale) and String.valid?(rationale) and
         String.trim(rationale) != "" and String.length(rationale) <= @max_rationale and
         not Regex.match?(~r/[\x00-\x08\x0B-\x1F\x7F]/u, rationale) and
         is_nil(get(raw, :defect)) and is_nil(get(raw, :defect_detail)),
       do: {:ok, %{absent_judgement() | status: "recorded", level: level, rationale: rationale}},
       else: {:error, :judgement}
  end

  defp judgement_for("malformed", raw) do
    with true <- is_nil(get(raw, :level)) and is_nil(get(raw, :rationale)),
         {:ok, defect} <- string_enum(get(raw, :defect), @findings_defects, :judgement),
         {:ok, detail} <-
           optional_bounded(get(raw, :defect_detail), @max_defect_detail, :judgement) do
      {:ok, %{absent_judgement() | status: "malformed", defect: defect, defect_detail: detail}}
    else
      _ -> {:error, :judgement}
    end
  end

  defp findings_list("recorded", items) when is_list(items) and length(items) <= @max_findings do
    case each_ok(items, &finding/1) do
      {:ok, list} -> {:ok, list}
      _error -> {:error, :findings}
    end
  end

  defp findings_list(status, items) when status != "recorded" and items in [nil, []],
    do: {:ok, []}

  defp findings_list(_status, _items), do: {:error, :findings}

  defp findings_defect("malformed", defect), do: string_enum(defect, @findings_defects, :defect)
  defp findings_defect(_status, nil), do: {:ok, nil}
  defp findings_defect(_status, _defect), do: {:error, :defect}

  defp finding(item) when is_map(item) do
    with {:ok, severity} <- string_enum(get(item, :severity), @findings_severities, :findings),
         {:ok, disposition} <-
           string_enum(get(item, :disposition), @findings_dispositions, :findings),
         {:ok, path} <- required_bounded(get(item, :path), @max_finding_path, :findings, true),
         {:ok, description} <-
           required_bounded(get(item, :description), @max_finding_description, :findings, false),
         {:ok, source} <-
           required_bounded(get(item, :source), @max_finding_source, :findings, false),
         {:ok, line} <- finding_line(get(item, :line)) do
      {:ok,
       %{
         "severity" => severity,
         "path" => path,
         "line" => line,
         "description" => description,
         "disposition" => disposition,
         "source" => source
       }}
    else
      _ -> :error
    end
  end

  defp finding(_other), do: :error

  defp finding_line(nil), do: {:ok, nil}
  defp finding_line(line) when is_integer(line) and line > 0, do: {:ok, line}
  defp finding_line(_other), do: {:error, :findings}

  # `allow_empty` is for a path (the parser bounds it only); a description and a source must
  # hold text.
  defp required_bounded(value, max, key, allow_empty) when is_binary(value) do
    if String.valid?(value) and String.length(value) <= max and
         (allow_empty or String.trim(value) != ""),
       do: {:ok, value},
       else: {:error, key}
  end

  defp required_bounded(_value, _max, key, _allow_empty), do: {:error, key}

  defp optional_bounded(nil, _max, _key), do: {:ok, nil}
  defp optional_bounded(value, max, key), do: required_bounded(value, max, key, true)

  defp string_enum(value, allowed, key) when is_atom(value) and not is_nil(value),
    do: string_enum(Atom.to_string(value), allowed, key)

  defp string_enum(value, allowed, key) when is_binary(value),
    do: if(value in allowed, do: {:ok, value}, else: {:error, key})

  defp string_enum(_value, _allowed, key), do: {:error, key}

  @doc "A bounded string or `nil`."
  @spec validate_text(term()) :: {:ok, String.t() | nil} | :error
  def validate_text(value), do: text(value, required: false)

  defp check(item) when is_map(item) do
    with {:ok, name} <- text(get(item, :name), required: true),
         {:ok, kind} <- enum(get(item, :kind), @kinds),
         {:ok, state} <- enum(get(item, :state), @states),
         {:ok, conclusion} <- text(get(item, :conclusion), required: false),
         {:ok, workflow} <- text(get(item, :workflow), required: false),
         {:ok, started_at} <- text(get(item, :started_at), required: false),
         {:ok, completed_at} <- text(get(item, :completed_at), required: false) do
      {:ok,
       %{
         "name" => name,
         "kind" => kind,
         "state" => state,
         "conclusion" => conclusion,
         "workflow" => workflow,
         "started_at" => started_at,
         "completed_at" => completed_at
       }}
    end
  end

  defp check(_other), do: :error

  defp enum(value, allowed) when is_atom(value) and not is_nil(value),
    do: enum(Atom.to_string(value), allowed)

  defp enum(value, allowed) when is_binary(value),
    do: if(value in allowed, do: {:ok, value}, else: :error)

  defp enum(_value, _allowed), do: :error

  defp text(nil, required: false), do: {:ok, nil}

  defp text(value, _opts) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value), do: {:ok, String.slice(value, 0, @max_text)}, else: :error
  end

  defp text("", required: false), do: {:ok, nil}
  defp text(_value, _opts), do: :error

  defp each_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil
end
