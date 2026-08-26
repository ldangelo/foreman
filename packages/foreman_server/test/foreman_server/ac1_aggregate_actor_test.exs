defmodule ForemanServer.AC1AggregateActorTest do
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # AC1: Aggregate actor model — empirical tests for custom Actor + CommandRouter.
  #
  # Six asserted behaviors:
  # AC1.1  Serialization — concurrent commands to same aggregate are queued in order
  # AC1.2  Stream rehydration on startup — state rebuilt from event store before first cmd
  # AC1.3  Crash + eager reopen with :permanent — supervisor restarts immediately, rehydrates
  # AC1.4  Post-restart command correctness — next command uses rehydrated state
  # AC1.5  Append-then-apply — conflict → aggregate state unchanged, event store authoritative
  # AC1.6  In-flight event lost on crash — event not appended before aggregate death
  #
  # Blocking infrastructure (BlockCommand, BlockingAggregate) lives in test/support/.
  # ---------------------------------------------------------------------------

  alias ForemanServer.{Aggregate, CommandRouter, RunAdmission}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.{BlockCommand, BlockingAggregate, RunSlotsReset, TestRouter}

  setup do
    # `RunAdmission.start/2` is the seed path for every AC1.* test. The
    # shared `run_slots:global` aggregate would otherwise accumulate
    # holders from prior suites or earlier examples in this file and
    # return `:slot_queued` for fresh admissions.
    RunSlotsReset.reset!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_run(run_id, task_id) do
    project_id = "project-#{uuid()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: System.tmp_dir!()},
        aggregate_id: "project:#{project_id}"
      })

    RunAdmission.start(project_id, %{
      run_id: run_id,
      task_id: task_id,
      workflow_snapshot: %{phases: []},
      phase_specs: []
    })
  end

  defp start_phase(run_id, phase_id) do
    CommandRouter.dispatch(%{
      type: "phase.start",
      payload: %{
        phase_id: phase_id,
        run_id: run_id,
        index: 1,
        name: "test",
        attempt: 1,
        artifact_template: "report.md"
      },
      aggregate_id: "phase:#{run_id}:#{phase_id}"
    })
  end

  defp complete_phase_payload(run_id, phase_id) do
    %{
      phase_id: phase_id,
      run_id: run_id,
      index: 1,
      artifact_path: "report.md",
      artifact_sha256: String.duplicate("a", 64),
      artifact_bytes: 1
    }
  end

  defp aggregate_pid(aggregate_id) do
    [{pid, _}] = Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id)
    pid
  end

  defp await_actor_alive(aggregate_id, retries) do
    Enum.reduce_while(1..retries, nil, fn _, _ ->
      case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
        [{pid, _}] when is_pid(pid) ->
          if Process.alive?(pid) do
            {:halt, {:ok, pid}}
          else
            :timer.sleep(10)
            {:cont, nil}
          end

        [] ->
          :timer.sleep(10)
          {:cont, nil}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  defp maybe_retry(_i, _retries), do: {:halt, {:error, :actor_not_alive}}

  # ---------------------------------------------------------------------------
  # AC1.1 — Serialization
  # ---------------------------------------------------------------------------

  test "AC1.1: two BlockCommands to same stream are serialized in order" do
    agg_id = "blocking:#{uuid()}"
    ref1 = make_ref()
    ref2 = make_ref()
    test_pid = self()

    task1 =
      Task.async(fn ->
        TestRouter.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :serial_test,
          ref: ref1,
          notify_pid: test_pid
        })
      end)

    assert_receive {:block_entered, ^ref1, _pid1}, 5_000

    task2 =
      Task.async(fn ->
        TestRouter.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :serial_test,
          ref: ref2,
          notify_pid: test_pid
        })
      end)

    refute_receive {:block_entered, ^ref2, _}, 100

    pid = aggregate_pid(agg_id)
    send(pid, {:release, ref1})
    assert_receive {:block_entered, ^ref2, pid2}, 5_000
    send(pid2, {:release, ref2})

    {:ok, _} = Task.await(task1)
    {:ok, _} = Task.await(task2)

    {:ok, events} = Store.read_stream_forward(agg_id, 0, 10)
    assert length(events) == 2
    types = Enum.map(events, & &1.event_type)
    assert types == ["BlockEvent", "BlockEvent"]
  end

  # ---------------------------------------------------------------------------
  # AC1.2 — Stream rehydration on startup (per-aggregate tests, static data)
  # ---------------------------------------------------------------------------

  test "AC1.2: Project aggregate rehydrates state from event store on startup" do
    id = "proj-#{uuid()}"
    agg_stream = "project:#{id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: id, path: "/tmp/p"},
        aggregate_id: agg_stream
      })

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert Map.get(state, :project_id) == id
    assert Map.get(state, :path) == "/tmp/p"

    projected = ForemanServer.ProjectionStore.project(id)
    assert projected != nil, "ProjectionStore must have projected the ProjectRegistered event"
    assert Map.get(projected, :project_id) == id
    assert Map.get(projected, :path) == "/tmp/p"
    assert Map.get(projected, :status) == "active"
  end

  test "AC1.2: Task aggregate rehydrates state from event store on startup" do
    id = "task-#{uuid()}"
    project_id = "proj-#{uuid()}"
    agg_stream = "task:#{id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "task.create",
        payload: %{task_id: id, project_id: project_id},
        aggregate_id: agg_stream
      })

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert Map.get(state, :task_id) == id
    assert Map.get(state, :project_id) == project_id
  end

  test "AC1.2: Run aggregate rehydrates state from event store on startup" do
    id = "run-#{uuid()}"
    task_id = "task-#{uuid()}"
    agg_stream = "run:#{id}"

    {:ok, _} = start_run(id, task_id)

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert Map.get(state, :run_id) == id
    assert Map.get(state, :task_id) == task_id
  end

  test "AC1.2: Worker aggregate rehydrates state from event store on startup" do
    id = "worker-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "worker:#{run_id}:#{id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "worker.record",
        payload: %{
          worker_id: id,
          run_id: run_id,
          event_type: "WorkerStarted",
          session_id: "sess-#{id}",
          adapter: "AC1.TestAdapter",
          prompt_path: "/tmp/prompt-#{id}"
        },
        aggregate_id: agg_stream
      })

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert Map.get(state, :worker_id) == id
    assert Map.get(state, :run_id) == run_id
    assert Map.get(state, :status) == "running"
  end

  test "AC1.2: Phase aggregate rehydrates state from event store on startup" do
    id = "phase-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "phase:#{run_id}:#{id}"

    {:ok, _} = start_phase(run_id, id)

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert Map.get(state, :phase_id) == id
    assert Map.get(state, :run_id) == run_id
    assert Map.get(state, :status) == "in_progress"
  end

  # ---------------------------------------------------------------------------
  # AC1.3 — Crash + eager reopen with :permanent (per-aggregate tests, static data)
  # ---------------------------------------------------------------------------

  test "AC1.3: Project :permanent crash, immediate restart, stream replay" do
    id = "proj-#{uuid()}"
    agg_stream = "project:#{id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: id, path: "/tmp/p"},
        aggregate_id: agg_stream
      })

    old_pid = aggregate_pid(agg_stream)
    assert Process.alive?(old_pid)

    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not emit DOWN after :kill")
    end

    assert {:ok, new_pid} = await_actor_alive(agg_stream, 50)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.archive",
        payload: %{project_id: id},
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(new_pid)
    assert Map.get(state, :status) == "archived"
  end

  test "AC1.3b: project archive active-run conflict returns detailed domain error without crashing the actor" do
    project_id = "proj-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "project:#{project_id}"

    assert {:ok, _} =
             CommandRouter.dispatch(%{
               type: "project.register",
               payload: %{project_id: project_id, path: "/tmp/p"},
               aggregate_id: agg_stream
             })

    assert {:ok, _} =
             CommandRouter.dispatch(%{
               command_id: "reserve:#{project_id}:#{run_id}",
               type: "project.reserve_run",
               payload: %{
                 project_id: project_id,
                 run_id: run_id,
                 command_id: "run-start:#{project_id}:#{run_id}",
                 sequence: 1,
                 run_start_payload: %{
                   project_id: project_id,
                   run_id: run_id,
                   task_id: "task-#{uuid()}",
                   workflow_snapshot: %{}
                 }
               },
               aggregate_id: agg_stream
             })

    assert {:error, :project_has_active_runs, [^run_id]} =
             CommandRouter.dispatch(%{
               type: "project.archive",
               payload: %{project_id: project_id},
               aggregate_id: agg_stream
             })

    actor_pid = aggregate_pid(agg_stream)
    assert Process.alive?(actor_pid)
    state = Aggregate.Actor.get_state(actor_pid)
    assert Map.get(state, :archived?) == false
    assert Map.has_key?(state.active_run_reservations, run_id)
  end

  test "AC1.3: Task :permanent crash, immediate restart, stream replay" do
    id = "task-#{uuid()}"
    project_id = "proj-#{uuid()}"
    agg_stream = "task:#{id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "task.create",
        payload: %{task_id: id, project_id: project_id},
        aggregate_id: agg_stream
      })

    old_pid = aggregate_pid(agg_stream)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not emit DOWN after :kill")
    end

    assert {:ok, new_pid} = await_actor_alive(agg_stream, 50)

    # After replay, the actor must still respond to commands. Use
    # `task.create` again — `task.close` was pruned in TRD-049; replaying
    # the existing TaskCreated event confirms the actor's mailbox and
    # `handle_command` path is healthy.
    assert {:error, {:already_exists, :task, ^id}} =
             CommandRouter.dispatch(%{
               type: "task.create",
               payload: %{task_id: id, project_id: project_id},
               aggregate_id: agg_stream
             })

    state = Aggregate.Actor.get_state(new_pid)
    assert Map.get(state, :task_id) == id
  end

  test "AC1.3: Run :permanent crash, immediate restart, stream replay" do
    id = "run-#{uuid()}"
    task_id = "task-#{uuid()}"
    agg_stream = "run:#{id}"

    {:ok, _} = start_run(id, task_id)

    old_pid = aggregate_pid(agg_stream)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not emit DOWN after :kill")
    end

    assert {:ok, new_pid} = await_actor_alive(agg_stream, 50)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "run.complete",
        payload: %{run_id: id},
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(new_pid)
    assert Map.get(state, :status) == "completed"
  end

  test "AC1.3: Worker :permanent crash, immediate restart, stream replay" do
    id = "worker-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "worker:#{run_id}:#{id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "worker.record",
        payload: %{
          worker_id: id,
          run_id: run_id,
          event_type: "WorkerStarted",
          session_id: "sess-#{id}",
          adapter: "AC1.TestAdapter",
          prompt_path: "/tmp/prompt-#{id}"
        },
        aggregate_id: agg_stream
      })

    old_pid = aggregate_pid(agg_stream)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not emit DOWN after :kill")
    end

    assert {:ok, new_pid} = await_actor_alive(agg_stream, 50)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "worker.record",
        payload: %{worker_id: id, run_id: run_id, event_type: "WorkerExited"},
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(new_pid)
    # TRD-011: `WorkerExited` is a transition, NOT a terminal marker.
    # Only `WorkerCrashed` seals the worker state. The replayed
    # state should reflect the explicit transition (status "exited").
    assert state.status == "exited"
    refute state.terminal?
  end

  test "AC1.3: Phase :permanent crash, immediate restart, stream replay" do
    id = "phase-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "phase:#{run_id}:#{id}"

    {:ok, _} = start_phase(run_id, id)

    old_pid = aggregate_pid(agg_stream)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not emit DOWN after :kill")
    end

    assert {:ok, new_pid} = await_actor_alive(agg_stream, 50)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "phase.complete",
        payload: complete_phase_payload(run_id, id),
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(new_pid)
    assert Map.get(state, :status) == "completed"
  end

  # ---------------------------------------------------------------------------
  # AC1.4 — Post-restart command correctness
  # ---------------------------------------------------------------------------

  test "AC1.4: after crash+reopen, CompleteRun succeeds because state was rehydrated" do
    run_id = "run-#{uuid()}"
    task_id = "task-#{uuid()}"
    agg_stream = "run:#{run_id}"

    {:ok, _} = start_run(run_id, task_id)

    pid = aggregate_pid(agg_stream)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not exit")
    end

    assert {:ok, new_pid} = await_actor_alive(agg_stream, 50)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "run.complete",
        payload: %{run_id: run_id},
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(new_pid)
    assert Map.get(state, :status) == "completed"

    {:ok, events} = Store.read_stream_forward(agg_stream, 0, 10)
    assert length(events) == 2
  end

  # ---------------------------------------------------------------------------
  # AC1.5 — Append-then-apply: conflict from external append
  # ---------------------------------------------------------------------------

  test "AC1.5: two CompletePhase race — actor reloads, re-decides, rejects on terminal state" do
    # AC-005-3: two CompletePhase commands race. The actor's first append fails
    # with :wrong_expected_version. On retry, the actor reloads state from the
    # stream, re-decides the command, and finds the aggregate already terminal —
    # so it rejects with :phase_terminal instead of producing a duplicate
    # PhaseCompleted event. Exactly-once is preserved.
    phase_id = "phase-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "phase:#{run_id}:#{phase_id}"

    # 1) Start the phase via the actor — stream: PhaseStarted (v1),
    #    actor state: status=in_progress, terminal?=false, version=1.
    {:ok, _} = start_phase(run_id, phase_id)

    actor_pid = aggregate_pid(agg_stream)
    state_after_start = Aggregate.Actor.get_state(actor_pid)
    assert Map.get(state_after_start, :status) == "in_progress"
    refute Map.get(state_after_start, :terminal?)

    # 2) External append of a PhaseCompleted wins the race. The actor's local
    #    state still reflects status=in_progress because it has not reloaded.
    #    Stream: [PhaseStarted, PhaseCompleted] (v1, v2).
    :ok =
      Store.append_to_stream(agg_stream, 1, [
        %Elixir.EventStore.EventData{
          event_type: "PhaseCompleted",
          data: complete_phase_payload(run_id, phase_id),
          metadata: %{}
        }
      ])

    {:ok, events_after_external} = Store.read_stream_forward(agg_stream, 0, 10)
    assert length(events_after_external) == 2

    # 3) The actor dispatches phase.complete. Locally it sees status=in_progress,
    #    so the first handle_command returns PhaseCompleted. The actor appends
    #    with expected_version=1 but actual=2 → :wrong_expected_version.
    #    The retry path reloads state from the stream (PhaseStarted then
    #    PhaseCompleted → status=completed, terminal?=true, version=2) and
    #    re-decides. Re-decision sees terminal state and rejects with
    #    :phase_terminal — no duplicate PhaseCompleted is appended.
    result =
      CommandRouter.dispatch(%{
        type: "phase.complete",
        payload: complete_phase_payload(run_id, phase_id),
        aggregate_id: agg_stream
      })

    assert {:error, :phase_terminal} = result

    assert Process.alive?(actor_pid),
           "aggregate must stay alive after a re-decision rejection"

    # State converged to the reloaded terminal state.
    state = Aggregate.Actor.get_state(actor_pid)
    assert Map.get(state, :status) == "completed"
    assert Map.get(state, :terminal?) == true

    # Stream is unchanged by the rejected retry: still 2 events, one PhaseCompleted.
    {:ok, events_final} = Store.read_stream_forward(agg_stream, 0, 10)
    assert length(events_final) == 2

    assert Enum.map(events_final, & &1.event_type) == [
             "PhaseStarted",
             "PhaseCompleted"
           ]

    completed_count =
      events_final
      |> Enum.count(fn e -> e.event_type == "PhaseCompleted" end)

    assert completed_count == 1,
           "exactly one PhaseCompleted must exist — the loser's retry must not append"
  end

  test "AC1.5b: retry exhaustion returns the actor's last reloaded stream version" do
    agg_id = "blocking:#{uuid()}"
    ref = make_ref()
    test_pid = self()

    task =
      Task.async(fn ->
        TestRouter.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :retry_exhaustion,
          ref: ref,
          notify_pid: test_pid
        })
      end)

    actor_pid =
      Enum.reduce(0..3, nil, fn expected_version, previous_pid ->
        assert_receive {:block_entered, ^ref, pid}, 5_000
        assert previous_pid in [nil, pid]

        :ok =
          Store.append_to_stream(agg_id, expected_version, [
            %Elixir.EventStore.EventData{
              event_type: "BlockEvent",
              data: %{aggregate_id: agg_id, aggregate_type: :retry_exhaustion},
              metadata: %{}
            }
          ])

        send(pid, {:release, ref})
        pid
      end)

    assert {:error, {:wrong_expected_version, 3}} = Task.await(task, 5_000)
    assert %{version: 3} = :sys.get_state(actor_pid)

    {:ok, events} = Store.read_stream_forward(agg_id, 0, 10)
    assert length(events) == 4
    assert Enum.all?(events, &(&1.event_type == "BlockEvent"))
  end

  # ---------------------------------------------------------------------------
  test "AC1.6: in-flight event is lost when aggregate crashes before append" do
    agg_id = "blocking:#{uuid()}"
    ref = make_ref()
    test_pid = self()

    task =
      Task.async(fn ->
        try do
          TestRouter.dispatch(%BlockCommand{
            aggregate_id: agg_id,
            aggregate_type: :inflight,
            ref: ref,
            notify_pid: test_pid
          })
        catch
          :exit, reason -> {:EXIT, reason}
        end
      end)

    assert_receive {:block_entered, ^ref, _}, 5_000

    assert Store.read_stream_forward(agg_id, 0, 10) == {:error, :stream_not_found},
           "in-flight event should not be in stream yet"

    pid = aggregate_pid(agg_id)
    ref_mon = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref_mon, :process, ^pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not exit")
    end

    result =
      case Task.yield(task, 5_000) do
        {:ok, res} -> res
        nil -> Task.shutdown(task)
      end

    assert match?({:error, _}, result) or match?({:EXIT, _}, result),
           "dispatch should fail when aggregate crashes before append completes"

    assert Store.read_stream_forward(agg_id, 0, 10) == {:error, :stream_not_found},
           "in-flight event must be absent from stream after crash"
  end

  # ---------------------------------------------------------------------------
  # AC1.7 — Correlation ref: mismatched reply is queued, not consumed
  # ---------------------------------------------------------------------------

  test "AC1.7: mismatched append reply is queued and does not satisfy selective receive" do
    agg_id = "blocking:#{uuid()}"
    wrong_ref = make_ref()
    test_pid = self()

    # Pre-start the actor so it is alive before dispatch.
    {:ok, actor_pid} = ForemanServer.Aggregator.start_aggregate(BlockingAggregate, agg_id)

    ref = make_ref()

    # Suspend CommandRouter so it queues the append request rather than processing it.
    # This lets the Actor park in its selective receive before CommandRouter replies.
    :ok = :sys.suspend(CommandRouter)

    on_exit(fn ->
      # Resume even on failure so subsequent tests aren't blocked.
      :sys.resume(CommandRouter)
    end)

    task =
      Task.async(fn ->
        TestRouter.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :conflict_test,
          ref: ref,
          notify_pid: test_pid
        })
      end)

    assert_receive {:block_entered, ^ref, ^actor_pid}, 5_000

    # Queue wrong_ref while Actor is parked in BlockingAggregate's release receive.
    # It will be waiting there when Actor enters its correlation receive.
    send(actor_pid, {:append_ok, wrong_ref, 1})

    # Send release. Actor exits BlockingAggregate receive, enters correlation receive,
    # sees wrong_ref already queued — ^ref will not match it.
    send(actor_pid, {:release, ref})

    # Task must still be blocked — wrong_ref is queued and does not satisfy
    # the selective receive (^ref does not match wrong_ref).
    assert Task.yield(task, 100) == nil,
           "mismatched ref must not satisfy Actor's selective receive"

    # Resume CommandRouter. It sends {:append_ok, right_ref, 1} to the Actor.
    # Actor's receive matches ^ref, skips wrong_ref, and completes.
    :sys.resume(CommandRouter)

    result = Task.await(task, 5_000)

    assert {:ok, _} = result,
           "matching ref must complete the command after wrong_ref was queued"
  end

  # ---------------------------------------------------------------------------
  # AC1d — Event roundtrip through EventStore
  # ---------------------------------------------------------------------------

  test "AC1d: event roundtrips through EventStore — data and type preserved" do
    run_id = "run-#{uuid()}"
    task_id = "task-#{uuid()}"
    agg_stream = "run:#{run_id}"

    {:ok, _} = start_run(run_id, task_id)

    {:ok, [recorded]} = Store.read_stream_forward(agg_stream, 0, 10)
    assert recorded.event_type == "RunStarted"

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert state.run_id == run_id
    assert state.task_id == task_id
  end

  # ---------------------------------------------------------------------------
  # AC1g — Commands execute in order, events applied in order
  # ---------------------------------------------------------------------------

  test "AC1g: commands execute in order, events applied in order" do
    run_id = "run-#{uuid()}"
    task_id = "task-#{uuid()}"
    agg_stream = "run:#{run_id}"

    {:ok, _} = start_run(run_id, task_id)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "run.complete",
        payload: %{run_id: run_id},
        aggregate_id: agg_stream
      })

    {:ok, events} = Store.read_stream_forward(agg_stream, 0, 10)
    assert length(events) == 2
    assert hd(events).event_type == "RunStarted"
    assert List.last(events).event_type == "RunCompleted"

    pid = aggregate_pid(agg_stream)
    state = Aggregate.Actor.get_state(pid)
    assert Map.get(state, :status) == "completed"
  end

  test "TRD-008 phase.fail: dispatch phase.fail → PhaseFailed, state terminal" do
    phase_id = "phase-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "phase:#{run_id}:#{phase_id}"

    {:ok, _} = start_phase(run_id, phase_id)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "phase.fail",
        payload: %{phase_id: phase_id, run_id: run_id, index: 1, reason: "test failure"},
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(aggregate_pid(agg_stream))
    assert Map.get(state, :status) == "failed"
    assert Map.get(state, :terminal?) == true

    {:ok, events} = Store.read_stream_forward(agg_stream, 0, 10)
    assert Enum.map(events, & &1.event_type) == ["PhaseStarted", "PhaseFailed"]
  end

  test "TRD-008 phase.skip: dispatch phase.skip on started phase → PhaseSkipped, state terminal" do
    phase_id = "phase-#{uuid()}"
    run_id = "run-#{uuid()}"
    agg_stream = "phase:#{run_id}:#{phase_id}"

    {:ok, _} = start_phase(run_id, phase_id)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "phase.skip",
        payload: %{phase_id: phase_id, run_id: run_id},
        aggregate_id: agg_stream
      })

    state = Aggregate.Actor.get_state(aggregate_pid(agg_stream))
    assert Map.get(state, :status) == "skipped"
    assert Map.get(state, :terminal?) == true

    {:ok, events} = Store.read_stream_forward(agg_stream, 0, 10)
    assert Enum.map(events, & &1.event_type) == ["PhaseStarted", "PhaseSkipped"]
  end
end
