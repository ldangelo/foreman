defmodule ForemanServer.Coordinator.ScenarioTest do
  @moduledoc """
  The executable specification of the product behaviour: paste three tasks, get
  three proposed threads, approve two, hear back from a thread, route a follow-up.
  Real aggregates, gateway, projections and Runner; the agent is scripted (no
  provider); `RunExecutor` is not started (the app's Dispatcher is stopped), so
  task approval is asserted, not execution.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.Agent.Stub
  alias ForemanServer.Coordinator.Turn
  alias ForemanServer.{CommandGateway, ProjectionStore}

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreadActions, FakeThreads, SpyGateway}

  test "paste three tasks -> three open proposals -> approve two -> report back -> follow-up routed",
       %{tmp_dir: dir} do
    :ok = Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)
    on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)

    p = H.register_project(dir)
    SpyGateway.watch()
    FakeThreads.put([])
    H.subscribe!()

    on_exit(fn ->
      SpyGateway.unwatch()
      FakeThreads.clear()
    end)

    script = start_supervised!({Stub, responses: []})
    name = :"co_scn_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {ForemanServer.Coordinator.Supervisor,
         name: name,
         agent: Stub,
         agent_opts: [script: script],
         only: [p],
         gateway: SpyGateway,
         threads: FakeThreads,
         thread_actions: FakeThreadActions,
         retry_backoff_ms: 0,
         backfill?: false},
        id: name
      )
    )

    say = fn id, text ->
      {:ok, _} =
        CommandGateway.dispatch_operator(%{
          command_id: "op-#{id}-#{p}",
          aggregate_id: "coordinator:#{p}",
          type: "coordinator.message",
          payload: %{project_id: p, message_id: id, text: text, source: "cli"}
        })
    end

    state = fn -> elem(ProjectionStore.coordinator_state(p), 1) end
    done = fn -> H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p)) end

    # 1. Three pasted tasks become three OPEN proposals and one proposal notice.
    proposals =
      Enum.map(
        1..3,
        &%{
          "title" => "Task #{&1}",
          "prompt" => "Do task #{&1} exactly",
          "workflow" => "implement"
        }
      )

    Stub.push(script, [
      {:ok,
       %Turn{
         reply: "Three independent tasks; proposing three threads.",
         actions: [%{"kind" => "propose_threads", "threads" => proposals}]
       }}
    ])

    say.("m1", "1. fix login\n2. add export\n3. rename config key")
    done.()

    [%{status: "proposed", result_ref: %{"task_ids" => [t1, t2, t3]}}] =
      state.().actions |> Map.values()

    assert Enum.all?([t1, t2, t3], &(ProjectionStore.task_projection(&1).status == "open"))

    [reply, notice] =
      state.().messages
      |> Enum.filter(&(&1.role in ["coordinator", "system"]))
      |> Enum.map(& &1.text)

    assert reply =~ "proposing three threads"
    assert notice =~ "Task 1" and notice =~ "Task 3" and notice =~ "go ahead"

    # 2. The operator approves two; the third stays open.
    approve = fn _ctx ->
      ids = state.().actions |> Map.values() |> Enum.flat_map(&(&1.result_ref["task_ids"] || []))

      {:ok,
       %Turn{
         reply: "Starting the first two.",
         actions: [%{"kind" => "approve_proposed", "task_ids" => Enum.take(ids, 2)}]
       }}
    end

    Stub.push(script, [approve])
    say.("m2", "go ahead with the first two")
    done.()

    assert ProjectionStore.task_projection(t1).status == "ready"
    assert ProjectionStore.task_projection(t2).status == "ready"
    assert ProjectionStore.task_projection(t3).status == "open"
    run1 = ProjectionStore.task_projection(t1).run_id
    FakeThreads.put([H.thread(p, 1, "completed", id: "run:#{run1}", task_id: t1)])

    # 3. A thread reports back (review verdict): the machine turn may route a follow-up.
    route = %{
      "kind" => "route_followup",
      "thread_id" => "run:#{run1}",
      "message" => "Please add the missing tests the review found."
    }

    Stub.push(script, [
      {:ok,
       %Turn{
         reply: "Task 1 is missing tests; asking the thread to add them.",
         actions: [
           route,
           %{"kind" => "start_thread", "title" => "x", "prompt" => "y", "workflow" => "implement"}
         ]
       }}
    ])

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: "review-#{p}",
        aggregate_id: "review:run:#{run1}",
        type: "review.record",
        payload: %{
          subject_kind: "run",
          subject_id: run1,
          project_id: p,
          verdict: "partially_met",
          summary: "Tests are thin.",
          gap_bead_ids: []
        }
      })

    done.()

    assert_received {:follow_up, "run:" <> _, "Please add the missing tests the review found.",
                     [message_id: "coord-" <> _]}

    [route_record, start_record] =
      state.().actions
      |> Map.values()
      |> Enum.filter(&(&1.turn_id =~ "report:"))
      |> Enum.sort_by(& &1.kind)

    assert {route_record.kind, route_record.status} == {"route_followup", "executed"}
    assert {start_record.kind, start_record.status} == {"start_thread", "rejected"}

    # 4. A later operator follow-up is routed to the same thread, not a duplicate.
    Stub.push(script, [
      {:ok,
       %Turn{reply: "Passed on.", actions: [%{route | "message" => "Also cover the empty case."}]}}
    ])

    say.("m3", "also cover the empty case in task 1")
    done.()
    assert_received {:follow_up, _, "Also cover the empty case.", _}

    # Nothing was merged or approved beyond the two operator-approved tasks; no run was created for task 3.
    types = SpyGateway.drain() |> Enum.map(&elem(&1, 0))
    assert Enum.count(types, &(&1 == "task.create")) == 3
    assert Enum.count(types, &(&1 == "task.approve")) == 2
    refute Enum.any?(types, &(&1 in ~w(merge_approve run.pr.merge project.archive)))

    assert {:ok, %{status: :idle, pending_messages: 0, consecutive_failures: 0}} =
             ProjectionStore.coordinator_status(p)
  end
end
