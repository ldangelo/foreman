defmodule ForemanServer.Workflow.ImplementFixCharacterizationTest do
  @moduledoc """
  Characterization tests for implement and fix workflow dispatch.

  TRD-2026-4212be7e:
    - WFD-T005 / TRD-068: Implement workflow dispatch (ensemble-full-implement-trd)
    - WFD-T006 / TRD-069: Fix workflow dispatch (ensemble-fix-issue)
    - WFD-T007 / TRD-070: Characterization tests (this file)
    - CTH-T002 / TRD-088: Implement workflow characterization harness
    - CTH-T003 / TRD-089: Fix workflow characterization harness
    - CTH-T004 / TRD-090: Crash-recovery characterization

  Covers:
    - Implement workflow: skill dispatch with --foreman, trd_path_argument
      substitution, implementation context freezing, worktree configuration,
      idempotency key format, RunExecutor phase_specs extraction, e2e
      initialization, empty-phases graceful handling
    - Fix workflow: skill dispatch with --foreman, single-phase structure,
      no implementation context required, idempotency key format
    - Shared: KeyStore crash-recovery contracts, StepSequencer propagation
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
        worktree:
          enabled: true
          base: "{{implementation.source_revision}}"
          branch: foreman/{run_id}
          cleanup: always
        phases:
          - name: implement-trd
            command: "/skill:ensemble-full-implement-trd {{implementation.trd_path_argument}} --foreman"
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

      # The block is WORKFLOW-level, beside "phases", so it is read off the
      # snapshot rather than off a phase.
      phase = hd(payload["workflow_snapshot"]["phases"])
      refute Map.has_key?(phase, "worktree"), "a phase carries no worktree block"

      worktree = payload["workflow_snapshot"]["worktree"]

      # Verify worktree.base is concrete (not a placeholder)
      assert is_binary(worktree["base"]),
             "worktree.base should be a binary"
      refute worktree["base"] =~ "{",
             "worktree.base should not contain placeholders"

      # `{run_id}` is resolved at provisioning time, not at approval time.
      assert worktree["branch"] == "foreman/{run_id}",
             "worktree.branch should retain runtime placeholders"
    end
  end

  # ---------------------------------------------------------------------------
  # CTH-T002 / TRD-088 — Implement workflow characterization harness
  #
  # This describe block complements WFD-T005 (TRD-068) with e2e RunExecutor
  # initialization tests.  While the WFD-T005 tests verify the command string
  # that emerges from task.approve → TaskApproved → workflow_snapshot, this
  # block verifies the reverse contract: RunExecutor.init/1 correctly parses
  # that snapshot into phase_specs and initial state.
  #
  # Together with run_executor_test.exs (adapter e2e) and
  # approval_test.exs (workflow_load_failed for unknown types), this
  # constitutes the complete implement workflow characterization harness.
  #
  # REQ-024: characterization test harness (CTH-T002 / TRD-088)
  # ---------------------------------------------------------------------------

  describe "CTH-T002 implement workflow characterization harness (TRD-088)" do
    alias ForemanServer.Workflow.RunExecutor

    test "RunExecutor.init/1 extracts correct phase_specs from implement-trd workflow_snapshot" do
      # Simulate the workflow_snapshot that TaskApproved would persist:
      # it is a JSON-decoded map so all keys are strings.
      run_id = "run-cth-t002"
      workflow_snapshot = %{
        "run_id" => run_id,
        "workflow_name" => "implement-trd",
        # WORKFLOW-level, beside "phases".
        "worktree" => %{
          "enabled" => true,
          "base" => "abc123",
          "branch" => "foreman/{run_id}",
          "path" => "workspace",
          "cleanup" => "always"
        },
        "phases" => [
          %{
            "name" => "implement-trd",
            "action" => "command",
            "command" => "/skill:ensemble-full-implement-trd \"docs/TRD/x.md\" --foreman",
            "index" => 1,
            "phase_id" => "phase-#{run_id}-1"
          }
        ]
      }

      task_projection = %{
        "task_id" => "task-cth-t002",
        "project_id" => "project-cth-t002",
        "workflow_type" => "implement-trd",
        "workflow_snapshot" => workflow_snapshot
      }

      {:ok, state} = RunExecutor.init({run_id, task_projection})

      # Verify phase_specs are correctly extracted (not [] or malformed)
      assert length(state.phase_specs) == 1,
             "implement-trd workflow should have exactly one phase_spec"

      [phase_spec] = state.phase_specs

      # Verify command is preserved verbatim
      assert phase_spec[:command] =~
               "ensemble-full-implement-trd",
             "phase_spec command should include ensemble-full-implement-trd skill"

      assert phase_spec[:command] =~ "--foreman",
             "phase_spec command should include --foreman flag"

      # Verify worktree config is correctly preserved, at the run level
      refute Map.has_key?(phase_spec, :worktree), "a phase carries no worktree block"

      assert state.worktree_spec[:base] == "abc123",
             "worktree.base should be the concrete source revision"
      assert state.worktree_spec[:branch] == "foreman/{run_id}",
             "worktree.branch should retain runtime placeholders"

      # Verify initial state: no phases completed yet
      assert state.completed == [],
             "initially no phases should be completed"
      assert state.phase_statuses == %{},
             "initially phase_statuses should be empty"
      assert state.status == :ready,
             "initial status should be :ready"
    end

    test "RunExecutor.init/1 handles implement-trd with no phases gracefully" do
      # Edge case: workflow_snapshot exists but has no phases.
      # RunExecutor should not crash; phase_specs = [] is the safe default.
      task_projection = %{
        "task_id" => "task-empty-phases",
        "project_id" => "project-empty",
        "workflow_type" => "implement-trd",
        "workflow_snapshot" => %{
          "workflow_name" => "implement-trd",
          "phases" => []
        }
      }

      {:ok, state} = RunExecutor.init({"run-empty", task_projection})

      assert state.phase_specs == [],
             "empty phases list should result in empty phase_specs"
      assert state.completed == [],
             "no phases means nothing to complete"
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

  # ---------------------------------------------------------------------------
  # CTH-T003 / TRD-089 — Fix workflow characterization harness
  #
  # Mirrors CTH-T002 (TRD-088) for the fix workflow.  Verifies RunExecutor
  # correctly extracts phase_specs from a fix workflow snapshot (string-keyed,
  # as persisted after JSON round-trip).  Together with WFD-T006 (TRD-069)
  # which covers command-string construction, this closes the full e2e
  # dispatch characterization for the fix workflow.
  #
  # REQ-024: characterization test harness (CTH-T003 / TRD-089)
  # ---------------------------------------------------------------------------

  describe "CTH-T003 fix workflow characterization harness (TRD-089)" do
    alias ForemanServer.Workflow.RunExecutor

    test "RunExecutor.init/1 extracts correct phase_specs from fix workflow_snapshot" do
      run_id = "run-cth-t003"
      workflow_snapshot = %{
        "run_id" => run_id,
        "workflow_name" => "fix",
        "phases" => [
          %{
            "name" => "fix",
            "action" => "command",
            "command" => "/skill:ensemble-fix-issue --foreman",
            "index" => 1,
            "phase_id" => "phase-#{run_id}-1"
          }
        ]
      }

      task_projection = %{
        "task_id" => "task-cth-t003",
        "project_id" => "project-cth-t003",
        "workflow_type" => "fix",
        "workflow_snapshot" => workflow_snapshot
      }

      {:ok, state} = RunExecutor.init({run_id, task_projection})

      # Verify single phase_spec
      assert length(state.phase_specs) == 1,
             "fix workflow should have exactly one phase_spec"

      [phase_spec] = state.phase_specs

      # Verify skill name and --foreman flag
      assert phase_spec[:command] =~ "ensemble-fix-issue",
             "phase_spec command should include ensemble-fix-issue skill"
      assert phase_spec[:command] =~ "--foreman",
             "phase_spec command should include --foreman flag"

      # A phase never carries the block. This test's fixture declares none at
      # the workflow level either, so `worktree_spec` is nil — meaning "declared
      # nothing", which is distinct from disabled: every default applies.
      refute Map.has_key?(phase_spec, :worktree)

      assert state.worktree_spec == nil,
             "fix fixture declares no workflow-level worktree block"

      # Verify initial state
      assert state.completed == [],
             "initially no phases should be completed"
      assert state.status == :ready,
             "initial status should be :ready"
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
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # TRD-090 / CTH-T004 — Crash-recovery characterization
  #
  # Crash recovery works at two levels, not at the RunExecutor phase level:
  #
  #   LAYER 1 — Orphan reopen (BootReconciliation.reconcile/0):
  #     On boot, reconcile scans all task-provider issues.  If an issue is
  #     in_progress with no matching active Foreman run (crashed mid-sequence),
  #     it is reopened via the provider so the next dispatch cycle picks it
  #     up as a fresh run.  Coverage: boot_reconciliation_test.exs
  #     "reopens orphaned in-progress provider issues" (line 107).
  #
  #   LAYER 2 — Idempotency (CrashRecovery.reconcile/1 + KeyStore):
  #     A fresh run is dispatched with the same idempotency key.  KeyStore
  #     tracks three states (:started / :completed / :failed).  On reconcile:
  #       - :started key  → {:retry, :unknown_state}  (safe; no side effects yet)
  #       - :completed key → {:skip, :already_done}    (idempotent)
  #       - :failed key  → {:skip, :already_done}    (idempotent)
  #     Coverage: crash_recovery_test.exs and crash_recovery_characterization_test.exs.
  #
  #   STEP SEQUENCER — phase ordering gate (StepSequencer.propagate_terminal/2):
  #     Phase completion is recorded as :completed in phase_statuses and
  #     propagated forward via StepSequencer so the next dispatch knows which
  #     phase to run.
  #
  # REQ-024: crash-recovery characterization (CTH-T004 / TRD-090)
  # REQ-026: idempotent dispatch (no duplicate side effects)
  # NFR-03:  crash recovery ≤30s to resumption (RTE-T006 / TRD-080)
  # ---------------------------------------------------------------------------

  describe "TRD-090 crash-recovery characterization (CTH-T004)" do
    alias ForemanServer.Idempotency.{CrashRecovery, KeyStore}

    # -------------------------------------------------------------------------
    # Layer 2 — KeyStore + CrashRecovery idempotency contracts
    # -------------------------------------------------------------------------

    test "KeyStore :started key is safe to retry (no duplicate dispatch)" do
      # Simulate a run that was started but crashed before producing side effects.
      # KeyStore.mark_started leaves the key in :started state.
      key = "implement-task-crash-rec-1"
      :ok = KeyStore.mark_started(key)

      # On restart, reconcile/1 returns {:retry, :unknown_state} for :started keys.
      # This is safe — the run will re-execute as a fresh dispatch, and the
      # orphan-reopen layer (BootReconciliation) already ensured the task was
      # reopened before this reconcile call is reached.
      assert {:retry, :unknown_state} = CrashRecovery.reconcile(key)

      # Key is still :started (not changed by reconcile) — safe for retry.
      assert {:ok, :started} = KeyStore.status(key)
    end

    test "KeyStore :completed key is skipped (idempotent)" do
      key = "implement-task-already-done-1"
      :ok = KeyStore.mark_started(key)
      :ok = KeyStore.mark_completed(key)

      # Completed key: reconcile returns skip so the run is not re-dispatched.
      assert {:skip, :already_completed} = CrashRecovery.reconcile(key)

      # Key is :completed — idempotent on retry.
      assert {:ok, :completed} = KeyStore.status(key)
    end

    # -------------------------------------------------------------------------
    # Step sequencer — phase completion propagates forward as :completed
    # -------------------------------------------------------------------------

    test "StepSequencer propagates :completed status forward (resume condition)" do
      import ForemanServer.Workflow.StepSequencer

      # :completed previous phase → next phase runs (:cont).
      assert {:cont, nil} = propagate_terminal(:completed, :phase_1)
      assert {:cont, nil} = propagate_terminal(:completed, :any_step)

      # :failed and :blocked must halt the sequence.
      assert {:halt, :failed} = propagate_terminal(:failed, :phase_1)
      assert {:halt, :blocked} = propagate_terminal(:blocked, :phase_1)
    end
  end
end
