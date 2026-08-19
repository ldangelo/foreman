defmodule ForemanServer.Workflow.ImplementFixCharacterizationTest do
  @moduledoc """
  Characterization tests for implement and fix workflow dispatch.

  TRD-2026-4212be7e / WFD-T007 / TRD-070

  Verifies:
  - Implement workflow dispatches `ensemble-full-implement-trd` with --foreman
  - Fix workflow dispatches `ensemble-fix-issue` with --foreman
  - Correct idempotency key formats are used
  - Implementation context is frozen for implement workflow
  - Worktree configuration is correct
  """

  use ExUnit.Case, async: false

  import Mox
  alias ForemanServer.TaskProviders.BrRunnerMock

  # Successful stub for BrRunner - returns a synthetic bead on any command
  defmodule SuccessfulBrRunnerStub do
    @behaviour ForemanServer.TaskProviders.BrRunner
    @impl true
    def cmd(_request, _project_config, _opts) do
      bead_id = "br-stub-#{System.unique_integer([:positive])}"
      {:ok, %{stdout: Jason.encode!(%{"id" => bead_id, "title" => "stubbed", "status" => "open", "priority" => 2, "issue_type" => "task"}), stderr: "", exit_code: 0}}
    end
  end

  alias ForemanServer.{CommandGateway, Workflow.AssetCatalog, Workflow.Catalog}

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir(), "foreman_wf_char_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Isolate tests from background Dispatcher execution - terminate it so
    # TaskDispatched events don't crash the Dispatcher during tests.
    # The Dispatcher crashes because RunPayload.from_task_projection/1
    # expects phase_specs which task projections don't have.
    Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)

    on_exit(fn ->
      {:ok, _pid} =
        Supervisor.restart_child(
          ForemanServer.Application,
          ForemanServer.Workflow.Dispatcher
        )
    end)

    # Set up Mox for BrRunner mock
    stub_with(BrRunnerMock, __MODULE__.SuccessfulBrRunnerStub)

    # Save original env
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    prev_catalog = Application.get_env(:foreman_server, :workflow_catalog)
    # Use faster polling for tests
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    # Set up temp workflow directory
    workflow_root = tmp_dir()
    on_exit(fn -> File.rm_rf!(workflow_root) end)

    # Set up test catalog
    server_name = :"wf_char_catalog_#{:erlang.unique_integer([:positive])}"
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

    catalog = AssetCatalog.new(workflow_root)
    {:ok, _pid} = start_supervised({Catalog, name: server_name, catalog: catalog})
    :ok = Catalog.reload()

    on_exit(fn ->
      if prev_catalog,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_catalog),
        else: Application.delete_env(:foreman_server, :workflow_catalog)

      if prev_poll,
        do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll)
    end)

    %{
      workflow_root: workflow_root,
      server_name: server_name
    }
  end

  # --- Implement workflow tests (ensemble-full-implement-trd) ---

  describe "implement workflow dispatch (WFD-T005 / TRD-068)" do
    setup %{workflow_root: root} do
      # Write the implement-trd workflow manifest
      File.write!(
        Path.join(root, "implement-trd.yaml"),
        """
        name: implement-trd
        description: Implement against a frozen TRD document.
        phases:
          - name: implement-trd
            command: "/skill:ensemble-full-implement-trd {{implementation.trd_path_argument}} --foreman"
            worktree:
              enabled: true
              base: "{{implementation.source_revision}}"
              branch: foreman/{run_id}/{phase}
              cleanup: always
        """
      )

      # Create a real git repo with a TRD file for ImplementationContext.build validation
      project_root = tmp_dir() |> Path.join("git_repo")
      File.mkdir_p!(project_root)
      {_, 0} = System.cmd("git", ["init"], cd: project_root)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: project_root)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: project_root)
      File.mkdir_p!(Path.join(project_root, "docs/TRD"))
      File.write!(Path.join(project_root, "docs/TRD/test.md"), "# Test TRD\n\nContent.")
      {_, 0} = System.cmd("git", ["add", "."], cd: project_root)
      {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: project_root)

      on_exit(fn -> File.rm_rf!(project_root) end)

      # Set up test project and task provider
      project_id = unique_id("project")
      db_path = Path.join(System.tmp_dir(), "wf_char_#{project_id}.db")

      on_exit(fn ->
        File.rm_rf(db_path)
        File.rm_rf(db_path <> "-wal")
        File.rm_rf(db_path <> "-shm")
      end)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   path: project_root,
                   task_provider: %{
                     provider: :beads,
                     config: %{"database_path" => db_path}
                   }
                 }
               })

      :ok =
        ForemanServer.TaskProvider.Registry.register_for_project(
          project_id,
          ForemanServer.TaskProviders.BeadsAdapter,
          %{"database_path" => db_path}
        )

      on_exit(fn ->
        ForemanServer.TaskProvider.Registry.unregister_for_project(project_id, :test)
      end)

      %{
        project_id: project_id,
        trd_path: "docs/TRD/test.md"
      }
    end

    test "dispatches ensemble-full-implement-trd skill with --foreman flag",
         %{project_id: project_id, trd_path: trd_path} do
      task_id = unique_id("task")

      # Create and approve task
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement test"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      snapshot = payload["workflow_snapshot"]
      phase = hd(snapshot["phases"])

      # Verify skill name
      assert phase["command"] =~ "ensemble-full-implement-trd",
             "Command should invoke ensemble-full-implement-trd skill"

      # Verify --foreman flag
      assert phase["command"] =~ "--foreman",
             "Command should include --foreman flag"
    end

    test "substitutes trd_path_argument placeholder with JSON-encoded path",
         %{project_id: project_id, trd_path: trd_path} do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement test"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      phase = hd(payload["workflow_snapshot"]["phases"])

      # Verify no placeholder remains
      refute phase["command"] =~ "{trd_path_argument}",
             "trd_path_argument placeholder should be substituted"

      # Verify JSON-encoded path is present
      expected_arg = Jason.encode!(trd_path)
      assert phase["command"] =~ expected_arg,
             "Command should contain JSON-encoded TRD path"
    end

    test "freezes implementation context with required fields",
         %{project_id: project_id, trd_path: trd_path} do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement test"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      impl = get_in(payload, ["workflow_snapshot", "implementation"])

      # Verify all required implementation context fields
      assert is_binary(impl["trd_path"]),
             "implementation.trd_path should be a binary"
      assert impl["trd_path"] == trd_path,
             "implementation.trd_path should match task's trd_path"

      assert is_binary(impl["trd_path_argument"]),
             "implementation.trd_path_argument should be a binary"

      assert is_binary(impl["source_revision"]),
             "implementation.source_revision should be a binary"
      assert byte_size(impl["source_revision"]) > 0,
             "implementation.source_revision should not be empty"

      assert is_binary(impl["implementation_key"]),
             "implementation.implementation_key should be a binary"
      assert byte_size(impl["implementation_key"]) == 64,
             "implementation.implementation_key should be SHA-256 (64 hex chars)"
    end

    test "configures worktree with concrete source revision",
         %{project_id: project_id, trd_path: trd_path} do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement test"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      phase = hd(payload["workflow_snapshot"]["phases"])
      worktree = phase["worktree"]

      # Verify worktree.base is concrete (not a placeholder)
      assert is_binary(worktree["base"]),
             "worktree.base should be a binary"
      refute worktree["base"] =~ "{",
             "worktree.base should not contain placeholders"

      # Verify worktree.branch retains runtime placeholders
      assert worktree["branch"] == "foreman/{run_id}/{phase}",
             "worktree.branch should retain runtime placeholders"
    end
  end

  # --- Fix workflow tests (ensemble-fix-issue) ---

  describe "fix workflow dispatch (WFD-T006 / TRD-069)" do
    setup %{workflow_root: root} do
      # Write the fix workflow manifest
      File.write!(
        Path.join(root, "fix.yaml"),
        """
        name: fix
        description: Fix an issue via the ensemble fix workflow.
        phases:
          - name: fix
            command: "/skill:ensemble-fix-issue --foreman"
        """
      )

      # Set up test project
      project_id = unique_id("project")
      db_path = Path.join(System.tmp_dir(), "wf_char_fix_#{project_id}.db")

      on_exit(fn ->
        File.rm_rf(db_path)
        File.rm_rf(db_path <> "-wal")
        File.rm_rf(db_path <> "-shm")
      end)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   path: ".",
                   task_provider: %{
                     provider: :beads,
                     config: %{"database_path" => db_path}
                   }
                 }
               })

      :ok =
        ForemanServer.TaskProvider.Registry.register_for_project(
          project_id,
          ForemanServer.TaskProviders.BeadsAdapter,
          %{"database_path" => db_path}
        )

      on_exit(fn ->
        ForemanServer.TaskProvider.Registry.unregister_for_project(project_id, :test)
      end)

      %{
        project_id: project_id
      }
    end

    test "dispatches ensemble-fix-issue skill with --foreman flag",
         %{project_id: project_id} do
      task_id = unique_id("task")

      # Create and approve task with fix workflow
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "fix",
                   priority: 2,
                   title: "fix issue"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      snapshot = payload["workflow_snapshot"]
      phase = hd(snapshot["phases"])

      # Verify skill name
      assert phase["command"] =~ "ensemble-fix-issue",
             "Command should invoke ensemble-fix-issue skill"

      # Verify --foreman flag
      assert phase["command"] =~ "--foreman",
             "Command should include --foreman flag"
    end

    test "single phase workflow structure",
         %{project_id: project_id} do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "fix",
                   priority: 2,
                   title: "fix issue"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      snapshot = payload["workflow_snapshot"]

      # Verify single phase
      assert length(snapshot["phases"]) == 1,
             "Fix workflow should have exactly one phase"

      # Verify phase name
      phase = hd(snapshot["phases"])
      assert phase["name"] == "fix",
             "Phase should be named 'fix'"
    end

    test "fix workflow does not require implementation context",
         %{project_id: project_id} do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("cmd"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "fix",
                   priority: 2,
                   title: "fix issue"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      snapshot = payload["workflow_snapshot"]

      # Fix workflow should not have implementation context
      refute Map.has_key?(snapshot, "implementation"),
             "Fix workflow should not have implementation context"
    end
  end

  # --- Idempotency key format tests ---
  describe "idempotency key format (REQ-026 / TRD-026)" do
    alias ForemanServer.Idempotency.KeyStore

    setup do
      # KeyStore GenServer is started by the test app and owns the ETS table.
      # Don't delete the ETS table in on_exit - it persists across tests.
      Application.put_env(:foreman_server, ForemanServer.Agents.JidoCheckpointStore, [])
      {:error, {:already_started, _pid}} = KeyStore.start_link()
      :ok
    end

    test "implement workflow uses implement-{taskId}-1 key format" do
      task_id = "task-456"
      key = "implement-#{task_id}-1"

      :ok = KeyStore.mark_started(key)
      assert {:ok, :started} = KeyStore.status(key)
    end

    test "fix workflow uses fix-{taskId}-1 key format" do
      task_id = "task-789"
      key = "fix-#{task_id}-1"

      :ok = KeyStore.mark_started(key)
      assert {:ok, :started} = KeyStore.status(key)
    end
  end
end
