defmodule ForemanServer.Coordinator.ExecutorTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Action, Commands, Dispatch, Executor, Tuning}
  alias ForemanServer.{CommandGateway, ProjectionStore}

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreadActions, FakeThreads, SpyGateway}

  setup %{tmp_dir: dir} do
    # A TaskApproved projection would let the app-level Dispatcher start a real run.
    :ok = Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)
    on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)

    project_id = H.register_project(dir)
    SpyGateway.watch()
    FakeThreads.put([])

    on_exit(fn ->
      SpyGateway.unwatch()
      FakeThreads.clear()
      FakeThreadActions.clear()
    end)

    {:ok, _} = Commands.turn_start(CommandGateway, project_id, "m1:a1", 1, ["m1"])
    {:ok, project_id: project_id}
  end

  defp ctx(project_id, overrides) do
    base = %{
      project_id: project_id,
      turn_id: "m1:a1",
      trigger_key: "m1",
      authority: :operator,
      operator_texts: ["please fix the login bug; max 2 at a time"],
      tuning: %Tuning{},
      workflows: ["implement"],
      gateway: SpyGateway,
      threads: FakeThreads,
      thread_actions: FakeThreadActions
    }

    struct!(Executor.Ctx, Map.merge(base, overrides))
  end

  defp items(project_id, raws, trigger \\ "m1") do
    Enum.map(raws, fn raw ->
      case Action.normalize(raw, project_id, trigger) do
        {:ok, action} -> {:ok, action}
        {:error, {:invalid_action, reason}} -> {:invalid, raw, reason}
      end
    end)
  end

  defp start(title \\ "Fix login", extra \\ %{}),
    do:
      Map.merge(
        %{
          "kind" => "start_thread",
          "title" => title,
          "prompt" => "Trace: boom",
          "workflow" => "implement"
        },
        extra
      )

  defp run(project_id, raws, overrides \\ %{}) do
    Executor.run(items(project_id, raws), ctx(project_id, overrides))
  end

  defp sent_types, do: Enum.map(SpyGateway.drain(), &elem(&1, 0))

  describe "closed command allowlist" do
    test "the coordinator may dispatch only these command types; no merge, approve-merge, archive or retry" do
      assert Enum.sort(Dispatch.command_types()) ==
               Enum.sort(
                 ~w(task.create task.approve project.update coordinator.append coordinator.action.record coordinator.turn.start coordinator.turn.complete coordinator.turn.fail)
               )

      for forbidden <-
            ~w(merge_approve run.pr.merge project.archive project.register project.reactivate task.retry run.cancel run.reset run.remove thread.resolve inbox.send) do
        assert {:error, {:forbidden_command, ^forbidden}} =
                 Dispatch.system(SpyGateway, %{
                   type: forbidden,
                   command_id: "x",
                   aggregate_id: "run:r",
                   payload: %{}
                 })
      end

      assert SpyGateway.drain() == []
    end

    test "a hijacked model emitting forbidden kinds has every one rejected and recorded, and the gateway sees none of them",
         %{project_id: p} do
      raws = [
        %{"kind" => "merge_approve", "run_id" => "r1"},
        %{"kind" => "run.pr.merge", "run_id" => "r1"},
        %{"kind" => "project.archive", "project_id" => p},
        %{"kind" => "answer", "text" => "ok", "command" => "merge_approve"}
      ]

      outcomes = run(p, raws)
      assert Enum.map(outcomes, & &1.status) == ["rejected", "rejected", "rejected", "rejected"]

      {:ok, conv} = ProjectionStore.coordinator_state(p)
      assert conv.actions |> Map.values() |> Enum.count(&(&1.status == "rejected")) == 4

      types = sent_types()
      assert Enum.all?(types, &(&1 == "coordinator.action.record"))
      assert length(types) == 4
    end
  end

  describe "start_thread" do
    test "creates an open task then approves it; the workflow comes from the catalog, not the model",
         %{project_id: p} do
      assert [%{status: "executed", result_ref: %{"task_ids" => [task_id], "run_id" => run_id}}] =
               run(p, [start()])

      assert is_binary(run_id)

      expected_approver = "coordinator:" <> p

      assert %{
               status: "ready",
               project_id: ^p,
               workflow_type: "implement",
               approved_by: ^expected_approver
             } = ProjectionStore.task_projection(task_id)

      assert Enum.take(sent_types(), 2) == ["task.create", "task.approve"]
    end

    test "an unknown explicit workflow is rejected with the valid list and never reaches task.create",
         %{project_id: p} do
      assert [%{status: "rejected", reason: reason}] =
               run(p, [start("t", %{"workflow" => "hotfix"})])

      assert reason =~ ~s(unknown workflow "hotfix")
      assert reason =~ "implement"
      refute "task.create" in sent_types()
    end

    test "no workflow and no task_type asks instead of guessing", %{project_id: p} do
      raw = %{"kind" => "start_thread", "title" => "t", "prompt" => "p"}
      assert [%{status: "rejected", reason: reason}] = run(p, [raw])
      assert reason =~ "no workflow could be chosen"
    end

    test "propose_before_start forces an open task whatever the model emitted", %{project_id: p} do
      assert [%{status: "proposed", result_ref: %{"task_ids" => [task_id]}}] =
               run(p, [start()], %{tuning: %Tuning{propose_before_start: true}})

      assert %{status: "open"} = ProjectionStore.task_projection(task_id)
      refute "task.approve" in sent_types()
    end

    test "the active thread cap rejects a start beyond it, visibly and before any task exists", %{
      project_id: p
    } do
      FakeThreads.put([
        H.thread(p, 1, "in_progress"),
        H.thread(p, 2, "blocked"),
        H.thread(p, 3, "completed")
      ])

      tuning = %Tuning{max_active_threads: 2}

      assert [%{status: "rejected", reason: "cap_exceeded: active_threads 2"}] =
               run(p, [start()], %{tuning: tuning})

      refute "task.create" in sent_types()
    end

    test "starts inside one turn count against the cap", %{project_id: p} do
      tuning = %Tuning{max_active_threads: 2}
      outcomes = run(p, [start("a"), start("b"), start("c")], %{tuning: tuning})
      assert Enum.map(outcomes, & &1.status) == ["executed", "executed", "rejected"]
      assert List.last(outcomes).reason == "cap_exceeded: active_threads 2"
    end

    test "a bead-matched live thread turns the start into a follow-up when reuse is on", %{
      project_id: p
    } do
      {:ok, _} =
        ForemanServer.CommandGateway.dispatch_system(%{
          command_id: "seed-task",
          aggregate_id: "task:seed",
          type: "task.create",
          payload: %{
            task_id: "seed",
            project_id: p,
            title: "seed",
            external_id: "bd-7",
            provider_tracked: false,
            status: "open"
          }
        })

      FakeThreads.put([H.thread(p, 1, "in_progress", task_id: "seed")])

      assert [
               %{
                 status: "executed",
                 result_ref: %{"thread_id" => "run:r1", "reused_thread" => true}
               }
             ] =
               run(p, [start("again", %{"bead_id" => "bd-7"})])

      assert_received {:follow_up, "run:r1", text, [message_id: "coord-" <> _]}
      assert text =~ "Trace: boom"
      refute "task.create" in sent_types()

      # With reuse off the same action starts a new thread.
      assert [%{status: "executed", result_ref: %{"task_ids" => [_]}}] =
               run(p, [start("again", %{"bead_id" => "bd-7"})], %{
                 tuning: %Tuning{reuse_threads: false},
                 trigger_key: "m2"
               })
    end
  end

  describe "propose_threads and approve_proposed" do
    test "three threads become three open tasks and one proposal notice", %{project_id: p} do
      raw = %{
        "kind" => "propose_threads",
        "threads" =>
          Enum.map(
            1..3,
            &%{"title" => "Task #{&1}", "prompt" => "do #{&1}", "workflow" => "implement"}
          )
      }

      assert [%{status: "proposed", result_ref: %{"task_ids" => ids}} = outcome] = run(p, [raw])
      assert length(ids) == 3
      assert Enum.all?(ids, &(ProjectionStore.task_projection(&1).status == "open"))
      refute "task.approve" in sent_types()

      notice = Executor.notice([outcome])
      assert notice =~ "Task 1" and notice =~ "Task 3" and notice =~ "go ahead"
    end

    test "approve_proposed starts only this project's tasks that this coordinator proposed and that are still open",
         %{project_id: p, tmp_dir: dir} do
      raw = %{
        "kind" => "propose_threads",
        "threads" =>
          Enum.map(1..2, &%{"title" => "T#{&1}", "prompt" => "p#{&1}", "workflow" => "implement"})
      }

      [%{result_ref: %{"task_ids" => [a, b]}}] = run(p, [raw])
      {:ok, conv} = ProjectionStore.coordinator_state(p)

      other = H.register_project(Path.join(dir, "other") |> tap(&File.mkdir_p!/1))

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          command_id: "foreign",
          aggregate_id: "task:foreign-1",
          type: "task.create",
          payload: %{
            task_id: "foreign-1",
            project_id: other,
            title: "x",
            status: "open",
            provider_tracked: false
          }
        })

      approve = %{"kind" => "approve_proposed", "task_ids" => [a, "foreign-1", "never-proposed"]}

      assert [
               %{
                 status: "executed",
                 result_ref: %{"approved" => [%{"task_id" => ^a}], "skipped" => skipped}
               }
             ] =
               run(p, [approve], %{recorded: conv.actions, trigger_key: "m2"})

      assert Enum.map(skipped, & &1["task_id"]) == ["foreign-1", "never-proposed"]
      assert ProjectionStore.task_projection(a).status != "open"
      assert ProjectionStore.task_projection(b).status == "open"
      assert ProjectionStore.task_projection("foreign-1").status == "open"
    end
  end

  describe "route_followup" do
    test "another project's thread is rejected out_of_project and nothing is sent", %{
      project_id: p
    } do
      FakeThreads.put([H.thread("someone-else", 1, "in_progress")])
      raw = %{"kind" => "route_followup", "thread_id" => "run:r1", "message" => "also handle X"}
      assert [%{status: "rejected", reason: reason}] = run(p, [raw])
      assert reason =~ "out_of_project"
      refute_received {:follow_up, _, _, _}
    end

    test "a live thread is steered with an idempotency key; terminal and resolved threads are reported to the model",
         %{project_id: p} do
      FakeThreads.put([H.thread(p, 1, "in_progress")])
      raw = %{"kind" => "route_followup", "thread_id" => "run:r1", "message" => "also handle X"}
      assert [%{status: "executed", result_ref: %{"thread_id" => "run:r1"}}] = run(p, [raw])
      assert_received {:follow_up, "run:r1", "also handle X", [message_id: "coord-" <> _]}

      FakeThreadActions.respond_with({:error, {:not_steerable, "completed"}})
      assert [%{status: "rejected", reason: reason}] = run(p, [raw], %{trigger_key: "m2"})
      assert reason =~ "thread_not_steerable"

      FakeThreadActions.respond_with({:error, :thread_resolved})
      assert [%{status: "rejected"}] = run(p, [raw], %{trigger_key: "m3"})

      assert [%{status: "rejected", reason: reason}] =
               run(p, [%{raw | "thread_id" => "run:ghost"}], %{trigger_key: "m4"})

      assert reason =~ "thread_not_found"
    end
  end

  describe "machine-originated turns cannot expand the work envelope" do
    test "start, approve, forget, tuning, add_repo and schedule are refused; answer and propose are allowed",
         %{project_id: p} do
      raws = [
        start(),
        %{"kind" => "approve_proposed", "task_ids" => ["x"]},
        %{"kind" => "forget", "name" => "n"},
        %{"kind" => "set_tuning", "key" => "max_active_threads", "value" => 50, "quote" => "x"},
        %{"kind" => "add_repo", "path" => "/etc", "quote" => "x"},
        %{"kind" => "schedule", "spec" => "every minute", "quote" => "x"},
        %{"kind" => "answer", "text" => "noted"},
        %{
          "kind" => "propose_threads",
          "threads" => [%{"title" => "follow up", "prompt" => "p", "workflow" => "implement"}]
        }
      ]

      statuses = p |> run(raws, %{authority: :machine}) |> Enum.map(& &1.status)

      assert statuses ==
               ~w(rejected rejected rejected rejected rejected rejected executed proposed)

      types = sent_types()
      refute "task.approve" in types
      refute "project.update" in types
    end
  end

  describe "idempotency" do
    test "re-running the same actions (a crash before they were recorded) creates no second task or approval",
         %{project_id: p} do
      first = run(p, [start()])
      second = run(p, [start()])
      assert [%{result_ref: %{"task_ids" => [id]}}] = first
      assert [%{result_ref: %{"task_ids" => [^id]}}] = second
      assert H.event_count("task:#{id}") == 2

      # The recorded fast path does not even touch the gateway.
      {:ok, conv} = ProjectionStore.coordinator_state(p)
      SpyGateway.drain()
      assert [%{status: "executed"}] = run(p, [start()], %{recorded: conv.actions})
      assert sent_types() == []
    end

    test "the per-turn action cap rejects the excess", %{project_id: p} do
      raws = Enum.map(1..4, &%{"kind" => "answer", "text" => "a#{&1}"})
      statuses = p |> run(raws, %{max_actions: 2}) |> Enum.map(& &1.status)
      assert statuses == ["executed", "executed", "rejected", "rejected"]
    end
  end
end
