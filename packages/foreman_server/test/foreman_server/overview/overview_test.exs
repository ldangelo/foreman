defmodule ForemanServer.OverviewTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @now 1_000_000_000

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp run(id, project \\ "p", extra \\ []) do
    [ev("RunStarted", %{run_id: id, task_id: "t-" <> id, project_id: project}) | extra]
  end

  defp seed do
    events =
      run("working") ++
        run("ready", "p", [
          ev("RunCompleted", %{run_id: "ready", project_id: "p"}),
          ev("PrReady", %{run_id: "ready", pr_url: "https://g/p/1"})
        ]) ++
        run("landing", "p", [
          ev("RunCompleted", %{run_id: "landing", project_id: "p"}),
          ev("PrReady", %{run_id: "landing", pr_url: "https://g/p/2"}),
          ev("MergeGateApproved", %{run_id: "landing", approver: "a", approver_identity: "a"})
        ]) ++
        run("failed", "p", [
          ev("RunFailed", %{run_id: "failed", project_id: "p", reason: "boom"})
        ]) ++
        run("idle", "p", [ev("RunCompleted", %{run_id: "idle", project_id: "p"})]) ++
        run("done", "p", [
          ev("RunCompleted", %{run_id: "done", project_id: "p"}),
          ev("ThreadResolved", %{
            thread_id: "run:done",
            project_id: "p",
            reason: "x",
            resolved_by: "op",
            source: "operator",
            at: "2026-10-20T00:00:00Z"
          })
        ]) ++
        [
          ev("JobsiteStarted", %{
            jobsite_id: "j1",
            repo_path: "/r",
            strategy: "worktree",
            project_id: "p"
          })
        ] ++
        run("other", "q", [
          ev("RunFailed", %{run_id: "other", project_id: "q", reason: "x"})
        ])

    :ok = ProjectionStore.apply_events(events)
  end

  defp ids(cards), do: cards |> Enum.map(& &1.thread_id) |> Enum.sort()

  test "groups threads by real projections and ignores other projects" do
    seed()
    {:ok, overview} = Overview.build("p", include_resolved: true, now_fun: fn -> @now end)

    assert ids(overview.groups.working) == ["jobsite:j1", "run:working"]

    assert ids(overview.groups.ready_for_review) == ["run:ready"]
    assert ids(overview.groups.landing) == ["run:landing"]
    assert ids(overview.groups.waiting_on_you) == ["run:failed"]
    assert ids(overview.groups.idle) == ["run:idle"]
    assert ids(overview.groups.resolved) == ["run:done"]

    assert overview.counts == %{
             ready_for_review: 1,
             waiting_on_you: 1,
             working: 2,
             landing: 1,
             idle: 1,
             resolved: 1
           }

    refute "run:other" in Enum.flat_map(Map.values(overview.groups), &ids/1)
  end

  test "attention is needed iff waiting-on-you or ready-for-review is non-empty" do
    seed()
    {:ok, overview} = Overview.build("p", now_fun: fn -> @now end)
    assert %{needed: true, count: 2, reasons: [:failed, :pr_ready]} = overview.attention
    assert Overview.attention("p") == overview.attention

    :ok = ProjectionStore.apply_events(run("calm", "calm-project"))
    assert %{needed: false, count: 0, reasons: []} = Overview.attention("calm-project")
  end

  test "a working thread with a pending tool-call approval is waiting on you until it is decided" do
    :ok =
      ProjectionStore.apply_events(
        run("needs-ok") ++
          [
            ev("ToolCallRequested", %{
              run_id: "needs-ok",
              tool_call_id: "c1",
              tool_name: "Write",
              requested_at: "2026-10-21T00:01:00Z"
            })
          ]
      )

    {:ok, waiting} = Overview.build("p", now_fun: fn -> @now end)
    assert ["run:needs-ok"] == ids(waiting.groups.waiting_on_you)
    assert [%{reason: :approval}] = waiting.groups.waiting_on_you
    assert %{needed: true, reasons: [:approval]} = waiting.attention

    :ok =
      ProjectionStore.apply_events([
        ev("ToolCallApproved", %{
          run_id: "needs-ok",
          tool_call_id: "c1",
          decided_at: "2026-10-21T00:02:00Z"
        })
      ])

    {:ok, after_decision} = Overview.build("p", now_fun: fn -> @now end)
    assert ["run:needs-ok"] == ids(after_decision.groups.working)
    assert after_decision.groups.waiting_on_you == []
  end

  test "include_resolved false skips resolved cards but keeps the count; limit bounds them" do
    seed()
    :ok = ProjectionStore.apply_events([ev("PrMerged", %{run_id: "idle"})])

    {:ok, without} = Overview.build("p")
    assert without.groups.resolved == []
    assert without.counts.resolved == 2

    {:ok, bounded} = Overview.build("p", include_resolved: true, resolved_limit: 1)
    assert [_one] = bounded.groups.resolved
    assert bounded.counts.resolved == 2
  end

  test "a PrUpdated merged event moves a card from ready_for_review to resolved" do
    seed()
    {:ok, before} = Overview.build("p", include_resolved: true)
    assert "run:ready" in ids(before.groups.ready_for_review)

    :ok =
      ProjectionStore.apply_events([
        ev("PrUpdated", %{run_id: "ready", pr_status: "merged", head_sha: "s"})
      ])

    {:ok, after_merge} = Overview.build("p", include_resolved: true)
    refute "run:ready" in ids(after_merge.groups.ready_for_review)
    assert "run:ready" in ids(after_merge.groups.resolved)
  end

  test "cards are ordered by updated_at descending inside a group" do
    :ok =
      ProjectionStore.apply_events(
        run("a") ++
          run("b") ++ [ev("RunStarted", %{run_id: "c", task_id: "t-c", project_id: "p"})]
      )

    {:ok, overview} = Overview.build("p")
    cards = overview.groups.working

    assert Enum.map(cards, & &1.updated_at) ==
             cards |> Enum.map(& &1.updated_at) |> Enum.sort(:desc)
  end

  test "a paused run that only holds a steer message is working, a plain pause waits on you" do
    :ok =
      ProjectionStore.apply_events(
        run("steered", "p", [
          ev("RunSteerQueued", %{run_id: "steered", message_id: "m1", text: "hi"}),
          ev("RunPaused", %{run_id: "steered"})
        ]) ++ run("paused", "p", [ev("RunPaused", %{run_id: "paused"})])
      )

    {:ok, overview} = Overview.build("p")
    assert [%{reason: :steering}] = overview.groups.working
    assert [%{reason: :paused, actions: actions}] = overview.groups.waiting_on_you
    assert actions == ["run.resume", "thread.resolve"]
  end

  test "no card exposes a merge or approve action; PR groups carry the operator hint as text" do
    seed()
    {:ok, overview} = Overview.build("p", include_resolved: true)
    cards = overview.groups |> Map.values() |> List.flatten()

    for card <- cards, action <- card.actions do
      refute action =~ ~r/merge|approve/i
    end

    assert [%{hint: "operator: foreman run approve-merge/merge"}] =
             overview.groups.ready_for_review
  end

  test "the DTO is string-keyed and whitelisted" do
    seed()
    {:ok, overview} = Overview.build("p", now_fun: fn -> @now end)
    dto = Overview.to_dto(overview)

    assert dto |> Map.keys() |> Enum.sort() ==
             ~w(attention counts generated_at groups project_id tabs)

    assert dto["groups"] |> Map.keys() |> Enum.sort() ==
             ~w(idle landing ready_for_review resolved waiting_on_you working)

    assert dto["attention"] == %{
             "needed" => true,
             "count" => 2,
             "reasons" => ["failed", "pr_ready"]
           }

    assert dto["generated_at"] == "1970-01-12T13:46:40.000Z"
  end
end
