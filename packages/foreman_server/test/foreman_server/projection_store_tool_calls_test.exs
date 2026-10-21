defmodule ForemanServer.ProjectionStoreToolCallsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{run_id: "r1", task_id: "t1", project_id: "p"}),
        ev("RunStarted", %{run_id: "r2", task_id: "t2", project_id: "q"})
      ])

    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp requested(run_id, id, at, extra \\ %{}) do
    ev(
      "ToolCallRequested",
      Map.merge(
        %{run_id: run_id, tool_call_id: id, tool_name: "Write", requested_at: at},
        extra
      )
    )
  end

  defp decided(type, run_id, id),
    do: ev(type, %{run_id: run_id, tool_call_id: id, decided_at: "2026-10-21T00:05:00Z"})

  test "a requested call is pending with the project resolved from the run, oldest first" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "later", "2026-10-21T00:02:00Z"),
        requested("r1", "earlier", "2026-10-21T00:01:00Z", %{input_summary: "write a.txt"})
      ])

    assert [
             %{tool_call_id: "earlier", project_id: "p", status: "requested"},
             %{tool_call_id: "later"}
           ] =
             ProjectionStore.pending_approvals("p")

    assert ProjectionStore.pending_approvals_by_run("p") == %{"r1" => 2}
    assert ProjectionStore.pending_approvals("q") == []
  end

  test "approved, denied and expired calls leave the pending set but stay readable with status :all" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "a", "2026-10-21T00:01:00Z"),
        requested("r1", "d", "2026-10-21T00:01:01Z"),
        requested("r1", "e", "2026-10-21T00:01:02Z"),
        requested("r1", "f", "2026-10-21T00:01:03Z"),
        decided("ToolCallApproved", "r1", "a"),
        decided("ToolCallDenied", "r1", "d"),
        ev("ToolCallExpired", %{run_id: "r1", tool_call_id: "e", at: "2026-10-21T01:00:00Z"}),
        decided("ToolCallApproved", "r1", "f"),
        ev("ToolCallFinished", %{
          worker_id: "approvals",
          run_id: "r1",
          tool_call_id: "f",
          outcome: "delivered"
        })
      ])

    assert ProjectionStore.pending_approvals("p") == []

    statuses =
      "r1"
      |> ProjectionStore.run_approvals(status: :all)
      |> Map.new(&{&1.tool_call_id, &1.status})

    assert statuses == %{"a" => "approved", "d" => "denied", "e" => "expired", "f" => "finished"}

    # "a" is approved and never settled, so it counts as an undelivered decision
    assert ProjectionStore.approval_counts(["r1"]) == %{
             pending: 0,
             expired: 1,
             failed_deliveries: 1
           }
  end

  test "a worker's ToolCallFinished (no tool_call_id) never settles a pending call" do
    :ok =
      ProjectionStore.apply_events([
        requested("r1", "a", "2026-10-21T00:01:00Z"),
        ev("ToolCallFinished", %{worker_id: "w", run_id: "r1", tool_name: "Write"})
      ])

    assert [%{tool_call_id: "a", status: "requested"}] = ProjectionStore.pending_approvals("p")
  end

  test "a decision for an unknown call and a malformed request are ignored, not fatal" do
    :ok =
      ProjectionStore.apply_events([
        decided("ToolCallApproved", "r1", "ghost"),
        ev("ToolCallRequested", %{run_id: "r1", bogus: true}),
        requested("r1", "ok", "2026-10-21T00:01:00Z")
      ])

    assert [%{tool_call_id: "ok"}] = ProjectionStore.pending_approvals("p")
    assert ProjectionStore.tool_call("r1", "ghost") == nil
  end

  test "the limit bounds a read and replay rebuilds the same projection" do
    events = for n <- 1..5, do: requested("r1", "c#{n}", "2026-10-21T00:0#{n}:00Z")
    :ok = ProjectionStore.apply_events(events)

    assert length(ProjectionStore.project_approvals("p", limit: 2)) == 2

    before = ProjectionStore.pending_approvals("p")
    ProjectionStoreReset.reset!()

    :ok =
      ProjectionStore.apply_events([
        ev("RunStarted", %{run_id: "r1", task_id: "t1", project_id: "p"}) | events
      ])

    assert ProjectionStore.pending_approvals("p") == before
  end
end
