defmodule ForemanServer.RunLifecycleReconcilerTest do
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.Aggregates.{Project, Run}
  alias ForemanServer.{Identity, ProjectionStore, RunLifecycleReconciler}

  @terminal_release [:foreman_server, :reconciler, :terminal_release]
  @orphan_retry [:foreman_server, :reconciler, :orphan_retry]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
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

  test "scheduled pass retains reservation when concurrent run.start wins after the absent-run load" do
    parent = self()
    payload = run_start_payload()
    {:ok, run_loader_state} = Agent.start_link(fn -> 0 end)

    pid =
      start_supervised!(
        {RunLifecycleReconciler,
         [
           name: unique_name(),
           interval_ms: 60_000,
           subscribe_fun: fn -> :ok end,
           list_active_runs_fun: fn -> [{"project-1", ["run-1"]}] end,
           project_loader_fun: fn project_id -> project_state(project_id, "run-1", payload) end,
           run_loader_fun: fn run_id ->
             case Agent.get_and_update(run_loader_state, fn
                    0 -> {:absent, 1}
                    count -> {:active, count + 1}
                  end) do
               :absent ->
                 send(parent, {:run_load, :absent, run_id})
                 absent_run_state(run_id)

               :active ->
                 send(parent, {:run_load, :active, run_id})
                 active_run_state(run_id, "project-1")
             end
           end,
           run_admission_fun: fn project_id, recovered_payload, timeout ->
             send(parent, {:retry, project_id, recovered_payload, timeout})
             {:error, {:already_exists, :run, "run-1"}}
           end,
           dispatch_fun: fn command, timeout ->
             send(parent, {:dispatch, command, timeout})
             {:ok, %{}}
           end
         ]}
      )

    send(pid, :scheduled)

    assert_receive {:run_load, :absent, "run-1"}, 1_000
    assert_receive {:retry, "project-1", ^payload, 5_000}, 1_000
    refute_received {:dispatch, _command, _timeout}

    assert_receive {
      :telemetry,
      @orphan_retry,
      %{duration_ms: duration_ms},
      %{project_id: "project-1", run_id: "run-1", outcome: {:already_exists, :run, "run-1"}}
    }

    assert is_integer(duration_ms)
    assert duration_ms >= 0

    send(pid, :scheduled)

    assert_receive {:run_load, :active, "run-1"}, 1_000
    refute_received {:retry, _project_id, _recovered_payload, _timeout}
    refute_received {:dispatch, _command, _timeout}
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

  defp run_start_payload do
    %{
      run_id: "run-1",
      task_id: "task-1",
      project_id: "project-1",
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
end
