defmodule ForemanServer.TaskProviders.ConcurrencyLimiterTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ConcurrencyLimiter
  alias ForemanServer.TaskProviders.SystemBrRunner

  @property_runs 5
  @runner_invocations_per_task 1

  setup_all do
    {:ok, _mox_apps} = Application.ensure_all_started(:mox)
    :ok
  end

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])
    original_path = System.get_env("PATH") || ""

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "concurrency_limiter_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    put_fake_br_on_path!(temp_dir)

    Application.put_env(
      :foreman_server,
      :task_provider,
      previous_config
      |> Keyword.put(:actor, nil)
      |> Keyword.put(:accepted_contract_versions, ["br.capabilities.v1"])
      |> Keyword.put(:providers, [])
      |> Keyword.put(:max_in_flight, 4)
      |> Keyword.put(:timeout_ms, 30_000)
    )

    start_supervised!(ConcurrencyLimiter)
    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "4 concurrent acquires succeed" do
    project_id = make_ref()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn -> ConcurrencyLimiter.acquire(project_id) end)
      end)
      |> Enum.map(&Task.await(&1, 500))

    assert results == [:ok, :ok, :ok, :ok]

    release_slots(project_id, 4)
  end

  test "5th acquire with timeout triggers BR_TIMEOUT_QUEUE" do
    project_id = make_ref()

    fill_slots(project_id, 4)

    assert {:error, :timeout} = ConcurrencyLimiter.acquire(project_id, 50)

    release_slots(project_id, 4)
  end

  test "release/1 frees a slot" do
    project_id = make_ref()
    parent = self()

    fill_slots(project_id, 4)

    waiting_acquire =
      Task.async(fn ->
        send(parent, :waiting_acquire_started)
        ConcurrencyLimiter.acquire(project_id, 200)
      end)

    assert_receive :waiting_acquire_started, 100
    Process.sleep(25)

    assert :ok = ConcurrencyLimiter.release(project_id)
    assert Task.await(waiting_acquire, 500) == :ok

    release_slots(project_id, 4)
  end

  test "per-call timeout is independent of acquire timeout" do
    project_id = make_ref()

    fill_slots(project_id, 4)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = ConcurrencyLimiter.acquire(project_id, 100)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 80
    assert elapsed_ms < 1_000

    release_slots(project_id, 4)
  end

  property "TRD-035 preserves per-caller database_path isolation for one caller",
           %{temp_dir: temp_dir} do
    check all(
            %{case_id: case_id, permutation: permutation} <- isolation_case_generator(1),
            max_runs: @property_runs
          ) do
      assert :ok =
               Task.async(fn ->
                 run_isolation_case(1, permutation, temp_dir, case_id)
               end)
               |> Task.await(15_000)
    end
  end

  property "TRD-035 preserves per-caller database_path isolation for four callers",
           %{temp_dir: temp_dir} do
    check all(
            %{case_id: case_id, permutation: permutation} <- isolation_case_generator(4),
            max_runs: @property_runs
          ) do
      assert :ok =
               Task.async(fn ->
                 run_isolation_case(4, permutation, temp_dir, case_id)
               end)
               |> Task.await(15_000)
    end
  end

  property "TRD-035 preserves per-caller database_path isolation for sixteen callers",
           %{temp_dir: temp_dir} do
    check all(
            %{case_id: case_id, permutation: permutation} <- isolation_case_generator(16),
            max_runs: @property_runs
          ) do
      assert :ok =
               Task.async(fn ->
                 run_isolation_case(16, permutation, temp_dir, case_id)
               end)
               |> Task.await(15_000)
    end
  end

  defp run_isolation_case(concurrency, permutation, temp_dir, case_id) do
    owner_pid = self()
    Mox.set_mox_private()

    Mox.stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    assignments =
      concurrency
      |> build_assignments(permutation, case_id)
      |> Enum.map(fn assignment ->
        Map.put(
          assignment,
          :project_config,
          register_project!(assignment.project_id, assignment.database_path)
        )
      end)

    tasks =
      Enum.map(assignments, fn assignment ->
        Task.async(fn ->
          send(owner_pid, {:blocked, self()})

          receive do
            {:start, ^owner_pid} -> :ok
          end

          assert {:ok, BeadsAdapter} =
                   Registry.route(
                     :set_priority,
                     {assignment.project_id, assignment.database_path}
                   )

          assert :ok =
                   BeadsAdapter.set_priority(assignment.task_id, 2, assignment.project_config)
        end)
      end)

    pid_to_assignment =
      Map.new(Enum.zip(tasks, assignments), fn {%Task{pid: caller_pid}, assignment} ->
        {caller_pid, assignment}
      end)

    pid_to_expected_database_path =
      Map.new(pid_to_assignment, fn {caller_pid, assignment} ->
        {caller_pid, assignment.database_path}
      end)

    Mox.expect(BrRunnerMock, :cmd, concurrency * @runner_invocations_per_task, fn request,
                                                                                  project_config,
                                                                                  opts ->
      caller_pid = self()
      assignment = Map.fetch!(pid_to_assignment, caller_pid)

      assert request ==
               {:set_priority,
                %{id: assignment.task_id, priority: 2, database_path: assignment.database_path}}

      assert project_config == %{}
      assert opts == [timeout_ms: 30_000]

      send(
        owner_pid,
        {:captured_argv, caller_pid, translated_argv(temp_dir, request, project_config)}
      )

      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    Enum.each(Map.keys(pid_to_assignment), fn caller_pid ->
      Mox.allow(BrRunnerMock, owner_pid, caller_pid)
    end)

    assert_blocked_callers!(Map.keys(pid_to_assignment))

    Enum.each(Map.keys(pid_to_assignment), fn caller_pid ->
      send(caller_pid, {:start, owner_pid})
    end)

    assert List.duplicate(:ok, concurrency) == Task.await_many(tasks, 5_000)

    captured_argvs = receive_captured_argvs(concurrency * @runner_invocations_per_task)

    assert length(captured_argvs) == concurrency * @runner_invocations_per_task

    assert Enum.sort(Map.values(pid_to_expected_database_path)) ==
             captured_argvs
             |> Enum.map(fn {caller_pid, argv} ->
               expected_database_path = Map.fetch!(pid_to_expected_database_path, caller_pid)

               assert expected_database_path in argv
               assert database_paths_in_argv(argv) == [expected_database_path]

               expected_database_path
             end)
             |> Enum.sort()

    Mox.verify!()
    :ok
  end

  defp isolation_case_generator(concurrency) do
    StreamData.fixed_map(%{
      case_id: StreamData.positive_integer(),
      permutation: permutation_generator(concurrency)
    })
  end

  defp permutation_generator(concurrency) do
    StreamData.constant(Enum.to_list(1..concurrency))
    |> StreamData.map(&Enum.shuffle/1)
  end

  defp build_assignments(_concurrency, permutation, case_id) do
    permutation
    |> Enum.with_index(1)
    |> Enum.map(fn {path_index, task_index} ->
      %{
        project_id: "trd-035-project-#{case_id}-#{task_index}",
        task_id: "trd-035-task-#{case_id}-#{task_index}",
        database_path: "/abs/trd-035/#{case_id}/db-#{path_index}.sqlite3"
      }
    end)
  end

  defp register_project!(project_id, database_path) do
    assert :ok =
             Registry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => database_path
             })

    assert Registry.routing_snapshot()[project_id] == BeadsAdapter

    assert {:active, %{provider_module: BeadsAdapter, config: project_config}} =
             :sys.get_state(Registry).per_project[project_id]

    assert project_config == %{"database_path" => database_path}
    project_config
  end

  defp assert_blocked_callers!(caller_pids) do
    blocked_callers =
      Enum.reduce(1..length(caller_pids), MapSet.new(), fn _, blocked ->
        receive do
          {:blocked, caller_pid} -> MapSet.put(blocked, caller_pid)
        after
          1_000 -> flunk("expected blocked caller notification for #{inspect(caller_pids)}")
        end
      end)

    assert blocked_callers == MapSet.new(caller_pids)
  end

  defp receive_captured_argvs(expected_count) do
    Enum.map(1..expected_count, fn _ ->
      receive do
        {:captured_argv, caller_pid, argv} -> {caller_pid, argv}
      after
        1_000 -> flunk("expected #{expected_count} captured argv messages")
      end
    end)
  end

  defp database_paths_in_argv(argv) do
    Enum.filter(argv, &String.starts_with?(&1, "/abs/"))
  end

  defp translated_argv(temp_dir, request, project_config) do
    assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
             SystemBrRunner.cmd(request, project_config)

    stdout
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == temp_dir))
  end

  defp put_fake_br_on_path!(temp_dir) do
    script_path = Path.join(temp_dir, "br")
    original_path = System.get_env("PATH") || ""

    File.write!(
      script_path,
      """
      #!/bin/sh
      set -eu
      for arg in "$@"; do
        printf '%s\n' "$arg"
      done
      """
    )

    File.chmod!(script_path, 0o755)
    System.put_env("PATH", "#{temp_dir}:#{original_path}")
  end

  defp fill_slots(project_id, count) do
    Enum.each(1..count, fn _ ->
      assert :ok = ConcurrencyLimiter.acquire(project_id)
    end)
  end

  defp release_slots(project_id, count) do
    Enum.each(1..count, fn _ ->
      assert :ok = ConcurrencyLimiter.release(project_id)
    end)
  end
end
