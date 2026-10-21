defmodule ForemanServer.Coordinator.ReporterTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Agent.Stub, ReportFormatter, Reporter, Turn}
  alias ForemanServer.{CommandGateway, ProjectionStore}

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.SpyGateway

  setup %{tmp_dir: dir} do
    :ok = Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)
    on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)

    project_id = H.register_project(dir)
    SpyGateway.watch()
    H.subscribe!()
    on_exit(&SpyGateway.unwatch/0)
    Process.put(:co_project, project_id)
    script = start_supervised!({Stub, responses: []})
    {:ok, project_id: project_id, script: script}
  end

  defp start_runtime(script, opts \\ []) do
    name = :"co_rep_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          agent: Stub,
          agent_opts: [script: script],
          only: [Process.get(:co_project)],
          gateway: SpyGateway,
          retry_backoff_ms: 0,
          backfill?: false
        ],
        opts
      )

    start_supervised!(
      Supervisor.child_spec({ForemanServer.Coordinator.Supervisor, opts}, id: name)
    )

    name
  end

  # Run ids are scoped to the project: the event store is shared by every test.
  defp rid(p, name), do: "#{p}-#{name}"

  defp record_review(p, name, attrs \\ %{}) do
    run_id = rid(p, name)

    payload =
      Map.merge(
        %{
          subject_kind: "run",
          subject_id: run_id,
          project_id: p,
          verdict: "partially_met",
          scores: %{"tests" => 2, "correctness" => 4},
          summary: "Tests are thin.",
          gap_bead_ids: ["gap-#{run_id}"]
        },
        attrs
      )

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: "review:run:#{run_id}",
        aggregate_id: "review:run:#{run_id}",
        type: "review.record",
        payload: payload
      })
  end

  defp reports(p),
    do:
      for(%{kind: "report"} = m <- elem(ProjectionStore.coordinator_state(p), 1).messages, do: m)

  test "ReviewRecorded for a project thread appends exactly one report and triggers exactly one turn",
       %{project_id: p, script: script} do
    Stub.push(script, [{:ok, %Turn{reply: "Noted the review.", actions: []}}])
    _ = start_runtime(script)

    record_review(p, "run-1")
    H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))

    key = "ReviewRecorded:#{rid(p, "run-1")}"

    assert [%{role: "system", report_key: ^key, text: text, suppressed: false}] =
             reports(p)

    assert text =~ "PARTIALLY_MET" and text =~ "correctness 4, tests 2" and
             text =~ "1 gap bead(s) filed" and text =~ "Tests are thin."

    assert length(Stub.calls(script)) == 1
    [ctx] = Stub.calls(script)
    assert ctx.text =~ "review verdict PARTIALLY_MET"
  end

  test "a second report with the same key appends nothing (duplicate delivery)", %{
    project_id: p,
    script: script
  } do
    Stub.push(script, [{:ok, %Turn{reply: "ok", actions: []}}])
    _ = start_runtime(script)
    record_review(p, "run-1")
    H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))

    {:ok, nil} =
      CommandGateway.dispatch_system(%{
        command_id: "dup-#{System.unique_integer([:positive])}",
        aggregate_id: "coordinator:#{p}",
        type: "coordinator.append",
        payload: %{
          project_id: p,
          message_id: "another-id",
          role: "system",
          kind: "report",
          text: "again",
          report_key: "ReviewRecorded:#{rid(p, "run-1")}"
        }
      })

    assert length(reports(p)) == 1
  end

  test "reports of events missed while the server was down are backfilled once", %{
    project_id: p,
    script: script
  } do
    record_review(p, "run-old")
    assert reports(p) == []

    rt = start_runtime(script, backfill?: true)
    reporter = Reporter.name(rt)
    # backfill runs in handle_continue; a call through the process is a barrier behind it
    :sys.get_state(reporter)
    old_key = "ReviewRecorded:#{rid(p, "run-old")}"
    assert [%{report_key: ^old_key}] = reports(p)

    Reporter.backfill(ForemanServer.Coordinator.Supervisor.runtime(rt, gateway: SpyGateway))
    assert length(reports(p)) == 1
  end

  test "a report about a thread that came from a review gap bead is kept but starts no turn", %{
    project_id: p,
    script: script
  } do
    rt = start_runtime(script)
    gap = "gap-#{p}"
    record_review(p, "run-src", %{bead_id: "src-#{p}", gap_bead_ids: [gap], verdict: "met"})
    H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))

    record_review(p, "run-gap", %{bead_id: gap, verdict: "not_met"})
    :sys.get_state(Reporter.name(rt))
    :sys.get_state(rt)

    gap_key = "ReviewRecorded:#{rid(p, "run-gap")}"

    assert [%{suppressed: false}, %{report_key: ^gap_key, suppressed: true}] =
             reports(p)

    assert {:ok, %{pending_messages: 0}} = ProjectionStore.coordinator_status(p)
    assert length(Stub.calls(script)) == 1
  end

  test "reports beyond report_turns_per_hour are listed but stop triggering turns, and the suppression is announced once",
       %{project_id: p, script: script} do
    previous = Application.get_env(:foreman_server, :coordinator)

    Application.put_env(
      :foreman_server,
      :coordinator,
      Keyword.put(previous, :report_turns_per_hour, 2)
    )

    on_exit(fn -> Application.put_env(:foreman_server, :coordinator, previous) end)

    rt = start_runtime(script)
    record_review(p, "r1")
    H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))
    record_review(p, "r2")
    H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))
    record_review(p, "r3")
    record_review(p, "r4")
    :sys.get_state(Reporter.name(rt))

    assert Enum.map(reports(p), & &1.suppressed) == [false, false, true, true]

    notices =
      for %{kind: "notice"} = m <- elem(ProjectionStore.coordinator_state(p), 1).messages,
          do: m.text

    assert [notice] = notices
    assert notice =~ "Too many thread reports"
    assert length(Stub.calls(script)) == 2
  end

  test "unrelated and malformed events are ignored", %{project_id: p, script: script} do
    rt = start_runtime(script)

    send(
      Reporter.name(rt),
      {:projection_event, %{event_type: "ReviewRecorded", data: %{subject_kind: "run"}}}
    )

    send(Reporter.name(rt), {:projection_event, %{event_type: "Whatever", data: %{}}})
    send(Reporter.name(rt), :noise)
    :sys.get_state(Reporter.name(rt))
    assert reports(p) == []
  end

  describe "ReportFormatter" do
    test "is bounded and one paragraph" do
      review = %{
        verdict: "not_met",
        scores: nil,
        summary: String.duplicate("long\nsummary ", 500),
        gap_bead_ids: []
      }

      text = ReportFormatter.format("ReviewRecorded", %{thread_id: "run:1", title: "T"}, review)
      assert byte_size(text) <= 1_520
      refute text =~ "\n"
      assert text =~ "[truncated]"
    end

    test "failures carry the reason, cancellations do not" do
      assert ReportFormatter.format(
               "RunFailed",
               %{thread_id: "run:1", title: "T", reason: "worker crashed"},
               %{}
             ) =~ "Reason: worker crashed"

      assert ReportFormatter.format("RunCancelled", %{thread_id: "run:1"}, %{}) =~ "was cancelled"
    end
  end
end
