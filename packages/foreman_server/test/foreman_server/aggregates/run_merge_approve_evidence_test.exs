defmodule ForemanServer.Aggregates.RunMergeApproveEvidenceTest do
  @moduledoc """
  TRD-036: `merge_approve` in the Run aggregate decides on the `evidence` `CommandGateway` stamps
  (TRD-022): it validates it, runs `PrEvidence.evaluate/2` over the record of the PR the gate holds,
  refuses with a typed reason and the inputs, or records the decision on `MergeGateApproved`.
  Pure aggregate tests: the record is built by folding the same events production folds.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.Events.MergeGateApproved
  alias ForemanServer.PrEvidence
  alias ForemanServer.TestSupport.GateEvidence
  alias ForemanServer.Workflow.MergeGate

  @run_id "run-evidence-gate"
  @identity "github:ldangelo"
  @url "https://github.com/o/x/pull/1"
  @head "head-1"
  @now 1_900_000_000_000
  @ref "ref-of-this-decision"
  @unit %{"name" => "unit", "kind" => "check_run"}
  @lint %{"name" => "lint", "kind" => "check_run"}
  @inputs ~w(checks_head_sha checks_observed_at evidence_digest checks_ref findings_head_sha
             findings_digest risk_head_sha risk_digest)

  setup do
    MergeGate.clear()
    :ok
  end

  # -- fixtures ---------------------------------------------------------------------

  defp started do
    {:ok, spec} =
      Run.handle_command(Run.initial_state(), %{
        type: "run.start",
        payload: %{
          run_id: @run_id,
          task_id: "task-1",
          project_id: "project-1",
          workflow_snapshot: %{}
        }
      })

    Run.apply_event(Run.initial_state(), %{event_type: spec.event_type, payload: spec.payload})
  end

  defp fold(state, type, payload) do
    payload = payload |> Map.put(:run_id, @run_id) |> Map.put_new(:pr_url, @url)
    Run.apply_event(state, %{event_type: type, payload: payload})
  end

  defp ready(state, head \\ @head) do
    payload = %{
      run_id: @run_id,
      project_id: "project-1",
      task_id: "task-1",
      pr_url: @url,
      branch_name: "foreman/task-1/#{@run_id}",
      head_sha: head,
      base_branch: "main"
    }

    {:ok, spec} = Run.handle_command(state, %{type: "run.pr.ready", payload: payload})
    Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})
  end

  defp item(name, state, conclusion \\ "SUCCESS") do
    %{
      "name" => name,
      "kind" => "check_run",
      "state" => state,
      "conclusion" => conclusion,
      "workflow" => "ci"
    }
  end

  defp checks(state, items, opts \\ []) do
    fold(state, "PrChecksChanged", %{
      head_sha: Keyword.get(opts, :head, @head),
      checks: items,
      checks_truncated: Keyword.get(opts, :truncated, false),
      observed_at: Keyword.get(opts, :observed_at, 1_800_000_000_000),
      digest: "digest-1",
      evidence_digest: "evidence-digest-1",
      observation_ref: Keyword.get(opts, :ref, @ref),
      required: [],
      policy_version: nil
    })
  end

  defp findings(state, head \\ @head, status \\ "recorded") do
    fold(state, "ReviewFindingsRecorded", %{
      head_sha: head,
      status: status,
      findings: [],
      defect: if(status == "malformed", do: "invalid_json"),
      defect_detail: nil,
      digest: "findings-digest-1",
      recorded_at: 1_800_000_000_000
    })
  end

  defp risk(state, head \\ @head) do
    fold(state, "PrRiskRecorded", %{
      head_sha: head,
      level: "LOW",
      rubric_version: "1",
      digest: "risk-digest-1",
      findings_digest: "findings-digest-1",
      seq: 1,
      recorded_at: 1_800_000_000_000
    })
  end

  defp waiver(state, codes, opts \\ []) do
    fold(state, "PrEvidenceWaived", %{
      head_sha: Keyword.get(opts, :head, @head),
      reasons: codes,
      policy_version: Keyword.get(opts, :version, PrEvidence.policy_version([@unit])),
      reason: "known flake",
      approver_identity: @identity,
      waived_at: 1_800_000_000_000
    })
  end

  # A PR whose every record is clean for `@head`: eligible under a policy of `[@unit]`.
  defp clean(required \\ [@unit]) do
    started()
    |> ready()
    |> checks(Enum.map(required, &item(&1["name"], "passing")))
    |> findings()
    |> risk()
  end

  defp gated(required \\ [@unit], ref \\ @ref), do: GateEvidence.gated(required, ref)

  # A PR record for each way evidence can be ineligible under a policy of `[@unit]`; everything
  # but the named defect is clean.
  defp scenario(:failing), do: clean() |> checks([item("unit", "failing", "FAILURE")])
  defp scenario(:pending), do: clean() |> checks([item("unit", "pending", "")])
  defp scenario(:missing), do: clean() |> checks([item("other", "passing")])
  defp scenario(:skipped), do: clean() |> checks([item("unit", "passing", "SKIPPED")])
  defp scenario(:stale_check), do: clean() |> checks([item("unit", "passing", "STALE")])

  defp scenario(:truncated),
    do: clean() |> checks([item("other", "passing")], truncated: true)

  defp scenario(:checks_other_head),
    do: clean() |> checks([item("unit", "passing")], head: "head-0")

  defp scenario(:other_observation),
    do: clean() |> checks([item("unit", "passing")], ref: "an-older-observation")

  defp scenario(:findings_absent),
    do: started() |> ready() |> checks([item("unit", "passing")]) |> risk()

  defp scenario(:findings_malformed), do: clean() |> findings(@head, "malformed")
  defp scenario(:findings_other_head), do: clean() |> findings("head-0")

  defp scenario(:risk_missing),
    do: started() |> ready() |> checks([item("unit", "passing")]) |> findings()

  defp scenario(:risk_other_head), do: clean() |> risk("head-0")

  defp approve(state, evidence, extra \\ %{}) do
    payload =
      %{run_id: @run_id, approver: "leo", approver_identity: @identity, head_sha: @head}
      |> Map.merge(extra)
      |> then(fn payload ->
        if evidence == :none, do: payload, else: Map.put(payload, :evidence, evidence)
      end)

    Run.handle_command(state, %{type: "merge_approve", payload: payload})
  end

  defp refusal(state, evidence, extra \\ %{}) do
    assert {:error, {:evidence_ineligible, @head, codes}, detail} =
             approve(state, evidence, extra)

    {codes, detail}
  end

  defp assert_nothing_decided(state) do
    assert Run.merge_gate(state) == :pending
    assert MergeGate.pending_for_key?("run:#{@run_id}")
    refute MergeGate.approved?("run:#{@run_id}")
  end

  # -- the refusal ------------------------------------------------------------------

  describe "a gated approval of ineligible evidence" do
    for {label, scenario, codes} <- [
          {"a failing required check", :failing, ["failing"]},
          {"a pending required check", :pending, ["pending"]},
          {"a required check that is not on the PR", :missing, ["missing"]},
          {"a skipped required check", :skipped, ["skipped"]},
          {"a STALE required check", :stale_check, ["stale"]},
          {"a cut check list that does not hold the required check", :truncated,
           ["checks_truncated"]},
          {"checks recorded for another head", :checks_other_head, ["other_sha"]},
          {"checks of another observation than the approval's", :other_observation, ["stale"]},
          {"no findings record", :findings_absent, ["findings_absent"]},
          {"a malformed findings record", :findings_malformed, ["findings_malformed"]},
          {"findings of another head", :findings_other_head, ["findings_other_sha"]},
          {"no risk record", :risk_missing, ["risk_missing"]},
          {"a risk record of another head", :risk_other_head, ["risk_other_sha"]}
        ] do
      test "#{label} is refused #{inspect(codes)}, appends nothing and leaves the gate pending" do
        state = scenario(unquote(scenario))
        {codes, detail} = refusal(state, gated())

        assert codes == unquote(codes)
        assert detail.status == :ineligible
        assert detail.head_sha == @head
        assert detail.policy_version == PrEvidence.policy_version([@unit])
        assert detail.checks_ref == @ref
        assert detail.now_ms == GateEvidence.off().now_ms
        assert detail.waived == []
        assert detail.waiver == nil
        assert Enum.map(detail.reasons, &Atom.to_string(&1.code)) == codes

        assert Enum.sort(Enum.map(Map.keys(detail.inputs), &Atom.to_string/1)) ==
                 Enum.sort(@inputs)

        # the decision is deterministic: the same command on the same state is refused identically
        assert {codes, detail} == refusal(state, gated())
        assert_nothing_decided(state)
      end
    end

    test "every refusal value is JSON-encodable (the controller answers it as the 422 detail)" do
      state = clean() |> checks([item("unit", "failing", "FAILURE")]) |> findings("head-0")
      {_codes, detail} = refusal(state, gated())

      assert {:ok, json} = Jason.encode(detail)
      decoded = Jason.decode!(json)
      assert decoded["status"] == "ineligible"
      assert [%{"code" => "failing", "subject" => "unit"} | _] = decoded["reasons"]
    end

    test "a findings_other_sha refusal returns the eight inputs the decision relied on" do
      state = clean() |> findings("head-0")
      {["findings_other_sha"], detail} = refusal(state, gated())

      assert detail.inputs == %{
               checks_head_sha: @head,
               checks_observed_at: 1_800_000_000_000,
               evidence_digest: "evidence-digest-1",
               checks_ref: @ref,
               findings_head_sha: "head-0",
               findings_digest: "findings-digest-1",
               risk_head_sha: @head,
               risk_digest: "risk-digest-1"
             }
    end

    test "every reason is named, not only the first" do
      state = started() |> ready() |> checks([item("unit", "failing", "FAILURE")])
      {codes, _detail} = refusal(state, gated())
      assert codes == ["failing", "findings_absent", "risk_missing"]
    end

    test "a PR with no record at all is refused as stale: no observation exists for the decision" do
      {codes, _} = refusal(started() |> ready() |> findings() |> risk(), gated())
      assert codes == ["stale"]
    end

    test "an old observation under a stale ref cannot satisfy a decision that names a new one" do
      state = clean() |> checks([item("unit", "passing")], ref: "recorded-by-an-earlier-attempt")

      assert {["stale"], detail} = refusal(state, gated([@unit], "ref-of-this-attempt"))
      assert detail.inputs.checks_ref == "ref-of-this-attempt"

      # naming the recorded one satisfies it
      assert {:ok, %{event_type: "MergeGateApproved"}} =
               approve(state, gated([@unit], "recorded-by-an-earlier-attempt"))
    end
  end

  # -- never waivable ---------------------------------------------------------------

  describe "waivers" do
    for {code, scenario} <- [
          {"failing", :failing},
          {"pending", :pending},
          {"stale", :stale_check},
          {"other_sha", :checks_other_head},
          {"checks_truncated", :truncated},
          {"findings_malformed", :findings_malformed},
          {"risk_missing", :risk_missing},
          {"risk_other_sha", :risk_other_head}
        ] do
      test "#{code} is not waivable, whatever codes the recorded waiver lists" do
        code = unquote(code)
        refute code in PrEvidence.waivable_codes()

        state = scenario(unquote(scenario)) |> waiver(PrEvidence.waivable_codes() ++ [code])
        {codes, detail} = refusal(state, gated())

        assert code in codes
        assert detail.waiver.applies == true
        assert_nothing_decided(state)
      end
    end

    test "a waiver for this head and this policy version that covers every reason approves" do
      state =
        started()
        |> ready()
        |> checks([item("unit", "passing", "SKIPPED")])
        |> risk()
        |> waiver(["skipped", "findings_absent"])

      assert {:ok, %{event_type: "MergeGateApproved", payload: payload}} = approve(state, gated())
      assert payload.evidence.status == "waived"
      assert Enum.sort(payload.evidence.waived) == ["findings_absent", "skipped"]
    end

    test "a waiver of a reason that does not arise is not recorded as covering it" do
      state = clean() |> waiver(["skipped"])
      assert {:ok, %{payload: payload}} = approve(state, gated())
      assert payload.evidence.status == "eligible"
      assert payload.evidence.waived == []
    end

    test "a waiver covering only some reasons refuses the rest and names what it covers" do
      state =
        started()
        |> ready()
        |> checks([item("unit", "passing", "SKIPPED")])
        |> risk()
        |> waiver(["skipped"])

      {codes, detail} = refusal(state, gated())
      assert codes == ["findings_absent"]
      assert detail.waived == ["skipped"]
      assert detail.waiver.applies == true
    end

    test "a waiver recorded under another policy version covers nothing: A waived, B added" do
      v1 = PrEvidence.policy_version([@unit])
      v2 = PrEvidence.policy_version([@unit, @lint])

      state =
        started()
        |> ready()
        |> checks([item("other", "passing")])
        |> findings()
        |> risk()
        |> waiver(["missing"], version: v1)

      {codes, detail} = refusal(state, gated([@unit, @lint]))

      assert codes == ["missing", "missing"]
      assert detail.waived == []
      assert detail.waiver.applies == false
      assert detail.waiver.ignored_because == :policy_changed
      assert detail.policy_version == v2
      assert Enum.map(detail.reasons, & &1.subject) == ["unit", "lint"]
    end

    test "a waiver for another head covers nothing" do
      state =
        started()
        |> ready()
        |> checks([item("other", "passing")])
        |> findings()
        |> risk()
        |> waiver(["missing"], head: "head-0")

      {["missing"], detail} = refusal(state, gated())
      assert detail.waived == []
      assert detail.waiver.ignored_because == :other_head
    end
  end

  # -- proceeding -------------------------------------------------------------------

  describe "an eligible approval" do
    test "records the evaluator's output with the approval and pins the head" do
      state = clean()
      assert {:ok, spec} = approve(state, gated())

      assert spec.event_type == "MergeGateApproved"
      assert spec.payload.head_sha == @head
      evidence = spec.payload.evidence

      assert evidence.status == "eligible"
      assert evidence.policy_version == PrEvidence.policy_version([@unit])
      assert evidence.required == [@unit]
      assert evidence.checks_ref == @ref
      assert evidence.now_ms == GateEvidence.off().now_ms
      assert evidence.waived == []

      assert evidence.inputs == %{
               checks_head_sha: @head,
               checks_observed_at: 1_800_000_000_000,
               evidence_digest: "evidence-digest-1",
               checks_ref: @ref,
               findings_head_sha: @head,
               findings_digest: "findings-digest-1",
               risk_head_sha: @head,
               risk_digest: "risk-digest-1"
             }

      # what the aggregate then holds
      approved = Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})
      assert Run.merge_gate(approved) == :approved
      assert Run.merge_pin(approved).head_sha == @head
      assert MergeGate.approved?("run:#{@run_id}")
    end

    test "a stable green PR whose checks were observed long ago is eligible: no age window" do
      state =
        started()
        |> ready()
        |> checks([item("unit", "passing")], observed_at: 1)
        |> findings()
        |> risk()

      assert {:ok, %{payload: %{evidence: %{status: "eligible", inputs: inputs}}}} =
               approve(state, gated())

      assert inputs.checks_observed_at == 1
    end

    test "the recorded evidence is the output of the decision, a plain map that encodes" do
      state = clean()
      {:ok, %{payload: payload}} = approve(state, gated())
      assert {:ok, _json} = Jason.encode(payload.evidence)

      # a later observation changes the record, not the decision already recorded
      later = checks(state, [item("unit", "failing", "FAILURE")], ref: "later")
      refute later == state
      assert payload.evidence.status == "eligible"
    end

    test "a gate-off approval (policy nil) refuses nothing on evidence, whatever the record holds" do
      state =
        started() |> ready() |> checks([item("unit", "failing", "FAILURE")]) |> findings("head-0")

      assert {:ok, %{payload: %{evidence: evidence}}} = approve(state, GateEvidence.off())
      assert evidence.status == "off"
      assert evidence.policy_version == nil
      assert evidence.required == nil
      assert evidence.checks_ref == nil
      assert evidence.waived == []

      assert Map.keys(evidence.inputs) |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
               Enum.sort(@inputs)

      assert Enum.all?(evidence.inputs, fn {_key, value} -> is_nil(value) end)
    end

    test "the policy that decides is the stamped one, never one the record carries" do
      # the record was observed under a gated policy; the stamp says gate off
      state = clean()
      assert {:ok, %{payload: %{evidence: %{status: "off"}}}} = approve(state, GateEvidence.off())
    end

    test "the decision reads no clock: the time is the stamped now_ms" do
      state = clean()
      {:ok, %{payload: a}} = approve(state, %{gated() | now_ms: 5})
      {:ok, %{payload: b}} = approve(state, %{gated() | now_ms: 5})
      assert a.evidence == b.evidence
      assert a.evidence.now_ms == 5
    end
  end

  # -- malformed evidence -----------------------------------------------------------

  describe "evidence that is absent or malformed" do
    @bad_policy_versions ["wrong-version", nil, 5]

    test "absent, not a map or without its fields is {:missing_or_invalid, :evidence}" do
      state = clean()
      good = gated()

      for evidence <- [
            :none,
            nil,
            "evidence",
            [],
            %{},
            Map.delete(good, :policy),
            Map.delete(good, :now_ms),
            %{good | now_ms: "1"},
            %{good | now_ms: nil},
            %{good | policy: "unit"},
            %{good | policy: %{}},
            %{good | policy: %{required: nil, version: "v"}},
            %{good | policy: %{required: "unit", version: "v"}},
            %{good | policy: %{required: [%{"name" => "unit"}], version: "v"}},
            %{good | policy: %{required: [5], version: "v"}}
          ] do
        assert {:error, {:missing_or_invalid, :evidence}} == approve(state, evidence),
               "evidence #{inspect(evidence)}"
      end

      for version <- @bad_policy_versions do
        assert {:error, {:missing_or_invalid, :evidence}} ==
                 approve(state, %{good | policy: %{good.policy | version: version}})
      end

      assert_nothing_decided(state)
    end

    test "a non-nil policy with a missing or blank checks_ref is {:missing_or_invalid, :checks_ref}" do
      state = clean()
      good = gated()

      for ref <- [nil, "", "   ", 5] do
        assert {:error, {:missing_or_invalid, :checks_ref}} ==
                 approve(state, %{good | checks_ref: ref})
      end

      assert {:error, {:missing_or_invalid, :checks_ref}} ==
               approve(state, Map.delete(good, :checks_ref))

      assert_nothing_decided(state)
    end

    test "string-keyed evidence is read like atom-keyed" do
      state = clean()

      evidence = %{
        "policy" => %{"required" => [@unit], "version" => PrEvidence.policy_version([@unit])},
        "checks_ref" => @ref,
        "now_ms" => @now
      }

      assert {:ok, %{payload: %{evidence: %{status: "eligible"}}}} = approve(state, evidence)
    end

    test "the approval is validated before the evidence: an unauthorised approver is named first" do
      assert {:error, :unauthorized_approver} ==
               approve(clean(), :none, %{approver_identity: "github:attacker"})
    end

    test "a gate that is not pending is refused before the evidence is read" do
      state = clean()
      {:ok, spec} = approve(state, gated())
      approved = Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})
      assert {:error, :merge_gate_already_approved} == approve(approved, :none)
    end
  end

  # -- old streams ------------------------------------------------------------------

  describe "replay" do
    test "an approval recorded before evidence existed still decodes and folds as before" do
      old = %{
        run_id: @run_id,
        approver: "leo",
        approver_identity: @identity,
        head_sha: @head,
        approved_at: 7
      }

      assert %MergeGateApproved{evidence: nil, head_sha: @head} =
               struct!(MergeGateApproved, old)

      state = started() |> ready() |> fold("MergeGateApproved", old)
      assert Run.merge_gate(state) == :approved
      assert %Run.MergePin{head_sha: @head, approved_at: 7} = Run.merge_pin(state)
    end

    test "folding an approval is the same with or without the evidence it carries" do
      state = clean()
      {:ok, spec} = approve(state, gated())

      with_evidence =
        Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})

      without =
        Run.apply_event(state, %{
          event_type: spec.event_type,
          payload: Map.delete(spec.payload, :evidence)
        })

      assert with_evidence == without
    end

    test "the recorded evidence survives a JSON round trip and folds from the decoded form" do
      state = clean()
      {:ok, spec} = approve(state, gated())
      decoded = spec.payload |> Jason.encode!() |> Jason.decode!()

      assert decoded["evidence"]["status"] == "eligible"
      assert Enum.sort(Map.keys(decoded["evidence"]["inputs"])) == Enum.sort(@inputs)

      replayed = Run.apply_event(state, %{event_type: "MergeGateApproved", payload: decoded})
      assert Run.merge_gate(replayed) == :approved
    end
  end
end
