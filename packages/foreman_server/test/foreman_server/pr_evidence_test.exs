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

  describe "evaluate/2" do
    alias ForemanServer.PrEvidence.{Eligibility, Reason}

    @h "sha-h1"
    @now 1_800_000_000_000

    defp ck(name, state \\ "passing", extra \\ %{}) do
      Map.merge(
        %{
          "name" => name,
          "kind" => "check_run",
          "state" => state,
          "conclusion" => if(state == "passing", do: "SUCCESS", else: "FAILURE"),
          "workflow" => "ci",
          "started_at" => nil,
          "completed_at" => nil
        },
        extra
      )
    end

    defp rq(name, extra \\ %{}), do: Map.merge(%{"name" => name, "kind" => "check_run"}, extra)

    defp checks_rec(items, extra \\ %{}) do
      Map.merge(
        %{
          head_sha: @h,
          items: items,
          truncated: false,
          observed_at: @now - 3 * 3_600_000,
          digest: "d",
          evidence_digest: "ed",
          observation_ref: "ref-1",
          required: nil,
          policy_version: nil
        },
        extra
      )
    end

    # Findings are part of every decision (TRD-015): the default record carries a clean review
    # of the decided head, so the check tests read only the check reasons.
    defp findings_rec(overrides \\ %{}) do
      Map.merge(
        %{
          head_sha: @h,
          status: "recorded",
          findings: [],
          defect: nil,
          defect_detail: nil,
          artifact_path: "/a/review.md",
          artifact_sha256: String.duplicate("a", 64),
          digest: "fd-1",
          recorded_at: 5
        },
        overrides
      )
    end

    # The risk record (TRD-018) is part of every decision too: a clean `evidence.risk` of the
    # decided head, so the check tests read only the check reasons.
    defp risk_rec(head, overrides \\ %{}) do
      Map.merge(
        %{
          head_sha: head,
          level: "HIGH",
          rubric_version: "1",
          digest: "rd-#{head}",
          findings_digest: "fd-1",
          seq: 1,
          recorded_at: 5
        },
        overrides
      )
    end

    defp record(evidence \\ %{}),
      do: %{
        evidence:
          Map.merge(
            PrEvidence.empty(),
            Map.merge(%{findings: findings_rec(), risk: risk_rec(@h)}, evidence)
          )
      }

    defp policy(required, version \\ "v1"), do: %{required: required, version: version}

    defp ctx(overrides \\ []) do
      Map.merge(
        %{
          head_sha: @h,
          policy: policy([rq("A"), rq("B")]),
          now_ms: @now,
          checks_ref: "ref-1"
        },
        Map.new(overrides)
      )
    end

    defp waiver(codes, overrides \\ %{}) do
      Map.merge(
        %{
          head_sha: @h,
          codes: codes,
          policy_version: "v1",
          reason: "r",
          waived_by: "w",
          waived_at: "t"
        },
        overrides
      )
    end

    defp rcodes(%Eligibility{reasons: reasons}), do: Enum.map(reasons, &{&1.code, &1.subject})

    test "every required check passing on the decided head is eligible; each failure mode has its code" do
      both = record(%{checks: checks_rec([ck("A"), ck("B")])})
      assert %Eligibility{status: :eligible, reasons: []} = PrEvidence.evaluate(both, ctx())

      only_a = record(%{checks: checks_rec([ck("A")])})
      r = PrEvidence.evaluate(only_a, ctx())
      assert r.status == :ineligible
      assert rcodes(r) == [missing: "B"]

      failing = record(%{checks: checks_rec([ck("A", "failing"), ck("B")])})
      assert rcodes(PrEvidence.evaluate(failing, ctx())) == [failing: "A"]

      pending =
        record(%{checks: checks_rec([ck("A", "pending", %{"conclusion" => nil}), ck("B")])})

      assert rcodes(PrEvidence.evaluate(pending, ctx())) == [pending: "A"]
    end

    test "evidence for another head is the single reason other_sha" do
      rec = record(%{checks: checks_rec([ck("A"), ck("B")], %{head_sha: "sha-h0"})})
      r = PrEvidence.evaluate(rec, ctx())
      assert r.status == :ineligible
      assert rcodes(r) == [other_sha: nil]
    end

    test "a STALE conclusion is stale for that check" do
      rec =
        record(%{
          checks: checks_rec([ck("A", "passing", %{"conclusion" => "STALE"}), ck("B")])
        })

      assert rcodes(PrEvidence.evaluate(rec, ctx())) == [stale: "A"]
    end

    test "a decision whose checks_ref differs from the recorded observation is one stale reason, no per-check reason" do
      rec = record(%{checks: checks_rec([ck("A", "failing")], %{observation_ref: "ref-0"})})
      r = PrEvidence.evaluate(rec, ctx())
      assert rcodes(r) == [stale: nil]
    end

    test "a decision with a checks_ref over a record with no checks is stale, a display read is missing" do
      assert rcodes(PrEvidence.evaluate(record(), ctx())) == [stale: nil]

      assert rcodes(PrEvidence.evaluate(record(), ctx(checks_ref: nil))) == [
               missing: "A",
               missing: "B"
             ]
    end

    test "a display read judges no age: stable green read two hours later is eligible on both reads" do
      rec =
        record(%{
          checks: checks_rec([ck("A"), ck("B")], %{observed_at: @now - 2 * 3_600_000})
        })

      assert %{status: :eligible} = PrEvidence.evaluate(rec, ctx(checks_ref: nil))
      assert %{status: :eligible} = PrEvidence.evaluate(rec, ctx())
      assert %{status: :eligible} = PrEvidence.evaluate(rec, ctx(now_ms: @now + 86_400_000))
    end

    test "the head and checks_ref combinations: display read still sees another head, a decision of a stale ref sees stale" do
      rec = record(%{checks: checks_rec([ck("A"), ck("B")], %{head_sha: "other"})})
      assert rcodes(PrEvidence.evaluate(rec, ctx(checks_ref: nil))) == [other_sha: nil]
      assert rcodes(PrEvidence.evaluate(rec, ctx())) == [other_sha: nil]

      same = record(%{checks: checks_rec([ck("A"), ck("B")])})
      assert PrEvidence.evaluate(same, ctx(checks_ref: "ref-2")).status == :ineligible
      assert PrEvidence.evaluate(same, ctx(checks_ref: nil)).status == :eligible
    end

    test "SKIPPED and NEUTRAL check runs are skipped unless the entry allows it" do
      for conclusion <- ["SKIPPED", "NEUTRAL"] do
        rec =
          record(%{
            checks: checks_rec([ck("A", "passing", %{"conclusion" => conclusion}), ck("B")])
          })

        assert rcodes(PrEvidence.evaluate(rec, ctx())) == [skipped: "A"]

        allowed = ctx(policy: policy([rq("A", %{"allow_skipped" => true}), rq("B")]))
        assert %{status: :eligible} = PrEvidence.evaluate(rec, allowed)
      end
    end

    test "a skipped status context is not skipped (only check runs conclude skipped)" do
      rec =
        record(%{
          checks:
            checks_rec([
              ck("S", "passing", %{"kind" => "status_context", "conclusion" => "SKIPPED"})
            ])
        })

      c = ctx(policy: policy([%{"name" => "S", "kind" => "status_context"}]))
      assert %{status: :eligible} = PrEvidence.evaluate(rec, c)
    end

    test "a rollup cut at 100 items: a missing entry is checks_truncated, a kept one is not" do
      kept = for n <- 1..100, do: ck("job-#{n}")
      rec = record(%{checks: checks_rec([ck("A") | tl(kept)], %{truncated: true})})

      r = PrEvidence.evaluate(rec, ctx())
      assert rcodes(r) == [checks_truncated: "B"]

      c = ctx(policy: policy([rq("A")]))
      assert %{status: :eligible, reasons: []} = PrEvidence.evaluate(rec, c)
    end

    test "an entry matches by kind and, when it names one, by workflow" do
      items = [
        ck("A", "failing", %{"workflow" => "other"}),
        ck("A", "passing", %{"workflow" => "ci"})
      ]

      rec = record(%{checks: checks_rec(items)})

      named = ctx(policy: policy([rq("A", %{"workflow" => "ci"})]))
      assert %{status: :eligible} = PrEvidence.evaluate(rec, named)

      unnamed = ctx(policy: policy([rq("A")]))
      assert rcodes(PrEvidence.evaluate(rec, unnamed)) == [failing: "A"]

      absent = ctx(policy: policy([rq("A", %{"workflow" => "nightly"})]))
      assert rcodes(PrEvidence.evaluate(rec, absent)) == [missing: "A"]

      context_only =
        record(%{checks: checks_rec([ck("A", "passing", %{"kind" => "status_context"})])})

      assert rcodes(PrEvidence.evaluate(context_only, ctx(policy: policy([rq("A")])))) == [
               missing: "A"
             ]
    end

    test "required [] is no_checks_configured; its waiver makes the PR waived" do
      c = ctx(policy: policy([]))
      r = PrEvidence.evaluate(record(), c)
      assert r.status == :ineligible
      assert rcodes(r) == [no_checks_configured: nil]

      waived = record(%{waiver: waiver(["no_checks_configured"])})
      r = PrEvidence.evaluate(waived, c)
      assert %Eligibility{status: :waived, reasons: [], policy_version: "v1"} = r
      assert [%Reason{code: :no_checks_configured}] = r.waived
      assert %{applies: true, ignored_because: nil, codes: ["no_checks_configured"]} = r.waiver
    end

    test "policy nil is off whatever the record holds, even an unreadable one, with every input nil" do
      good = record(%{checks: checks_rec([ck("A", "failing")])})
      bad = record(%{checks: %{items: "nope"}})

      for rec <- [good, bad, nil, :garbage] do
        r = PrEvidence.evaluate(rec, ctx(policy: nil))

        assert %Eligibility{
                 status: :off,
                 reasons: [],
                 waived: [],
                 waiver: nil,
                 policy_version: nil
               } = r

        assert map_size(r.inputs) == 8
        assert Enum.all?(r.inputs, fn {_k, v} -> is_nil(v) end)
      end
    end

    test "the policy comes from ctx, not from the stored required: a cleared policy is off" do
      rec =
        record(%{
          checks: checks_rec([ck("A", "failing")], %{required: [rq("A")], policy_version: "v1"})
        })

      assert PrEvidence.evaluate(rec, ctx(policy: nil)).status == :off
      assert PrEvidence.evaluate(rec, ctx(policy: policy([rq("Z")]))).status == :ineligible

      # the stored list names the failing A; the policy of the decision names only B
      stored =
        record(%{checks: checks_rec([ck("A", "failing"), ck("B")], %{required: [rq("A")]})})

      assert %{status: :eligible} = PrEvidence.evaluate(stored, ctx(policy: policy([rq("B")])))
    end

    test "a waiver covering missing does not cover a failing reason: ineligible, failing remains, missing is waived" do
      rec =
        record(%{
          checks: checks_rec([ck("A", "failing")]),
          waiver: waiver(["missing"])
        })

      r = PrEvidence.evaluate(rec, ctx())
      assert r.status == :ineligible
      assert rcodes(r) == [failing: "A"]
      assert [%Reason{code: :missing, subject: "B"}] = r.waived
    end

    test "a waiver covering every waivable reason makes it waived; never-waivable codes stay even when listed" do
      rec = record(%{checks: checks_rec([ck("A")]), waiver: waiver(["missing"])})
      r = PrEvidence.evaluate(rec, ctx())
      assert r.status == :waived
      assert [%Reason{code: :missing, subject: "B"}] = r.waived

      stale =
        record(%{
          checks: checks_rec([ck("A", "passing", %{"conclusion" => "STALE"}), ck("B")]),
          waiver: waiver(["stale"])
        })

      assert PrEvidence.evaluate(stale, ctx()).status == :ineligible

      other =
        record(%{
          checks: checks_rec([ck("A"), ck("B")], %{head_sha: "o"}),
          waiver: waiver(["other_sha"])
        })

      assert PrEvidence.evaluate(other, ctx()).status == :ineligible

      truncated =
        record(%{
          checks: checks_rec([ck("A")], %{truncated: true}),
          waiver: waiver(["checks_truncated"])
        })

      assert PrEvidence.evaluate(truncated, ctx()).status == :ineligible
    end

    test "a waiver for another head covers nothing and is shown as ignored: other_head" do
      rec =
        record(%{
          checks: checks_rec([ck("A")]),
          waiver: waiver(["missing"], %{head_sha: "old"})
        })

      r = PrEvidence.evaluate(rec, ctx())
      assert r.status == :ineligible
      assert r.waived == []
      assert %{applies: false, ignored_because: :other_head, head_sha: "old"} = r.waiver
    end

    test "a waiver of policy V1 is ignored under V2 (policy_changed) and applies under V1" do
      rec = record(%{checks: checks_rec([ck("X")]), waiver: waiver(["missing"])})
      v1 = ctx(policy: policy([rq("A")], "v1"))
      v2 = ctx(policy: policy([rq("A"), rq("B")], "v2"))

      r1 = PrEvidence.evaluate(rec, v1)
      assert r1.status == :waived
      assert [%Reason{code: :missing, subject: "A"}] = r1.waived

      r2 = PrEvidence.evaluate(rec, v2)
      assert r2.status == :ineligible
      assert rcodes(r2) == [missing: "A", missing: "B"]
      assert r2.waived == []
      assert %{applies: false, ignored_because: :policy_changed} = r2.waiver
    end

    test "a waiver under a record already eligible is shown and applies" do
      rec = record(%{checks: checks_rec([ck("A"), ck("B")]), waiver: waiver(["missing"])})
      r = PrEvidence.evaluate(rec, ctx())
      assert r.status == :eligible
      assert %{applies: true} = r.waiver
    end

    test "inputs carry the check, findings and risk values; absent records are nil" do
      rec =
        record(%{
          checks: checks_rec([ck("A"), ck("B")]),
          findings: %{head_sha: @h, digest: "f"},
          risk: %{head_sha: "r-head", digest: "r"}
        })

      r = PrEvidence.evaluate(rec, ctx())

      assert r.inputs == %{
               checks_head_sha: @h,
               checks_observed_at: @now - 3 * 3_600_000,
               evidence_digest: "ed",
               checks_ref: "ref-1",
               findings_head_sha: @h,
               findings_digest: "f",
               risk_head_sha: "r-head",
               risk_digest: "r"
             }

      bare =
        PrEvidence.evaluate(
          record(%{checks: checks_rec([ck("A"), ck("B")]), findings: nil, risk: nil}),
          ctx()
        )

      assert %{findings_head_sha: nil, findings_digest: nil, risk_head_sha: nil, risk_digest: nil} =
               bare.inputs

      assert bare.inputs.checks_head_sha == @h
    end

    test "an unreadable record is unknown with the single reason evidence_unreadable, never eligible, never missing" do
      unreadable = [
        record(%{checks: %{head_sha: @h, items: :nope}}),
        record(%{checks: %{head_sha: @h, items: [%{"kind" => "check_run"}]}}),
        record(%{checks: %{head_sha: @h, items: [%{"name" => 7}]}}),
        record(%{checks: %{head_sha: @h, items: ["str"]}}),
        record(%{checks: "bogus"}),
        %{evidence: "bogus"},
        nil
      ]

      for rec <- unreadable do
        r = PrEvidence.evaluate(rec, ctx())
        assert %Eligibility{status: :unknown, waived: [], waiver: nil} = r
        assert [%Reason{code: :evidence_unreadable, subject: nil, detail: detail}] = r.reasons
        assert is_binary(detail)
      end

      waived =
        record(%{checks: %{head_sha: @h, items: :nope}, waiver: waiver(["evidence_unreadable"])})

      assert PrEvidence.evaluate(waived, ctx()).status == :unknown
    end

    test "a record with no evidence key reads as empty" do
      assert rcodes(PrEvidence.evaluate(%{}, ctx(checks_ref: nil))) == [
               missing: "A",
               missing: "B",
               findings_absent: nil,
               risk_missing: nil
             ]
    end

    test "evaluated_at is now_ms and no reason depends on it" do
      rec = record(%{checks: checks_rec([ck("A", "failing"), ck("B")])})
      a = PrEvidence.evaluate(rec, ctx(now_ms: 1))
      b = PrEvidence.evaluate(rec, ctx(now_ms: 2))
      assert a.evaluated_at == 1 and b.evaluated_at == 2
      assert a.reasons == b.reasons and a.status == b.status
    end

    test "evaluate_checks/2 reads no waiver" do
      rec = record(%{checks: checks_rec([ck("A")]), waiver: waiver(["missing"])})

      assert {:ineligible, [%Reason{code: :missing, subject: "B"}]} =
               PrEvidence.evaluate_checks(rec, ctx())

      assert {:off, []} = PrEvidence.evaluate_checks(rec, ctx(policy: nil))
    end

    test "the eligibility encodes as JSON: status a string, reasons objects, eight inputs with null" do
      rec =
        record(%{
          checks: checks_rec([ck("A", "failing"), ck("B", "pending")]),
          waiver: waiver(["missing"])
        })

      r = PrEvidence.evaluate(rec, ctx(policy: policy([rq("A"), rq("B"), rq("C")])))
      assert r.status == :ineligible

      decoded = r |> Jason.encode!() |> Jason.decode!()
      assert decoded["status"] == "ineligible"

      assert [%{"code" => "failing", "subject" => "A", "detail" => "FAILURE"}, pending] =
               decoded["reasons"]

      assert %{"code" => "pending", "subject" => "B", "detail" => nil} = pending

      assert Enum.all?(
               decoded["reasons"],
               &(Map.keys(&1) |> Enum.sort() == ["code", "detail", "subject"])
             )

      assert [%{"code" => "missing", "subject" => "C"}] = decoded["waived"]

      assert map_size(decoded["inputs"]) == 8
      assert decoded["inputs"]["findings_digest"] == "fd-1"
      assert decoded["waiver"]["applies"] == true
    end
  end

  describe "evaluate/2 findings reasons (TRD-015)" do
    alias ForemanServer.PrEvidence.{Eligibility, Reason}

    @fh "sha-f1"
    @fnow 1_800_000_000_000

    defp passing_checks(head),
      do: %{
        head_sha: head,
        items: [
          %{
            "name" => "A",
            "kind" => "check_run",
            "state" => "passing",
            "conclusion" => "SUCCESS",
            "workflow" => "ci"
          }
        ],
        truncated: false,
        observed_at: 1,
        digest: "d",
        evidence_digest: "ed",
        observation_ref: "ref-1",
        required: nil,
        policy_version: nil
      }

    defp fctx(head \\ @fh, overrides \\ %{}),
      do:
        Map.merge(
          %{
            head_sha: head,
            policy: %{required: [%{"name" => "A", "kind" => "check_run"}], version: "v1"},
            now_ms: @fnow,
            checks_ref: "ref-1"
          },
          overrides
        )

    defp frec(findings, head \\ @fh),
      do: %{
        evidence:
          Map.merge(PrEvidence.empty(), %{
            checks: passing_checks(head),
            findings: findings,
            risk: risk_rec(head)
          })
      }

    defp fcodes(rec, ctx),
      do: rec |> PrEvidence.evaluate(ctx) |> Map.fetch!(:reasons) |> Enum.map(& &1.code)

    defp recorded(head, overrides \\ %{}),
      do:
        Map.merge(
          %{
            head_sha: head,
            status: "recorded",
            findings: [],
            defect: nil,
            defect_detail: nil,
            artifact_path: nil,
            artifact_sha256: nil,
            digest: "dg-#{head}",
            recorded_at: 1
          },
          overrides
        )

    test "a clean recorded review of the decided head is the only way to no findings reason" do
      assert %Eligibility{status: :eligible, reasons: []} =
               PrEvidence.evaluate(frec(recorded(@fh)), fctx())

      assert fcodes(frec(nil), fctx()) == [:findings_absent]
    end

    test "an absent record is findings_absent, never a clean review, with its text" do
      rec = frec(recorded(@fh, %{status: "absent", defect_detail: "no block written"}))
      r = PrEvidence.evaluate(rec, fctx())
      assert r.status == :ineligible

      assert [%Reason{code: :findings_absent, subject: nil, detail: "no block written"}] =
               r.reasons
    end

    test "the defect decides the malformed code: only legacy_format is the waivable one" do
      for defect <- PrEvidence.findings_defects() do
        rec = frec(recorded(@fh, %{status: "malformed", defect: defect, defect_detail: "d"}))

        expected =
          if defect == "legacy_format", do: :findings_legacy_format, else: :findings_malformed

        assert fcodes(rec, fctx()) == [expected], "defect #{defect}"
      end
    end

    test "recorded for another head is findings_other_sha; absent and malformed keep their code" do
      assert fcodes(frec(recorded("sha-f0")), fctx()) == [:findings_other_sha]

      assert fcodes(frec(recorded("sha-f0", %{status: "absent"})), fctx()) == [:findings_absent]

      assert fcodes(
               frec(recorded("sha-f0", %{status: "malformed", defect: "multiple_blocks"})),
               fctx()
             ) == [:findings_malformed]

      assert fcodes(
               frec(recorded("sha-f0", %{status: "malformed", defect: "legacy_format"})),
               fctx()
             ) == [:findings_legacy_format]
    end

    test "a display read with no head reads a recorded review as findings_other_sha" do
      # TRD-015: `recorded` for a head other than `ctx.head_sha` is `findings_other_sha`. A caller
      # that supplies no head has no head the review can be bound to, so it is never read as clean.
      assert :findings_other_sha in fcodes(frec(recorded(@fh)), fctx(nil, %{checks_ref: nil}))
    end

    test "a display read judges findings the same way" do
      assert fcodes(frec(recorded("sha-f0")), fctx(@fh, %{checks_ref: nil})) == [
               :findings_other_sha
             ]
    end

    test "the waivable findings codes are waivable, the malformed one is not" do
      waiver = fn codes ->
        %{
          head_sha: @fh,
          codes: codes,
          policy_version: "v1",
          reason: "r",
          waived_by: "w",
          waived_at: 1
        }
      end

      with_waiver = fn findings, codes ->
        rec = frec(findings)
        put_in(rec.evidence.waiver, waiver.(codes))
      end

      legacy = recorded(@fh, %{status: "malformed", defect: "legacy_format"})

      assert %{status: :waived} =
               PrEvidence.evaluate(with_waiver.(legacy, ["findings_legacy_format"]), fctx())

      assert %{status: :waived} =
               PrEvidence.evaluate(with_waiver.(nil, ["findings_absent"]), fctx())

      assert %{status: :waived} =
               PrEvidence.evaluate(
                 with_waiver.(recorded("sha-f0"), ["findings_other_sha"]),
                 fctx()
               )

      multi = recorded(@fh, %{status: "malformed", defect: "multiple_blocks"})

      assert %{status: :ineligible, reasons: [%Reason{code: :findings_malformed}]} =
               PrEvidence.evaluate(with_waiver.(multi, ["findings_malformed"]), fctx())
    end

    test "inputs carry the record's own head and digest for a decision on that head or another" do
      rec = frec(recorded(@fh))

      for decided <- [@fh, "sha-f2"] do
        r = PrEvidence.evaluate(rec, fctx(decided))
        assert r.inputs.findings_head_sha == @fh
        assert r.inputs.findings_digest == "dg-#{@fh}"
      end

      none = PrEvidence.evaluate(frec(nil), fctx())
      assert none.inputs.findings_head_sha == nil and none.inputs.findings_digest == nil

      off = PrEvidence.evaluate(rec, fctx(@fh, %{policy: nil}))
      assert off.status == :off and off.inputs.findings_digest == nil
    end
  end

  describe "evaluate/2 risk reasons (TRD-018)" do
    alias ForemanServer.PrEvidence.{Eligibility, Reason}

    defp risk_only(rec, risk), do: put_in(rec.evidence.risk, risk)

    test "a record for the decided head is no reason; none is risk_missing; another head is risk_other_sha" do
      assert %Eligibility{status: :eligible, reasons: []} =
               PrEvidence.evaluate(frec(recorded(@fh)), fctx())

      assert [%Reason{code: :risk_missing, subject: nil}] =
               frec(recorded(@fh))
               |> risk_only(nil)
               |> PrEvidence.evaluate(fctx())
               |> Map.fetch!(:reasons)

      assert [%Reason{code: :risk_other_sha, subject: nil, detail: detail}] =
               frec(recorded(@fh))
               |> risk_only(risk_rec("sha-f0"))
               |> PrEvidence.evaluate(fctx())
               |> Map.fetch!(:reasons)

      assert detail =~ "sha-f0" and detail =~ @fh
    end

    test "a display read judges the risk the same way" do
      rec = frec(recorded(@fh)) |> risk_only(risk_rec("sha-f0"))
      assert fcodes(rec, fctx(@fh, %{checks_ref: nil})) == [:risk_other_sha]
      assert fcodes(risk_only(rec, nil), fctx(@fh, %{checks_ref: nil})) == [:risk_missing]
    end

    test "neither code is waivable, even when a waiver for this head and policy lists it" do
      refute "risk_missing" in PrEvidence.waivable_codes()
      refute "risk_other_sha" in PrEvidence.waivable_codes()

      waiver = %{
        head_sha: @fh,
        codes: ["risk_missing", "risk_other_sha"],
        policy_version: "v1",
        reason: "r",
        waived_by: "w",
        waived_at: 1
      }

      for risk <- [nil, risk_rec("sha-f0")] do
        rec = frec(recorded(@fh)) |> risk_only(risk)
        rec = put_in(rec.evidence.waiver, waiver)

        assert %{status: :ineligible, reasons: [%Reason{}], waived: []} =
                 PrEvidence.evaluate(rec, fctx())
      end
    end

    test "a waiver covering the waivable findings gap leaves a missing risk uncovered" do
      rec = frec(nil) |> risk_only(nil)

      rec =
        put_in(rec.evidence.waiver, %{
          head_sha: @fh,
          codes: ["findings_absent"],
          policy_version: "v1",
          reason: "r",
          waived_by: "w",
          waived_at: 1
        })

      assert %{
               status: :ineligible,
               reasons: [%Reason{code: :risk_missing}],
               waived: [%Reason{code: :findings_absent}]
             } = PrEvidence.evaluate(rec, fctx())
    end

    test "the inputs copy the record's own head and digest; a head move does not change them" do
      rec = frec(recorded(@fh))

      for decided <- [@fh, "sha-f2"] do
        r = PrEvidence.evaluate(rec, fctx(decided))
        assert r.inputs.risk_head_sha == @fh
        assert r.inputs.risk_digest == "rd-#{@fh}"
      end

      none = rec |> risk_only(nil) |> PrEvidence.evaluate(fctx())
      assert none.inputs.risk_head_sha == nil and none.inputs.risk_digest == nil

      off = PrEvidence.evaluate(rec, fctx(@fh, %{policy: nil}))

      assert off.status == :off and off.inputs.risk_head_sha == nil and
               off.inputs.risk_digest == nil

      lacking = PrEvidence.evaluate(risk_only(rec, %{level: "LOW"}), fctx())
      assert lacking.inputs.risk_head_sha == nil and lacking.inputs.risk_digest == nil
    end

    test "a risk that is not a map makes the record unreadable" do
      assert %{status: :unknown, reasons: [%Reason{code: :evidence_unreadable}]} =
               frec(recorded(@fh)) |> risk_only("HIGH") |> PrEvidence.evaluate(fctx())
    end
  end

  describe "the PrRiskRecorded fold (TRD-018)" do
    defp risk_event(head) do
      {"PrRiskRecorded",
       %{
         project_id: "p1",
         task_id: "t1",
         head_sha: head,
         level: "HIGH",
         rubric_version: "1",
         digest: "dg-#{head}",
         findings_digest: "fd-1",
         seq: 1,
         recorded_at: 5
       }}
    end

    defp moved(head), do: {"PrUpdated", %{head_sha: head, pr_status: "open"}}

    test "the aggregate and the projection hold one evidence.risk, kept with its own head across a head move" do
      {aggregate, projection} = fold_both([moved("h1"), risk_event("h1"), moved("h2")])

      assert aggregate.evidence.risk == projection.evidence.risk

      assert %{
               head_sha: "h1",
               level: "HIGH",
               rubric_version: "1",
               digest: "dg-h1",
               findings_digest: "fd-1",
               seq: 1,
               recorded_at: 5
             } = aggregate.evidence.risk

      assert aggregate.head_sha == "h2" and projection.head_sha == "h2"
    end

    test "a replay from the JSON event log (string keys) gives the same record" do
      {live, _} = fold_both([moved("h1"), risk_event("h1")])
      {type, payload} = risk_event("h1")
      json = payload |> Jason.encode!() |> Jason.decode!()
      {replayed, projection} = fold_both([moved("h1"), {type, json}])

      assert live.evidence.risk == replayed.evidence.risk
      assert projection.evidence.risk == live.evidence.risk
    end
  end

  describe "findings digest and validation" do
    defp finding_map(extra \\ %{}),
      do:
        Map.merge(
          %{
            "severity" => "major",
            "path" => "lib/a.ex",
            "line" => 3,
            "description" => "bad",
            "disposition" => "open",
            "source" => "repo-rules"
          },
          extra
        )

    test "the digest depends on the findings, not only on status and defect" do
      {:ok, a} = PrEvidence.validate_findings("recorded", [finding_map()], nil, nil)
      {:ok, b} = PrEvidence.validate_findings("recorded", [finding_map(%{"line" => 4})], nil, nil)
      assert PrEvidence.findings_digest(a) != PrEvidence.findings_digest(b)
      assert PrEvidence.findings_digest(a) == PrEvidence.findings_digest(a)
      assert PrEvidence.findings_digest(a) =~ ~r/\A[0-9a-f]{16}\z/
    end

    test "atom-keyed and string-keyed findings normalise to one form" do
      atoms = %{
        severity: :major,
        path: "lib/a.ex",
        line: 3,
        description: "bad",
        disposition: :open,
        source: "repo-rules"
      }

      assert {:ok, %{findings: [one]}} =
               PrEvidence.validate_findings(:recorded, [atoms], nil, nil)

      assert {:ok, %{findings: [^one]}} =
               PrEvidence.validate_findings("recorded", [finding_map()], nil, nil)

      assert one == finding_map()
    end

    test "unknown severity, disposition, bad line, over-bound text, 101 findings are refused" do
      for bad <- [
            finding_map(%{"severity" => "blocker"}),
            finding_map(%{"disposition" => "wontfix"}),
            finding_map(%{"line" => 0}),
            finding_map(%{"line" => "3"}),
            finding_map(%{"description" => String.duplicate("x", 1001)}),
            finding_map(%{"description" => " "}),
            finding_map(%{"source" => String.duplicate("s", 65)}),
            finding_map(%{"path" => String.duplicate("p", 1025)}),
            "not a map"
          ] do
        assert {:error, :findings} = PrEvidence.validate_findings("recorded", [bad], nil, nil)
      end

      assert {:error, :findings} =
               PrEvidence.validate_findings(
                 "recorded",
                 List.duplicate(finding_map(), 101),
                 nil,
                 nil
               )

      assert {:ok, _} =
               PrEvidence.validate_findings(
                 "recorded",
                 List.duplicate(finding_map(), 100),
                 nil,
                 nil
               )
    end

    test "findings on a non-recorded status, a defect off malformed, an unknown defect are refused" do
      assert {:error, :findings} =
               PrEvidence.validate_findings("absent", [finding_map()], nil, nil)

      assert {:error, :findings} =
               PrEvidence.validate_findings("malformed", [finding_map()], "invalid_json", nil)

      assert {:error, :defect} = PrEvidence.validate_findings("recorded", [], "invalid_json", nil)
      assert {:error, :defect} = PrEvidence.validate_findings("malformed", [], "weird", nil)
      assert {:error, :defect} = PrEvidence.validate_findings("malformed", [], nil, nil)
      assert {:error, :status} = PrEvidence.validate_findings("clean", [], nil, nil)

      assert {:error, :defect_detail} =
               PrEvidence.validate_findings(
                 "malformed",
                 [],
                 "invalid_json",
                 String.duplicate("d", 501)
               )

      assert {:ok, %{status: "absent", findings: [], defect: nil}} =
               PrEvidence.validate_findings(:absent, nil, nil, nil)
    end
  end

  describe "judgement validation (TRD-041)" do
    @absent %{status: "absent", level: nil, rationale: nil, defect: nil, defect_detail: nil}

    test "nil and a bare absent map are the absent judgement" do
      assert {:ok, @absent} = PrEvidence.validate_judgement(nil)
      assert {:ok, @absent} = PrEvidence.validate_judgement(%{status: "absent"})

      assert {:ok, @absent} =
               PrEvidence.validate_judgement(%{"status" => "absent", "level" => nil})
    end

    test "a valid recorded judgement keeps its level and rationale, at the 1000 character bound" do
      for level <- ~w(LOW MEDIUM HIGH) do
        assert {:ok, %{status: "recorded", level: ^level, rationale: "why", defect: nil}} =
                 PrEvidence.validate_judgement(%{
                   status: "recorded",
                   level: level,
                   rationale: "why"
                 })
      end

      edge = String.duplicate("é", 1000)

      assert {:ok, %{rationale: ^edge}} =
               PrEvidence.validate_judgement(%{status: "recorded", level: "LOW", rationale: edge})

      # a newline and a tab stay
      assert {:ok, _} =
               PrEvidence.validate_judgement(%{
                 status: "recorded",
                 level: "LOW",
                 rationale: "a\nb\tc"
               })
    end

    test "a valid malformed judgement keeps its defect and detail" do
      assert {:ok,
              %{status: "malformed", defect: "multiple_blocks", defect_detail: "two", level: nil}} =
               PrEvidence.validate_judgement(%{
                 status: "malformed",
                 defect: "multiple_blocks",
                 defect_detail: "two"
               })

      assert {:ok, %{status: "malformed", defect: "invalid_json", defect_detail: nil}} =
               PrEvidence.validate_judgement(%{status: "malformed", defect: "invalid_json"})
    end

    test "a rationale with a control character or over 1000 characters is refused" do
      base = %{status: "recorded", level: "LOW"}

      for bad <- ["a\e[31mb", "a\0b", "a\rb", "a\x7Fb", String.duplicate("x", 1001), "", "   ", 5] do
        assert {:error, :judgement} =
                 PrEvidence.validate_judgement(Map.put(base, :rationale, bad))
      end
    end

    test "an absent judgement with a companion field is refused" do
      for extra <- [
            %{level: "LOW"},
            %{rationale: "x"},
            %{defect: "invalid_json"},
            %{defect_detail: "x"}
          ] do
        assert {:error, :judgement} =
                 PrEvidence.validate_judgement(Map.put(extra, :status, "absent"))
      end
    end

    test "a malformed judgement needs a known defect and carries no level or rationale" do
      for bad <- [
            %{status: "malformed"},
            %{status: "malformed", defect: "nonsense"},
            %{status: "malformed", defect: "invalid_json", level: "HIGH"},
            %{status: "malformed", defect: "invalid_json", rationale: "x"},
            %{
              status: "malformed",
              defect: "invalid_json",
              defect_detail: String.duplicate("x", 501)
            }
          ] do
        assert {:error, :judgement} = PrEvidence.validate_judgement(bad)
      end
    end

    test "a recorded judgement needs a level in LOW, MEDIUM, HIGH and a rationale, and no defect" do
      for bad <- [
            %{status: "recorded", rationale: "x"},
            %{status: "recorded", level: "CRITICAL", rationale: "x"},
            %{status: "recorded", level: "low", rationale: "x"},
            %{status: "recorded", level: "LOW"},
            %{status: "recorded", level: "LOW", rationale: "x", defect: "invalid_json"},
            %{status: "recorded", level: "LOW", rationale: "x", defect_detail: "d"}
          ] do
        assert {:error, :judgement} = PrEvidence.validate_judgement(bad)
      end
    end

    test "an unknown key, an unknown status and a non-map are refused" do
      assert {:error, :judgement} =
               PrEvidence.validate_judgement(%{
                 status: "recorded",
                 level: "LOW",
                 rationale: "x",
                 extra: 1
               })

      assert {:error, :judgement} = PrEvidence.validate_judgement(%{status: "clean"})
      assert {:error, :judgement} = PrEvidence.validate_judgement(%{})
      assert {:error, :judgement} = PrEvidence.validate_judgement("HIGH")
      assert {:error, :judgement} = PrEvidence.validate_judgement([])
    end

    test "string-keyed (replayed) input normalises to the same atom-keyed map" do
      atom_keyed = %{status: "recorded", level: "HIGH", rationale: "touches auth"}
      string_keyed = %{"status" => "recorded", "level" => "HIGH", "rationale" => "touches auth"}

      assert {:ok, expected} = PrEvidence.validate_judgement(atom_keyed)
      assert PrEvidence.normalise_judgement(string_keyed) == expected
      assert PrEvidence.normalise_judgement(atom_keyed) == expected

      assert expected == %{
               status: "recorded",
               level: "HIGH",
               rationale: "touches auth",
               defect: nil,
               defect_detail: nil
             }
    end

    test "normalise_judgement falls back to absent and mints no atom from an unknown string key" do
      key = "unknown_judgement_key_#{System.unique_integer([:positive])}"

      assert @absent ==
               PrEvidence.normalise_judgement(%{
                 "status" => "recorded",
                 "level" => "HIGH",
                 "rationale" => "x",
                 key => 1
               })

      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

      for bad <- [nil, "HIGH", %{"status" => "recorded", "level" => "CRITICAL"}, %{status: 1}] do
        assert PrEvidence.normalise_judgement(bad) == @absent
      end
    end
  end

  describe "findings evidence (both folds)" do
    defp findings_event(head, extra \\ %{}) do
      {"ReviewFindingsRecorded",
       Map.merge(
         %{
           head_sha: head,
           status: "recorded",
           findings: [finding_map()],
           defect: nil,
           defect_detail: nil,
           artifact_path: "/w/review.md",
           artifact_sha256: String.duplicate("b", 64),
           digest: "dg-#{head}",
           recorded_at: 7
         },
         extra
       )}
    end

    test "the record is stored with its head and digest, identically by the aggregate and the projection" do
      {aggregate, projection} = records = fold_both([findings_event("h1")])

      assert {same, same} = shared(records)

      assert %{
               head_sha: "h1",
               status: "recorded",
               digest: "dg-h1",
               artifact_path: "/w/review.md",
               recorded_at: 7,
               findings: [%{"severity" => "major"}]
             } = aggregate.evidence.findings

      assert aggregate.evidence.findings == projection.evidence.findings
      # a findings record is not a head observation
      assert aggregate.head_sha == nil
    end

    test "a replayed (string-keyed JSON) stream folds to the same record as the live one" do
      events = [
        findings_event("h1", %{
          status: "malformed",
          findings: [],
          defect: "invalid_json",
          defect_detail: "x"
        }),
        checks_event("h2")
      ]

      live = fold_both(events)

      replayed =
        events
        |> Enum.map(fn {type, payload} ->
          {type, payload |> Jason.encode!() |> Jason.decode!()}
        end)
        |> then(fn stringified ->
          aggregate =
            Enum.reduce(stringified, started(), fn {type, payload}, state ->
              Run.apply_event(state, %{
                event_type: type,
                payload: Map.merge(%{"run_id" => "r1", "pr_url" => @url}, payload)
              })
            end)

          projection =
            Enum.reduce(stringified, %{}, fn {type, payload}, watch ->
              PrWatchFold.fold(
                watch,
                type,
                Map.merge(%{"run_id" => "r1", "pr_url" => @url}, payload)
              )
            end)

          {aggregate.pr_watch[@url], projection["r1"][@url]}
        end)

      assert {same, same} = shared(replayed)
      assert elem(live, 0).evidence.findings == elem(replayed, 0).evidence.findings
      assert elem(live, 1).evidence.findings == elem(replayed, 1).evidence.findings
    end

    test "a head move keeps the record with ITS head: nothing is voided, a malformed code is not lost" do
      {aggregate, projection} =
        records =
        fold_both([
          findings_event("h1", %{
            status: "malformed",
            findings: [],
            defect: "multiple_blocks",
            defect_detail: "two blocks"
          }),
          checks_event("h1"),
          checks_event("h2")
        ])

      assert {same, same} = shared(records)
      assert aggregate.head_sha == "h2"

      assert %{head_sha: "h1", status: "malformed", defect: "multiple_blocks"} =
               aggregate.evidence.findings

      assert aggregate.evidence.findings == projection.evidence.findings

      ctx = %{
        head_sha: "h2",
        policy: %{required: [], version: "v1"},
        now_ms: 1,
        checks_ref: nil
      }

      assert :findings_malformed in Enum.map(
               PrEvidence.evaluate(aggregate, ctx).reasons,
               & &1.code
             )
    end

    test "recorded for h1 reads findings_other_sha for a decision on h2, in both records" do
      {aggregate, projection} = fold_both([findings_event("h1"), review_event("h2")])
      ctx = %{head_sha: "h2", policy: %{required: [], version: "v1"}, now_ms: 1, checks_ref: nil}

      for record <- [aggregate, projection] do
        assert :findings_other_sha in Enum.map(
                 PrEvidence.evaluate(record, ctx).reasons,
                 & &1.code
               )
      end
    end

    test "inputs carry the folded record's head and digest under a policy, for either decided head" do
      {aggregate, projection} = fold_both([findings_event("h1"), checks_event("h2")])

      for record <- [aggregate, projection], decided <- ["h1", "h2"] do
        ctx = %{
          head_sha: decided,
          policy: %{required: [], version: "v1"},
          now_ms: 1,
          checks_ref: nil
        }

        inputs = PrEvidence.evaluate(record, ctx).inputs
        assert inputs.findings_head_sha == "h1"
        assert inputs.findings_digest == "dg-h1"
      end
    end

    test "a later record replaces the earlier one; a malformed payload never raises" do
      {aggregate, _} =
        fold_both([
          findings_event("h1"),
          findings_event("h1", %{status: "absent", findings: [], digest: "dg-b"})
        ])

      assert %{status: "absent", digest: "dg-b", findings: []} = aggregate.evidence.findings

      assert %{evidence: %{findings: %{findings: [], head_sha: nil}}} =
               PrEvidence.apply_event(%{head_sha: nil}, "ReviewFindingsRecorded", %{
                 findings: :junk
               })
    end
  end

  describe "policy_version/1" do
    test "is nil for no gate, order-insensitive, and moves with any entry field" do
      a = %{"name" => "A", "kind" => "check_run"}
      b = %{"name" => "B", "kind" => "check_run"}

      assert PrEvidence.policy_version(nil) == nil
      v = PrEvidence.policy_version([a, b])
      assert v =~ ~r/\A[0-9a-f]{16}\z/
      assert v == PrEvidence.policy_version([b, a])
      assert v == PrEvidence.policy_version([%{name: "A", kind: "check_run"}, b])
      refute v == PrEvidence.policy_version([a])
      refute v == PrEvidence.policy_version([a, Map.put(b, "allow_skipped", true)])
      refute v == PrEvidence.policy_version([a, Map.put(b, "workflow", "ci")])
      refute PrEvidence.policy_version([]) == v
    end
  end

  describe "project_policy/1" do
    alias ForemanServer.ProjectionStore

    defp register!(config) do
      id = "p-policy-#{System.unique_integer([:positive])}"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ProjectRegistered",
            payload: %{project_id: id, path: "/tmp/#{id}", config: config}
          }
        ])

      id
    end

    test "a set list returns the entries and their version" do
      required = [%{"name" => "ci", "kind" => "check_run", "workflow" => "build"}]
      id = register!(%{required_checks: required})

      assert {:ok, %{required: ^required, version: version}} = PrEvidence.project_policy(id)
      assert version == PrEvidence.policy_version(required)
    end

    test "[] is the gate on with no checks, nil is gate off" do
      empty = register!(%{required_checks: []})
      assert {:ok, %{required: [], version: v}} = PrEvidence.project_policy(empty)
      assert is_binary(v)

      off = register!(%{})
      assert {:ok, nil} = PrEvidence.project_policy(off)
    end

    test "a project the projection does not know is an error, not gate off" do
      assert {:error, {:policy_unavailable, :project_not_found}} =
               PrEvidence.project_policy("p-unknown-#{System.unique_integer([:positive])}")

      assert {:error, {:policy_unavailable, _}} = PrEvidence.project_policy(nil)
    end

    test "a projection that does not answer is policy_unavailable, not gate off" do
      stub = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(stub, :kill) end)

      reader = fn id -> GenServer.call(stub, {:project_projection, id}, 20) end

      assert {:error, {:policy_unavailable, {:exit, {:timeout, _}}}} =
               PrEvidence.project_policy("p-1", reader)

      assert {:error, {:policy_unavailable, {:exit, :noproc}}} =
               PrEvidence.project_policy("p-1", fn _ -> exit(:noproc) end)
    end
  end
end
