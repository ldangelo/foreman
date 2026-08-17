defmodule ForemanServer.RunLifecycleReconcilerTest do
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.Aggregates.{Project, Run}

  alias ForemanServer.{
    Aggregate,
    CommandRouter,
    EventStore,
    Identity,
    ProjectionStore,
    RunAdmission,
    RunLifecycleReconciler
  }

  @terminal_release [:foreman_server, :reconciler, :terminal_release]
  @orphan_retry [:foreman_server, :reconciler, :orphan_retry]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)
    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    :ok
  end

  setup do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@terminal_release, @orphan_retry],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  test "subscription path releases from authoritative terminal events, reloads the run, and skips projection lookups" do
    parent = self()
    subscription_ref = make_ref()

    pid =
      start_supervised!(
        {RunLifecycleReconciler,
         [
           name: unique_name(),
           subscribe_fun: fn ->
             send(parent, :subscribed)
             {:ok, subscription_ref}
           end,
           ack_fun: fn acked_subscription, events ->
             send(parent, {:acked, acked_subscription, events})
             :ok
           end,
           project_loader_fun: fn project_id ->
             send(parent, {:project_load, project_id})
             project_state(project_id, "run-1", run_start_payload())
           end,
           run_loader_fun: fn run_id ->
             send(parent, {:run_load, run_id})
             terminal_run_state(run_id, "project-1")
           end,
           dispatch_fun: fn command, timeout ->
             send(parent, {:dispatch, command, timeout})
             {:ok, %{}}
           end
         ]}
      )

    assert_receive :subscribed

    assert %{subscription: :subscribed, subscription_ref: ^subscription_ref, interval_ms: 30_000} =
             :sys.get_state(pid)

    events = [
      %RecordedEvent{
        event_number: 7,
        event_id: "evt-1",
        stream_uuid: "run:run-1",
        stream_version: 3,
        correlation_id: nil,
        causation_id: nil,
        event_type: "RunCompleted",
        data: %{run_id: "run-1", sequence: 3},
        metadata: %{},
        created_at: DateTime.utc_now()
      }
    ]

    send(pid, {:events, events})

    assert_receive {:run_load, "run-1"}, 1_000

    assert_receive {
                     :dispatch,
                     %{
                       aggregate_id: "project:project-1",
                       command_id: command_id,
                       type: "project.release_run_reservation",
                       payload: %{
                         project_id: "project-1",
                         run_id: "run-1",
                         reason: "terminal_event"
                       }
                     },
                     5_000
                   },
                   1_000

    assert command_id ==
             Identity.project_run_reservation_release_command_id(
               "project-1",
               "run-1",
               "terminal_event"
             )

    assert_receive {:acked, ^subscription_ref, ^events}, 1_000
    refute_received {:project_load, _project_id}

    assert_receive {
      :telemetry,
      @terminal_release,
      %{duration_ms: duration_ms},
      %{path: :subscribed, project_id: "project-1", run_id: "run-1", outcome: :released}
    }

    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end

  test "scheduled pass enumerates projection candidates, rehydrates state, and releases terminal runs" do
    parent = self()

    pid =
      start_supervised!(
        {RunLifecycleReconciler,
         [
           name: unique_name(),
           interval_ms: 60_000,
           subscribe_fun: fn -> :ok end,
           list_active_runs_fun: fn ->
             send(parent, :listed_active_runs)
             [{"project-1", ["run-1"]}]
           end,
           project_loader_fun: fn project_id ->
             send(parent, {:project_load, project_id})
             project_state(project_id, "run-1", run_start_payload())
           end,
           run_loader_fun: fn run_id ->
             send(parent, {:run_load, run_id})
             terminal_run_state(run_id, "project-1")
           end,
           dispatch_fun: fn command, timeout ->
             send(parent, {:dispatch, command, timeout})
             {:ok, %{}}
           end
         ]}
      )

    send(pid, :scheduled)

    assert_receive :listed_active_runs, 1_000
    assert_receive {:project_load, "project-1"}, 1_000
    assert_receive {:run_load, "run-1"}, 1_000

    assert_receive {
                     :dispatch,
                     %{
                       aggregate_id: "project:project-1",
                       type: "project.release_run_reservation",
                       payload: %{
                         project_id: "project-1",
                         run_id: "run-1",
                         reason: "terminal_run"
                       }
                     },
                     5_000
                   },
                   1_000

    assert_receive {
      :telemetry,
      @terminal_release,
      %{duration_ms: duration_ms},
      %{path: :scheduled, project_id: "project-1", run_id: "run-1", outcome: :released}
    }

    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end

  test "scheduled pass defaults candidate enumeration to ProjectionStore.list_projects_with_active_runs/0" do
    parent = self()
    original_state = :sys.get_state(ProjectionStore)

    on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _state -> original_state end)
    end)

    :sys.replace_state(ProjectionStore, fn state ->
      %{state | project_active_runs: %{"project-1" => ["run-1"]}}
    end)

    pid =
      start_supervised!(
        {RunLifecycleReconciler,
         [
           name: unique_name(),
           interval_ms: 60_000,
           subscribe_fun: fn -> :ok end,
           project_loader_fun: fn project_id ->
             send(parent, {:project_load, project_id})
             project_state(project_id, "run-1", run_start_payload())
           end,
           run_loader_fun: fn run_id ->
             send(parent, {:run_load, run_id})
             terminal_run_state(run_id, "project-1")
           end,
           dispatch_fun: fn command, timeout ->
             send(parent, {:dispatch, command, timeout})
             {:ok, %{}}
           end
         ]}
      )

    state = :sys.get_state(pid)
    assert {:module, ProjectionStore} == :erlang.fun_info(state.list_active_runs_fun, :module)

    assert {:name, :list_projects_with_active_runs} ==
             :erlang.fun_info(state.list_active_runs_fun, :name)

    assert {:arity, 0} == :erlang.fun_info(state.list_active_runs_fun, :arity)

    send(pid, :scheduled)

    assert_receive {:project_load, "project-1"}, 1_000
    assert_receive {:run_load, "run-1"}, 1_000

    assert_receive {
                     :dispatch,
                     %{
                       aggregate_id: "project:project-1",
                       type: "project.release_run_reservation",
                       payload: %{
                         project_id: "project-1",
                         run_id: "run-1",
                         reason: "terminal_run"
                       }
                     },
                     5_000
                   },
                   1_000
  end

  test "scheduled pass retries absent runs from reservation payload without releasing on successful retry" do
    parent = self()
    payload = run_start_payload()

    pid =
      start_supervised!(
        {RunLifecycleReconciler,
         [
           name: unique_name(),
           interval_ms: 60_000,
           subscribe_fun: fn -> :ok end,
           list_active_runs_fun: fn -> [{"project-1", ["run-1"]}] end,
           project_loader_fun: fn project_id -> project_state(project_id, "run-1", payload) end,
           run_loader_fun: fn run_id -> absent_run_state(run_id) end,
           run_admission_fun: fn project_id, recovered_payload, timeout ->
             send(parent, {:retry, project_id, recovered_payload, timeout})
             {:ok, %{accepted: true}}
           end,
           dispatch_fun: fn command, timeout ->
             send(parent, {:dispatch, command, timeout})
             {:ok, %{}}
           end
         ]}
      )

    send(pid, :scheduled)

    assert_receive {:retry, "project-1", ^payload, 5_000}, 1_000
    refute_received {:dispatch, _command, _timeout}

    assert_receive {
      :telemetry,
      @orphan_retry,
      %{duration_ms: duration_ms},
      %{project_id: "project-1", run_id: "run-1", outcome: :ok}
    }

    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end

  test "scheduled pass retains non-terminal existing runs for the next pass" do
    parent = self()

    pid =
      start_supervised!(
        {RunLifecycleReconciler,
         [
           name: unique_name(),
           interval_ms: 60_000,
           subscribe_fun: fn -> :ok end,
           list_active_runs_fun: fn -> [{"project-1", ["run-1"]}] end,
           project_loader_fun: fn project_id ->
             send(parent, {:project_load, project_id})
             project_state(project_id, "run-1", run_start_payload())
           end,
           run_loader_fun: fn run_id ->
             send(parent, {:run_load, run_id})
             active_run_state(run_id, "project-1")
           end,
           run_admission_fun: fn project_id, payload, timeout ->
             send(parent, {:retry, project_id, payload, timeout})
             {:ok, %{}}
           end,
           dispatch_fun: fn command, timeout ->
             send(parent, {:dispatch, command, timeout})
             {:ok, %{}}
           end
         ]}
      )

    send(pid, :scheduled)

    assert_receive {:project_load, "project-1"}, 1_000
    assert_receive {:run_load, "run-1"}, 1_000
    refute_received {:retry, _project_id, _payload, _timeout}
    refute_received {:dispatch, _command, _timeout}
    refute_received {:telemetry, @orphan_retry, _measurements, _metadata}
  end

  test "scheduled pass releases for each definitive retry rejection and retains on non-allowlisted failure" do
    parent = self()
    payload = run_start_payload()
    definitive_reasons = [:phase_terminal, :project_archived, :unknown_project, :unknown_workflow]

    Enum.each(definitive_reasons, fn reason ->
      pid =
        start_absent_run_reconciler(parent, payload,
          tag: {:release, reason},
          run_admission_result: {:error, reason},
          dispatch_tag: :dispatch_release
        )

      send(pid, :scheduled)

      assert_receive {{:retry, {:release, ^reason}}, "project-1", ^payload, 5_000}, 1_000

      assert_receive {
                       :dispatch_release,
                       %{
                         aggregate_id: "project:project-1",
                         type: "project.release_run_reservation",
                         payload: %{
                           project_id: "project-1",
                           run_id: "run-1",
                           reason: "definitive_retry_rejection"
                         }
                       },
                       5_000
                     },
                     1_000

      assert_receive {
        :telemetry,
        @orphan_retry,
        %{duration_ms: release_duration_ms},
        %{project_id: "project-1", run_id: "run-1", outcome: ^reason}
      }

      assert is_integer(release_duration_ms)
      assert release_duration_ms >= 0
    end)

    ambiguous_pid =
      start_absent_run_reconciler(parent, payload,
        tag: {:retain, :timeout},
        run_admission_result: {:error, :timeout},
        dispatch_tag: :dispatch_retain
      )

    send(ambiguous_pid, :scheduled)

    assert_receive {{:retry, {:retain, :timeout}}, "project-1", ^payload, 5_000}, 1_000
    refute_received {:dispatch_retain, _command, _timeout}

    assert_receive {
      :telemetry,
      @orphan_retry,
      %{duration_ms: retain_duration_ms},
      %{project_id: "project-1", run_id: "run-1", outcome: :timeout}
    }

    assert is_integer(retain_duration_ms)
    assert retain_duration_ms >= 0
  end

  test "scheduled pass and concurrent dispatch_run_start converge to one RunStarted without releasing the reservation" do
    parent = self()
    project_id = unique_id("project")
    run_id = unique_id("run")
    task_id = unique_id("task")
    payload = run_start_payload(run_id, task_id, project_id)

    register_project!(project_id)
    reserve_run!(project_id, run_id, payload)

    state = %{
      interval_ms: 60_000,
      timeout_ms: 5_000,
      subscribe_fun: fn -> :ok end,
      ack_fun: fn _subscription, _events -> :ok end,
      list_active_runs_fun: fn -> [{project_id, [run_id]}] end,
      project_loader_fun: &load_project_state!/1,
      run_loader_fun: fn loaded_run_id ->
        run_state = load_run_state!(loaded_run_id)

        if loaded_run_id == run_id do
          send(parent, {:run_loaded_for_race, self(), loaded_run_id, run_state.exists?})

          receive do
            :continue_after_dispatch -> run_state
          after
            5_000 ->
              flunk("timed out waiting to resume scheduled reconciler for #{loaded_run_id}")
          end
        else
          run_state
        end
      end,
      run_admission_fun: &RunAdmission.start/3,
      dispatch_fun: &ForemanServer.CommandGateway.dispatch_system/2,
      telemetry_module: ForemanServer.Telemetry
    }

    stream =
      Task.async_stream(
        [:scheduled_pass, :concurrent_dispatch],
        fn
          :scheduled_pass ->
            result = RunLifecycleReconciler.reconcile_scheduled(state)
            send(parent, {:scheduled_result, result})
            result

          :concurrent_dispatch ->
            send(parent, {:dispatch_ready, self()})

            receive do
              :dispatch_now ->
                result = CommandRouter.dispatch_run_start(project_id, payload, 5_000)
                send(parent, {:dispatch_result, result})
                result
            after
              5_000 -> flunk("timed out waiting to start concurrent dispatch for #{run_id}")
            end
        end,
        ordered: false,
        max_concurrency: 2,
        timeout: 15_000
      )

    collector = Task.async(fn -> Enum.to_list(stream) end)

    assert_receive {:dispatch_ready, dispatch_pid}, 1_000
    assert_receive {:run_loaded_for_race, scheduled_pid, ^run_id, false}, 1_000

    send(dispatch_pid, :dispatch_now)

    assert_receive {:dispatch_result, dispatch_result}, 5_000

    assert match?({:ok, _}, dispatch_result) or
             match?({:error, {:already_exists, :run, ^run_id}}, dispatch_result)

    send(scheduled_pid, :continue_after_dispatch)

    task_results =
      Task.await(collector, 15_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert :ok in task_results

    assert_receive {:scheduled_result, :ok}, 5_000

    assert_receive {:telemetry, @orphan_retry, %{duration_ms: duration_ms}, metadata}, 5_000
    assert metadata.project_id == project_id
    assert metadata.run_id == run_id
    assert metadata.outcome == :ok or metadata.outcome == {:already_exists, :run, run_id}
    assert is_integer(duration_ms)
    assert duration_ms >= 0

    run_projection =
      wait_until(
        fn ->
          case ProjectionStore.run(run_id) do
            %{run_id: ^run_id} = projection -> {:ok, projection}
            _ -> :retry
          end
        end,
        "run projection #{run_id}"
      )

    assert run_projection.project_id == project_id
    assert run_projection.task_id == task_id
    assert run_projection.workflow_snapshot == payload.workflow_snapshot

    assert Enum.any?(ProjectionStore.list_projects_with_active_runs(), fn
             {^project_id, [^run_id]} -> true
             _ -> false
           end)

    project_projection = ProjectionStore.project_projection(project_id)
    assert project_projection.status == "active"
    assert project_projection.archived? == false

    {project_state, _version} = Aggregate.load(Project, "project:#{project_id}")
    assert Map.has_key?(project_state.active_run_reservations, run_id)

    assert {:ok, run_events} = EventStore.read_stream_forward("run:#{run_id}", 0, 10)
    assert Enum.map(run_events, & &1.event_type) == ["RunStarted"]

    assert {:ok, project_events} = EventStore.read_stream_forward("project:#{project_id}", 0, 10)

    assert Enum.map(project_events, & &1.event_type) == [
             "ProjectRegistered",
             "ProjectRunReserved"
           ]

    refute Enum.any?(project_events, &(&1.event_type == "ProjectRunReservationReleased"))
  end

  defp start_absent_run_reconciler(parent, payload, opts) do
    tag = Keyword.fetch!(opts, :tag)
    run_admission_result = Keyword.fetch!(opts, :run_admission_result)
    dispatch_tag = Keyword.fetch!(opts, :dispatch_tag)

    start_supervised!(
      {RunLifecycleReconciler,
       [
         name: unique_name(),
         interval_ms: 60_000,
         subscribe_fun: fn -> :ok end,
         list_active_runs_fun: fn -> [{"project-1", ["run-1"]}] end,
         project_loader_fun: fn project_id -> project_state(project_id, "run-1", payload) end,
         run_loader_fun: fn run_id -> absent_run_state(run_id) end,
         run_admission_fun: fn project_id, recovered_payload, timeout ->
           send(parent, {{:retry, tag}, project_id, recovered_payload, timeout})
           run_admission_result
         end,
         dispatch_fun: fn command, timeout ->
           send(parent, {dispatch_tag, command, timeout})
           {:ok, %{}}
         end
       ]}
    )
  end

  defp unique_name do
    String.to_atom("run_lifecycle_reconciler_test_#{System.unique_integer([:positive])}")
  end

  defp unique_id(prefix) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    "#{prefix}-run-lifecycle-reconciler-#{suffix}"
  end

  defp run_start_payload do
    run_start_payload("run-1", "task-1", "project-1")
  end

  defp run_start_payload(run_id, task_id, project_id) do
    %{
      run_id: run_id,
      task_id: task_id,
      project_id: project_id,
      approval_id: "approval-1",
      workflow_snapshot: %{id: "workflow-1", version: 1},
      phase_specs: [%{phase_id: "phase-1", adapter: :test, prompt: "go"}]
    }
  end

  defp project_state(project_id, run_id, payload) do
    %Project.State{
      exists?: true,
      project_id: project_id,
      path: "/tmp/#{project_id}",
      status: "active",
      default_branch: "main",
      archived?: false,
      active_run_reservations: %{
        run_id => %{
          project_id: project_id,
          run_id: run_id,
          sequence: 1,
          command_id: "run:start:#{run_id}:reservation",
          run_start_payload: payload
        }
      },
      config: %{},
      health: %{ok: true}
    }
  end

  defp register_project!(project_id) do
    assert {:ok, _} =
             CommandRouter.dispatch(%{
               aggregate_id: "project:#{project_id}",
               command_id: "register:#{project_id}",
               type: "project.register",
               payload: %{
                 project_id: project_id,
                 name: "Run Lifecycle #{project_id}",
                 path: System.tmp_dir!()
               }
             })
  end

  defp reserve_run!(project_id, run_id, payload) do
    command_id = "reserve:#{project_id}:#{run_id}"

    assert {:ok, _} =
             CommandRouter.dispatch(%{
               aggregate_id: "project:#{project_id}",
               command_id: command_id,
               type: "project.reserve_run",
               payload: %{
                 project_id: project_id,
                 run_id: run_id,
                 command_id: command_id,
                 sequence: 1,
                 run_start_payload: payload
               }
             })
  end

  defp load_project_state!(project_id) do
    {state, _version} = Aggregate.load(Project, "project:#{project_id}")
    state
  end

  defp load_run_state!(run_id) do
    {state, _version} = Aggregate.load(Run, "run:#{run_id}")
    state
  end

  defp absent_run_state(run_id) do
    %Run.State{
      exists?: false,
      run_id: run_id,
      task_id: nil,
      project_id: nil,
      status: nil,
      terminal?: false,
      last_sequence: 0,
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    }
  end

  defp active_run_state(run_id, project_id) do
    %Run.State{
      exists?: true,
      run_id: run_id,
      task_id: "task-1",
      project_id: project_id,
      status: "in_progress",
      terminal?: false,
      last_sequence: 1,
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    }
  end

  defp terminal_run_state(run_id, project_id) do
    %Run.State{
      exists?: true,
      run_id: run_id,
      task_id: "task-1",
      project_id: project_id,
      status: "completed",
      terminal?: true,
      last_sequence: 2,
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    }
  end

  defp wait_until(fun, description, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, description, deadline)
  end

  defp do_wait_until(fun, description, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{description}")
        else
          Process.sleep(25)
          do_wait_until(fun, description, deadline)
        end

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{description} (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_wait_until(fun, description, deadline)
        end
    end
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) do
      :ok
    else
      start_supervised!(child_spec)
      :ok
    end
  end
end
