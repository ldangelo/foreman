defmodule ForemanServer.PrWatch.DTOTest do
  # TRD-023: the status read model. The evidence fields are derived by the evaluator the approval
  # gate decides with. Most tests build a watch record through the real fold
  # (`PrEvidence.apply_event/3`) and read it through `DTO.from_projection/3`; the parity, the
  # MCP and the HTTP tests go through the real gateway, aggregate, projection and `DTO.fetch/1`.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, EventStore, PrEvidence, ProjectionStore, RunPrMerge}
  alias ForemanServer.MCP.Tools
  alias ForemanServer.PrWatch.DTO
  alias ForemanServer.PrWatchFold
  alias ForemanServer.TestSupport.GateEvidence
  alias ForemanServer.Workflow.MergeGate

  @endpoint ForemanServerWeb.Endpoint
  @token "pr-dto-token"
  @now 1_800_000_900_000
  @unit %{"name" => "unit", "kind" => "check_run"}
  @pr "https://github.com/acme/repo/pull/7"

  # -- record fixtures (the real fold) -----------------------------------------------

  defp policy(required \\ [@unit]),
    do: {:ok, %{required: required, version: PrEvidence.policy_version(required)}}

  defp ctx(opts),
    do: %{
      policy: Keyword.get(opts, :policy, policy()),
      now_ms: Keyword.get(opts, :now_ms, @now),
      run_status: Keyword.get(opts, :run_status, "in_progress")
    }

  defp base(head \\ "h1") do
    "run-1"
    |> PrWatchFold.new_record(@pr)
    |> Map.merge(%{
      status: "open",
      head_sha: head,
      project_id: "project-1",
      base_branch: "main",
      branch_name: "foreman/run-1/work"
    })
  end

  defp fold(record, type, payload), do: PrEvidence.apply_event(record, type, payload)

  defp check_item(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "unit",
        "kind" => "check_run",
        "state" => "passing",
        "conclusion" => "SUCCESS",
        "workflow" => "ci",
        "started_at" => "2026-11-12T13:58:43Z",
        "completed_at" => "2026-11-12T13:58:49Z"
      },
      overrides
    )
  end

  defp with_checks(record, items \\ [check_item()], opts \\ []) do
    fold(record, "PrChecksChanged", %{
      head_sha: Keyword.get(opts, :head, record.head_sha),
      checks: items,
      checks_truncated: Keyword.get(opts, :truncated, false),
      observed_at: Keyword.get(opts, :observed_at, @now - 1_000),
      digest: "notification-digest",
      evidence_digest: "evidence-digest",
      observation_ref: "ref-1"
    })
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "severity" => "major",
        "path" => "lib/a.ex",
        "line" => 12,
        "description" => "a null check is missing",
        "disposition" => "open",
        "source" => "review"
      },
      overrides
    )
  end

  defp with_findings(record, findings \\ [], opts \\ []) do
    fold(record, "ReviewFindingsRecorded", %{
      head_sha: Keyword.get(opts, :head, record.head_sha),
      status: Keyword.get(opts, :status, "recorded"),
      findings: findings,
      defect: Keyword.get(opts, :defect),
      defect_detail: Keyword.get(opts, :defect_detail),
      judgement: Keyword.get(opts, :judgement),
      digest: "findings-digest",
      recorded_at: @now - 2_000
    })
  end

  defp with_risk(record, opts \\ []) do
    fold(record, "PrRiskRecorded", %{
      head_sha: Keyword.get(opts, :head, record.head_sha),
      level: Keyword.get(opts, :level, "LOW"),
      rubric_version: "1",
      digest: Keyword.get(opts, :digest, "risk-digest"),
      findings_digest: "findings-digest",
      rationale: [
        %{"rule" => "size", "level" => "LOW", "basis" => "machine", "detail" => "3 lines"}
      ],
      instructions: ["Read the diff."],
      seq: 1,
      recorded_at: @now - 3_000
    })
  end

  defp with_report(record, opts \\ []) do
    fold(record, "PrCommentPublished", %{
      head_sha: Keyword.get(opts, :head, record.head_sha),
      digest: Keyword.get(opts, :digest, "risk-digest"),
      status: Keyword.get(opts, :status, "published"),
      reason: Keyword.get(opts, :reason),
      comment_url: "https://github.com/acme/repo/pull/7#issuecomment-1",
      recorded_at: @now - 500
    })
  end

  defp with_waiver(record, codes, opts \\ []) do
    {:ok, %{version: version}} = policy()

    fold(record, "PrEvidenceWaived", %{
      head_sha: Keyword.get(opts, :head, record.head_sha),
      reasons: codes,
      policy_version: Keyword.get(opts, :version, version),
      reason: "the unit job is skipped on docs changes",
      approver_identity: "github:ldangelo",
      waived_at: @now - 4_000
    })
  end

  # A record that is eligible under `policy()`.
  defp unpublished(head \\ "h1"),
    do: head |> base() |> with_checks() |> with_findings() |> with_risk()

  defp clean(head \\ "h1"), do: head |> unpublished() |> with_report()

  defp policy_required(required),
    do: %{required: required, version: PrEvidence.policy_version(required)}

  defp dto(record, opts \\ []) do
    gate = Keyword.get(opts, :gate, "pending")
    DTO.from_projection(record, gate, ctx(opts))
  end

  defp codes(reasons), do: Enum.map(reasons, & &1.code)
  defp actions(dto), do: Enum.map(dto.next_actions, & &1.action)

  # -- shape -------------------------------------------------------------------------

  describe "shape" do
    test "every evidence block is projected with its own head and labels" do
      record =
        base()
        |> with_checks([check_item(), check_item(%{"name" => "lint", "state" => "pending"})])
        |> with_findings([finding()],
          judgement: %{status: "recorded", level: "HIGH", rationale: "free text of the agent"}
        )
        |> with_risk(level: "HIGH")
        |> with_report()
        |> with_waiver(["findings_absent"])
        |> fold("PrReadyFailed", %{stage: "signal", reason: "gh said no", failed_at: 55})

      dto = dto(record)

      assert %{
               status: "eligible",
               head_sha: "h1",
               waived: [],
               policy_version: version,
               evaluated_at: @now
             } = dto.eligibility

      assert {:ok, %{version: ^version}} = policy()

      assert %{
               head_sha: "h1",
               current: true,
               stale: false,
               old: false,
               observed_at: observed_at,
               truncated: false,
               evidence_digest: "evidence-digest",
               items: [unit, lint]
             } = dto.checks

      assert observed_at == @now - 1_000

      assert unit == %{
               name: "unit",
               kind: "check_run",
               workflow: "ci",
               state: "passing",
               conclusion: "SUCCESS",
               started_at: "2026-11-12T13:58:43Z",
               completed_at: "2026-11-12T13:58:49Z"
             }

      assert %{name: "lint", state: "pending"} = lint
      # the notification digest is the Notifier's, not the display's
      refute Map.has_key?(dto.checks, :digest)

      assert %{
               head_sha: "h1",
               current: true,
               stale: false,
               status: "recorded",
               digest: "findings-digest",
               unresolved: %{"major" => 1, "critical" => 0, "minor" => 0, "nitpick" => 0},
               total: 1,
               listed_truncated: false,
               items: [
                 %{
                   severity: "major",
                   disposition: "open",
                   description: "a null check is missing",
                   path: "lib/a.ex",
                   line: 12,
                   source: "review"
                 }
               ],
               judgement: %{status: "recorded", level: "HIGH", defect: nil}
             } = dto.findings

      # the judgement's free-text rationale is not part of the read
      refute inspect(dto.findings) =~ "free text of the agent"

      assert %{
               head_sha: "h1",
               current: true,
               stale: false,
               level: "HIGH",
               rubric_version: "1",
               digest: "risk-digest",
               seq: 1,
               rationale: [%{rule: "size", level: "LOW", basis: "machine", detail: "3 lines"}],
               instructions: ["Read the diff."]
             } = dto.risk

      assert %{
               head_sha: "h1",
               codes: ["findings_absent"],
               policy_version: ^version,
               reason: "the unit job is skipped on docs changes",
               waived_by: "github:ldangelo",
               waived_at: waived_at,
               applies: true,
               ignored_because: nil,
               current: true
             } = dto.waiver

      assert waived_at == @now - 4_000

      assert %{
               head_sha: "h1",
               digest: "risk-digest",
               status: "published",
               comment_url: "https://github.com/acme/repo/pull/7#issuecomment-1",
               current: true,
               stale: false
             } = dto.report

      assert dto.delivery_issue == %{stage: "signal", reason: "gh said no", failed_at: 55}
      assert Jason.encode!(dto) =~ "\"eligibility\""
    end

    test "a PR with no evidence has nil blocks and a gated status that says why" do
      dto = dto(base())

      assert dto.checks == nil
      assert dto.findings == nil
      assert dto.risk == nil
      assert dto.waiver == nil
      assert dto.report == nil
      assert dto.delivery_issue == nil

      assert %{status: "ineligible", reasons: reasons} = dto.eligibility
      assert codes(reasons) == ["missing", "findings_absent", "risk_missing"]
    end

    test "a clean record is eligible; a project with no policy is off, never eligible" do
      assert %{status: "eligible", reasons: [], waived: []} = dto(clean()).eligibility

      assert %{status: "off", reasons: [], policy_version: nil} =
               dto(clean(), policy: {:ok, nil}).eligibility
    end
  end

  # -- parity ------------------------------------------------------------------------

  describe "the status is the decision the gate would take" do
    test "evidence of every kind reads as PrEvidence.evaluate/2 over the same record" do
      scenarios = [
        base(),
        clean(),
        base() |> with_checks([check_item(%{"state" => "failing", "conclusion" => "FAILURE"})]),
        base() |> with_checks([check_item(%{"conclusion" => "SKIPPED"})]) |> with_findings(),
        base() |> with_checks([], truncated: true) |> with_findings() |> with_risk(),
        clean() |> with_findings([], status: "malformed", defect: "invalid_json"),
        clean() |> with_risk(head: "h0"),
        clean("h2") |> Map.put(:head_sha, "h1"),
        clean() |> with_waiver(["missing"]),
        clean() |> Map.put(:evidence, "not a map")
      ]

      for record <- scenarios,
          policy <- [
            policy(),
            {:ok, policy_required([@unit, %{"name" => "lint", "kind" => "status_context"}])},
            {:ok, nil}
          ] do
        {:ok, policy_map} = policy

        gate =
          PrEvidence.evaluate(record, %{
            head_sha: record.head_sha,
            policy: policy_map,
            now_ms: @now,
            checks_ref: nil
          })

        shown = dto(record, policy: policy).eligibility

        assert shown.status == Atom.to_string(gate.status)

        assert Enum.map(shown.reasons, &{&1.code, &1.subject}) ==
                 Enum.map(gate.reasons, &{Atom.to_string(&1.code), &1.subject})

        assert Enum.map(shown.waived, & &1.code) ==
                 Enum.map(gate.waived, &Atom.to_string(&1.code))

        assert shown.policy_version == gate.policy_version
      end
    end
  end

  # -- stale labelling ---------------------------------------------------------------

  describe "stale labelling" do
    test "blocks recorded for another head are stale and the reasons say so" do
      record =
        "h1"
        |> clean()
        |> fold("PrUpdated", %{head_sha: "h2"})
        |> Map.put(:head_sha, "h2")

      dto = dto(record)

      for block <- [dto.checks, dto.findings, dto.risk, dto.report] |> Enum.reject(&is_nil/1) do
        assert %{head_sha: "h1", current: false, stale: true} = block
      end

      assert dto.report.stale == true
      assert dto.eligibility.status == "ineligible"

      assert codes(dto.eligibility.reasons) == [
               "other_sha",
               "findings_other_sha",
               "risk_other_sha"
             ]
    end

    test "a report for the right head whose digest is not the risk record's is stale" do
      dto = clean() |> with_report(digest: "older-digest") |> dto()
      assert %{current: true, stale: true, digest: "older-digest"} = dto.report

      dto = clean() |> with_report(head: "h0") |> dto()
      assert %{current: false, stale: true} = dto.report

      dto = clean() |> with_report() |> dto()
      assert %{current: true, stale: false} = dto.report
    end

    test "an old observation is marked old and is never a reason" do
      fresh = dto(clean())

      old =
        base()
        |> with_checks([check_item()], observed_at: @now - 900_001)
        |> with_findings()
        |> with_risk()
        |> dto()

      assert old.checks.old == true
      assert fresh.checks.old == false
      assert old.eligibility.status == "eligible"
      assert old.eligibility.reasons == []
    end
  end

  # -- unknown -----------------------------------------------------------------------

  describe "unknown" do
    test "a policy that cannot be read is unknown with its reason, never off or eligible" do
      dto = dto(clean() |> with_waiver(["skipped"]), policy: {:error, ":project_not_found"})

      assert %{
               status: "unknown",
               head_sha: "h1",
               reasons: [%{code: "evidence_unreadable", detail: detail}],
               waived: [],
               policy_version: nil
             } = dto.eligibility

      assert detail =~ ":project_not_found"
      assert dto.next_actions == []
    end

    test "a record whose evidence cannot be read is unknown and shows no block" do
      for bad <- ["not a map", 17, [:x]] do
        dto = dto(Map.put(clean(), :evidence, bad))

        assert %{status: "unknown", reasons: [%{code: "evidence_unreadable"}]} = dto.eligibility

        assert [dto.checks, dto.findings, dto.risk, dto.waiver, dto.report] ==
                 List.duplicate(nil, 5)

        assert dto.next_actions == []
      end

      broken = put_in(clean(), [:evidence, :checks, :items], :not_a_list)
      assert %{status: "unknown"} = dto(broken).eligibility
    end

    test "a run's PR in a project the projection does not know reads unknown through fetch/1" do
      %{run_id: run_id, pr_url: pr_url} = ready_run!("project-missing-#{token()}")

      assert {:ok, %{prs: [%{pr_url: ^pr_url, eligibility: eligibility}]}} = DTO.fetch(run_id)
      assert %{status: "unknown", reasons: [%{code: "evidence_unreadable"}]} = eligibility
    end
  end

  # -- waiver under another policy version -------------------------------------------

  describe "waivers" do
    defp skipped_record(waiver_opts) do
      base()
      |> with_checks([check_item(%{"conclusion" => "SKIPPED"})])
      |> with_findings()
      |> with_risk()
      |> with_report()
      |> with_waiver(["skipped"], waiver_opts)
    end

    test "a waiver that applies waives; one under another policy version is ignored and offered again" do
      applying = dto(skipped_record([]))
      assert applying.eligibility.status == "waived"
      assert codes(applying.eligibility.waived) == ["skipped"]
      assert applying.eligibility.reasons == []
      assert %{applies: true, ignored_because: nil} = applying.waiver
      refute "waive" in actions(applying)

      changed = dto(skipped_record(version: "an-older-policy"))
      assert changed.eligibility.status == "ineligible"
      assert codes(changed.eligibility.reasons) == ["skipped"]
      assert changed.eligibility.waived == []

      assert %{
               applies: false,
               ignored_because: "policy_changed",
               policy_version: "an-older-policy"
             } = changed.waiver

      assert [%{action: "waive", command: "run.pr.waive_evidence", codes: ["skipped"]}] =
               changed.next_actions
    end

    test "a waiver for another head is ignored as other_head" do
      other = dto(skipped_record(head: "h0"))

      assert other.eligibility.status == "ineligible"
      assert %{applies: false, ignored_because: "other_head", current: false} = other.waiver
      assert "waive" in actions(other)
    end

    test "a waiver of a gate that is off or unreadable has no verdict on it" do
      off = dto(skipped_record([]), policy: {:ok, nil})
      assert %{applies: nil, ignored_because: nil} = off.waiver

      unknown = dto(skipped_record([]), policy: {:error, ":exit"})
      assert %{applies: nil, ignored_because: nil} = unknown.waiver
    end
  end

  # -- next actions ------------------------------------------------------------------

  describe "next_actions" do
    test "fix_ci for a failing required check" do
      dto =
        base()
        |> with_checks([check_item(%{"state" => "failing", "conclusion" => "FAILURE"})])
        |> with_findings()
        |> with_risk()
        |> with_report()
        |> dto()

      assert [%{action: "fix_ci", command: "run.pr.fix_ci", codes: ["failing"]}] =
               dto.next_actions
    end

    test "rerun_review has no command and is offered for every findings reason" do
      for {record, code} <- [
            {base() |> with_checks() |> with_risk() |> with_report(), "findings_absent"},
            {clean() |> with_findings([], status: "malformed", defect: "invalid_json"),
             "findings_malformed"},
            {clean() |> with_findings([], status: "malformed", defect: "legacy_format"),
             "findings_legacy_format"},
            {clean() |> with_findings([], head: "h0"), "findings_other_sha"}
          ] do
        dto = dto(record, gate: nil)
        assert [%{action: "rerun_review", command: nil, codes: [^code]}] = dto.next_actions
      end

      assert actions(dto(clean())) == []
    end

    test "waive only while the gate is pending and only for a waivable reason" do
      record = base() |> with_checks() |> with_risk() |> with_report()

      assert [%{action: "rerun_review"}, %{action: "waive", codes: ["findings_absent"]}] =
               dto(record, gate: "pending").next_actions

      for gate <- [nil, "none", "approved"] do
        assert actions(dto(record, gate: gate)) == ["rerun_review"]
      end

      # a malformed block and a failing check are not waivable
      malformed = clean() |> with_findings([], status: "malformed", defect: "invalid_json")
      assert actions(dto(malformed, gate: "pending")) == ["rerun_review"]
    end

    test "publish only for a gated PR whose current risk record has no published report" do
      assert actions(dto(unpublished())) == ["publish"]
      assert [%{command: "run.pr.publish_report", codes: []}] = dto(unpublished()).next_actions

      assert actions(dto(unpublished() |> with_report())) == []

      assert actions(dto(unpublished() |> with_report(status: "refused", reason: "gh_failed"))) ==
               ["publish"]

      assert actions(dto(unpublished() |> with_report(digest: "older"))) == ["publish"]
      assert actions(dto(unpublished() |> with_report(head: "h0"))) == ["publish"]

      assert actions(dto(unpublished(), policy: {:ok, nil})) == []
      assert actions(dto(unpublished(), policy: {:error, ":exit"})) == []
      assert actions(dto(%{unpublished() | status: "merged"})) == []
      assert actions(dto(base() |> with_checks() |> with_findings())) == []
    end

    test "reset when the run is failed, stuck, blocked or paused and a findings reason stands" do
      record = base() |> with_checks() |> with_risk() |> with_report()

      for status <- ["failed", "stuck", "blocked", "paused"] do
        assert %{action: "reset", command: "run.reset", codes: ["findings_absent"]} =
                 record
                 |> dto(run_status: status, gate: nil)
                 |> Map.fetch!(:next_actions)
                 |> List.last()
      end

      for status <- ["in_progress", "completed", nil] do
        refute "reset" in actions(dto(record, run_status: status, gate: nil))
      end

      refute "reset" in actions(dto(clean(), run_status: "failed", gate: nil))

      # a failed run with a failing check and no findings reason has nothing to reset
      failing =
        base()
        |> with_checks([check_item(%{"state" => "failing", "conclusion" => "FAILURE"})])
        |> with_findings()
        |> with_risk()
        |> with_report()

      assert actions(dto(failing, run_status: "failed", gate: nil)) == ["fix_ci"]
    end

    test "the set is closed and in a fixed order" do
      record =
        base() |> with_checks([check_item(%{"state" => "failing", "conclusion" => "FAILURE"})])

      dto = dto(record, run_status: "failed", gate: "pending")

      assert actions(dto) == ["fix_ci", "rerun_review", "waive", "reset"]

      assert Enum.all?(
               dto.next_actions,
               &(Map.keys(&1) |> Enum.sort() == [:action, :codes, :command])
             )
    end
  end

  # -- untrusted text ----------------------------------------------------------------

  describe "untrusted text" do
    test "is scrubbed of controls and invalid bytes, cut, and the list is bounded" do
      hostile =
        "line one\nline two\e[31m @org/team <b>x</b> " <> <<0xFF>> <> String.duplicate("z", 2_000)

      findings =
        [finding(%{"description" => hostile, "path" => "lib/\nx.ex"})] ++
          for n <- 1..24,
              do:
                finding(%{
                  "description" => "minor #{n}",
                  "severity" => "minor",
                  "disposition" => "fixed"
                })

      dto =
        base()
        |> with_checks([check_item(%{"name" => "unit\u0085evil", "conclusion" => "OK\r\nX"})])
        |> with_findings(findings)
        |> with_risk()
        |> fold("PrReadyFailed", %{
          stage: "s",
          reason: "bad\u0000" <> String.duplicate("r", 900),
          failed_at: 1
        })
        |> dto()

      assert %{items: items, total: 25, listed_truncated: true} = dto.findings
      assert length(items) == 20

      # the open major finding sorts first and is cut at 300 characters with no control character
      assert [%{description: description, path: path} | _] = items
      assert String.length(description) == 300
      refute description =~ ~r/[\x00-\x1F\x7F]/
      assert description =~ "line one line two"
      assert path == "lib/ x.ex"
      assert String.valid?(description)

      assert [%{name: "unit evil", conclusion: "OK  X"}] = dto.checks.items
      assert String.length(dto.delivery_issue.reason) == 300
      refute dto.delivery_issue.reason =~ <<0>>

      # the whole read is valid JSON
      assert {:ok, _json} = Jason.encode(dto)
    end
  end

  # -- through the real gateway ------------------------------------------------------

  describe "against the gate (gateway, aggregate, projection)" do
    setup do
      MergeGate.clear()
      {:ok, gh} = Agent.start_link(fn -> %{head: "head-one", conclusion: "SUCCESS"} end)

      RunPrMerge.set_command_runner(fn "gh", args, _opts ->
        case args do
          ["pr", "view" | _] -> {view_json(Agent.get(gh, & &1)), 0}
          _other -> {"", 0}
        end
      end)

      previous = Application.get_env(:foreman_server, :api_bearer_token)
      Application.put_env(:foreman_server, :api_bearer_token, @token)

      on_exit(fn ->
        Application.delete_env(:foreman_server, :merge_gate_readers)
        RunPrMerge.clear_command_runner()

        if previous == nil,
          do: Application.delete_env(:foreman_server, :api_bearer_token),
          else: Application.put_env(:foreman_server, :api_bearer_token, previous)
      end)

      %{gh: gh}
    end

    test "a refusal and the status name the same reasons; a failing check offers fix_ci", %{
      gh: gh
    } do
      Agent.update(gh, &%{&1 | conclusion: "FAILURE"})
      project_id = register_project!(%{required_checks: [@unit]})
      %{run_id: run_id} = ready_run!(project_id)

      assert {:error, {:evidence_ineligible, "head-one", refused}, _detail} = approve(run_id)
      assert "failing" in refused

      assert {:ok, %{prs: [pr]}} = DTO.fetch(run_id)
      assert pr.eligibility.status == "ineligible"
      assert Enum.map(pr.eligibility.reasons, & &1.code) == refused
      assert pr.merge_gate == "pending"
      assert [%{action: "fix_ci"} | _] = pr.next_actions
      assert %{current: true, items: [%{name: "unit", state: "failing"}]} = pr.checks
      assert %{level: _level, current: true} = pr.risk
    end

    test "findings the run never recorded are refused and shown as the same reason", %{gh: _gh} do
      project_id = register_project!(%{required_checks: [@unit]})
      %{run_id: run_id} = ready_run!(project_id, findings: false)

      assert {:error, {:evidence_ineligible, "head-one", refused}, _detail} = approve(run_id)
      assert refused == ["findings_absent"]

      assert {:ok, %{prs: [pr]}} = DTO.fetch(run_id)
      assert Enum.map(pr.eligibility.reasons, & &1.code) == refused
      assert "rerun_review" in actions(pr)
      assert "waive" in actions(pr)
    end

    test "an approved eligible PR reads eligible, a gate-off project reads off" do
      project_id = register_project!(%{required_checks: [@unit]})
      %{run_id: run_id} = ready_run!(project_id)
      assert {:ok, _} = approve(run_id)

      assert {:ok, %{prs: [pr]}} = DTO.fetch(run_id)
      assert pr.eligibility.status == "eligible"
      assert pr.eligibility.reasons == []
      assert pr.merge_gate == "approved"
      assert %{current: true, stale: false} = pr.findings

      open = register_project!(%{})
      %{run_id: open_run} = ready_run!(open)
      assert {:ok, _} = approve(open_run)
      assert {:ok, %{prs: [%{eligibility: %{status: "off", reasons: []}}]}} = DTO.fetch(open_run)
    end

    test "reading the status appends nothing and decides nothing", %{gh: _gh} do
      project_id = register_project!(%{required_checks: [@unit]})
      %{run_id: run_id} = ready_run!(project_id)
      before = stream_length(run_id)

      assert {:ok, first} = DTO.fetch(run_id)
      assert {:ok, second} = DTO.fetch(run_id)

      assert stream_length(run_id) == before
      assert [%{merge_gate: "pending"}] = first.prs
      assert [%{merge_gate: "pending"}] = second.prs
    end

    test "the MCP reader and the HTTP route return the evidence and match each other" do
      project_id = register_project!(%{required_checks: [@unit]})
      %{run_id: run_id} = ready_run!(project_id, findings: false)
      assert {:error, {:evidence_ineligible, _, _}, _} = approve(run_id)

      assert {:ok, body} = Tools.call_tool("foreman_pr_status", %{run_id: run_id})

      http =
        build_conn()
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get("/api/runs/#{run_id}/prs")
        |> json_response(200)

      assert [%{"eligibility" => eligibility, "next_actions" => next_actions}] = http["prs"]
      assert eligibility["status"] == "ineligible"
      assert Enum.any?(eligibility["reasons"], &(&1["code"] == "findings_absent"))
      assert Enum.any?(next_actions, &(&1["action"] == "rerun_review" and &1["command"] == nil))

      mcp = body |> Jason.encode!() |> Jason.decode!()
      assert strip_clock(mcp) == strip_clock(http)
    end

    test "the reader is a read tool: no tool of the surface merges or approves" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      assert "foreman_pr_status" in names
      refute Enum.any?(names, &(&1 =~ ~r/merge|approve/i))

      description = Enum.find(Tools.list_tools(), &(&1.name == "foreman_pr_status")).description
      refute description =~ ~r/merge|approve/i
    end
  end

  # -- gateway fixtures ----------------------------------------------------------------

  defp token, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp strip_clock(%{"prs" => prs} = body) do
    %{
      body
      | "prs" =>
          Enum.map(
            prs,
            &update_in(&1, ["eligibility"], fn e -> Map.delete(e, "evaluated_at") end)
          )
    }
  end

  defp register_project!(config) do
    project_id = "project-dto-#{token()}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project_id, path: "/tmp/#{project_id}", config: config}
        }
      ])

    project_id
  end

  defp ready_run!(project_id, opts \\ []) do
    run_id = "run-dto-#{token()}"
    pr_url = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: project_id, task_id: "task-dto"}

    :ok =
      EventStore.append_to_stream("run:#{run_id}", 0, [
        %Elixir.EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          project_id: project_id,
          task_id: "task-dto",
          pr_url: pr_url,
          branch_name: "foreman/task-dto/run",
          head_sha: "head-one",
          base_branch: "main"
        }
      })

    run = %{run_id: run_id, pr_url: pr_url, project_id: project_id, task_id: "task-dto"}
    if Keyword.get(opts, :findings, true), do: GateEvidence.record_findings!(run, "head-one")
    run
  end

  defp view_json(%{head: head, conclusion: conclusion}) do
    Jason.encode!(%{
      "state" => "OPEN",
      "mergeable" => "MERGEABLE",
      "headRefOid" => head,
      "headRefName" => "foreman/task-dto/run",
      "baseRefName" => "main",
      "statusCheckRollup" => [
        %{
          "__typename" => "CheckRun",
          "completedAt" => "2026-11-12T13:58:49Z",
          "conclusion" => conclusion,
          "name" => "unit",
          "startedAt" => "2026-11-12T13:58:43Z",
          "status" => "COMPLETED",
          "workflowName" => "ci"
        }
      ],
      "files" => [%{"path" => "lib/a.ex", "additions" => 3, "deletions" => 1}],
      "changedFiles" => 1,
      "additions" => 3,
      "deletions" => 1
    })
  end

  defp approve(run_id) do
    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{token()}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload: %{
        run_id: run_id,
        approver: "leo",
        approver_identity: "github:ldangelo",
        head_sha: "head-one"
      }
    })
  end

  defp stream_length(run_id) do
    {:ok, events} = EventStore.read_stream_forward("run:#{run_id}", 0, 10_000)
    length(events)
  end
end
