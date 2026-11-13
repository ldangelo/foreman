defmodule ForemanServer.PrEvidenceTest do
  @moduledoc """
  `PrEvidence`: the evidence fold both the aggregate (`Aggregates.Run.PrWatch`) and the
  projection (`PrWatchFold`) call first. Parity of the two records, the head reset record by
  record, the waiver and the folds' tolerance of malformed stored events.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.{PrEvidence, PrWatchFold}

  @url "https://github.com/acme/repo/pull/7"
  @shared [:head_sha, :checks_state, :checks_digest, :review_decision, :review_digest, :evidence]

  defp started do
    Run.apply_event(Run.initial_state(), %{
      event_type: "RunStarted",
      run_id: "r1",
      task_id: "t1",
      project_id: "p1",
      sequence: 1
    })
  end

  # Fold the same events through both records; return {aggregate record, projection record}.
  defp fold_both(events) do
    aggregate =
      Enum.reduce(events, started(), fn {type, payload}, state ->
        Run.apply_event(state, %{event_type: type, payload: base(payload)})
      end)

    projection =
      Enum.reduce(events, %{}, fn {type, payload}, watch ->
        PrWatchFold.fold(watch, type, base(payload))
      end)

    {aggregate.pr_watch[@url], projection["r1"][@url]}
  end

  defp base(payload), do: Map.merge(%{run_id: "r1", pr_url: @url}, payload)

  defp checks_event(head, extra \\ %{}) do
    {"PrChecksChanged",
     Map.merge(
       %{
         head_sha: head,
         checks_state: "failing",
         digest: "d-#{head}",
         observation_seq: 1,
         failing: [%{name: "unit"}],
         checks: [
           %{
             "name" => "unit",
             "kind" => "check_run",
             "state" => "failing",
             "conclusion" => "FAILURE",
             "workflow" => "ci",
             "started_at" => "2026-11-12T13:58:43Z",
             "completed_at" => "2026-11-12T13:58:49Z"
           }
         ],
         checks_truncated: false,
         evidence_digest: "e-#{head}",
         observation_ref: nil,
         required: [%{"name" => "unit", "kind" => "check_run"}],
         policy_version: "p1",
         observed_at: 10
       },
       extra
     )}
  end

  defp review_event(head),
    do:
      {"PrReviewChanged",
       %{
         head_sha: head,
         review_decision: "changes_requested",
         digest: "r-#{head}",
         observation_seq: 1,
         comment_ids: ["IC_1"],
         thread_ids: ["T1"]
       }}

  defp waived(head, reasons, extra \\ %{}) do
    {"PrEvidenceWaived",
     Map.merge(
       %{
         head_sha: head,
         reasons: reasons,
         policy_version: "p1",
         reason: "known flake",
         approver_identity: "leo",
         waived_at: 99
       },
       extra
     )}
  end

  defp shared({aggregate, projection}),
    do: {Map.take(aggregate, @shared), Map.take(projection, @shared)}

  describe "checks evidence" do
    test "a PrChecksChanged with checks stores evidence.checks bound to its head, in both folds" do
      {aggregate, projection} = records = fold_both([checks_event("h1")])

      assert {same, same} = shared(records)

      assert %{
               head_sha: "h1",
               truncated: false,
               observed_at: 10,
               digest: "d-h1",
               evidence_digest: "e-h1",
               observation_ref: nil,
               required: [%{"name" => "unit", "kind" => "check_run"}],
               policy_version: "p1",
               items: [%{"name" => "unit", "state" => "failing"}]
             } = aggregate.evidence.checks

      assert projection.evidence.checks == aggregate.evidence.checks
    end

    test "an old event with no checks folds as before and leaves evidence.checks as it was" do
      {aggregate, projection} =
        records =
        fold_both([
          checks_event("h1"),
          {"PrChecksChanged",
           %{head_sha: "h1", checks_state: "passing", digest: "d2", observation_seq: 2}}
        ])

      assert {same, same} = shared(records)
      assert aggregate.checks_state == "passing"
      assert aggregate.evidence.checks.evidence_digest == "e-h1"
      assert projection.evidence.checks.evidence_digest == "e-h1"
    end

    test "a stored event whose checks is not a list or holds malformed items never raises" do
      for bad <- ["nope", %{"a" => 1}, 5] do
        {aggregate, projection} =
          fold_both([
            checks_event("h1"),
            checks_event("h1", %{checks: bad, evidence_digest: "x"})
          ])

        assert aggregate.evidence.checks.evidence_digest == "e-h1"
        assert projection.evidence.checks.evidence_digest == "e-h1"
      end

      malformed = checks_event("h1", %{checks: [1, nil, %{"kind" => 7}], evidence_digest: "m"})
      {aggregate, projection} = records = fold_both([malformed])

      assert {same, same} = shared(records)
      assert aggregate.evidence.checks.items == [1, nil, %{"kind" => 7}]
      assert projection.evidence.checks.evidence_digest == "m"
    end

    test "a replayed (string-keyed) payload folds to the same evidence as the live one" do
      {type, payload} = checks_event("h1")
      live = PrWatchFold.fold(%{}, type, base(payload))["r1"][@url]

      replayed =
        PrWatchFold.fold(
          %{},
          type,
          base(payload) |> Jason.encode!() |> Jason.decode!()
        )["r1"][@url]

      assert replayed.evidence == live.evidence
    end

    test "a record with no evidence reads as empty and never raises" do
      assert %{evidence: %{checks: nil, waiver: nil, findings: nil, risk: nil, report: nil}} =
               PrEvidence.apply_event(%{head_sha: nil}, "PrMerged", %{})

      assert %{evidence: %{checks: nil}} = PrEvidence.apply_event(%{}, "PrChecksChanged", nil)
    end
  end

  describe "head reset" do
    test "PrUpdated moving the head resets the current-head observation in both folds" do
      records =
        fold_both([
          checks_event("h1"),
          review_event("h1"),
          {"PrUpdated", %{head_sha: "h2", pr_status: "open"}}
        ])

      assert {same, same} = shared(records)
      {aggregate, projection} = records

      for record <- [aggregate, projection] do
        assert record.head_sha == "h2"
        assert record.checks_state == nil
        assert record.checks_digest == nil
        assert record.review_decision == nil
        assert record.review_digest == nil
      end

      assert projection.failing == []
    end

    test "a PrChecksChanged for a new head leaves no review_decision of the old head" do
      {aggregate, projection} =
        records = fold_both([review_event("h1"), checks_event("h2")])

      assert {same, same} = shared(records)
      assert aggregate.review_decision == nil and projection.review_decision == nil
      assert aggregate.review_digest == nil and projection.review_digest == nil
      assert aggregate.checks_state == "failing" and projection.checks_state == "failing"
    end

    test "a PrReviewChanged for a new head leaves no checks_state of the old head" do
      {aggregate, projection} =
        records = fold_both([checks_event("h1"), review_event("h2")])

      assert {same, same} = shared(records)
      assert aggregate.checks_state == nil and projection.checks_state == nil
      assert aggregate.checks_digest == nil and projection.checks_digest == nil
      assert projection.failing == []
      assert aggregate.review_decision == "changes_requested"
    end

    test "PrReady moves the head the same way" do
      {aggregate, projection} =
        records = fold_both([checks_event("h1"), {"PrReady", %{head_sha: "h2"}}])

      assert {same, same} = shared(records)
      assert aggregate.checks_state == nil and projection.checks_state == nil
    end

    test "the sequence counters, comment and thread ids, fix bookkeeping and evidence are kept" do
      {_aggregate, projection} =
        fold_both([
          checks_event("h1"),
          review_event("h1"),
          {"PrFixRequested", %{kind: "ci", attempt: 1, trigger: "auto", head_sha: "h1"}},
          {"PrUpdated", %{head_sha: "h2", pr_status: "open"}}
        ])

      assert projection.checks_seq == 1 and projection.review_seq == 1
      assert projection.comment_ids == ["IC_1"] and projection.thread_ids == ["T1"]
      assert %{attempts: %{"ci" => 1}} = projection.fix
      # recorded for h1, kept: a reader compares the record's head with the head it decides
      assert %{head_sha: "h1", evidence_digest: "e-h1"} = projection.evidence.checks
    end

    test "the same head, or a record with no head yet, resets nothing" do
      {aggregate, projection} =
        records = fold_both([checks_event("h1"), review_event("h1")])

      assert {same, same} = shared(records)
      assert aggregate.checks_state == "failing" and projection.checks_state == "failing"
      assert aggregate.review_decision == "changes_requested"
    end
  end

  describe "waiver" do
    test "holds sorted, de-duplicated codes and the approver identity as waived_by" do
      records = fold_both([waived("h1", ["b", "a", "b", "c"])])
      assert {same, same} = shared(records)
      {aggregate, projection} = records

      expected = %{
        head_sha: "h1",
        codes: ["a", "b", "c"],
        policy_version: "p1",
        reason: "known flake",
        waived_by: "leo",
        waived_at: 99
      }

      assert aggregate.evidence.waiver == expected
      assert projection.evidence.waiver == expected
    end

    test "a second waiver replaces the first" do
      {aggregate, projection} =
        fold_both([waived("h1", ["a"]), waived("h1", ["z", "y"], %{reason: "again"})])

      for record <- [aggregate, projection] do
        assert %{codes: ["y", "z"], reason: "again", head_sha: "h1"} = record.evidence.waiver
      end
    end

    test "an event moving the head voids a waiver recorded for the old head" do
      records = fold_both([checks_event("h1"), waived("h1", ["a"]), checks_event("h2")])
      assert {same, same} = shared(records)
      {aggregate, projection} = records
      assert aggregate.evidence.waiver == nil and projection.evidence.waiver == nil
    end

    test "a waiver recorded for the new head before any event brought it survives that event" do
      for moving <- [checks_event("h2"), review_event("h2"), {"PrUpdated", %{head_sha: "h2"}}] do
        records = fold_both([checks_event("h1"), waived("h2", ["a"]), moving])
        assert {same, same} = shared(records)
        {aggregate, projection} = records
        assert %{head_sha: "h2", codes: ["a"]} = aggregate.evidence.waiver
        assert projection.evidence.waiver == aggregate.evidence.waiver
      end
    end

    test "it is a function of the payload map, string keys included" do
      record =
        PrEvidence.apply_event(%{head_sha: "h1"}, "PrEvidenceWaived", %{
          "head_sha" => "h1",
          "reasons" => ["b", "a", "a"],
          "approver_identity" => "leo",
          "reason" => "r",
          "policy_version" => nil,
          "waived_at" => 1
        })

      assert %{codes: ["a", "b"], waived_by: "leo"} = record.evidence.waiver
    end
  end

  describe "validate_checks/1 and validate_required/1" do
    defp item(extra \\ %{}) do
      Map.merge(
        %{name: "unit", kind: :check_run, state: :failing, conclusion: "FAILURE"},
        extra
      )
    end

    test "normalise to one string-keyed form, atoms or strings in" do
      assert {:ok, [from_atoms]} = PrEvidence.validate_checks([item()])

      assert {:ok, [^from_atoms]} =
               PrEvidence.validate_checks([
                 %{
                   "name" => "unit",
                   "kind" => "check_run",
                   "state" => "failing",
                   "conclusion" => "FAILURE"
                 }
               ])

      assert %{"kind" => "check_run", "state" => "failing", "workflow" => nil} = from_atoms
    end

    test "an unknown kind or state, a non-list, a missing name and more than 100 items are refused" do
      assert :error = PrEvidence.validate_checks([item(%{kind: :webhook})])
      assert :error = PrEvidence.validate_checks([item(%{state: :great})])
      assert :error = PrEvidence.validate_checks([item(%{name: nil})])
      assert :error = PrEvidence.validate_checks("nope")
      assert :error = PrEvidence.validate_checks([:not_a_map])
      assert {:ok, _} = PrEvidence.validate_checks(List.duplicate(item(), 100))
      assert :error = PrEvidence.validate_checks(List.duplicate(item(), 101))
    end

    test "text is bounded" do
      assert {:ok, [%{"name" => name}]} =
               PrEvidence.validate_checks([item(%{name: String.duplicate("x", 500)})])

      assert String.length(name) == 200
    end

    test "required is nil or at most 20 named, kinded entries" do
      assert {:ok, nil} = PrEvidence.validate_required(nil)

      assert {:ok, [%{"name" => "a", "kind" => "check_run"}]} =
               PrEvidence.validate_required([%{name: "a", kind: "check_run"}])

      assert :error = PrEvidence.validate_required([%{name: "a"}])
      assert :error = PrEvidence.validate_required("a")

      entry = %{"name" => "a", "kind" => "check_run"}
      assert {:ok, _} = PrEvidence.validate_required(List.duplicate(entry, 20))
      assert :error = PrEvidence.validate_required(List.duplicate(entry, 21))
    end
  end
end
