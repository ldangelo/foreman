defmodule ForemanServer.WorkerEnvironmentTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Project, ProjectStore, WorkerEnvironment, WorkerLauncher}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-worker-environment-test-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(tmp_dir, "bin")
    projects_dir = Path.join(tmp_dir, "projects")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(projects_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    old_path = System.get_env("PATH") || ""
    System.put_env("PATH", bin_dir <> ":" <> old_path)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      System.put_env("PATH", old_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)

    {:ok, tmp_dir: tmp_dir, bin_dir: bin_dir, projects_dir: projects_dir}
  end

  test "build_env_map/3 returns a complete worker env map for a registered project", %{
    projects_dir: projects_dir
  } do
    project_id = "project-complete"
    project_dir = register_project(projects_dir, project_id,
      env: %{
        "BASE_ENV" => "project-value",
        "CI" => "true",
        "GITHUB_TOKEN" => "should-be-stripped"
      },
      project_secrets: %{"PROJECT_TOKEN" => "project-secret"},
      run_secrets: %{"RUN_TOKEN" => "run-secret"}
    )

    assert File.dir?(project_dir)

    assert {:ok, env_map} =
             WorkerEnvironment.build_env_map(project_id, "run-complete", %{
               "BASE_ENV" => "task-override",
               "TASK_ONLY" => "task-value",
               "DATABASE_URL" => "blocked"
             })

    assert env_map == %{
             "BASE_ENV" => "task-override",
             "CI" => "true",
             "FOREMAN_PROJECT_ID" => project_id,
             "FOREMAN_RUN_ID" => "run-complete",
             "PROJECT_TOKEN" => "project-secret",
             "RUN_TOKEN" => "run-secret",
             "TASK_ONLY" => "task-value"
           }
  end

  test "env maps stay isolated between workers and projects", %{projects_dir: projects_dir} do
    register_project(projects_dir, "project-one",
      env: %{"ONE_ENV" => "one"},
      project_secrets: %{"PROJECT_ONE_TOKEN" => "project-one-secret"},
      run_secrets: %{"RUN_ONE_TOKEN" => "run-one-secret"}
    )

    register_project(projects_dir, "project-two",
      env: %{"TWO_ENV" => "two"},
      project_secrets: %{"PROJECT_TWO_TOKEN" => "project-two-secret"},
      run_secrets: %{"RUN_TWO_TOKEN" => "run-two-secret"}
    )

    assert {:ok, first_env} = WorkerEnvironment.build_env_map("project-one", "run-one")
    assert {:ok, second_env} = WorkerEnvironment.build_env_map("project-two", "run-two")
    assert {:ok, first_env_again} = WorkerEnvironment.build_env_map("project-one", "run-one")

    assert first_env == first_env_again
    assert first_env["ONE_ENV"] == "one"
    assert first_env["PROJECT_ONE_TOKEN"] == "project-one-secret"
    assert first_env["RUN_ONE_TOKEN"] == "run-one-secret"
    assert first_env["FOREMAN_PROJECT_ID"] == "project-one"
    assert first_env["FOREMAN_RUN_ID"] == "run-one"
    refute Map.has_key?(first_env, "TWO_ENV")
    refute Map.has_key?(first_env, "PROJECT_TWO_TOKEN")
    refute Map.has_key?(first_env, "RUN_TWO_TOKEN")

    assert second_env["TWO_ENV"] == "two"
    assert second_env["PROJECT_TWO_TOKEN"] == "project-two-secret"
    assert second_env["RUN_TWO_TOKEN"] == "run-two-secret"
    assert second_env["FOREMAN_PROJECT_ID"] == "project-two"
    assert second_env["FOREMAN_RUN_ID"] == "run-two"
    refute Map.has_key?(second_env, "ONE_ENV")
    refute Map.has_key?(second_env, "PROJECT_ONE_TOKEN")
    refute Map.has_key?(second_env, "RUN_ONE_TOKEN")
  end

  test "config changes apply on the next worker launch for the same run but not mid-run", %{
    bin_dir: bin_dir,
    projects_dir: projects_dir,
    tmp_dir: tmp_dir
  } do
    project_id = "project-reload"

    project_dir =
      register_project(projects_dir, project_id,
        env: %{"LAUNCH_VALUE" => "before-update"},
        project_secrets: %{"LAUNCH_SECRET" => "before-secret"}
      )

    started_path = Path.join(tmp_dir, "worker-started")
    release_path = Path.join(tmp_dir, "worker-release")

    foreman = Path.join(bin_dir, "foreman")

    File.write!(foreman, """
    #!/usr/bin/env sh
    echo "task_id=$3"
    echo "launch_value=${LAUNCH_VALUE:-unset}"
    echo "launch_secret=${LAUNCH_SECRET:-unset}"
    echo "project_id=${FOREMAN_PROJECT_ID:-unset}"
    echo "run_id=${FOREMAN_RUN_ID:-unset}"
    echo started > \"#{started_path}\"
    while [ ! -f \"#{release_path}\" ]; do
      sleep 0.05
    done
    echo "launch_value_after_wait=${LAUNCH_VALUE:-unset}"
    echo "launch_secret_after_wait=${LAUNCH_SECRET:-unset}"
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    run_id = "run-shared"
    first_task_id = "task-old-env"
    second_task_id = "task-new-env"

    assert {:ok, _} =
             WorkerLauncher.launch(
               %{task_id: first_task_id, project_id: project_id, project_path: project_dir, task_type: "feature"},
               run_id,
               ["developer"]
             )

    assert_eventually(fn -> File.exists?(started_path) end, & &1)

    assert {:ok, _} =
             ProjectStore.save(%Project{
               id: project_id,
               path: project_dir,
               config: %{
                 env: %{"LAUNCH_VALUE" => "after-update"},
                 project_secrets: %{"LAUNCH_SECRET" => "after-secret"}
               }
             })

    File.write!(release_path, "release")

    assert_eventually(
      fn -> worker_exit_output(run_id, first_task_id) end,
      fn output ->
        is_binary(output) and
          String.contains?(output, "task_id=#{first_task_id}") and
          String.contains?(output, "launch_value=before-update") and
          String.contains?(output, "launch_secret=before-secret") and
          String.contains?(output, "launch_value_after_wait=before-update") and
          String.contains?(output, "launch_secret_after_wait=before-secret") and
          not String.contains?(output, "after-update")
      end
    )

    assert {:ok, _} =
             WorkerLauncher.launch(
               %{task_id: second_task_id, project_id: project_id, project_path: project_dir, task_type: "feature"},
               run_id,
               ["developer"]
             )

    assert_eventually(
      fn -> worker_exit_output(run_id, second_task_id) end,
      fn output ->
        is_binary(output) and
          String.contains?(output, "task_id=#{second_task_id}") and
          String.contains?(output, "launch_value=after-update") and
          String.contains?(output, "launch_secret=after-secret") and
          String.contains?(output, "launch_value_after_wait=after-update") and
          String.contains?(output, "launch_secret_after_wait=after-secret") and
          not String.contains?(output, "before-update")
      end
    )
  end

  defp register_project(projects_dir, project_id, config) do
    project_dir = Path.join(projects_dir, project_id)
    File.mkdir_p!(project_dir)

    assert {:ok, _} =
             ProjectStore.save(%Project{
               id: project_id,
               path: project_dir,
               config: Enum.into(config, %{})
             })

    project_dir
  end

  defp worker_exit_output(run_id, task_id) do
    "worker-launch:#{run_id}"
    |> EventStore.stream()
    |> Enum.find_value(fn event ->
      if event.event_type == "WorkerProcessExited" and event.payload.task_id == task_id do
        event.payload.output
      end
    end)
  end

  defp assert_eventually(fun, predicate, attempts \\ 40)

  defp assert_eventually(fun, predicate, attempts) when attempts > 0 do
    result = fun.()

    if predicate.(result) do
      assert true
    else
      Process.sleep(20)
      assert_eventually(fun, predicate, attempts - 1)
    end
  end

  defp assert_eventually(_fun, _predicate, 0) do
    flunk("expected condition to become true")
  end
end
