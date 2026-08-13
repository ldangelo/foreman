defmodule ForemanServer.RunAdmissionTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{
    Aggregate,
    CommandRouter,
    EventStore,
    Identity,
    ProjectionStore,
    RunAdmission
  }

  @poll_timeout_ms 8_000

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

  describe "start/2" do
    test "emits telemetry, reserves the project slot, and appends RunStarted with a deterministic command id" do
      project_id = unique_id("project")
      run_id = unique_id("run")
      task_id = unique_id("task")
      workflow_snapshot = %{phases: [%{id: "phase-1", kind: "command"}]}

      register_project!(project_id)

      payload = %{
        run_id: run_id,
        task_id: task_id,
        workflow_snapshot: workflow_snapshot,
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: unique_id("approval")
      }

      handler_id = "run-admission-#{unique_id("telemetry")}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:foreman, :run_admission, :start]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:ok, _} = RunAdmission.start(project_id, payload)

        assert_receive {
          :telemetry_event,
          [:foreman, :run_admission, :start],
          %{count: 1},
          %{project_id: ^project_id, run_id: ^run_id, task_id: ^task_id}
        }

        reservation =
          project_state(project_id)
          |> Map.fetch!(:active_run_reservations)
          |> Map.fetch!(run_id)

        assert reservation.command_id ==
                 Identity.run_start_command_id(
                   project_id,
                   run_id,
                   workflow_snapshot_hash(workflow_snapshot)
                 )

        run = wait_for_run(run_id)
        assert run.project_id == project_id
        assert run.task_id == task_id
        assert run.workflow_snapshot == workflow_snapshot
      after
        :telemetry.detach(handler_id)
      end
    end

    test "compensates the reservation on unknown_workflow rejection" do
      project_id = unique_id("project")
      run_id = unique_id("run")
      task_id = unique_id("task")

      register_project!(project_id)

      assert {:error, :unknown_workflow} =
               RunAdmission.start(project_id, %{run_id: run_id, task_id: task_id})

      refute Map.has_key?(project_state(project_id).active_run_reservations, run_id)

      {:ok, events} = EventStore.read_stream_forward("project:#{project_id}", 0, 99_999)

      assert Enum.map(events, & &1.event_type) == [
               "ProjectRegistered",
               "ProjectRunReserved",
               "ProjectRunReservationReleased"
             ]
    end

    test "normalizes archived-project rejection before run.start" do
      project_id = unique_id("project")
      run_id = unique_id("run")
      task_id = unique_id("task")

      register_project!(project_id)
      archive_project!(project_id)

      assert {:error, :project_archived} =
               RunAdmission.start(project_id, %{
                 run_id: run_id,
                 task_id: task_id,
                 workflow_snapshot: %{phases: []}
               })

      assert ProjectionStore.run(run_id) == nil
      refute Map.has_key?(project_state(project_id).active_run_reservations, run_id)
    end

    test "CommandRouter.dispatch/2 rejects direct run.start callers with a RunAdmission.start/2 error" do
      assert_raise ArgumentError,
                   ~r/ForemanServer\.RunAdmission\.start\/2/,
                   fn ->
                     CommandRouter.dispatch(%{
                       aggregate_id: "run:run-direct",
                       command_id: "run-direct",
                       type: "run.start",
                       payload: %{
                         run_id: "run-direct",
                         task_id: "task-direct",
                         project_id: "project-direct",
                         workflow_snapshot: %{phases: []}
                       }
                     })
                   end
    end

    test "does not expose CommandRouter.do_dispatch/2 externally" do
      assert_raise UndefinedFunctionError, fn ->
        apply(CommandRouter, :do_dispatch, ["cmd-1", %{payload: %{}, timeout: 5_000}])
      end
    end
  end

  describe "dispatch_run_start/3 — implementation_key collision" do
    test "rejects a second dispatch with the same implementation_key" do
      project_id = unique_id("project")
      run_id_1 = unique_id("run")
      run_id_2 = unique_id("run")
      task_id = unique_id("task")
      implementation_key = "trd-key-#{unique_id("k")}"

      register_project!(project_id)

      assert {:ok, _} =
               CommandRouter.dispatch_run_start(
                 project_id,
                 build_run_start_payload(run_id_1, task_id, implementation_key)
               )

      state = project_state(project_id)
      reservation = Map.get(state.active_run_reservations, run_id_1)
      assert reservation != nil
      assert Map.get(reservation, :implementation_key) == implementation_key

      assert {:error, {:implementation_already_active, ^implementation_key, ^run_id_1}} =
               CommandRouter.dispatch_run_start(
                 project_id,
                 build_run_start_payload(run_id_2, task_id, implementation_key)
               )

      assert Map.get(project_state(project_id).active_run_reservations, run_id_2) == nil
    end

    test "admits a second dispatch with a different implementation_key" do
      project_id = unique_id("project")
      run_id_1 = unique_id("run")
      run_id_2 = unique_id("run")
      task_id = unique_id("task")

      register_project!(project_id)

      assert {:ok, _} =
               CommandRouter.dispatch_run_start(
                 project_id,
                 build_run_start_payload(run_id_1, task_id, "trd-key-#{unique_id("a")}")
               )

      assert {:ok, _} =
               CommandRouter.dispatch_run_start(
                 project_id,
                 build_run_start_payload(run_id_2, task_id, "trd-key-#{unique_id("b")}")
               )

      assert Map.get(project_state(project_id).active_run_reservations, run_id_2) != nil
    end
  end

  defp build_run_start_payload(run_id, task_id, implementation_key) do
    workflow_snapshot = %{
      "phases" => [%{id: "phase-1", kind: "command"}],
      "implementation" => %{"implementation_key" => implementation_key}
    }

    %{
      run_id: run_id,
      task_id: task_id,
      workflow_snapshot: workflow_snapshot,
      phase_specs: [%{phase_id: "phase-1", kind: "command"}],
      approval_id: unique_id("approval")
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
                 name: "Run Admission #{project_id}",
                 path: System.tmp_dir!()
               }
             })
  end

  defp archive_project!(project_id) do
    assert {:ok, _} =
             CommandRouter.dispatch(%{
               aggregate_id: "project:#{project_id}",
               command_id: "archive:#{project_id}",
               type: "project.archive",
               payload: %{project_id: project_id}
             })
  end

  defp wait_for_run(run_id) do
    poll_until(
      fn ->
        case ProjectionStore.run(run_id) do
          %{run_id: ^run_id} = run -> {:ok, run}
          %{run_id: other} -> {:error, {:run_id_mismatch, other}}
          nil -> {:error, :missing}
        end
      end,
      "run #{run_id}"
    )
  end

  defp project_state(project_id) do
    case Registry.lookup(ForemanServer.AggregateRegistry, "project:#{project_id}") do
      [{pid, _value}] -> Aggregate.Actor.get_state(pid)
      [] -> flunk("expected project aggregate for #{project_id} to be started")
    end
  end

  defp poll_until(fun, message) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(fun, deadline, message)
  end

  defp do_poll(fun, deadline, message) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{message} (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_poll(fun, deadline, message)
        end
    end
  end

  defp unique_id(prefix) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    "#{prefix}-run-admission-#{suffix}"
  end

  defp workflow_snapshot_hash(snapshot) do
    snapshot
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
