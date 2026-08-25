defmodule ForemanServer.Aggregates.RunTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandRouter, RunAdmission}
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.RunSlotsReset

  setup do
    # RunAdmission.start/2 (used by seed_run/2 below) consumes a slot on
    # the shared `run_slots:global` aggregate. Without per-test reset,
    # later replay tests queue behind earlier admissions.
    RunSlotsReset.reset!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Existing unit tests
  # ---------------------------------------------------------------------------

  test "run.start emits RunStarted and apply_event marks the run awaiting_worker" do
    run_id = "run-start"

    {:ok, event_spec} =
      Run.handle_command(Run.initial_state(), %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-1",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    state =
      Run.apply_event(Run.initial_state(), %{
        event_type: event_spec.event_type,
        payload: event_spec.payload
      })

    assert event_spec.event_type == "RunStarted"
    assert event_spec.stream_id == "run:#{run_id}"
    assert state.run_id == run_id
    assert state.task_id == "task-1"
    assert state.project_id == "project-test-run_id"
    assert state.status == "awaiting_worker"
    assert state.terminal? == false
  end

  test "WorkerStarted transitions awaiting_worker → in_progress" do
    run_id = "run-worker-started-#{uuid()}"

    state =
      Run.initial_state()
      |> Run.apply_event(%{
        event_type: "RunStarted",
        payload: %{
          run_id: run_id,
          task_id: "task-1",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    assert state.status == "awaiting_worker"

    state =
      Run.apply_event(state, %{
        event_type: "WorkerStarted",
        payload: %{
          worker_id: "worker-1",
          run_id: run_id,
          session_id: "session-1",
          adapter: "default",
          prompt_path: "/tmp/prompt.md"
        }
      })

    assert state.status == "in_progress"
    assert state.terminal? == false
    assert state.worker_status["worker-1"].status == "running"
  end

  test "WorkerStarted on a non-awaiting run does not regress status" do
    run_id = "run-already-in-progress-#{uuid()}"

    state =
      Run.initial_state()
      |> Run.apply_event(%{
        event_type: "RunStarted",
        payload: %{
          run_id: run_id,
          task_id: "task-1",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })
      |> Run.apply_event(%{
        event_type: "WorkerStarted",
        payload: %{
          worker_id: "worker-1",
          run_id: run_id,
          session_id: "session-1",
          adapter: "default",
          prompt_path: "/tmp/prompt.md"
        }
      })
      |> Run.apply_event(%{
        event_type: "RunPaused",
        payload: %{run_id: run_id, reason: "manual_pause"}
      })

    assert state.status == "paused"

    state =
      Run.apply_event(state, %{
        event_type: "WorkerStarted",
        payload: %{
          worker_id: "worker-2",
          run_id: run_id,
          session_id: "session-2",
          adapter: "default",
          prompt_path: "/tmp/prompt.md"
        }
      })

    assert state.status == "paused",
           "WorkerStarted must not flip a paused run back to in_progress"
  end

  # :project_id and :workflow_snapshot used to slip through the aggregate and
  # reach the event store, where the typed `RunStarted` struct's
  # `@enforce_keys` raised at projection time and crashed the boot. The
  # aggregate boundary now rejects these malformed payloads.
  #
  # `:task_id` is deliberately NOT in this table: commit ac72149f ("fix
  # (aggregate): relax task_id and source for work-flow events") relaxed
  # both `RunStarted.@enforce_keys` and this handler to `optional_binary`
  # for task_id because `work.submit`-sourced runs
  # (`RunPayload.from_work_projection/1`) legitimately start with no
  # task_id. See the "accepts a missing task_id" test below.
  for {field, bad_payload} <- [
        {:project_id,
         %{run_id: "run-missing-project", task_id: "task-x", workflow_snapshot: %{}}},
        {:workflow_snapshot,
         %{run_id: "run-missing-snapshot", task_id: "task-x", project_id: "project-x"}}
      ] do
    test "run.start rejects payload missing #{field} (no event emitted)" do
      assert {:error, {:missing_or_invalid, _}} =
               Run.handle_command(Run.initial_state(), %{
                 type: "run.start",
                 payload: unquote(Macro.escape(bad_payload))
               })
    end
  end

  test "run.start accepts a missing task_id and preserves payload.source (work-flow runs have no task_id)" do
    assert {:ok, event_spec} =
             Run.handle_command(Run.initial_state(), %{
               type: "run.start",
               payload: %{
                 run_id: "run-work-no-task",
                 project_id: "project-x",
                 workflow_snapshot: %{},
                 source: :work
               }
             })

    assert event_spec.event_type == "RunStarted"
    assert event_spec.payload.run_id == "run-work-no-task"
    assert event_spec.payload.task_id == nil
    assert event_spec.payload.source == :work
  end

  test "run.start rejects non-map workflow_snapshot" do
    assert {:error, {:missing_or_invalid, :workflow_snapshot}} =
             Run.handle_command(Run.initial_state(), %{
               type: "run.start",
               payload: %{
                 run_id: "run-bad-snapshot",
                 task_id: "task-x",
                 project_id: "project-x",
                 workflow_snapshot: "not-a-map"
               }
             })
  end

  test "run.complete marks the run completed and terminal" do
    run_id = "run-complete"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-2",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    started_state =
      Run.apply_event(initial_state, %{
        event_type: start_event.event_type,
        payload: start_event.payload
      })

    {:ok, complete_event} =
      Run.handle_command(started_state, %{
        type: "run.complete",
        payload: %{run_id: run_id, sequence: 1}
      })

    completed_state =
      Run.apply_event(started_state, %{
        event_type: complete_event.event_type,
        payload: complete_event.payload
      })

    assert complete_event.event_type == "RunCompleted"
    assert complete_event.payload.project_id == "project-test-run_id"
    assert completed_state.project_id == "project-test-run_id"
    assert completed_state.status == "completed"
    assert completed_state.terminal? == true
    assert completed_state.last_sequence == 1
  end

  # TRD-009: run.cancel
  # ---------------------------------------------------------------------------

  test "run.cancel emits RunCancelled and marks the run cancelled and terminal" do
    run_id = "run-cancel"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-3",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    started_state =
      Run.apply_event(initial_state, %{
        event_type: start_event.event_type,
        payload: start_event.payload
      })

    {:ok, cancel_event} =
      Run.handle_command(started_state, %{
        type: "run.cancel",
        payload: %{run_id: run_id, reason: "user_abort"}
      })

    assert cancel_event.event_type == "RunCancelled"
    assert cancel_event.stream_id == "run:#{run_id}"
    assert cancel_event.payload.run_id == run_id
    assert cancel_event.payload.project_id == "project-test-run_id"
    assert cancel_event.payload.reason == "user_abort"
    assert cancel_event.payload.status == "cancelled"

    cancelled_state =
      Run.apply_event(started_state, %{
        event_type: cancel_event.event_type,
        payload: cancel_event.payload
      })

    assert cancelled_state.status == "cancelled"
    assert cancelled_state.project_id == "project-test-run_id"
    assert cancelled_state.terminal? == true
    assert cancelled_state.run_id == run_id
  end

  test "run.cancel on a terminal run is rejected" do
    run_id = "run-cancel-twice"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-4",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    started_state =
      Run.apply_event(initial_state, %{
        event_type: start_event.event_type,
        payload: start_event.payload
      })

    {:ok, complete_event} =
      Run.handle_command(started_state, %{
        type: "run.complete",
        payload: %{run_id: run_id, sequence: 1}
      })

    completed_state =
      Run.apply_event(started_state, %{
        event_type: complete_event.event_type,
        payload: complete_event.payload
      })

    assert {:error, {:run_terminal, "completed"}} =
             Run.handle_command(completed_state, %{
               type: "run.cancel",
               payload: %{run_id: run_id}
             })
  end

  # ---------------------------------------------------------------------------
  # TRD-009: RunAlreadyCompleted on terminal run (idempotent re-dispatch)
  # ---------------------------------------------------------------------------

  test "run.complete on a terminal run emits RunAlreadyCompleted and state is unchanged" do
    run_id = "run-already-completed"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-5",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    started_state =
      Run.apply_event(initial_state, %{
        event_type: start_event.event_type,
        payload: start_event.payload
      })

    {:ok, complete_event} =
      Run.handle_command(started_state, %{
        type: "run.complete",
        payload: %{run_id: run_id, sequence: 1}
      })

    completed_state =
      Run.apply_event(started_state, %{
        event_type: complete_event.event_type,
        payload: complete_event.payload
      })

    # Second complete: terminal run → RunAlreadyCompleted, state unchanged.
    {:ok, already_event} =
      Run.handle_command(completed_state, %{
        type: "run.complete",
        payload: %{run_id: run_id, sequence: 2}
      })

    assert already_event.event_type == "RunAlreadyCompleted"
    assert already_event.stream_id == "run:#{run_id}"
    assert already_event.payload.run_id == run_id
    assert already_event.payload.status == "completed"

    after_state =
      Run.apply_event(completed_state, %{
        event_type: already_event.event_type,
        payload: already_event.payload
      })

    # State MUST remain unchanged — `RunAlreadyCompleted` apply_event is a no-op.
    assert after_state == completed_state
  end

  test "run.complete on a failed terminal run emits RunAlreadyCompleted and state is unchanged" do
    run_id = "run-already-failed"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-6",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    started_state =
      Run.apply_event(initial_state, %{
        event_type: start_event.event_type,
        payload: start_event.payload
      })

    {:ok, fail_event} =
      Run.handle_command(started_state, %{
        type: "run.fail",
        payload: %{run_id: run_id, reason: "worker_crashed"}
      })

    failed_state =
      Run.apply_event(started_state, %{
        event_type: fail_event.event_type,
        payload: fail_event.payload
      })

    assert failed_state.status == "failed"
    assert failed_state.terminal? == true

    {:ok, already_event} =
      Run.handle_command(failed_state, %{
        type: "run.complete",
        payload: %{run_id: run_id, sequence: 1}
      })

    assert already_event.event_type == "RunAlreadyCompleted"
    assert already_event.payload.status == "failed"

    after_state =
      Run.apply_event(failed_state, %{
        event_type: already_event.event_type,
        payload: already_event.payload
      })

    assert after_state == failed_state
  end

  test "run.block emits RunBlocked and preserves project_id on terminal state" do
    run_id = "run-blocked"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-7",
          project_id: "project-test-run_id",
          workflow_snapshot: %{}
        }
      })

    started_state =
      Run.apply_event(initial_state, %{
        event_type: start_event.event_type,
        payload: start_event.payload
      })

    {:ok, block_event} =
      Run.handle_command(started_state, %{
        type: "run.block",
        payload: %{run_id: run_id, reason: "awaiting_review"}
      })

    blocked_state =
      Run.apply_event(started_state, %{
        event_type: block_event.event_type,
        payload: block_event.payload
      })

    assert block_event.event_type == "RunBlocked"
    assert block_event.payload.project_id == "project-test-run_id"
    assert blocked_state.status == "blocked"
    assert blocked_state.project_id == "project-test-run_id"
    assert blocked_state.terminal? == true
  end

  test "terminal run event structs require project_id alongside run_id" do
    assert_raise ArgumentError, fn ->
      struct!(ForemanServer.Events.RunCompleted, run_id: "run-1", sequence: 1)
    end

    assert_raise ArgumentError, fn ->
      struct!(ForemanServer.Events.RunFailed, run_id: "run-1", sequence: 1)
    end

    assert_raise ArgumentError, fn ->
      struct!(ForemanServer.Events.RunCancelled, run_id: "run-1")
    end

    assert_raise ArgumentError, fn ->
      struct!(ForemanServer.Events.RunFlaggedStuck, run_id: "run-1", flagged_at: 1)
    end

    assert_raise ArgumentError, fn ->
      struct!(ForemanServer.Events.RunBlocked, run_id: "run-1")
    end
  end

  # ---------------------------------------------------------------------------
  # TRD-009: Aggregate.load/2 replay tests (4)
  #
  # Each test starts the run through RunAdmission, then calls
  # `Aggregate.load(Run, run_id)` to rehydrate state from the EventStore —
  # the canonical replay path exercised on Actor restart.
  # ---------------------------------------------------------------------------

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp dispatch(%{type: "run.start", payload: payload}) do
    project_id = "project-#{payload.run_id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{
          project_id: project_id,
          name: "Run replay #{payload.run_id}",
          path: System.tmp_dir!()
        }
      })

    RunAdmission.start(project_id, Map.put(payload, :project_id, project_id))
  end

  defp dispatch(command), do: CommandRouter.dispatch(command, 5_000)

  defp recover_state(run_id) do
    {state, version} = Aggregate.load(Run, "run:#{run_id}")
    {state, version}
  end

  test "replay restores an in-progress (non-terminal) run state" do
    run_id = "run-replay-active-#{uuid()}"
    cmd_id = "cmd-#{uuid()}"

    assert {:ok, _} =
             dispatch(%{
               command_id: cmd_id,
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.start",
               payload: %{
                 run_id: run_id,
                 task_id: "task-a",
                 project_id: "project-test-run_id",
                 workflow_snapshot: %{}
               }
             })

    {state, version} = recover_state(run_id)

    assert state.exists? == true
    assert state.run_id == run_id
    assert state.task_id == "task-a"
    assert state.project_id == "project-#{run_id}"
    assert state.status == "awaiting_worker"
    assert state.terminal? == false
    assert version == 1
  end

  test "replay restores a completed (terminal) run state" do
    run_id = "run-replay-completed-#{uuid()}"

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.start",
               payload: %{
                 run_id: run_id,
                 task_id: "task-b",
                 project_id: "project-test-run_id",
                 workflow_snapshot: %{}
               }
             })

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.complete",
               payload: %{run_id: run_id, sequence: 1}
             })

    {state, version} = recover_state(run_id)

    assert state.exists? == true
    assert state.run_id == run_id
    assert state.project_id == "project-#{run_id}"
    assert state.status == "completed"
    assert state.terminal? == true
    assert state.last_sequence == 1
    assert version == 2
  end

  test "replay restores a cancelled (terminal) run state" do
    run_id = "run-replay-cancelled-#{uuid()}"

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.start",
               payload: %{
                 run_id: run_id,
                 task_id: "task-c",
                 project_id: "project-test-run_id",
                 workflow_snapshot: %{}
               }
             })

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.cancel",
               payload: %{run_id: run_id, reason: "user_abort"}
             })

    {state, version} = recover_state(run_id)

    assert state.exists? == true
    assert state.run_id == run_id
    assert state.project_id == "project-#{run_id}"
    assert state.status == "cancelled"
    assert state.terminal? == true
    assert version == 2
  end

  test "replay restores a failed (terminal) run state" do
    run_id = "run-replay-failed-#{uuid()}"

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.start",
               payload: %{
                 run_id: run_id,
                 task_id: "task-d",
                 project_id: "project-test-run_id",
                 workflow_snapshot: %{}
               }
             })

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.fail",
               payload: %{run_id: run_id, reason: "worker_crashed", sequence: 1}
             })

    {state, version} = recover_state(run_id)

    assert state.exists? == true
    assert state.run_id == run_id
    assert state.project_id == "project-#{run_id}"
    assert state.status == "failed"
    assert state.terminal? == true
    assert state.last_sequence == 1
    assert version == 2
  end

  # ---------------------------------------------------------------------------
  # TRD-009: `RunAlreadyCompleted` through replay is a no-op — state preserved
  # ---------------------------------------------------------------------------

  test "RunAlreadyCompleted persisted during replay is a no-op on terminal state" do
    run_id = "run-replay-already-#{uuid()}"

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.start",
               payload: %{
                 run_id: run_id,
                 task_id: "task-e",
                 project_id: "project-test-run_id",
                 workflow_snapshot: %{}
               }
             })

    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.complete",
               payload: %{run_id: run_id, sequence: 1}
             })

    {state_before, _} = recover_state(run_id)
    assert state_before.status == "completed"
    assert state_before.terminal? == true

    # Re-dispatch complete on the terminal run — emits RunAlreadyCompleted.
    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: "run:#{run_id}",
               type: "run.complete",
               payload: %{run_id: run_id, sequence: 2}
             })

    {state_after, version_after} = recover_state(run_id)

    # State must remain unchanged after RunAlreadyCompleted.
    assert state_after.terminal? == state_before.terminal?
    assert state_after.last_sequence == state_before.last_sequence
    # Stream now has 3 events: RunStarted, RunCompleted, RunAlreadyCompleted.
    assert version_after == 3
  end

  # ---------------------------------------------------------------------------
  # TRD-009: optimistic concurrency conflict → bounded retry converges to
  # RunAlreadyCompleted (AC-004-1, AC-004-4).
  #
  # Mirrors the AC-005-3 phase race pattern but for the Run aggregate:
  #   1. `run.start` via RunAdmission → RunStarted at version 1, actor state
  #      is in_progress (not terminal).
  #   2. Two concurrent `:append` of RunCompleted at expected_version=1 →
  #      exactly one wins, the other is rejected with
  #      `{:error, :wrong_expected_version}` at the EventStore layer.
  #   3. Fresh dispatch of `run.complete` via the normal actor+router path
  #      converges to terminal state via the actor's bounded retry: the
  #      actor's local version is stale (1), the first append conflicts,
  #      bounded-retry reloads state via Aggregate.load/2 (replays the
  #      winning RunCompleted → status=completed, terminal?=true), re-decides
  #      via handle_command, and emits a RunAlreadyCompleted event spec
  #      (state unchanged). The append at version 2 succeeds →
  #      RunAlreadyCompleted appended at version 3.
  # ---------------------------------------------------------------------------

  defp await_append_reply(ref) do
    receive do
      {:append_ok, ^ref, _count, _latency} -> :ok
      {:error, ^ref, reason, _latency} -> {:error, reason}
    after
      5_000 -> :timeout
    end
  end

  defp completed_event_data(run_id) do
    %Elixir.EventStore.EventData{
      event_type: "RunCompleted",
      data: %{run_id: run_id, sequence: 1},
      metadata: %{}
    }
  end

  test "run.complete race at router+EventStore boundary, fresh dispatch converges to RunAlreadyCompleted" do
    run_id = "run-race-#{uuid()}"
    stream = "run:#{run_id}"

    # 1. Start run via the admission boundary.
    assert {:ok, _} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: stream,
               type: "run.start",
               payload: %{
                 run_id: run_id,
                 task_id: "task-race",
                 project_id: "project-test-run_id",
                 workflow_snapshot: %{}
               }
             })

    [{actor_pid, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)

    state_initial = Aggregate.Actor.get_state(actor_pid)
    assert state_initial.status == "awaiting_worker"
    refute state_initial.terminal?

    # 2. Two concurrent :append of RunCompleted at expected_version=1.
    ref_a = make_ref()
    ref_b = make_ref()

    task_a =
      Task.async(fn ->
        send(
          CommandRouter,
          {:append, stream, [completed_event_data(run_id)], 1, ref_a, self()}
        )

        await_append_reply(ref_a)
      end)

    task_b =
      Task.async(fn ->
        send(
          CommandRouter,
          {:append, stream, [completed_event_data(run_id)], 1, ref_b, self()}
        )

        await_append_reply(ref_b)
      end)

    outcomes =
      [Task.await(task_a, 5_000), Task.await(task_b, 5_000)]
      |> Enum.sort()

    assert outcomes == [:ok, {:error, :wrong_expected_version}],
           "exactly one concurrent append must win; the other is rejected at the EventStore layer"

    # Stream is now at version 2 with one RunCompleted. Actor's local state
    # is unchanged — still version 1, status=awaiting_worker, not terminal.
    {:ok, events_after_race} = Store.read_stream_forward(stream, 0, 10)
    assert length(events_after_race) == 2
    assert Enum.map(events_after_race, & &1.event_type) == ["RunStarted", "RunCompleted"]

    state_after_race = Aggregate.Actor.get_state(actor_pid)

    assert state_after_race.status == "awaiting_worker",
           "actor must not have observed the racing :append messages"

    refute state_after_race.terminal?

    # 3. Fresh dispatch via the normal actor+router path. Locally the actor
    # sees awaiting_worker, so handle_command returns a RunCompleted event spec
    assert {:ok, %{"event_type" => "RunAlreadyCompleted"}} =
             dispatch(%{
               command_id: "cmd-#{uuid()}",
               aggregate_type: "Run",
               aggregate_id: stream,
               type: "run.complete",
               payload: %{run_id: run_id, sequence: 1}
             })

    state_final = Aggregate.Actor.get_state(actor_pid)
    assert state_final.status == "completed"
    assert state_final.terminal? == true

    # Stream invariants: exactly one RunStarted, exactly one RunCompleted,
    # exactly one RunAlreadyCompleted. The failed append was rejected; the
    # retry appended only RunAlreadyCompleted.
    {:ok, events_final} = Store.read_stream_forward(stream, 0, 10)

    assert Enum.map(events_final, & &1.event_type) == [
             "RunStarted",
             "RunCompleted",
             "RunAlreadyCompleted"
           ]

    completed_count =
      Enum.count(events_final, fn e -> e.event_type == "RunCompleted" end)

    assert completed_count == 1,
           "fresh dispatch must not append a duplicate RunCompleted"
  end

  test "run.pr.update emits PrUpdated and apply_event sets run_id on the Run aggregate" do
    run_id = "run-pr-update"

    state_started =
      Run.apply_event(Run.initial_state(), %{
        event_type: "RunStarted",
        run_id: run_id,
        task_id: "task-1",
        sequence: 1
      })

    assert {:ok, event_spec} =
             Run.handle_command(state_started, %{
               type: "run.pr.update",
               payload: %{
                 run_id: run_id,
                 project_id: "proj-1",
                 task_id: "task-1",
                 pr_url: "https://github.com/owner/repo/pull/7",
                 branch_name: "feature/branch",
                 head_sha: "deadbeef",
                 base_branch: "main",
                 phase: "update"
               }
             })

    assert event_spec.event_type == "PrUpdated"
    assert event_spec.stream_id == "run:#{run_id}"
    assert event_spec.payload.run_id == run_id

    new_state =
      Run.apply_event(state_started, %{
        event_type: "PrUpdated",
        run_id: run_id,
        payload: event_spec.payload
      })

    assert new_state.run_id == run_id
    refute new_state.terminal?
  end
end
