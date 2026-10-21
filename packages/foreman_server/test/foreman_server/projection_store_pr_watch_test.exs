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
