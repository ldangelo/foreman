defmodule ForemanServer.Workflow.TaskStateTransitionsTest do
  @moduledoc """
  End-to-end test for TaskProvider state transitions (TRD-016-TEST).

  Validates that RunExecutor correctly sequences the three TaskProvider lifecycle
  callbacks through their corresponding state transitions:

  1. claim/3 → bead status transitions to "in_progress"
  2. complete/3 → bead status transitions to "closed"
  3. fail/3 → bead status transitions to "blocked" with reason

  Tests PRD ACs: AC-005-1 (run start triggers claim), AC-005-2 (run success triggers complete)

  Dependencies: TRD-016 (verify call site wiring), TRD-015 (transient retry logic)
  """

  use ExUnit.Case, async: false

  import Mox
  import ExUnit.CaptureLog

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.Workflow.RunExecutor
  alias ForemanServer.CommandGateway

  @moduletag timeout: 60_000

  @claim_event [:foreman_server, :task_provider, :beads_adapter, :claim, :success]
  @complete_event [:foreman_server, :task_provider, :beads_adapter, :complete, :success]
  @fail_event [:foreman_server, :task_provider, :beads_adapter, :fail, :success]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "task_state_transitions_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      System.put_env("PATH", original_path)
      stop_schema_cache()
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  # Helpers

  defp start_schema_cache! do
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)
  end

  defp expect_schema_boot_fetches do
    expect(BrRunnerMock, :cmd, 4, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      {:ok, %{stdout: Jason.encode!(schema_document(schema_name))}}
    end)
  end

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
    %{
      "type" => "object",
      "required" => ["id", "description"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      }
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

  defp stop_schema_cache do
    case GenServer.whereis(JsonSchemaCache) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp register_project!(project_id, database_path) do
    project_config = %{"database_path" => database_path}

    assert :ok = Registry.register_for_project(project_id, BeadsAdapter, project_config)

    # `RunExecutor.claim/4`, `complete/4`, and `fail/4` resolve their
    # provider through a real project projection (`resolve_provider/3`
    # reads `ProjectionStore.project_projection/1`), not through
    # `TaskProvider.Registry` — a project must also be seeded via the
    # `project.register` system command for those calls to succeed.
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "TaskStateTransitions #{project_id}",
      path: System.tmp_dir!(),
      task_provider: %{provider: "beads", config: %{"database_path" => database_path}}
    })

    project_config
  end

  defp dispatch_system!(type, aggregate_id, payload) do
    command_id = "#{type}:#{aggregate_id}:#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: command_id,
               aggregate_id: aggregate_id,
               type: type,
               payload: payload
             })
  end

  defp issue_with_status(status) do
    %Issue{
      id: "bead-transitions",
      title: "Task state transitions test",
      description: "Testing claim → in_progress, complete → closed, fail → blocked",
      status: status,
      priority: 2,
      dependencies: [],
      assignee: nil,
      notes: nil,
      design: nil,
      labels: ["test"],
      metadata: %{}
    }
  end

  # Tests

  describe "task state transitions" do
    test "claim/3 transitions bead status to 'in_progress'", %{temp_dir: temp_dir} do
      start_schema_cache!()

      cached_database_path = "/abs/transitions/claim.db"
      _project_config = register_project!("proj-claim-test", cached_database_path)
      payload = issue_with_status("in_progress")

      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        # Verify claim transitions to in_progress
        assert request == {:update, %{flags: ["--claim", "bead-transitions"]}}

        assert project_config == %{
                 "database_path" => cached_database_path,
                 run_id: "run-test-claim"
               }

        assert opts == [timeout_ms: 30_000]

        {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
      end)

      # Invoke claim/3 and verify it returns the issue with in_progress status
      assert {:ok, issue} =
               RunExecutor.claim(
                 "proj-claim-test",
                 "bead-transitions",
                 "foreman-runner",
                 "run-test-claim"
               )

      assert issue.status == "in_progress"
    end

    test "complete/3 transitions bead status to 'closed'", %{temp_dir: temp_dir} do
      start_schema_cache!()

      cached_database_path = "/abs/transitions/complete.db"
      _project_config = register_project!("proj-complete-test", cached_database_path)
      payload = issue_with_status("closed")

      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        # Verify complete transitions to closed
        assert request == {:close, %{id: "bead-transitions"}}

        assert project_config == %{database_path: cached_database_path}
        assert opts == [timeout_ms: 30_000]

        {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
      end)

      # Invoke complete/3 and verify it returns the issue with closed status
      assert {:ok, issue} =
               RunExecutor.complete(
                 "proj-complete-test",
                 "bead-transitions",
                 "run-test-complete",
                 nil
               )

      assert issue.status == "closed"
    end

    test "fail/3 transitions bead status to 'blocked' with failure reason", %{
      temp_dir: temp_dir
    } do
      start_schema_cache!()

      ref = :telemetry_test.attach_event_handlers(self(), [@fail_event])
      on_exit(fn -> :telemetry.detach(ref) end)

      cached_database_path = "/abs/transitions/fail.db"
      _project_config = register_project!("proj-fail-test", cached_database_path)

      payload = issue_with_status("blocked")

      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        # Verify fail transitions to blocked
        assert request ==
                 {:update,
                  %{
                    flags: [
                      "bead-transitions",
                      "--status",
                      "blocked",
                      "--transition-comment",
                      "foreman-run:run-test-fail:"
                    ],
                    database_path: cached_database_path
                  }}

        assert project_config == %{database_path: cached_database_path}
        assert opts == [timeout_ms: 30_000]

        {:ok, %{stdout: Jason.encode!(payload), stderr: "", exit_code: 0}}
      end)

      # Invoke fail/3 with a failure reason and verify it returns the issue with blocked status
      failure_reason = %{
        "cause" => "run failed",
        "error_code" => 1,
        "terminal" => true
      }

      assert {:ok, issue} =
               RunExecutor.fail(
                 "proj-fail-test",
                 "bead-transitions",
                 "run-test-fail",
                 failure_reason
               )

      assert issue.status == "blocked"

      # Verify telemetry event was emitted
      assert_receive {@fail_event, ^ref, _measurements, _metadata}
    end

    test "full lifecycle: claim → complete → closed sequence", %{temp_dir: temp_dir} do
      start_schema_cache!()

      cached_database_path = "/abs/transitions/lifecycle.db"
      _project_config = register_project!("proj-lifecycle-test", cached_database_path)

      # Expect claim call
      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        assert request == {:update, %{flags: ["--claim", "bead-transitions"]}}

        {:ok,
         %{stdout: Jason.encode!(issue_with_status("in_progress")), stderr: "", exit_code: 0}}
      end)

      # Execute claim
      assert {:ok, claim_issue} =
               RunExecutor.claim(
                 "proj-lifecycle-test",
                 "bead-transitions",
                 "foreman-runner",
                 "run-lifecycle"
               )

      assert claim_issue.status == "in_progress"

      # Expect complete call
      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        assert request == {:close, %{id: "bead-transitions"}}

        {:ok, %{stdout: Jason.encode!(issue_with_status("closed")), stderr: "", exit_code: 0}}
      end)

      # Execute complete
      assert {:ok, complete_issue} =
               RunExecutor.complete(
                 "proj-lifecycle-test",
                 "bead-transitions",
                 "run-lifecycle",
                 nil
               )

      assert complete_issue.status == "closed"
    end

    test "terminal failure path: claim → fail → blocked sequence", %{temp_dir: temp_dir} do
      start_schema_cache!()

      ref = :telemetry_test.attach_event_handlers(self(), [@fail_event])
      on_exit(fn -> :telemetry.detach(ref) end)

      cached_database_path = "/abs/transitions/terminal_fail.db"
      _project_config = register_project!("proj-terminal-fail-test", cached_database_path)

      # Expect claim call
      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        assert request == {:update, %{flags: ["--claim", "bead-transitions"]}}

        {:ok,
         %{stdout: Jason.encode!(issue_with_status("in_progress")), stderr: "", exit_code: 0}}
      end)

      # Execute claim
      assert {:ok, claim_issue} =
               RunExecutor.claim(
                 "proj-terminal-fail-test",
                 "bead-transitions",
                 "foreman-runner",
                 "run-terminal-fail"
               )

      assert claim_issue.status == "in_progress"

      # Expect fail call (terminal failure)
      expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
        assert request ==
                 {:update,
                  %{
                    flags: [
                      "bead-transitions",
                      "--status",
                      "blocked",
                      "--transition-comment",
                      "foreman-run:run-terminal-fail:"
                    ],
                    database_path: cached_database_path
                  }}

        {:ok, %{stdout: Jason.encode!(issue_with_status("blocked")), stderr: "", exit_code: 0}}
      end)

      # Execute fail (terminal failure)
      failure_reason = %{"cause" => "deployment failed", "error_code" => 1}

      assert {:ok, fail_issue} =
               RunExecutor.fail(
                 "proj-terminal-fail-test",
                 "bead-transitions",
                 "run-terminal-fail",
                 failure_reason
               )

      assert fail_issue.status == "blocked"
      assert_receive {@fail_event, ^ref, _measurements, _metadata}
    end
  end
end
