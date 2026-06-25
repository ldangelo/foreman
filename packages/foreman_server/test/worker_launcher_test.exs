defmodule ForemanServer.WorkerLauncherTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, WorkerLauncher}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "foreman-worker-launcher-test-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(tmp_dir, "bin")
    project_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(project_dir)

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
    {:ok, bin_dir: bin_dir, project_dir: project_dir}
  end

  test "zero-exit launch success does not mark run or task completed", %{bin_dir: bin_dir, project_dir: project_dir} do
    foreman = Path.join(bin_dir, "foreman")

    File.write!(foreman, """
    #!/usr/bin/env sh
    echo 'worker launched'
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    task = %{task_id: "task-a", project_id: "project-a", project_path: project_dir, task_type: "feature"}
    run_id = "00000000-0000-0000-0000-000000000001"

    assert {:ok, _} = WorkerLauncher.launch(task, run_id, ["developer"])

    assert_eventually(fn -> EventStore.stream("worker-launch:#{run_id}") end, fn events ->
      Enum.any?(events, &(&1.event_type == "WorkerLaunchCompleted"))
    end)

    assert EventStore.stream("run:#{run_id}") == []
    refute match?(%{status: "completed"}, ProjectionStore.task("task-a"))
  end

  test "workflow label selects launched worker workflow", %{bin_dir: bin_dir, project_dir: project_dir} do
    foreman = Path.join(bin_dir, "foreman")
    args_file = Path.join(project_dir, "args.txt")

    File.write!(foreman, """
    #!/usr/bin/env sh
    printf '%s\n' "$@" > #{args_file}
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    task = %{task_id: "task-a", project_id: "project-a", project_path: project_dir, task_type: "feature", labels: ["workflow:docs"]}
    run_id = "00000000-0000-0000-0000-000000000009"

    assert {:ok, %{workflow: "docs"}} = WorkerLauncher.launch(task, run_id, ["developer"])

    assert_eventually(fn -> if(File.exists?(args_file), do: File.read!(args_file), else: "") end, fn args ->
      String.contains?(args, "run\ntask\ntask-a\ndocs\n")
    end)
  end

  test "zero-exit worker output with pipeline failure marks task failed", %{bin_dir: bin_dir, project_dir: project_dir} do
    foreman = Path.join(bin_dir, "foreman")

    File.write!(foreman, """
    #!/usr/bin/env sh
    echo '[PIPELINE] FAILED ($1.23)'
    echo '[PHASE: DEVELOPER] FAILED: Phase exceeded maxTurns (120)'
    exit 0
    """)

    File.chmod!(foreman, 0o755)

    task = %{task_id: "task-a", project_id: "project-a", project_path: project_dir, task_type: "feature"}

    assert {:ok, _} = WorkerLauncher.launch(task, "00000000-0000-0000-0000-000000000001", ["developer"])

    assert_eventually(fn -> ProjectionStore.task("task-a") end, fn task ->
      task && task.status == "failed" && task.failure_reason == "max_turns"
    end)
  end

  defp assert_eventually(fun, predicate, attempts \\ 20)
  defp assert_eventually(fun, predicate, attempts) when attempts > 0 do
    value = fun.()

    if predicate.(value) do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, predicate, attempts - 1)
    end
  end

  defp assert_eventually(fun, predicate, 0) do
    value = fun.()
    flunk("condition not met; last value: #{inspect(value)}, predicate: #{inspect(predicate)}")
  end
end
