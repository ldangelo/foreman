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

  describe "non-primary repositories' PR states (E12)" do
    defp b_ready(run_id \\ "r1", repo_id \\ "b", n \\ 2) do
      ev("PrReady", %{
        run_id: run_id,
        repo_id: repo_id,
        pr_url: "https://g/#{repo_id}/pull/#{n}",
        pr_number: n,
        head_sha: "sha-#{repo_id}"
      })
    end

    test "a run with no other repository's PR reads []; so does an unknown run" do
      apply!([ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1"})])
      assert ProjectionStore.repo_pr_states("r1") == []
      assert ProjectionStore.repo_pr_states("nope") == []
      assert ProjectionStore.repo_pr_states_for_project("p1") == %{}
    end

    test "a repo_id event folds into its own view and leaves the primary's untouched" do
      apply!([
        ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1", head_sha: "sha-a"}),
        b_ready()
      ])

      assert [view] = ProjectionStore.repo_pr_states("r1")

      assert %{
               run_id: "r1",
               repo_id: "b",
               pr_url: "https://g/b/pull/2",
               pr_number: 2,
               pr_state: :open,
               head_sha: "sha-b",
               merge_gate: :pending
             } = view

      assert view |> Map.keys() |> Enum.sort() ==
               Enum.sort(
                 ~w(run_id repo_id pr_url pr_number pr_state head_sha base_branch merge_gate
                    merge_gate_at pr_updated_at)a
               )

      assert %{pr_url: "https://g/p/1", head_sha: "sha-a", merge_gate: :pending} =
               ProjectionStore.pr_state("r1")
    end

    # `Map.update(state, :repo_pr_states, %{}, fun)` stores the default WITHOUT calling `fun` when
    # the key is absent, and a fresh projection has no such key: the first repo_id event was lost
    # unless a primary PR event had created the key before it.
    test "the first PR event of a fresh projection may be a non-primary repository's" do
      apply!([b_ready()])

      assert [%{repo_id: "b", pr_state: :open, pr_url: "https://g/b/pull/2"}] =
               ProjectionStore.repo_pr_states("r1")
    end

    test "views are ordered by repo_id and each repository keeps its own state" do
      apply!([
        b_ready("r1", "c", 3),
        b_ready("r1", "b", 2),
        ev("PrUpdated", %{run_id: "r1", repo_id: "b", pr_status: "merged", head_sha: "sha-b"}),
        ev("MergeGateApproved", %{
          run_id: "r1",
          repo_id: "c",
          approver: "a",
          approver_identity: "a"
        })
      ])

      assert [
               %{repo_id: "b", pr_state: :merged, merge_gate: :pending},
               %{repo_id: "c", pr_state: :open, merge_gate: :approved}
             ] = ProjectionStore.repo_pr_states("r1")
    end

    test "repo_pr_states_for_project keys runs with such a PR and ignores other projects" do
      apply!([
        ev("PrReady", %{run_id: "r1", pr_url: "https://g/p/1"}),
        b_ready("r1"),
        b_ready("r2", "b", 9)
      ])

      assert %{"r1" => [%{repo_id: "b", run_id: "r1"}]} =
               states = ProjectionStore.repo_pr_states_for_project("p1")

      assert Map.keys(states) == ["r1"]
      assert Map.keys(ProjectionStore.repo_pr_states_for_project("p2")) == ["r2"]
      assert ProjectionStore.repo_pr_states_for_project("none") == %{}
    end

    test "replaying the same events yields identical per-repository state" do
      events = [
        b_ready(),
        ev("MergeGateApproved", %{
          run_id: "r1",
          repo_id: "b",
          approver: "a",
          approver_identity: "a"
        }),
        ev("PrUpdated", %{run_id: "r1", repo_id: "b", pr_status: "merged", observed_at: 7})
      ]

      apply!(events)
      before = ProjectionStore.repo_pr_states_for_project("p1")
      assert [%{pr_state: :merged, merge_gate: :approved, pr_updated_at: 7}] = before["r1"]

      ProjectionStoreReset.reset!()
      apply!([ev("RunStarted", %{run_id: "r1", project_id: "p1", task_id: "t1"}) | events])

      assert ProjectionStore.repo_pr_states_for_project("p1") == before
    end
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
