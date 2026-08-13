defmodule ForemanServer.Workflow.BootReconciliationTest do
  use ExUnit.Case, async: false

  import Mox
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.{BeadsAdapter, BrRunnerMock, JsonSchemaCache, SystemBrRunner}
  alias ForemanServer.Workflow.BootReconciliation

  @cache_name :foreman_server_json_schema_cache
  @orphan_reopen_event [:foreman_server, :workflow, :boot_reconciliation, :orphan_reopen]
  @matching_in_progress_event [
    :foreman_server,
    :workflow,
    :boot_reconciliation,
    :matching_in_progress
  ]
  @already_closed_event [:foreman_server, :workflow, :boot_reconciliation, :already_closed]
  @healthy_event [:foreman_server, :workflow, :boot_reconciliation, :healthy]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
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

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_task_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: "foreman-runner",
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)
    cleanup_boot_reconciliation_state()

    stub(BrRunnerMock, :cmd, fn
      {:where, %{database_path: database_path}}, project_config, opts ->
        assert project_config == %{database_path: database_path}
        assert opts == [timeout_ms: 30_000]
        {:ok, %{stdout: ~s({"database_path":"#{database_path}"}), stderr: "", exit_code: 0}}

      {:schema, %{schema: schema_name}}, %{}, [] ->
        {:ok, %{stdout: Jason.encode!(schema_document(schema_name)), stderr: "", exit_code: 0}}

      request, project_config, opts ->
        flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    ensure_started(JsonSchemaCache, @cache_name)

    ensure_started(
      ForemanServer.TaskProvider.ProjectProviderProjector,
      ForemanServer.TaskProvider.ProjectProviderProjector
    )

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "boot_reconciliation_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    write_fake_br!(temp_dir, default_fake_br_body())

    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
      System.put_env("PATH", original_path)
      stop_schema_cache()
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "reopens orphaned in-progress provider issues", %{temp_dir: temp_dir} do
    ref = attach_boot_events([@orphan_reopen_event])
    project_id = unique_id("project")
    task_id = unique_id("task")
    database_path = unique_database_path("orphan")
    seed_project!(project_id, project_task_provider(database_path))
    register_project!(project_id, database_path)

    coordination_payload = coordination_issue_payload(task_id, "in_progress")
    reopened_payload = issue_details_payload(%{"id" => task_id, "status" => "open"})

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["coordination", "status", "--db", database_path, "--json"]
      )

      {:ok, %{stdout: Jason.encode!([coordination_payload]), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    task_id,
                    "--status",
                    "open",
                    "--transition-comment",
                    "foreman-run-reconciled"
                  ],
                  database_path: database_path
                }}

      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          database_path,
          task_id,
          "--status",
          "open",
          "--transition-comment",
          "foreman-run-reconciled",
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(reopened_payload), stderr: "", exit_code: 0}}
    end)

    assert :ok = BootReconciliation.reconcile()

    assert_receive {@orphan_reopen_event, ^ref, %{count: 1}, metadata}, 1_000
    assert metadata.project_id == project_id
    assert metadata.issue_id == task_id
    assert metadata.status == "in_progress"
    assert metadata.has_matching_run? == false
  end

  test "emits matching_in_progress when provider and Foreman both show active work", %{
    temp_dir: temp_dir
  } do
    ref = attach_boot_events([@matching_in_progress_event])
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    database_path = unique_database_path("matching")
    workflow_snapshot = %{phases: []}

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    coordination_payload = coordination_issue_payload(task_id, "in_progress")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["coordination", "status", "--db", database_path, "--json"]
      )

      {:ok, %{stdout: Jason.encode!([coordination_payload]), stderr: "", exit_code: 0}}
    end)

    assert :ok = BootReconciliation.reconcile()

    assert_receive {@matching_in_progress_event, ^ref, %{count: 1}, metadata}, 1_000
    assert metadata.project_id == project_id
    assert metadata.issue_id == task_id
    assert metadata.status == "in_progress"
    assert metadata.has_matching_run? == true
  end

  test "emits already_closed when the active Foreman run points at a closed provider issue", %{
    temp_dir: temp_dir
  } do
    ref = attach_boot_events([@already_closed_event])
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    database_path = unique_database_path("already-closed")
    workflow_snapshot = %{phases: []}

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    coordination_payload = coordination_issue_payload(task_id, "closed")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["coordination", "status", "--db", database_path, "--json"]
      )

      {:ok, %{stdout: Jason.encode!([coordination_payload]), stderr: "", exit_code: 0}}
    end)

    assert :ok = BootReconciliation.reconcile()

    assert_receive {@already_closed_event, ^ref, %{count: 1}, metadata}, 1_000
    assert metadata.project_id == project_id
    assert metadata.issue_id == task_id
    assert metadata.status == "closed"
    assert metadata.has_matching_run? == true
  end

  test "emits healthy when provider issue is not in progress and no Foreman run exists", %{
    temp_dir: temp_dir
  } do
    ref = attach_boot_events([@healthy_event])
    project_id = unique_id("project")
    task_id = unique_id("task")
    database_path = unique_database_path("healthy")

    seed_project!(project_id, project_task_provider(database_path))
    register_project!(project_id, database_path)

    coordination_payload = coordination_issue_payload(task_id, "open")

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["coordination", "status", "--db", database_path, "--json"]
      )

      {:ok, %{stdout: Jason.encode!([coordination_payload]), stderr: "", exit_code: 0}}
    end)

    assert :ok = BootReconciliation.reconcile()

    assert_receive {@healthy_event, ^ref, %{count: 1}, metadata}, 1_000
    assert metadata.project_id == project_id
    assert metadata.issue_id == task_id
    assert metadata.status == "open"
    assert metadata.has_matching_run? == false
  end

  test "second reconciliation does not reopen again after the issue becomes healthy", %{
    temp_dir: temp_dir
  } do
    ref = attach_boot_events([@orphan_reopen_event, @healthy_event])
    project_id = unique_id("project")
    task_id = unique_id("task")
    database_path = unique_database_path("rerun")

    seed_project!(project_id, project_task_provider(database_path))
    register_project!(project_id, database_path)

    reopened_payload = issue_details_payload(%{"id" => task_id, "status" => "open"})

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["coordination", "status", "--db", database_path, "--json"]
      )

      {:ok,
       %{
         stdout: Jason.encode!([coordination_issue_payload(task_id, "in_progress")]),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    task_id,
                    "--status",
                    "open",
                    "--transition-comment",
                    "foreman-run-reconciled"
                  ],
                  database_path: database_path
                }}

      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          database_path,
          task_id,
          "--status",
          "open",
          "--transition-comment",
          "foreman-run-reconciled",
          "--json"
        ]
      )

      {:ok, %{stdout: Jason.encode!(reopened_payload), stderr: "", exit_code: 0}}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:coordination_status, %{}}
      assert runner_project_config == %{database_path: database_path}
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["coordination", "status", "--db", database_path, "--json"]
      )

      {:ok,
       %{
         stdout: Jason.encode!([coordination_issue_payload(task_id, "open")]),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert :ok = BootReconciliation.reconcile()
    assert_receive {@orphan_reopen_event, ^ref, %{count: 1}, _metadata}, 1_000

    assert :ok = BootReconciliation.reconcile()
    assert_receive {@healthy_event, ^ref, %{count: 1}, healthy_metadata}, 1_000
    assert healthy_metadata.issue_id == task_id

    refute_receive {@orphan_reopen_event, ^ref, _, _}, 100
  end

  describe "task-run orphan scan" do
    test "dispatches task.run_terminated when in_progress task is bound to terminal run with no ack",
         %{temp_dir: _temp_dir} do
      task_id = unique_id("task")
      run_id = unique_id("run")

      seed_orphan_task!(task_id, run_id)

      assert :ok = BootReconciliation.scan_task_run_orphans()

      assert {:ok, _task} =
               wait_until(
                 fn ->
                   case ProjectionStore.task_projection(task_id) do
                     nil ->
                       :retry

                     task ->
                       if Map.get(task, :acknowledged_run_id) == run_id,
                         do: {:ok, task},
                         else: :retry
                   end
                 end,
                 "orphan scan to acknowledge terminal run",
                 1_000
               )
    end

    test "skips task whose status is closed", %{temp_dir: _temp_dir} do
      task_id = unique_id("task-closed")
      run_id = unique_id("run-closed")

      seed_terminal_status_task!(task_id, run_id, "closed")

      assert :ok = BootReconciliation.scan_task_run_orphans()

      Process.sleep(100)
      assert [] = Registry.lookup(ForemanServer.AggregateRegistry, "task:" <> task_id)
    end

    test "skips task whose status is failed", %{temp_dir: _temp_dir} do
      task_id = unique_id("task-failed")
      run_id = unique_id("run-failed")

      seed_terminal_status_task!(task_id, run_id, "failed")

      assert :ok = BootReconciliation.scan_task_run_orphans()

      Process.sleep(100)
      assert [] = Registry.lookup(ForemanServer.AggregateRegistry, "task:" <> task_id)
    end

    test "skips task whose run_id is already acknowledged", %{temp_dir: _temp_dir} do
      task_id = unique_id("task-acked")
      run_id = unique_id("run-acked")

      seed_acknowledged_task!(task_id, run_id)

      assert :ok = BootReconciliation.scan_task_run_orphans()

      Process.sleep(100)
      assert [] = Registry.lookup(ForemanServer.AggregateRegistry, "task:" <> task_id)
    end

    test "skips task when bound run is not terminal", %{temp_dir: _temp_dir} do
      task_id = unique_id("task-running")
      run_id = unique_id("run-running")

      seed_running_task!(task_id, run_id)

      assert :ok = BootReconciliation.scan_task_run_orphans()

      Process.sleep(100)
      assert [] = Registry.lookup(ForemanServer.AggregateRegistry, "task:" <> task_id)
    end
  end

  describe "boot scan API contracts" do
    test "scan_task_run_orphans/0 returns :ok and dispatches asynchronously",
         %{temp_dir: _temp_dir} do
      task_id = unique_id("task-cast")
      run_id = unique_id("run-cast")

      seed_orphan_task!(task_id, run_id)

      assert :ok = BootReconciliation.scan_task_run_orphans()

      assert {:ok, _pid} =
               wait_until_actor("task:" <> task_id, "cast to dispatch orphan", 1_000)
    end

    test "run_terminated/2 fans out via cast", %{temp_dir: _temp_dir} do
      task_id = unique_id("task-terminated")
      run_id = unique_id("run-terminated")

      seed_orphan_task!(task_id, run_id)

      assert :ok = BootReconciliation.run_terminated(run_id, "run_flagged_stuck")

      assert {:ok, _pid} =
               wait_until_actor("task:" <> task_id, "run_terminated to dispatch", 1_000)
    end
  end

  describe "boot scan startup deferral" do
    test "run_terminated/2 defers dispatch when CommandRouter is not registered", %{
      temp_dir: _temp_dir
    } do
      task_id = unique_id("task-defer")
      run_id = unique_id("run-defer")

      seed_in_progress_task!(task_id, run_id)

      app_sup = Process.whereis(ForemanServer.Application)
      assert is_pid(app_sup)

      :ok = Supervisor.terminate_child(app_sup, ForemanServer.CommandRouter)
      assert is_nil(Process.whereis(ForemanServer.CommandRouter))

      on_exit(fn ->
        case Process.whereis(ForemanServer.CommandRouter) do
          nil -> Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)
          _pid -> :ok
        end
      end)

      seed_terminal_run!(run_id)

      # Cast run_terminated directly to exercise the
      # handle_cast({:run_terminated, _, _}) -> schedule_scan(:not_ready)
      # path while the router is down.
      assert :ok = BootReconciliation.run_terminated(run_id, "run_flagged_stuck")

      Process.sleep(20)
      assert Map.get(ProjectionStore.task_projection(task_id), :acknowledged_run_id) == nil

      {:ok, _} = Supervisor.restart_child(app_sup, ForemanServer.CommandRouter)

      assert {:ok, _task} =
               wait_until(
                 fn ->
                   case ProjectionStore.task_projection(task_id) do
                     %{acknowledged_run_id: ^run_id} = task -> {:ok, task}
                     _ -> :retry
                   end
                 end,
                 "deferred scan to acknowledge terminal run",
                 2_000
               )
    end
  end

  describe "worktree-create orphan scan" do
    @orphan_preserved_event [:foreman_server, :vcs, :worktree, :orphan_preserved]

    setup %{temp_dir: temp_dir} do
      # Worktree.clean_orphan calls the real git worktree remove.
      repo_dir = Path.join(temp_dir, "wt-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo_dir)

      System.cmd("git", ["init", "--quiet", "--initial-branch=main", repo_dir])
      System.cmd("git", ["-C", repo_dir, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", repo_dir, "config", "user.name", "Test"])
      File.write!(Path.join(repo_dir, "README.md"), "hello")
      System.cmd("git", ["-C", repo_dir, "add", "README.md"])
      System.cmd("git", ["-C", repo_dir, "commit", "--quiet", "-m", "init"])

      worktree_path = Path.join(temp_dir, "wt-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(repo_dir) end)

      {:ok, repo_dir: repo_dir, worktree_path: worktree_path}
    end

    test "removes orphan entry and on-disk worktree when cleanup succeeds",
         %{repo_dir: repo_dir, worktree_path: worktree_path} do
      _ref = attach_boot_events([@orphan_preserved_event])
      run_id = unique_id("wt-run")
      phase_id = "phase"
      op_id = "wt-" <> run_id <> "-create-" <> phase_id

      {output, 0} = System.cmd("git", ["-C", repo_dir, "worktree", "add", worktree_path])
      assert output != ""

      seed_worktree_create_orphan!(op_id, run_id, phase_id, repo_dir, worktree_path)
      seed_terminal_run!(run_id)

      assert :ok = BootReconciliation.scan_worktree_create_orphans()

      assert {:ok, nil} =
               wait_until(
                 fn ->
                   case ProjectionStore.worktree_create_orphan(op_id) do
                     nil -> {:ok, nil}
                     _ -> :retry
                   end
                 end,
                 "worktree-create orphan entry removed for #{op_id}",
                 2_000
               )

      refute File.dir?(worktree_path),
             "expected cleanup to remove on-disk worktree #{worktree_path}"
    end

    test "emits :dirty orphan_preserved with worktree_path when worktree is dirty",
         %{repo_dir: repo_dir, worktree_path: worktree_path} do
      ref = attach_boot_events([@orphan_preserved_event])
      run_id = unique_id("wt-dirty")
      phase_id = "phase"
      op_id = "wt-" <> run_id <> "-create-" <> phase_id

      {output, 0} = System.cmd("git", ["-C", repo_dir, "worktree", "add", worktree_path])
      assert output != ""
      File.write!(Path.join(worktree_path, "staged.md"), "dirty")

      seed_worktree_create_orphan!(op_id, run_id, phase_id, repo_dir, worktree_path)
      seed_terminal_run!(run_id)

      assert :ok = BootReconciliation.scan_worktree_create_orphans()

      assert_receive {@orphan_preserved_event, ^ref, %{operation_id: ^op_id},
                      %{run_id: ^run_id, worktree_path: ^worktree_path, reason: :dirty}},
                     2_000

      assert %{operation_id: ^op_id} = ProjectionStore.worktree_create_orphan(op_id)
    end

    test "emits :resolve_dispatch_failed with worktree_path when resolve dispatch fails",
         %{repo_dir: repo_dir, worktree_path: worktree_path} do
      ref = attach_boot_events([@orphan_preserved_event])
      run_id = unique_id("wt-resolve-fail")
      phase_id = "phase"
      op_id = "wt-" <> run_id <> "-create-" <> phase_id

      {output, 0} = System.cmd("git", ["-C", repo_dir, "worktree", "add", worktree_path])
      assert output != ""

      seed_worktree_create_orphan!(op_id, run_id, phase_id, repo_dir, worktree_path)
      seed_terminal_run!(run_id)

      # Stub only the orphan_resolve dispatch (cleanup still flows through the
      # real VcsAdapter). The injected function returns `{:error, :test}`
      # so BootReconciliation takes the `:resolve_dispatch_failed` branch
      # while the on-disk worktree is still cleaned up. Process-local: no
      # global side-effects across async tests. Cleanup is in the test
      # process (not on_exit) because each test runs in its own process
      # and the key only lives in this test's dictionary.
      Process.put(:boot_reconciliation_orphan_resolve_dispatch, fn _ -> {:error, :test} end)

      try do
        assert :ok = BootReconciliation.scan_worktree_create_orphans()

        assert_receive {@orphan_preserved_event, ^ref, %{operation_id: ^op_id},
                        %{
                          run_id: ^run_id,
                          worktree_path: ^worktree_path,
                          reason: :resolve_dispatch_failed
                        }},
                       2_000

        assert %{operation_id: ^op_id} = ProjectionStore.worktree_create_orphan(op_id)
      after
        Process.delete(:boot_reconciliation_orphan_resolve_dispatch)
      end
    end
  end

  defp seed_worktree_create_orphan!(op_id, run_id, phase_id, repo_dir, worktree_path) do
    project_id = unique_id("wt-project")

    append_and_apply("vcs:" <> op_id, 0, "WorktreeCreateOrphanRecorded", %{
      operation_id: op_id,
      project_id: project_id,
      run_id: run_id,
      phase_id: phase_id,
      worktree_path: worktree_path,
      repo_path: repo_dir,
      reason: "create_dispatch_failed"
    })
  end

  defp seed_orphan_task!(task_id, run_id) do
    seed_in_progress_task!(task_id, run_id)
    seed_terminal_run!(run_id)
  end

  defp seed_terminal_status_task!(task_id, run_id, "closed") do
    seed_in_progress_task!(task_id, run_id)

    append_and_apply("task:" <> task_id, 3, "TaskExecutionCompleted", %{
      task_id: task_id,
      run_id: run_id
    })

    seed_terminal_run!(run_id)
  end

  defp seed_terminal_status_task!(task_id, run_id, "failed") do
    seed_in_progress_task!(task_id, run_id)

    append_and_apply("task:" <> task_id, 3, "TaskExecutionFailed", %{
      task_id: task_id,
      run_id: run_id,
      reason: "boom"
    })

    seed_terminal_run!(run_id)
  end

  defp seed_acknowledged_task!(task_id, run_id) do
    seed_in_progress_task!(task_id, run_id)

    append_and_apply(
      "task:" <> task_id,
      3,
      "TaskRunTerminated",
      %{
        task_id: task_id,
        run_id: run_id,
        reason: "run_cancelled",
        acknowledged_at: "2026-08-10T00:01:00Z"
      }
    )

    seed_terminal_run!(run_id)
  end

  defp seed_running_task!(task_id, run_id) do
    seed_in_progress_task!(task_id, run_id)
  end

  defp seed_in_progress_task!(task_id, run_id) do
    project_id = unique_id("project-orphan")

    append_and_apply("task:" <> task_id, 0, "TaskCreated", %{
      task_id: task_id,
      project_id: project_id,
      title: "orphan #{task_id}",
      status: "open",
      task_type: "implementation"
    })

    append_and_apply("task:" <> task_id, 1, "TaskApproved", %{
      task_id: task_id,
      approval_id: unique_id("approval"),
      approved_by: "alice",
      approved_at: "2026-08-10T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: %{run_id: run_id, phases: []}
    })

    append_and_apply("task:" <> task_id, 2, "TaskUpdated", %{
      task_id: task_id,
      status: "in_progress"
    })
  end

  defp seed_terminal_run!(run_id) do
    append_and_apply("run:" <> run_id, 0, "RunFlaggedStuck", %{
      run_id: run_id,
      project_id: unique_id("project-orphan"),
      flagged_at: 1_700_000_000_000
    })
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventStore.EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end

  defp wait_until_actor(aggregate_id, label, timeout_ms) do
    wait_until(
      fn ->
        case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
          [{pid, _}] -> {:ok, pid}
          [] -> :retry
        end
      end,
      label,
      timeout_ms
    )
  end

  defp attach_boot_events(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)

    on_exit(fn ->
      :telemetry.detach(ref)
    end)

    ref
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end

  defp wait_until(fun, label, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, label)
  end

  defp do_wait_until(fun, deadline, label) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_until(fun, deadline, label)
        else
          flunk("timed out waiting for #{label}")
        end

      other ->
        flunk("unexpected wait result for #{label}: #{inspect(other)}")
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-boot-reconciliation-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp unique_database_path(script_key) do
    path = Path.join(System.tmp_dir!(), "#{script_key}-#{System.unique_integer([:positive])}.db")
    File.touch!(path)
    path
  end

  defp project_task_provider(database_path) do
    %{
      provider: BeadsAdapter,
      config: %{"database_path" => database_path}
    }
  end

  defp project_database_path(task_provider) do
    get_in(task_provider, [:config, :database_path]) ||
      get_in(task_provider, [:config, "database_path"]) ||
      get_in(task_provider, ["config", :database_path]) ||
      get_in(task_provider, ["config", "database_path"])
  end

  defp fetch_map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch_map_value(_map, _key), do: nil

  defp coordination_issue_payload(task_id, status, overrides \\ %{}) do
    issue_details_payload(
      Map.merge(
        %{
          "id" => task_id,
          "title" => "Boot reconciliation #{task_id}",
          "status" => status,
          "priority" => 2,
          "dependencies" => [],
          "dependents" => [],
          "assignee" => nil,
          "description" => "coordination issue payload",
          "notes" => nil,
          "design" => nil,
          "labels" => ["workflow", status],
          "metadata" => %{"provider_id" => "beads"}
        },
        overrides
      )
    )
  end

  defp register_project!(project_id, database_path) do
    assert {:ok, project_config} =
             wait_until(
               fn ->
                 case :sys.get_state(TaskProviderRegistry).per_project[project_id] do
                   {:active,
                    %{
                      provider_module: BeadsAdapter,
                      config: %{"database_path" => ^database_path} = config
                    }} ->
                     {:ok, config}

                   _other ->
                     :retry
                 end
               end,
               "project provider registration for #{project_id}"
             )

    assert {:ok, BeadsAdapter} = TaskProviderRegistry.route(:reopen, {project_id, database_path})
    project_config
  end

  defp cleanup_boot_reconciliation_state do
    boot_project_ids =
      ProjectionStore.list_projects()
      |> Enum.map(&fetch_map_value(&1, :project_id))
      |> Enum.filter(&boot_reconciliation_id?/1)

    Enum.each(boot_project_ids, fn project_id ->
      _ = TaskProviderRegistry.unregister_for_project(project_id, :test_cleanup)
    end)

    :sys.replace_state(ProjectionStore, fn state ->
      %{
        state
        | projects:
            Map.reject(state.projects, fn {project_id, _project} ->
              boot_reconciliation_id?(project_id)
            end),
          runs:
            Map.reject(state.runs, fn {run_id, run} ->
              boot_reconciliation_id?(run_id) ||
                boot_reconciliation_id?(fetch_map_value(run, :project_id)) ||
                boot_reconciliation_id?(fetch_map_value(run, :task_id))
            end),
          tasks:
            Map.reject(state.tasks, fn {task_id, task} ->
              boot_reconciliation_id?(task_id) ||
                boot_reconciliation_id?(fetch_map_value(task, :project_id)) ||
                boot_reconciliation_id?(fetch_map_value(task, :run_id))
            end),
          phases:
            Map.reject(state.phases, fn {phase_id, phase} ->
              boot_reconciliation_id?(phase_id) ||
                boot_reconciliation_id?(fetch_map_value(phase, :run_id)) ||
                boot_reconciliation_id?(fetch_map_value(phase, :task_id))
            end),
          pr_associations:
            Map.reject(state.pr_associations, fn {run_id, association} ->
              boot_reconciliation_id?(run_id) ||
                boot_reconciliation_id?(fetch_map_value(association, :run_id))
            end),
          scheduler_intents:
            Map.reject(state.scheduler_intents, fn {intent_id, intent} ->
              boot_reconciliation_id?(intent_id) ||
                boot_reconciliation_id?(fetch_map_value(intent, :project_id)) ||
                boot_reconciliation_id?(fetch_map_value(intent, :run_id)) ||
                boot_reconciliation_id?(fetch_map_value(intent, :task_id))
            end)
      }
    end)
  end

  defp boot_reconciliation_id?(value) when is_binary(value) do
    String.contains?(value, "-boot-reconciliation-")
  end

  defp boot_reconciliation_id?(_value), do: false

  defp schema_document("ready-issue") do
    %{
      "type" => "object",
      "required" => [
        "id",
        "title",
        "status",
        "priority",
        "dependencies",
        "assignee",
        "description",
        "notes",
        "design",
        "labels",
        "metadata"
      ],
      "properties" => %{
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "priority" => %{"type" => "integer"},
        "dependencies" => %{"type" => "array"},
        "assignee" => %{"type" => ["string", "null"]},
        "description" => %{"type" => ["string", "null"]},
        "notes" => %{"type" => ["string", "null"]},
        "design" => %{"type" => ["string", "null"]},
        "labels" => %{"type" => "array"},
        "metadata" => %{"type" => "object"}
      }
    }
  end

  defp schema_document("issue-details") do
    required = issue_details_required_fields()
    properties = issue_details_properties()

    %{
      "$defs" => %{
        "issue" => %{
          "type" => "object",
          "required" => required,
          "properties" => properties
        }
      },
      "type" => "object",
      "required" => required,
      "properties" => properties
    }
  end

  defp schema_document("error") do
    %{
      "type" => "object",
      "required" => ["code", "message"],
      "properties" => %{
        "code" => %{"type" => "string"},
        "message" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("commands") do
    %{
      "type" => "object",
      "metadata" => %{"contractVersion" => "br.capabilities.v1"},
      "properties" => %{
        "commands" => %{"type" => "array"}
      }
    }
  end

  defp issue_details_required_fields do
    [
      "id",
      "title",
      "status",
      "priority",
      "dependencies",
      "dependents",
      "assignee",
      "description",
      "notes",
      "design",
      "labels",
      "metadata"
    ]
  end

  defp issue_details_properties do
    %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "priority" => %{"type" => "integer"},
      "dependencies" => %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/issue"}
      },
      "dependents" => %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/issue"}
      },
      "assignee" => %{"type" => ["string", "null"]},
      "description" => %{"type" => ["string", "null"]},
      "notes" => %{"type" => ["string", "null"]},
      "design" => %{"type" => ["string", "null"]},
      "labels" => %{"type" => "array"},
      "metadata" => %{"type" => "object"}
    }
  end

  defp issue_details_payload(overrides) do
    Map.merge(
      %{
        "id" => "bead-default",
        "title" => "Default issue",
        "status" => "open",
        "priority" => 1,
        "dependencies" => [],
        "dependents" => [],
        "assignee" => nil,
        "description" => nil,
        "notes" => nil,
        "design" => nil,
        "labels" => [],
        "metadata" => %{}
      },
      overrides
    )
  end

  defp seed_project!(project_id, task_provider) do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: project_id,
                   path: System.tmp_dir!(),
                   task_provider: task_provider
                 }
               }
             ])
  end

  defp seed_project_task_and_run!(project_id, task_id, run_id, workflow_snapshot, task_provider) do
    seed_project!(project_id, task_provider)
    register_project!(project_id, project_database_path(task_provider))

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: task_id,
                   project_id: project_id,
                   workflow_snapshot: workflow_snapshot
                 }
               }
             ])
  end

  defp assert_translated_argv(temp_dir, request, project_config, expected_argv) do
    with_fake_br(
      temp_dir,
      default_fake_br_body(),
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd(request, project_config)

        assert String.split(stdout, "\n", trim: true) == expected_argv
      end
    )
  end

  defp default_fake_br_body do
    """
    for arg in "$@"; do
      printf '%s\\n' "$arg"
    done
    """
  end

  defp write_fake_br!(temp_dir, body) do
    script_path = Path.join(temp_dir, "br")
    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)
  end

  defp with_fake_br(temp_dir, body, fun) do
    original_path = System.get_env("PATH") || ""
    write_fake_br!(temp_dir, body)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
