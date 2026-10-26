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
    assert [%{actions: ["run.cancel", "thread.resolve"]}] = waiting.groups.waiting_on_you
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
    # Distinct clocks per run (the projection stamps events from the caller's
    # `:projection_store_now_ms`), applied out of id order so neither insertion
    # nor id order can produce the expected result.
    for {id, at} <- [{"a", 2_000}, {"b", 1_000}, {"c", 3_000}] do
      Process.put(:projection_store_now_ms, fn -> at end)
      :ok = ProjectionStore.apply_events(run(id))
    end

    Process.delete(:projection_store_now_ms)

    {:ok, overview} = Overview.build("p", now_fun: fn -> @now end)
    cards = overview.groups.working

    assert Enum.map(cards, & &1.thread_id) == ["run:c", "run:a", "run:b"]
    assert Enum.map(cards, & &1.updated_at) == [3_000, 2_000, 1_000]
  end

  test "an unknown configured attention group raises instead of silently never matching" do
    previous = Application.get_env(:foreman_server, :overview)
    Application.put_env(:foreman_server, :overview, attention_groups: [:waiting_on_yuo])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman_server, :overview, previous),
        else: Application.delete_env(:foreman_server, :overview)
    end)

    assert_raise ArgumentError, ~r/waiting_on_yuo/, fn -> Overview.attention_groups() end
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
             ~w(attention counts generated_at groups project_id tabs truncated)

    assert dto["truncated"] == false

    assert dto["groups"] |> Map.keys() |> Enum.sort() ==
             ~w(idle landing ready_for_review resolved waiting_on_you working)

    assert dto["attention"] == %{
             "needed" => true,
             "count" => 2,
             "reasons" => ["failed", "pr_ready"]
           }

    assert dto["generated_at"] == "1970-01-12T13:46:40.000Z"
  end

  describe "the 500-thread bound" do
    defp fill(project, count) do
      :ok =
        ProjectionStore.apply_events(
          for i <- 1..count do
            id = "fill-#{project}-#{i}"
            ev("RunStarted", %{run_id: id, task_id: "t-" <> id, project_id: project})
          end
        )
    end

    test "a project over the bound is reported truncated, with only the newest threads counted" do
      limit = ForemanServer.Threads.max_limit()
      fill("big", limit + 1)

      {:ok, overview} = Overview.build("big", now_fun: fn -> @now end)
      assert overview.truncated
      assert Enum.sum(Map.values(overview.counts)) == limit
      assert Overview.summary("big").truncated
      assert Overview.to_dto(overview)["truncated"] == true
      assert %{"big" => %{truncated: true}} = Overview.summaries(["big"])
    end

    test "exactly at the bound is not truncated" do
      limit = ForemanServer.Threads.max_limit()
      fill("exact", limit)

      {:ok, overview} = Overview.build("exact", now_fun: fn -> @now end)
      refute overview.truncated
      assert Enum.sum(Map.values(overview.counts)) == limit
    end
  end

  test "project_fields_many equals project_fields per project but builds the threads once" do
    seed()
    :ok = ProjectionStore.apply_events(run("calm", "calm-project"))

    projects = [
      %{project_id: "p"},
      %{project_id: "calm-project"},
      %{project_id: "p", archived?: true},
      %{name: "no id"}
    ]

    expected = Enum.map(projects, &Overview.project_fields/1)

    mfa = {ProjectionStore, :thread_inputs, 0}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      assert Overview.project_fields_many(projects) == expected
      assert {:call_count, 1} = :erlang.trace_info(mfa, :call_count)
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end

    assert [
             %{attention_count: 2},
             %{attention_count: 0},
             %{attention_count: 0},
             %{attention_count: 0}
           ] =
             expected

    assert [%{attention: %{"needed" => true}} | _] = expected
  end
end
