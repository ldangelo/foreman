defmodule ForemanServer.RunLifecycleReconcilerSlotTest do
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.Aggregates.{Project, Run}
  alias ForemanServer.{Identity, RunLifecycleReconciler}

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

  describe "slot release from terminal event subscription" do
    test "terminal event triggers slot release alongside lease release" do
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

      assert %{subscription: :subscribed, subscription_ref: ^subscription_ref} =
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

      assert_receive {:dispatch,
                      %{
                        type: "project.release_run_reservation",
                        payload: %{
                          project_id: "project-1",
                          run_id: "run-1",
                          reason: "terminal_event"
                        }
                      }, 5_000},
                     1_000

      assert_receive {:dispatch,
                      %{
                        type: "run_slots.release",
                        aggregate_id: "run_slots:global",
                        payload: %{run_id: "run-1"}
                      }, 5_000},
                     1_000

      assert_receive {:acked, ^subscription_ref, ^events}, 1_000

      assert_receive {:telemetry, @terminal_release, %{duration_ms: duration_ms},
                      %{
                        path: :subscribed,
                        project_id: "project-1",
                        run_id: "run-1",
                        outcome: :released
                      }}

      assert is_integer(duration_ms) and duration_ms >= 0
    end
  end

  describe "backstop sweep for promoted-but-unstarted waiter" do
    test "scheduled pass detects promoted-but-unstarted waiter and retries after two intervals" do
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
               count =
                 Agent.get_and_update(run_loader_state, fn current -> {current, current + 1} end)

               send(parent, {:run_load_attempt, count + 1, run_id})

               if count < 2 do
                 absent_run_state(run_id)
               else
                 active_run_state(run_id, "project-1")
               end
             end,
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
      assert_receive {:run_load_attempt, 1, "run-1"}, 1_000
      assert_receive {:retry, "project-1", ^payload, 5_000}, 1_000

      send(pid, :scheduled)
      assert_receive {:run_load_attempt, 2, "run-1"}, 1_000
      assert_receive {:retry, "project-1", ^payload, 5_000}, 1_000

      send(pid, :scheduled)
      assert_receive {:run_load_attempt, 3, "run-1"}, 1_000
      refute_receive {:retry, "project-1", ^payload, 5_000}, 200
      refute_received {:dispatch, _command, _timeout}
    end

    test "retry is idempotent when executor started in the meantime" do
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
               case Agent.get_and_update(run_loader_state, fn current ->
                      {current, current + 1}
                    end) do
                 0 ->
                   send(parent, {:run_load, :absent, run_id})
                   absent_run_state(run_id)

                 _ ->
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

      assert_receive {:telemetry, @orphan_retry, %{duration_ms: duration_ms},
                      %{
                        project_id: "project-1",
                        run_id: "run-1",
                        outcome: {:already_exists, :run, "run-1"}
                      }}

      assert is_integer(duration_ms) and duration_ms >= 0

      send(pid, :scheduled)

      assert_receive {:run_load, :active, "run-1"}, 1_000
      refute_receive {:retry, _project_id, _payload, _timeout}, 200
      refute_receive {:dispatch, _command, _timeout}, 200
    end
  end

  defp unique_name do
    String.to_atom("run_lifecycle_reconciler_slot_test_#{System.unique_integer([:positive])}")
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
