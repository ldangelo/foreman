defmodule ForemanServer.ProjectionStorePrWatchTest do
  @moduledoc """
  The `pr_watch` read model: per-PR records folded from the E9 events, rebuilt
  identically from the JSON event log, tolerant of malformed historical
  payloads, and excluding merged/closed/stopped PRs from `watched_prs/0`.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @a "https://github.com/acme/repo/pull/1"
  @b "https://github.com/acme/repo/pull/2"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp ev(type, payload),
    do: %{
      event_type: type,
      payload: Map.merge(%{run_id: "r1", project_id: "p", task_id: "t"}, payload)
    }

  defp events do
    [
      ev("RunStarted", %{workflow_snapshot: %{}}),
      %{event_type: "PrAssociated", payload: %{run_id: "r1", pr_url: @a, pr_number: 1}},
      ev("PrUpdated", %{
        pr_url: @a,
        pr_status: "open",
        head_sha: "h1",
        base_branch: "main",
        branch_name: "b1"
      }),
      ev("PrChecksChanged", %{
        pr_url: @a,
        head_sha: "h1",
        pr_status: "open",
        checks_state: "failing",
        failing: [%{name: "unit"}, %{name: "lint"}],
        digest: "d1",
        observation_seq: 1
      }),
      ev("PrReviewChanged", %{
        pr_url: @a,
        head_sha: "h1",
        review_decision: "changes_requested",
        comment_ids: ["IC_1"],
        thread_ids: ["T1"],
        digest: "r1",
        observation_seq: 1
      }),
      ev("PrFixRequested", %{pr_url: @a, kind: "ci", attempt: 1, trigger: "auto", head_sha: "h1"}),
      ev("PrFixStarted", %{pr_url: @a, kind: "ci", attempt: 1, jobsite_id: "js-1"})
    ]
  end

  test "folds each event type into one record per run and pr_url" do
    :ok = ProjectionStore.apply_events(events())

    assert [record] = ProjectionStore.pr_watch("r1")

    assert %{
             pr_url: @a,
             status: "open",
             head_sha: "h1",
             base_branch: "main",
             branch_name: "b1",
             checks_state: "failing",
             failing: ["unit", "lint"],
             checks_digest: "d1",
             checks_seq: 1,
             review_decision: "changes_requested",
             review_digest: "r1",
             comment_ids: ["IC_1"],
             thread_ids: ["T1"],
             watching: true,
             agent_review: nil
           } = record

    assert %{attempts: %{"ci" => 1}, in_flight: "js-1", in_flight_kind: "ci"} = record.fix
  end

  test "a fix finishing clears the in-flight marker and records the outcome; exhaustion is per kind" do
    :ok =
      ProjectionStore.apply_events(
        events() ++
          [
            ev("PrFixFinished", %{
              pr_url: @a,
              kind: "ci",
              attempt: 1,
              outcome: "no_change",
              finished_at: 42
            }),
            ev("PrFixExhausted", %{pr_url: @a, kind: "ci", reason: "no_progress", head_sha: "h1"})
          ]
      )

    assert [%{fix: fix}] = ProjectionStore.pr_watch("r1")

    assert %{
             in_flight: nil,
             last_outcome: %{"ci" => "no_change"},
             last_finished_at: 42,
             exhausted: %{"ci" => "h1"}
           } = fix
  end

  test "two PRs on one run are two records" do
    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{workflow_snapshot: %{}}),
        ev("PrUpdated", %{pr_url: @a, pr_status: "open", head_sha: "h1"}),
        ev("PrUpdated", %{pr_url: @b, pr_status: "conflicted", head_sha: "h2"})
      ])

    assert [%{pr_url: @a, status: "open"}, %{pr_url: @b, status: "conflicted"}] =
             ProjectionStore.pr_watch("r1")

    assert Enum.map(ProjectionStore.watched_prs(), & &1.pr_url) |> Enum.sort() == [@a, @b]
  end

  test "PrReadyFailed holds evidence.delivery_issue in the record; the next PrReady clears it, and a replay agrees" do
    failed =
      ev("PrReadyFailed", %{
        pr_url: @a,
        stage: "ready_dispatch",
        reason: "not_found",
        failed_at: 99
      })

    :ok = ProjectionStore.apply_events(events() ++ [failed])
    assert [%{evidence: %{delivery_issue: issue}}] = ProjectionStore.pr_watch("r1")
    assert issue == %{stage: "ready_dispatch", reason: "not_found", failed_at: 99}
    live = ProjectionStore.pr_watch("r1")

    json_events =
      (events() ++ [failed])
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.map(&%{event_type: &1["event_type"], payload: &1["payload"]})

    ProjectionStoreReset.reset!()
    assert :ok = ProjectionStore.apply_events(json_events)
    assert strip(ProjectionStore.pr_watch("r1")) == strip(live)

    :ok = ProjectionStore.apply_events([ev("PrReady", %{pr_url: @a, head_sha: "h1"})])
    assert [%{evidence: %{delivery_issue: nil}}] = ProjectionStore.pr_watch("r1")
  end

  test "ReviewFindingsRecorded holds evidence.findings with its own head across a head move, and a replay agrees" do
    findings =
      ev("ReviewFindingsRecorded", %{
        pr_url: @a,
        head_sha: "h0",
        status: "malformed",
        findings: [],
        defect: "multiple_blocks",
        defect_detail: "two blocks",
        artifact_path: "/w/review.md",
        artifact_sha256: String.duplicate("a", 64),
        digest: "0123456789abcdef",
        recorded_at: 5
      })

    # `events/0` leaves the PR on head h1, so the record is bound to a head other than the PR's
    all = events() ++ [findings]
    :ok = ProjectionStore.apply_events(all)
    assert [%{head_sha: head, evidence: %{findings: record}}] = ProjectionStore.pr_watch("r1")
    assert head != "h0"

    assert %{
             head_sha: "h0",
             status: "malformed",
             defect: "multiple_blocks",
             digest: "0123456789abcdef",
             findings: []
           } = record

    live = ProjectionStore.pr_watch("r1")

    json_events =
      all
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.map(&%{event_type: &1["event_type"], payload: &1["payload"]})

    ProjectionStoreReset.reset!()
    assert :ok = ProjectionStore.apply_events(json_events)
    assert strip(ProjectionStore.pr_watch("r1")) == strip(live)

    :ok =
      ProjectionStore.apply_events([
        ev("PrUpdated", %{pr_url: @a, head_sha: "h9", pr_status: "open"})
      ])

    assert [%{head_sha: "h9", evidence: %{findings: %{head_sha: "h0", status: "malformed"}}}] =
             ProjectionStore.pr_watch("r1")
  end

  describe "the judgement on ReviewFindingsRecorded (TRD-041)" do
    defp findings_event(extra) do
      ev(
        "ReviewFindingsRecorded",
        Map.merge(
          %{
            pr_url: @a,
            head_sha: "h0",
            status: "recorded",
            findings: [],
            defect: nil,
            defect_detail: nil,
            artifact_path: "/w/review.md",
            artifact_sha256: String.duplicate("a", 64),
            digest: "0123456789abcdef",
            recorded_at: 5
          },
          extra
        )
      )
    end

    test "the judgement is held with the findings, for the event's own head, and a JSON replay agrees" do
      judgement = %{
        status: "recorded",
        level: "HIGH",
        rationale: "touches auth",
        defect: nil,
        defect_detail: nil
      }

      all = events() ++ [findings_event(%{judgement: judgement})]
      :ok = ProjectionStore.apply_events(all)

      assert [%{head_sha: pr_head, evidence: %{findings: record}}] =
               ProjectionStore.pr_watch("r1")

      # bound to the head of the findings record, not to the PR's current head
      assert record.head_sha == "h0"
      assert pr_head != "h0"
      assert record.judgement == judgement
      live = ProjectionStore.pr_watch("r1")

      json_events =
        all
        |> Jason.encode!()
        |> Jason.decode!()
        |> Enum.map(&%{event_type: &1["event_type"], payload: &1["payload"]})

      ProjectionStoreReset.reset!()
      assert :ok = ProjectionStore.apply_events(json_events)
      assert strip(ProjectionStore.pr_watch("r1")) == strip(live)
    end

    test "an event written before the field has no judgement and reads as absent" do
      :ok = ProjectionStore.apply_events(events() ++ [findings_event(%{})])

      assert [%{evidence: %{findings: %{judgement: judgement}}}] = ProjectionStore.pr_watch("r1")

      assert judgement == %{
               status: "absent",
               level: nil,
               rationale: nil,
               defect: nil,
               defect_detail: nil
             }
    end

    test "a judgement that does not validate reads as absent, never as a level" do
      bad = %{status: "recorded", level: "CRITICAL", rationale: "x"}
      :ok = ProjectionStore.apply_events(events() ++ [findings_event(%{judgement: bad})])

      assert [%{evidence: %{findings: %{judgement: %{status: "absent", level: nil}}}}] =
               ProjectionStore.pr_watch("r1")
    end
  end

  test "replay from the JSON event log (string keys) rebuilds the identical state" do
    :ok = ProjectionStore.apply_events(events())
    live = ProjectionStore.pr_watch("r1")

    json_events =
      events()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.map(&%{event_type: &1["event_type"], payload: &1["payload"]})

    ProjectionStoreReset.reset!()
    assert :ok = ProjectionStore.apply_events(json_events)

    assert ProjectionStore.pr_watch("r1") |> strip() == strip(live)
  end

  defp strip(records), do: Enum.map(records, &Map.drop(&1, [:updated_at]))

  test "a malformed payload is skipped, later events still apply, nothing raises" do
    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{workflow_snapshot: %{}}),
        %{event_type: "PrChecksChanged", payload: %{run_id: "r1", checks_state: "failing"}},
        ev("PrChecksChanged", %{
          pr_url: @a,
          head_sha: "h1",
          checks_state: "passing",
          digest: "d",
          observation_seq: 1
        })
      ])

    assert [%{pr_url: @a, checks_state: "passing"}] = ProjectionStore.pr_watch("r1")
  end

  test "evidence replays identically from JSON and a malformed stored checks never stops the replay" do
    checks = [%{name: "unit", kind: "check_run", state: "failing"}]

    evidence_events =
      events() ++
        [
          ev("PrChecksChanged", %{
            pr_url: @a,
            head_sha: "h1",
            checks_state: "failing",
            digest: "d2",
            observation_seq: 2,
            checks: checks,
            evidence_digest: "e2",
            observation_ref: "n-1"
          }),
          ev("PrChecksChanged", %{
            pr_url: @a,
            head_sha: "h1",
            checks_state: "failing",
            digest: "d3",
            observation_seq: 3,
            checks: "not a list",
            evidence_digest: "ignored"
          })
        ]

    :ok = ProjectionStore.apply_events(evidence_events)
    live = ProjectionStore.pr_watch("r1")

    assert [
             %{
               evidence: %{
                 checks: %{head_sha: "h1", evidence_digest: "e2", observation_ref: "n-1"}
               }
             }
           ] =
             live

    json_events =
      evidence_events
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.map(&%{event_type: &1["event_type"], payload: &1["payload"]})

    ProjectionStoreReset.reset!()
    assert :ok = ProjectionStore.apply_events(json_events)

    replayed = ProjectionStore.pr_watch("r1")
    assert Enum.map(replayed, & &1.evidence.checks.evidence_digest) == ["e2"]

    assert strip(replayed) |> Enum.map(&Map.delete(&1.evidence.checks, :items)) ==
             strip(live) |> Enum.map(&Map.delete(&1.evidence.checks, :items))
  end

  test "a new head resets the projection's current-head observation and keeps the evidence record" do
    :ok =
      ProjectionStore.apply_events(
        events() ++ [ev("PrUpdated", %{pr_url: @a, pr_status: "open", head_sha: "h2"})]
      )

    assert [
             %{
               head_sha: "h2",
               checks_state: nil,
               failing: [],
               checks_digest: nil,
               review_decision: nil,
               review_digest: nil,
               checks_seq: 1,
               comment_ids: ["IC_1"]
             }
           ] = ProjectionStore.pr_watch("r1")
  end

  test "merged, closed and stopped PRs are not watched; a restart watch brings it back" do
    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{workflow_snapshot: %{}}),
        ev("PrUpdated", %{pr_url: @a, pr_status: "open", head_sha: "h"}),
        ev("PrUpdated", %{pr_url: @b, pr_status: "open", head_sha: "h"})
      ])

    assert length(ProjectionStore.watched_prs()) == 2

    :ok = ProjectionStore.apply_events([ev("PrMerged", %{pr_url: @a})])
    assert [%{pr_url: @b}] = ProjectionStore.watched_prs()

    :ok = ProjectionStore.apply_events([ev("PrWatchStopped", %{pr_url: @b, reason: "operator"})])
    assert [] = ProjectionStore.watched_prs()

    :ok = ProjectionStore.apply_events([ev("PrWatchStarted", %{pr_url: @b, reason: "operator"})])
    assert [%{pr_url: @b, watching: true}] = ProjectionStore.watched_prs()
  end

  test "the run's review verdict shows up as agent_review on every record without altering them" do
    :ok =
      ProjectionStore.apply_events(
        events() ++
          [
            %{
              event_type: "ReviewRecorded",
              payload: %{
                subject_kind: "run",
                subject_id: "r1",
                project_id: "p",
                verdict: "partially_met",
                summary: "s",
                gap_bead_ids: ["bd-1"],
                at: "2026-01-01T00:00:00Z"
              }
            }
          ]
      )

    assert [
             %{
               agent_review: %{
                 verdict: "partially_met",
                 gap_bead_ids: ["bd-1"],
                 at: "2026-01-01T00:00:00Z"
               }
             }
           ] =
             ProjectionStore.pr_watch("r1")
  end

  test "an unknown run has no records" do
    assert ProjectionStore.pr_watch("run-unknown") == []
  end
end
