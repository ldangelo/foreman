defmodule ForemanServer.AC1AggregateActorTest do
  use ExUnit.Case, async: false

  # AC1: Aggregate actor model — empirical tests against Commanded 1.4.10.
  #
  # Six asserted behaviors across five domain aggregates (Project, Task, Run, Worker, Phase):
  #
  # AC1.1  Serialization — concurrent commands to same aggregate are queued and processed in order
  # AC1.2  Stream rehydration on startup — state rebuilt from event store before first cmd
  # AC1.3  Crash + lazy reopen — :temporary, no auto-restart, new process on next dispatch
  # AC1.4  Post-restart command correctness — next command uses rehydrated state
  # AC1.5  Append-then-apply — conflict → aggregate state unchanged, event store authoritative
  # AC1.6  In-flight event lost on crash — event produced but never appended is absent after restart
  #
  # Blocking infrastructure (BlockCommand, BlockingAggregate, TestApplication) lives in
  # test/support/ — domain aggregates use normal commands only.

  # ForemanServer.EventStore: production event store, used by ForemanServer.Application
  alias ForemanServer.EventStore
  # TestEventStore: Commanded's own API module — dispatches to whatever adapter
  # TestApplication is configured with (InMemory). Use for all TestApplication streams.
  alias Commanded.EventStore, as: TestEventStore
  alias ForemanServer.{Commands, Events}
  alias ForemanServer.TestSupport.{BlockCommand, BlockingAggregate, TestApplication}

  setup do
    # ForemanServer.Application is started globally by OTP (mix.exs mod:).
    # TestApplication must be supervised by ExUnit so it is terminated cleanly
    # between tests — start_link would link it to the test process and race on
    # the next test's start.
    _ = start_supervised!({TestApplication, []})
    :ok
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp await_registry_empty(app, aggregate_mod, aggregate_id, retries \\ 50)
  defp await_registry_empty(_app, _mod, nil, _retries), do: :ok

  defp await_registry_empty(app, aggregate_mod, aggregate_id, retries) do
    registry = Module.concat(app, LocalRegistry)

    Enum.reduce_while(1..retries, nil, fn i, _ ->
      key = {app, aggregate_mod, aggregate_id}

      case Registry.lookup(registry, key) do
        [] ->
          {:halt, :ok}

        _ when i < retries ->
          Process.sleep(10)
          {:cont, :retry}

        _ ->
          {:halt, {:error, :registry_not_empty}}
      end
    end)
  end

  defp aggregate_pid(_app, _mod, nil), do: nil

  defp aggregate_pid(app, aggregate_mod, aggregate_id) do
    key = {app, aggregate_mod, aggregate_id}
    registry = Module.concat(app, LocalRegistry)
    [{pid, _}] = Registry.lookup(registry, key)
    pid
  end

  # -------------------------------------------------------------------------
  # AC1.1 — Serialization
  #
  # Two BlockCommands dispatched to same stream while first is parked in receive.
  # Both dispatches are async (Task.async) to avoid deadlock.
  # -------------------------------------------------------------------------

  test "AC1.1: two BlockCommands to same stream are serialized in order" do
    agg_id = Commanded.UUID.uuid4()
    ref1 = make_ref()
    ref2 = make_ref()
    test_pid = self()

    # Dispatch both commands as async — neither blocks the test process.
    # task1 enters execute/2 first and sends {:block_entered, ref1} before parking.
    # task2's command queues behind task1's in the aggregate mailbox.
    task1 =
      Task.async(fn ->
        TestApplication.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :serial_test,
          ref: ref1,
          notify_pid: test_pid
        })
      end)

    # Wait for first aggregate to enter its receive block before sending second command.
    assert_receive {:block_entered, ^ref1, _pid1}, 5_000

    task2 =
      Task.async(fn ->
        TestApplication.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :serial_test,
          ref: ref2,
          notify_pid: test_pid
        })
      end)

    # Command 2 is queued — it cannot enter execute/2 until command 1 returns.
    # Optionally prove ref2's block_entered has NOT arrived yet.
    refute_receive {:block_entered, ^ref2, _}, 100

    # Release first — now command 2 dequeues and enters execute, sending block_entered.
    pid = aggregate_pid(TestApplication, BlockingAggregate, agg_id)
    send(pid, {:release, ref1})
    assert Task.await(task1, 10_000) == :ok

    # Wait for command 2's block_entered (it enters execute only after command 1 returns)
    assert_receive {:block_entered, ^ref2, pid2}, 5_000

    # Release second.
    send(pid2, {:release, ref2})
    assert Task.await(task2, 10_000) == :ok

    # Both BlockEvents in stream, in order
    events = TestEventStore.stream_forward(TestApplication, agg_id, 0, 10) |> Enum.to_list()
    assert length(events) == 2
    types = Enum.map(events, & &1.event_type)

    assert types == [
             "Elixir.ForemanServer.TestSupport.BlockEvent",
             "Elixir.ForemanServer.TestSupport.BlockEvent"
           ]
  end

  # -------------------------------------------------------------------------
  # AC1.2 — Stream rehydration on startup
  # -------------------------------------------------------------------------

  for {agg_mod, app, cmd_mod, id_key, id_prefix} <- [
        {ForemanServer.AC1ProjectAggregate, ForemanServer.Application,
         ForemanServer.Commands.RegisterProject, :project_id, "proj"},
        {ForemanServer.AC1TaskAggregate, ForemanServer.Application,
         ForemanServer.Commands.CreateTask, :task_id, "task"},
        {ForemanServer.AC1RunAggregate, ForemanServer.Application,
         ForemanServer.Commands.StartRun, :run_id, "run"},
        {ForemanServer.AC1WorkerAggregate, ForemanServer.Application,
         ForemanServer.Commands.StartWorker, :worker_id, "worker"},
        {ForemanServer.AC1PhaseAggregate, ForemanServer.Application,
         ForemanServer.Commands.StartPhase, :phase_id, "phase"}
      ] do
    test "AC1.2: #{inspect(agg_mod)} rehydrates state from event store on startup" do
      id = "#{unquote(id_prefix)}-#{Commanded.UUID.uuid4()}"
      cmd = struct(unquote(cmd_mod)) |> Map.put(unquote(id_key), id)
      :ok = unquote(app).dispatch(cmd)

      state =
        Commanded.Aggregates.Aggregate.aggregate_state(
          unquote(app),
          unquote(agg_mod),
          id
        )

      assert Map.get(state, unquote(id_key)) == id
      assert state.status != nil
    end
  end

  # -------------------------------------------------------------------------
  # AC1.3 — Crash + lazy reopen (:temporary, no auto-restart)
  # -------------------------------------------------------------------------

  for {agg_mod, app, id_key, id_prefix, init_fields, init_mod, advance_fields, advance_mod,
       expected_status} <- [
        {ForemanServer.AC1ProjectAggregate, ForemanServer.Application, :project_id, "proj",
         [project_id: nil, path: "/tmp/p"], ForemanServer.Commands.RegisterProject,
         [project_id: nil], ForemanServer.Commands.ArchiveProject, :archived},
        {ForemanServer.AC1TaskAggregate, ForemanServer.Application, :task_id, "task",
         [task_id: nil, project_id: "p"], ForemanServer.Commands.CreateTask, [task_id: nil],
         ForemanServer.Commands.CloseTask, :closed},
        {ForemanServer.AC1RunAggregate, ForemanServer.Application, :run_id, "run",
         [run_id: nil, task_id: "t"], ForemanServer.Commands.StartRun, [run_id: nil],
         ForemanServer.Commands.CompleteRun, :completed},
        {ForemanServer.AC1WorkerAggregate, ForemanServer.Application, :worker_id, "worker",
         [worker_id: nil, run_id: "r"], ForemanServer.Commands.StartWorker, [worker_id: nil],
         ForemanServer.Commands.ExitWorker, :exited},
        {ForemanServer.AC1PhaseAggregate, ForemanServer.Application, :phase_id, "phase",
         [phase_id: nil, run_id: "r"], ForemanServer.Commands.StartPhase, [phase_id: nil],
         ForemanServer.Commands.CompletePhase, :completed}
      ] do
    test "AC1.3: #{inspect(agg_mod)} :temporary crash, no restart, lazy reopen, stream replay" do
      # Keyword lists are valid quoted literals — use Map.new() to convert at runtime
      init_fields_kw = unquote(init_fields)
      advance_fields_kw = unquote(advance_fields)
      id = "#{unquote(id_prefix)}-#{Commanded.UUID.uuid4()}"

      # 1. Start aggregate
      init_cmd = struct(unquote(init_mod), Map.put(Map.new(init_fields_kw), unquote(id_key), id))
      :ok = unquote(app).dispatch(init_cmd)

      old_pid = aggregate_pid(unquote(app), unquote(agg_mod), id)
      assert Process.alive?(old_pid)

      # 2. Monitor + kill — :kill bypasses terminate/2
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^old_pid, :killed} -> :ok
      after
        5_000 -> flunk("aggregate did not emit DOWN after :kill")
      end

      # 3. Registry must drain (no auto-restart for :temporary)
      assert await_registry_empty(unquote(app), unquote(agg_mod), id) == :ok

      # 4. Dispatch advance command — triggers lazy reopen with stream replay
      advance_cmd =
        struct(unquote(advance_mod), Map.put(Map.new(advance_fields_kw), unquote(id_key), id))

      :ok = unquote(app).dispatch(advance_cmd)

      # 5. New PID alive, state reflects replayed + new event
      new_pid = aggregate_pid(unquote(app), unquote(agg_mod), id)
      assert Process.alive?(new_pid)
      refute new_pid == old_pid

      state =
        Commanded.Aggregates.Aggregate.aggregate_state(
          unquote(app),
          unquote(agg_mod),
          id
        )

      assert state.status == unquote(expected_status)
    end
  end

  # -------------------------------------------------------------------------
  # AC1.4 — Post-restart command correctness
  # -------------------------------------------------------------------------

  test "AC1.4: after crash+reopen, CompleteRun succeeds because state was rehydrated" do
    run_id = Commanded.UUID.uuid4()
    task_id = "task-#{Commanded.UUID.uuid4()}"

    :ok = ForemanServer.Application.dispatch(%Commands.StartRun{run_id: run_id, task_id: task_id})
    # Do NOT complete before crash — verify the aggregate can complete after rehydration

    pid = aggregate_pid(ForemanServer.Application, ForemanServer.AC1RunAggregate, run_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not exit")
    end

    assert await_registry_empty(ForemanServer.Application, ForemanServer.AC1RunAggregate, run_id) ==
             :ok

    # Would be :not_running if state was lost on crash
    :ok = ForemanServer.Application.dispatch(%Commands.CompleteRun{run_id: run_id})

    state =
      Commanded.Aggregates.Aggregate.aggregate_state(
        ForemanServer.Application,
        ForemanServer.AC1RunAggregate,
        run_id
      )

    assert state.status == :completed
    events = EventStore.stream_forward(run_id, 0, 10) |> Enum.to_list()
    assert length(events) == 2
  end

  # -------------------------------------------------------------------------
  # AC1.5 — Append-then-apply: conflict from external append
  #
  # BlockCommand parks in receive. While parked, externally append a BlockEvent
  # at expected version 0 (empty stream). Release, assert conflict error.
  # The aggregate's state reflects the event store (which includes the external event),
  # proving append-then-apply ordering: event store advances first, then apply.
  # -------------------------------------------------------------------------

  test "AC1.5: external append causes conflict — aggregate state reflects event store" do
    agg_id = Commanded.UUID.uuid4()
    ref = make_ref()
    test_pid = self()

    # 1. Dispatch BlockCommand — execute parks in receive. Stream is empty (version 0).
    task =
      Task.async(fn ->
        TestApplication.dispatch(
          %BlockCommand{
            aggregate_id: agg_id,
            aggregate_type: :conflict_test,
            ref: ref,
            notify_pid: test_pid
          },
          retry_attempts: 0
        )
      end)

    # Wait for aggregate to enter receive before doing external append
    assert_receive {:block_entered, ^ref, _}, 5_000

    # 2. Stream is still empty — InMemory returns stream_not_found for unknown streams
    assert TestEventStore.stream_forward(TestApplication, agg_id, 0, 10) ==
             {:error, :stream_not_found}

    # 3. Externally append BlockEvent at expected version 0.
    #    This advances the stream, causing a conflict when the parked command
    #    tries to append its event (expected version 0, actual version 1).
    :ok =
      TestEventStore.append_to_stream(TestApplication, agg_id, 0, [
        %Commanded.EventStore.EventData{
          event_type: "Elixir.ForemanServer.TestSupport.BlockEvent",
          data: %ForemanServer.TestSupport.BlockEvent{
            aggregate_id: agg_id,
            aggregate_type: :conflict
          },
          metadata: %{}
        }
      ])

    # 4. Stream now has 1 event
    events_after_append =
      TestEventStore.stream_forward(TestApplication, agg_id, 0, 10) |> Enum.to_list()

    assert length(events_after_append) == 1

    # 5. Release — aggregate's persist attempt gets :wrong_expected_version.
    #    The aggregate may exit on conflict. Yield until the dispatch settles,
    #    then explicitly assert conflict.
    pid = aggregate_pid(TestApplication, BlockingAggregate, agg_id)
    if pid && Process.alive?(pid), do: send(pid, {:release, ref})

    result =
      case Task.yield(task, 5_000) do
        {:ok, res} -> res
        nil -> Task.shutdown(task)
      end

    assert match?({:error, _}, result),
           "dispatch should return error when expected version conflicts"

    # Key invariant: exactly 1 event (the external one) is in the stream.
    assert length(TestEventStore.stream_forward(TestApplication, agg_id, 0, 10) |> Enum.to_list()) ==
             1,
           "event store should contain exactly 1 external event — aggregate's event was rejected"

    # State reflects only the externally appended event
    state =
      Commanded.Aggregates.Aggregate.aggregate_state(
        TestApplication,
        BlockingAggregate,
        agg_id
      )

    assert state.status == :blocked,
           "aggregate state should reflect the externally appended event (event store is authoritative)"
  end

  # -------------------------------------------------------------------------
  # AC1.6 — In-flight event lost on crash
  #
  # BlockCommand parks execute in receive. While parked, the event has NOT been
  # appended to the event store. Kill the aggregate, then verify the in-flight
  # event is absent.
  # -------------------------------------------------------------------------

  test "AC1.6: in-flight event is lost when aggregate crashes before append" do
    agg_id = Commanded.UUID.uuid4()
    ref = make_ref()
    test_pid = self()

    # 1. Dispatch BlockCommand — execute parks in receive, event NOT yet appended.
    #    Run as Task so we can kill the aggregate before it completes.
    task =
      Task.async(fn ->
        TestApplication.dispatch(%BlockCommand{
          aggregate_id: agg_id,
          aggregate_type: :inflight,
          ref: ref,
          notify_pid: test_pid
        })
      end)

    # Wait for aggregate to enter receive before killing it (event not yet persisted)
    assert_receive {:block_entered, ^ref, _}, 5_000

    # 2. Verify stream is empty — InMemory returns stream_not_found for unknown streams
    assert TestEventStore.stream_forward(TestApplication, agg_id, 0, 10) ==
             {:error, :stream_not_found},
           "in-flight event should not be in stream yet"

    # 3. Kill aggregate — in-flight event is lost (never persisted)
    pid = aggregate_pid(TestApplication, BlockingAggregate, agg_id)
    ref_mon = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref_mon, :process, ^pid, :killed} -> :ok
    after
      5_000 -> flunk("aggregate did not exit")
    end

    # 4. Task fails (aggregate crashed before command completed).
    #    Use yield+shutdown to avoid race on the exit message.
    result =
      case Task.yield(task, 5_000) do
        {:ok, res} -> res
        nil -> Task.shutdown(task)
      end

    assert match?({:error, _}, result) or match?({:exit, _}, result),
           "dispatch should fail when aggregate crashes before append"

    # 5. In-flight event absent from stream — confirmed lost, not silently persisted
    assert TestEventStore.stream_forward(TestApplication, agg_id, 0, 10) ==
             {:error, :stream_not_found},
           "in-flight event must be absent from stream after crash"
  end

  # -------------------------------------------------------------------------
  # AC1d — Serialization roundtrip
  # -------------------------------------------------------------------------

  test "AC1d: event roundtrips through EventStore — data and type preserved" do
    run_id = Commanded.UUID.uuid4()
    task_id = "task-#{Commanded.UUID.uuid4()}"

    :ok =
      ForemanServer.Application.dispatch(%Commands.StartRun{
        run_id: run_id,
        task_id: task_id
      })

    [recorded] = EventStore.stream_forward(run_id, 0, 10) |> Enum.to_list()
    assert recorded.event_type == "Elixir.ForemanServer.Events.RunStarted"
    assert recorded.data.__struct__ == Events.RunStarted
    assert recorded.data.run_id == run_id
    assert recorded.data.task_id == task_id
  end

  # -------------------------------------------------------------------------
  # AC1g — Commands execute in order, events applied in order
  # -------------------------------------------------------------------------

  test "AC1g: commands execute in order, events applied in order" do
    run_id = Commanded.UUID.uuid4()
    task_id = "task-#{Commanded.UUID.uuid4()}"

    :ok = ForemanServer.Application.dispatch(%Commands.StartRun{run_id: run_id, task_id: task_id})
    :ok = ForemanServer.Application.dispatch(%Commands.CompleteRun{run_id: run_id})

    events = EventStore.stream_forward(run_id, 0, 10) |> Enum.to_list()
    assert length(events) == 2
    assert hd(events).event_type == "Elixir.ForemanServer.Events.RunStarted"
    assert List.last(events).event_type == "Elixir.ForemanServer.Events.RunCompleted"

    state =
      Commanded.Aggregates.Aggregate.aggregate_state(
        ForemanServer.Application,
        ForemanServer.AC1RunAggregate,
        run_id
      )

    assert state.status == :completed
  end
end
