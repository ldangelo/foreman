defmodule ForemanServer.Overview.PrStateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "r1", project_id: "p1", task_id: "t1"}},
        %{event_type: "RunStarted", payload: %{run_id: "r2", project_id: "p2", task_id: "t2"}}
      ])

    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}
  defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

  defp updated(status, sha \\ "abc"),
    do: ev("PrUpdated", %{run_id: "r1", pr_status: status, head_sha: sha, base_branch: "main"})

  test "unknown run reads nil; a known run without a PR reads defaults" do
    assert ProjectionStore.pr_state("nope") == nil

    assert %{run_id: "r1", pr_state: nil, merge_gate: :none, pr_url: nil, failure_reason: nil} =
             ProjectionStore.pr_state("r1")
  end

  test "returns exactly the documented keys" do
    assert ProjectionStore.pr_state("r1") |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(run_id pr_url pr_number pr_state head_sha base_branch merge_gate
                          merge_gate_at pr_updated_at failure_reason)a)
  end

  test "PrAssociated seeds url and number as an open PR" do
    apply!([
      ev("PrAssociated", %{run_id: "r1", pr_url: "https://g/o/r/pull/7", pr_number: 7})
    ])

    assert %{pr_state: :open, pr_url: "https://g/o/r/pull/7", pr_number: 7, merge_gate: :none} =
             ProjectionStore.pr_state("r1")
  end

  test "PrReady holds the merge gate, approval releases it, PrReset clears it" do
    apply!([ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1", head_sha: "s1"})])

    assert %{pr_state: :open, merge_gate: :pending, head_sha: "s1"} =
             ProjectionStore.pr_state("r1")

    apply!([
      ev("MergeGateApproved", %{
        run_id: "r1",
        approver: "a",
        approver_identity: "a",
        approved_at: 5
      })
    ])

    assert %{merge_gate: :approved, merge_gate_at: 5} = ProjectionStore.pr_state("r1")

    apply!([ev("PrReset", %{run_id: "r1"})])
    assert %{merge_gate: :none, pr_state: :open} = ProjectionStore.pr_state("r1")

    apply!([ev("MergeGatePending", %{run_id: "r1", pr_url: "https://g/p/1", paused_at: 9})])
    assert %{merge_gate: :pending, merge_gate_at: 9} = ProjectionStore.pr_state("r1")
  end

  test "PrUpdated and PrMerged after the run is terminal still fold" do
    apply!([
      ev("RunCompleted", %{run_id: "r1", project_id: "p1"}),
      ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1"}),
      updated("conflicted"),
      updated("merged", "def")
    ])

    assert %{pr_state: :merged, head_sha: "def", base_branch: "main"} =
             ProjectionStore.pr_state("r1")

    assert %{status: "completed"} = ProjectionStore.run("r1")
  end

  test "a merged PR does not reopen on a stale PrUpdated; PrReset does" do
    apply!([updated("merged"), updated("open", "older")])
    assert %{pr_state: :merged} = ProjectionStore.pr_state("r1")

    apply!([ev("PrReset", %{run_id: "r1"})])
    assert %{pr_state: :open} = ProjectionStore.pr_state("r1")
  end

  test "PrMerged event and string statuses fold" do
    apply!([ev("PrMerged", %{run_id: "r1"})])
    assert %{pr_state: :merged} = ProjectionStore.pr_state("r1")
    apply!([ev("PrUpdated", %{"run_id" => "r2", "pr_status" => "closed"})])
    assert %{pr_state: :closed} = ProjectionStore.pr_state("r2")
  end

  test "failure_reason is the RunFailed reason, only for a failed run" do
    apply!([ev("RunFailed", %{run_id: "r1", project_id: "p1", reason: "tests red"})])
    assert %{failure_reason: "tests red"} = ProjectionStore.pr_state("r1")
    assert %{failure_reason: nil} = ProjectionStore.pr_state("r2")
  end

  test "malformed payloads are logged and skipped, later valid events still apply" do
    log =
      capture_log(fn ->
        apply!([
          ev("PrUpdated", %{run_id: "r1", pr_status: "garbage"}),
          ev("PrUpdated", %{pr_status: "merged"}),
          ev("PrReady", %{run_id: "", pr_url: "x"}),
          ev("MergeGateApproved", %{}),
          ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1"})
        ])
      end)

    assert log =~ "skipped malformed PrUpdated"
    assert %{pr_state: :open, merge_gate: :pending} = ProjectionStore.pr_state("r1")
  end

  test "pr_states_for_project groups by project and ignores other projects' runs" do
    apply!([
      ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1"}),
      ev("PrReady", %{run_id: "r2", pr_url: "https://g/p/2"})
    ])

    assert %{"r1" => %{merge_gate: :pending}} =
             states = ProjectionStore.pr_states_for_project("p1")

    assert Map.keys(states) == ["r1"]
    assert ProjectionStore.pr_states_for_project("none") == %{}
  end

  test "replaying the same events yields identical state" do
    events = [
      ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1", head_sha: "s"}),
      ev("MergeGateApproved", %{run_id: "r1", approver: "a", approver_identity: "a"}),
      updated("merged"),
      ev("PrUpdated", %{run_id: "r1", pr_status: "garbage"})
    ]

    capture_log(fn -> apply!(events) end)
    before = ProjectionStore.pr_states_for_project("p1")

    capture_log(fn ->
      ProjectionStoreReset.reset!()
      apply!([ev("RunStarted", %{run_id: "r1", project_id: "p1", task_id: "t1"}) | events])
    end)

    assert ProjectionStore.pr_states_for_project("p1") == before
  end
end
