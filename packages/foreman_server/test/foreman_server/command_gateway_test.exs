defmodule ForemanServer.CommandGatewayTestHelper do
  def reset_projection_store do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
  end
end

defmodule ForemanServer.CommandGatewayTest.SuccessfulBrRunnerStub do
  @behaviour ForemanServer.TaskProviders.BrRunner

  @impl true
  def cmd(_request, _project_config, _opts) do
    bead_id = "br-stub-#{System.unique_integer([:positive])}"

    {:ok,
     %{
       stdout:
         Jason.encode!(%{
           "id" => bead_id,
           "title" => "stubbed",
           "status" => "open",
           "priority" => 2,
           "issue_type" => "task"
         }),
       stderr: "",
       exit_code: 0
     }}
  end
end

defmodule ForemanServer.CommandGatewayTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectStore, ProjectionStore}

  describe "envelope validation" do
    test "rejects command without command_id" do
      assert {:error, {:invalid_envelope, :missing_command_id}} =
               CommandGateway.dispatch_operator(%{
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects command without aggregate_id" do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects command without type" do
      assert {:error, {:invalid_envelope, :missing_type}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects non-allowed operator type" do
      assert {:error, {:command_not_allowed, "task.delete"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.delete",
                 payload: %{task_id: "abc"}
               })
    end
  end

  describe "aggregate_id contract" do
    test "project.register requires prefixed aggregate_id matching project_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "project.register",
                 payload: %{project_id: "abc", path: "/tmp/p"}
               })
    end

    test "task.create requires task:<id> aggregate_id matching task_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })
    end

    test "task.approve requires task:<id> aggregate_id matching task_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "abc", approved_by: "alice"}
               })
    end

    test "rejects numeric and non-binary entity IDs without crashing" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "project:123",
                 type: "project.register",
                 payload: %{project_id: 123, path: "/tmp/p"}
               })

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: ["nested"], project_id: "p1"}
               })

      # aggregate_id itself must be a binary - non-binary aggregate_id is
      # caught at the envelope-shape layer (missing_aggregate_id).
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: :not_a_string,
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.approve",
                 payload: %{task_id: nil, approved_by: "alice"}
               })
    end
  end

  describe "project lifecycle validation" do
    test "project.register rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "project:abc",
                 type: "project.register",
                 payload: %{path: "/tmp/p"}
               })
    end

    test "project.update rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-update-1",
                 aggregate_id: "project:abc",
                 type: "project.update",
                 payload: %{path: "/tmp/p"}
               })
    end

    test "project.archive rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-archive-1",
                 aggregate_id: "project:abc",
                 type: "project.archive",
                 payload: %{}
               })
    end
  end

  describe "task.create validation" do
    test "rejects missing project_id when task_id present" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end
  end

  describe "run.cancel validation" do
    test "rejects missing run_id" do
      assert {:error, {:invalid_envelope, :missing_run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:abc",
                 type: "run.cancel",
                 payload: %{}
               })
    end

    test "rejects empty run_id" do
      assert {:error, {:invalid_envelope, :missing_run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:abc",
                 type: "run.cancel",
                 payload: %{run_id: ""}
               })
    end

    test "rejects non-binary run_id" do
      assert {:error, {:invalid_envelope, :missing_run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:abc",
                 type: "run.cancel",
                 payload: %{run_id: 123}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:wrong",
                 type: "run.cancel",
                 payload: %{run_id: "abc"}
               })
    end

    test "rejects non-prefixed aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "run.cancel",
                 payload: %{run_id: "abc"}
               })
    end

    test "accepts well-formed run.cancel and surfaces aggregate-layer error" do
      # No run exists for this id, so dispatch will fail at the aggregate
      # layer with {:error, {:run_not_found, _}} or similar. The test
      # confirms envelope validation succeeds and the failure is NOT an
      # envelope error.
      result =
        CommandGateway.dispatch_operator(%{
          command_id: "cid-1",
          aggregate_id: "run:run-no-such",
          type: "run.cancel",
          payload: %{run_id: "run-no-such", reason: "test"}
        })

      refute match?({:error, {:invalid_envelope, _}}, result)
      refute match?({:error, {:command_not_allowed, _}}, result)
    end
  end

  describe "task.approve validation" do
    test "rejects missing task_id" do
      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.approve",
                 payload: %{}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects nonexistent task when payload is well-formed" do
      assert {:error, {:task_not_found, "missing-task"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:missing-task",
                 type: "task.approve",
                 payload: %{task_id: "missing-task"}
               })
    end
  end

  describe "task.create no-id flow (AC-020-NO-ID)" do
    import Mox
    alias ForemanServer.TaskProviders.BrRunnerMock
    alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry

    # Stub module: cmd/3 returns a synthetic bead for no-id tests.
    # Individual tests override cmd/3 via Mox.expect to capture bead_id.
    defmodule NoIdBrRunnerStub do
      @behaviour ForemanServer.TaskProviders.BrRunner
      @impl true
      def cmd(_request, _project_config, _opts) do
        {:ok,
         %{
           stdout:
             Jason.encode!(%{
               "id" => "stub-beader-#{:rand.uniform(99999)}",
               "title" => "stub",
               "status" => "open",
               "priority" => 2,
               "issue_type" => "task"
             }),
           stderr: "",
           exit_code: 0
         }}
      end
    end

    setup do
      # Isolate from background execution (same pattern as implementation context freezing tests)
      assert :ok =
               Supervisor.terminate_child(
                 ForemanServer.Application,
                 ForemanServer.Workflow.Dispatcher
               )

      on_exit(fn ->
        assert {:ok, _pid} =
                 Supervisor.restart_child(
                   ForemanServer.Application,
                   ForemanServer.Workflow.Dispatcher
                 )
      end)

      ForemanServer.CommandGatewayTestHelper.reset_projection_store()

      on_exit(fn ->
        ForemanServer.CommandGatewayTestHelper.reset_projection_store()
      end)

      # Register a project with a beads task provider
      project_id = unique_id("project")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   path: System.tmp_dir!(),
                   task_provider: %{
                     provider: :beads,
                     config: %{"database_path" => "/tmp/cg-noid-#{project_id}.db"}
                   }
                 }
               })

      :ok =
        TaskProviderRegistry.register_for_project(
          project_id,
          ForemanServer.TaskProviders.BeadsAdapter,
          %{"database_path" => "/tmp/cg-noid-#{project_id}.db"}
        )

      on_exit(fn ->
        _ = TaskProviderRegistry.unregister_for_project(project_id, :test_cleanup)
      end)

      # Install the no-id stub as default; individual tests override with expect
      stub_with(BrRunnerMock, __MODULE__.NoIdBrRunnerStub)

      %{project_id: project_id}
    end

    setup :verify_on_exit!

    test "no aggregate_id / no task_id resolves issue id via provider and enriches aggregate_id + payload",
         %{project_id: project_id} do
      bead_id = "bead-#{:rand.uniform(99999)}"

      expect(BrRunnerMock, :cmd, 1, fn
        {:create, %{title: title, priority: 2, type: "task"}}, _cfg, _opts
        when is_binary(title) ->
          send(self(), {:bead_id, bead_id})

          {:ok,
           %{
             stdout:
               Jason.encode!(%{
                 "id" => bead_id,
                 "title" => title,
                 "status" => "open",
                 "priority" => 2,
                 "issue_type" => "task"
               }),
             stderr: "",
             exit_code: 0
           }}
      end)

      assert {:ok, event_spec} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 # No aggregate_id → no-id branch in prepare_operator_command
                 type: "task.create",
                 payload: %{
                   project_id: project_id,
                   title: "no-id task",
                   # validate_create_attrs requires priority (0..4 int) and task_type
                   priority: 2,
                   task_type: "task"
                 }
               })

      # The aggregate_id is set to "task:<bead_id>" by prepare_operator_command
      assert event_spec["stream_id"] == "task:#{bead_id}"
      assert event_spec["payload"]["task_id"] == bead_id
      assert event_spec["payload"]["external_id"] == bead_id

      # Verify the mock was actually called (bead_id sent)
      assert_receive {:bead_id, ^bead_id}
    end

    test "client-supplied external_id is rejected in no-id branch",
         %{project_id: project_id} do
      assert {:error, :external_id_not_allowed_via_operator} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 type: "task.create",
                 payload: %{
                   project_id: project_id,
                   title: "no-id task",
                   external_id: "user-provided-id"
                 }
               })
    end

    test "client-supplied task_id is rejected in no-id branch",
         %{project_id: project_id} do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 type: "task.create",
                 payload: %{
                   project_id: project_id,
                   title: "no-id task",
                   task_id: "client-task-id"
                 }
               })
    end

    test "client-supplied task_id (string key) is rejected in no-id branch",
         %{project_id: project_id} do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 type: "task.create",
                 payload: %{
                   :project_id => project_id,
                   :title => "no-id task",
                   "task_id" => "client-task-id"
                 }
               })
    end
  end

  describe "task.approve implementation context freezing" do
    import Mox
    alias ForemanServer.TaskProviders.BrRunnerMock
    alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
    alias ForemanServer.Workflow.AssetCatalog
    alias ForemanServer.Workflow.Catalog

    setup do
      # Isolate the gateway from background execution: terminate the
      # Dispatcher child so `TaskApproved` projections don't trigger a
      # run that races `on_exit` fixture cleanup. Without this, the
      # supervisor of RunExecutor crashes with
      # "prompt file … is not tracked by the workflow catalog" between
      # tests. We restart the child in `on_exit` once fixture cleanup
      # has settled. ProjectionStore drops the broadcast on the floor
      # because there is no subscriber while the dispatcher is down.
      assert :ok =
               Supervisor.terminate_child(
                 ForemanServer.Application,
                 ForemanServer.Workflow.Dispatcher
               )

      on_exit(fn ->
        assert {:ok, _pid} =
                 Supervisor.restart_child(
                   ForemanServer.Application,
                   ForemanServer.Workflow.Dispatcher
                 )
      end)

      ForemanServer.CommandGatewayTestHelper.reset_projection_store()

      on_exit(fn ->
        ForemanServer.CommandGatewayTestHelper.reset_projection_store()
      end)

      # Set up a real git repo at a tmp path so ImplementationContext can
      # resolve HEAD, project_root, and a tracked TRD blob.
      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

      project_root =
        Path.join(System.tmp_dir!(), "cg-ic-test-#{suffix}-#{System.unique_integer([:positive])}")

      File.rm_rf!(project_root)
      File.mkdir_p!(Path.join([project_root, "docs", "TRD"]))
      File.write!(Path.join([project_root, "docs", "TRD", "x.md"]), "# TRD\nbody\n")
      File.mkdir_p!(Path.join(project_root, ".beads"))
      File.write!(Path.join([project_root, ".beads", "config.json"]), Jason.encode!(%{}))

      for {args, label} <- [
            {["init", "-q", "-b", "main"], "init"},
            {["config", "user.email", "test@example.com"], "email"},
            {["config", "user.name", "Test"], "name"},
            {["add", "."], "add"},
            {["commit", "-q", "-m", "init"], "commit"}
          ] do
        {_, 0} = System.cmd("git", ["-C", project_root | args], stderr_to_stdout: true)
      end

      on_exit(fn -> File.rm_rf!(project_root) end)

      # Set up a test-scoped Workflow.Catalog with the workflow types the
      # gateway's freeze_implementation_context/2 keys off of.
      workflow_root =
        Path.join(System.tmp_dir!(), "cg-ic-wf-#{suffix}-#{System.unique_integer([:positive])}")

      File.rm_rf!(workflow_root)
      File.mkdir_p!(Path.join(workflow_root, "prompts"))

      write_workflow = fn name, body ->
        File.write!(Path.join(workflow_root, "#{name}.yaml"), body)
      end

      write_workflow.("implement-trd", """
      name: implement-trd
      description: Implement against a frozen TRD document.
      phases:
        - name: only
          prompt: do.md
      """)

      write_workflow.("implement-trd-beads", """
      name: implement-trd-beads
      description: Implement against a frozen TRD document with a Beads task tree.
      phases:
        - name: only
          prompt: do.md
      """)

      write_workflow.("task", """
      name: task
      description: Generic non-worktree workflow.
      phases:
        - name: only
          prompt: do.md
      """)

      File.write!(Path.join([workflow_root, "prompts", "do.md"]), "do")

      prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
      Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

      prev_server = Application.get_env(:foreman_server, :workflow_catalog)
      server_name = :"cg_ic_catalog_#{suffix}"
      Application.put_env(:foreman_server, :workflow_catalog, server_name)

      catalog = AssetCatalog.new(workflow_root)
      start_supervised!({Catalog, name: server_name, catalog: catalog})
      :ok = Catalog.reload()

      on_exit(fn ->
        if prev_server,
          do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
          else: Application.delete_env(:foreman_server, :workflow_catalog)

        if prev_poll,
          do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll)

        File.rm_rf!(workflow_root)
      end)

      # Register the project at the git repo root with a task provider
      # pointing at the Beads database inside the repo.
      project_id = unique_id("project")
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   path: project_root,
                   task_provider: %{
                     provider: :beads,
                     config: %{"database_path" => "/tmp/cg-ic-#{suffix}.db"}
                   }
                 }
               })

      :ok =
        TaskProviderRegistry.register_for_project(
          project_id,
          ForemanServer.TaskProviders.BeadsAdapter,
          %{"database_path" => "/tmp/cg-ic-#{suffix}.db"}
        )

      on_exit(fn ->
        _ = TaskProviderRegistry.unregister_for_project(project_id, :test_cleanup)
      end)

      %{
        project_id: project_id,
        task_id: task_id,
        project_root: project_root,
        trd_path: "docs/TRD/x.md"
      }
    end

    setup :set_mox_global
    setup :verify_on_exit!

    setup do
      stub_with(BrRunnerMock, ForemanServer.CommandGatewayTest.SuccessfulBrRunnerStub)
      :ok
    end

    test "implement-trd task freezes workflow_snapshot.implementation with the five required fields",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
                 }
               })

      command_id = unique_id("approval")

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      # The advisory fix: the projected workflow_type wins over the
      # projected task_type so the right manifest is loaded.
      # TaskApproved deliberately omits top-level workflow_name; it lives
      # under workflow_snapshot.workflow_name in the serialized payload.

      assert payload["workflow_snapshot"]["workflow_name"] == "implement-trd"

      implementation = get_in(payload, ["workflow_snapshot", "implementation"])

      assert is_map(implementation)

      assert implementation["trd_path"] == trd_path
      assert implementation["trd_path_argument"] == Jason.encode!(trd_path)
      assert implementation["project_root"] != nil
      assert String.length(implementation["source_revision"]) in [40, 64]
      assert String.length(implementation["implementation_key"]) == 64
      # beads_database_path is omitted for the non-beads workflow.
      refute Map.has_key?(implementation, "beads_database_path")
    end

    test "implement-trd-beads task includes beads_database_path in the frozen implementation context",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd-beads",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      assert payload["workflow_snapshot"]["workflow_name"] == "implement-trd-beads"

      implementation = get_in(payload, ["workflow_snapshot", "implementation"])
      assert is_map(implementation)
      assert implementation["beads_database_path"] =~ "cg-ic-"
    end

    test "legacy task without workflow_type passes workflow_snapshot through unchanged",
         %{project_id: project_id, task_id: task_id} do
      # Use a generic task_type whose manifest does not require a
      # frozen implementation context.
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   priority: 2,
                   title: "legacy"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      assert payload["workflow_snapshot"]["workflow_name"] == "task"
      refute get_in(payload, ["workflow_snapshot", "implementation"])
    end

    test "idempotent re-approval preserves the previously frozen implementation context",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
                 }
               })

      command_id = unique_id("approval")

      assert {:ok, %{"payload" => first_payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      first_implementation = get_in(first_payload, ["workflow_snapshot", "implementation"])
      assert is_map(first_implementation)

      # Re-send with the same command_id. The duplicate-dispatch path
      # returns the stored `TaskApproved` event verbatim, so the rebuilt
      # payload MUST equal the original payload — including the frozen
      # implementation context. This guards the `recorded_event_to_event_spec`
      # contract against future serializers that skip key normalization.
      assert {:ok, %{"payload" => second_payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      second_implementation = get_in(second_payload, ["workflow_snapshot", "implementation"])
      assert second_implementation == first_implementation
      assert second_payload == first_payload
    end

    test "ImplementationContext.build failure propagates instead of being swallowed",
         %{project_id: project_id, task_id: task_id} do
      # trd_path escapes the project root via ../ so build/1 must fail.
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: "../escape.md",
                   priority: 2,
                   title: "implement"
                 }
               })

      assert {:error, {:implementation_context_failed, _}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })
    end

    test "implement-trd-beads task.create with a prompt and no trd_path cannot bypass ImplementationContext",
         %{project_id: project_id, task_id: task_id} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd-beads",
                   prompt: "do the beads thing",
                   provider_tracked: false,
                   priority: 2,
                   title: "ad-hoc beads task"
                 }
               })

      assert {:error, {:implementation_context_failed, _}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })
    end
  end

  describe "task.approve strict rendering of phases[*].command and worktree.base" do
    import Mox
    alias ForemanServer.TaskProviders.BrRunnerMock
    alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
    alias ForemanServer.Workflow.AssetCatalog
    alias ForemanServer.Workflow.Catalog

    setup do
      assert :ok =
               Supervisor.terminate_child(
                 ForemanServer.Application,
                 ForemanServer.Workflow.Dispatcher
               )

      on_exit(fn ->
        assert {:ok, _pid} =
                 Supervisor.restart_child(
                   ForemanServer.Application,
                   ForemanServer.Workflow.Dispatcher
                 )
      end)

      ForemanServer.CommandGatewayTestHelper.reset_projection_store()

      on_exit(fn ->
        ForemanServer.CommandGatewayTestHelper.reset_projection_store()
      end)

      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

      project_root =
        Path.join(System.tmp_dir!(), "cg-sr-test-#{suffix}-#{System.unique_integer([:positive])}")

      File.rm_rf!(project_root)
      File.mkdir_p!(Path.join([project_root, "docs", "TRD"]))
      File.write!(Path.join([project_root, "docs", "TRD", "x.md"]), "# TRD\nbody\n")
      File.mkdir_p!(Path.join(project_root, ".beads"))
      File.write!(Path.join([project_root, ".beads", "config.json"]), Jason.encode!(%{}))

      for {args, _label} <- [
            {["init", "-q", "-b", "main"], "init"},
            {["config", "user.email", "test@example.com"], "email"},
            {["config", "user.name", "Test"], "name"},
            {["add", "."], "add"},
            {["commit", "-q", "-m", "init"], "commit"}
          ] do
        {_, 0} = System.cmd("git", ["-C", project_root | args], stderr_to_stdout: true)
      end

      on_exit(fn -> File.rm_rf!(project_root) end)

      workflow_root =
        Path.join(System.tmp_dir!(), "cg-sr-wf-#{suffix}-#{System.unique_integer([:positive])}")

      File.rm_rf!(workflow_root)
      File.mkdir_p!(Path.join(workflow_root, "prompts"))

      write_workflow = fn name, body ->
        File.write!(Path.join(workflow_root, "#{name}.yaml"), body)
      end

      write_workflow.("implement-trd", """
      name: implement-trd
      description: Implement against a frozen TRD document.
      worktree:
        enabled: true
        base: "{{implementation.source_revision}}"
        branch: foreman/{task_id}
        cleanup: always
      phases:
        - name: implement-trd
          command: "/skill:ensemble-full-implement-trd {{implementation.trd_path_argument}} --foreman"
      """)

      prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
      Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

      prev_server = Application.get_env(:foreman_server, :workflow_catalog)
      server_name = :"cg_sr_catalog_#{suffix}"
      Application.put_env(:foreman_server, :workflow_catalog, server_name)

      catalog = AssetCatalog.new(workflow_root)
      start_supervised!({Catalog, name: server_name, catalog: catalog})
      :ok = Catalog.reload()

      on_exit(fn ->
        if prev_server,
          do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
          else: Application.delete_env(:foreman_server, :workflow_catalog)

        if prev_poll,
          do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll)

        File.rm_rf!(workflow_root)
      end)

      project_id = unique_id("project")
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   path: project_root,
                   task_provider: %{
                     provider: :beads,
                     config: %{"database_path" => "/tmp/cg-sr-#{suffix}.db"}
                   }
                 }
               })

      :ok =
        TaskProviderRegistry.register_for_project(
          project_id,
          ForemanServer.TaskProviders.BeadsAdapter,
          %{"database_path" => "/tmp/cg-sr-#{suffix}.db"}
        )

      on_exit(fn ->
        _ = TaskProviderRegistry.unregister_for_project(project_id, :test_cleanup)
      end)

      %{
        project_id: project_id,
        task_id: task_id,
        project_root: project_root,
        trd_path: "docs/TRD/x.md"
      }
    end

    setup :set_mox_global
    setup :verify_on_exit!

    setup do
      stub_with(BrRunnerMock, ForemanServer.CommandGatewayTest.SuccessfulBrRunnerStub)
      :ok
    end

    test "phases[*].command is materialized to the concrete skill invocation (no {trd_path_argument} placeholder)",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
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
      assert is_map(snapshot)

      phase = hd(snapshot["phases"])
      assert is_map(phase)

      expected_argument = Jason.encode!(trd_path)
      expected_command = "/skill:ensemble-full-implement-trd #{expected_argument} --foreman"

      # The rendered command value lives under the canonical string key
      # (the persisted/JSON-decoded form). The atom twin is removed so
      # JSON encoding cannot produce duplicate fields.
      assert phase["command"] == expected_command
      refute phase["command"] =~ "{trd_path_argument}"
      refute Map.has_key?(phase, :command)
    end

    test "worktree.base is materialized to the concrete source revision",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
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

      source_revision = get_in(snapshot, ["implementation", "source_revision"])
      assert is_binary(source_revision) and source_revision != ""

      # The worktree block is declared ONCE at workflow level, so its
      # rendered copy lives on the snapshot beside "phases". A
      # per-phase block was the previous, wrong shape: it implied one
      # clone per phase when a run has exactly one worktree.
      # Canonical string-keyed (persisted in TaskApproved payload).
      worktree = snapshot["worktree"]
      assert worktree["base"] == source_revision
      refute worktree["base"] =~ "{source_revision}"
      refute Map.has_key?(snapshot, :worktree)
      refute Map.has_key?(worktree, :base)

      # Regression guard: no phase may carry a worktree block.
      refute Map.has_key?(phase, "worktree")
      refute Map.has_key?(phase, :worktree)
    end

    test "worktree.branch retains runtime placeholders (rendered at execution time)",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
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
      worktree = snapshot["worktree"]
      refute Map.has_key?(hd(snapshot["phases"]), "worktree")

      assert worktree["branch"] == "foreman/{task_id}"
      # worktree.path is not declared in this manifest; RunExecutor
      # defaults the leaf to "workspace" at runtime, so it must not
      # appear in the approval-time snapshot. (Nor may Catalog or
      # Approval inject a default: they carry the block verbatim.)
      refute Map.has_key?(worktree, "path")
      refute Map.has_key?(worktree, :path)
    end

    test "rendered workflow_snapshot survives a JSON round-trip without regressing to placeholders",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
                 }
               })

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      # Round-trip the rendered snapshot through JSON, mirroring the
      # TaskApproved event persistence path. The persisted form is the
      # JSON-decoded projection, so this is the canonical input to
      # `RunExecutor.init/1`.
      snapshot = payload["workflow_snapshot"]
      encoded = Jason.encode!(snapshot)
      assert {:ok, decoded} = Jason.decode(encoded)

      # Encoding must produce a single entry per field. Duplicate JSON
      # keys would silently drop one value per encoder and trip a
      # regression on the renderer.
      assert Jason.decode!(encoded) == decoded

      [decoded_phase] = decoded["phases"]
      decoded_worktree = decoded["worktree"]
      refute Map.has_key?(decoded_phase, "worktree")

      expected_argument = Jason.encode!(trd_path)
      expected_command = "/skill:ensemble-full-implement-trd #{expected_argument} --foreman"

      assert decoded_phase["command"] == expected_command
      refute decoded_phase["command"] =~ "{trd_path_argument}"

      source_revision = get_in(decoded, ["implementation", "source_revision"])
      assert decoded_worktree["base"] == source_revision
      refute decoded_worktree["base"] =~ "{source_revision}"

      # Branch placeholders survive the round-trip so the execution-time
      # renderer can substitute them. `worktree.path` is not declared in
      # this manifest; RunExecutor defaults the leaf to "workspace".
      assert decoded_worktree["branch"] == "foreman/{task_id}"
      refute Map.has_key?(decoded_worktree, "path")
    end

    test "task.approve persists a rendered workflow_snapshot in the projection (not raw placeholders)",
         %{project_id: project_id, task_id: task_id, trd_path: trd_path} do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
                 }
               })

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("approval"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      # Persisted projection must mirror the rendered snapshot — not the
      # raw dotted templates. The TaskApproved event payload is the
      # authoritative input to ProjectionStore.apply_event_by_type/3
      # for "TaskApproved"; this test asserts the end-to-end contract
      # rather than just the dispatch return value.
      persisted = ProjectionStore.task_projection(task_id)
      assert is_map(persisted)

      # ProjectionStore stores atom-keyed maps. `workflow_snapshot` lives
      # under the atom key because the projection uses `Map.put/3` with
      # atom keys throughout `apply_event_by_type/3`.
      persisted_snapshot = persisted[:workflow_snapshot]
      assert is_map(persisted_snapshot)

      source_revision = get_in(persisted_snapshot, ["implementation", "source_revision"])
      assert is_binary(source_revision) and source_revision != ""

      [persisted_phase] = persisted_snapshot["phases"]
      persisted_worktree = persisted_snapshot["worktree"]

      # Regression guard: the worktree block lives on the snapshot, not
      # duplicated onto each phase.
      refute Map.has_key?(persisted_phase, "worktree")

      # command must be concrete — no {{implementation.*}} tokens, no
      # {trd_path_argument} tokens. The bundle uses dotted
      # double-brace form; this assertion covers both.
      refute persisted_phase["command"] =~ "{trd_path_argument}"
      refute persisted_phase["command"] =~ "{{implementation.trd_path_argument}}"

      assert persisted_phase["command"] ==
               "/skill:ensemble-full-implement-trd #{Jason.encode!(trd_path)} --foreman"

      # worktree.base must be the concrete source revision, not the
      # {{implementation.source_revision}} placeholder.
      refute persisted_worktree["base"] =~ "{source_revision}"
      refute persisted_worktree["base"] =~ "{{implementation.source_revision}}"
      assert persisted_worktree["base"] == source_revision

      # Branch keeps the runtime placeholder; path stays absent.
      assert persisted_worktree["branch"] == "foreman/{task_id}"
      refute Map.has_key?(persisted_worktree, "path")
    end

    test "rendered phase command and workflow worktree.base retain approval-time SHA after HEAD movement",
         %{
           project_id: project_id,
           task_id: task_id,
           project_root: project_root,
           trd_path: trd_path
         } do
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "task",
                   workflow_type: "implement-trd",
                   trd_path: trd_path,
                   priority: 2,
                   title: "implement"
                 }
               })

      command_id = unique_id("approval")

      assert {:ok, %{"payload" => first_payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      first_implementation = get_in(first_payload, ["workflow_snapshot", "implementation"])
      sha1 = first_implementation["source_revision"]
      assert is_binary(sha1) and String.length(sha1) in [40, 64]

      [first_phase] = first_payload["workflow_snapshot"]["phases"]
      first_worktree = first_payload["workflow_snapshot"]["worktree"]
      expected_argument = Jason.encode!(trd_path)
      expected_command = "/skill:ensemble-full-implement-trd #{expected_argument} --foreman"

      assert first_phase["command"] == expected_command
      refute first_phase["command"] =~ "{trd_path_argument}"
      refute Map.has_key?(first_phase, "worktree")
      assert first_worktree["base"] == sha1
      refute first_worktree["base"] =~ "{source_revision}"

      # Advance HEAD with a fresh commit so a naive re-render would
      # pick up a new SHA. The freeze semantic only holds if downstream
      # rendering reads from the persisted snapshot, not from HEAD.
      File.write!(Path.join([project_root, "docs", "TRD", "extra.md"]), "# extra\n")

      {_, 0} =
        System.cmd("git", ["-C", project_root, "add", "."], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "git",
          ["-C", project_root, "commit", "-q", "-m", "advance"],
          stderr_to_stdout: true
        )

      # Replay the original approval command_id. The duplicate-dispatch
      # path returns the stored TaskApproved verbatim, so the rebuilt
      # rendered phase MUST retain the approval-time SHA and trd_path.
      assert {:ok, %{"payload" => second_payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "operator-1"}
               })

      [second_phase] = second_payload["workflow_snapshot"]["phases"]
      second_worktree = second_payload["workflow_snapshot"]["worktree"]
      assert second_phase["command"] == expected_command
      refute second_phase["command"] =~ "{trd_path_argument}"
      refute Map.has_key?(second_phase, "worktree")
      assert second_worktree["base"] == sha1
      refute second_worktree["base"] =~ "{source_revision}"
      assert second_payload == first_payload
    end
  end

  describe "render_strict_fields / input block (TRD-019)" do
    # Convenience to call the private render_strict_fields/1
    defp render_strict_fields(snapshot) do
      apply(ForemanServer.CommandGateway, :render_strict_fields, [snapshot])
    end

    # Convenience to call the private render_command/3
    defp render_command(phase, impl, input) do
      apply(ForemanServer.CommandGateway, :render_command, [phase, impl, input])
    end

    test "returns snapshot unchanged when neither implementation nor input block exists" do
      snapshot = %{"phases" => [%{"command" => "echo hello"}]}

      result = render_strict_fields(snapshot)

      assert result == snapshot
      assert result["phases"] == [%{"command" => "echo hello"}]
    end

    test "returns snapshot unchanged when implementation block is empty map" do
      snapshot = %{"implementation" => %{}, "phases" => [%{"command" => "echo hello"}]}

      result = render_strict_fields(snapshot)

      assert result == snapshot
    end

    test "returns snapshot unchanged when input block is empty map" do
      snapshot = %{"input" => %{}, "phases" => [%{"command" => "echo hello"}]}

      result = render_strict_fields(snapshot)

      assert result == snapshot
    end

    test "fires and renders phases when input block is present (no implementation)" do
      snapshot = %{
        "input" => %{"prompt" => "Write tests", "prompt_argument" => "--spec test"},
        "phases" => [
          %{"command" => "run {{input.prompt}} {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      assert result["phases"] == [
               %{"command" => "run Write tests --spec test"}
             ]
    end

    test "fires and renders phases when implementation block is present" do
      snapshot = %{
        "implementation" => %{
          "trd_path_argument" => "docs/TRD/x.md",
          "source_revision" => "abc123"
        },
        "phases" => [
          %{"command" => "/skill:ensemble {{implementation.trd_path_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      assert result["phases"] == [
               %{"command" => "/skill:ensemble docs/TRD/x.md"}
             ]
    end

    test "render_command substitutes {{input.prompt}}" do
      phase = %{"command" => "prompt: '{{input.prompt}}'"}

      result = render_command(phase, nil, %{"prompt" => "Hello World"})

      assert result["command"] == "prompt: 'Hello World'"
    end

    test "render_command substitutes {{input.prompt_argument}}" do
      phase = %{"command" => "arg={{input.prompt_argument}}"}

      result = render_command(phase, nil, %{"prompt_argument" => "--verbose"})

      assert result["command"] == "arg=--verbose"
    end

    test "render_command preserves newlines in substituted {{input.prompt}}" do
      phase = %{"command" => "code:\n{{input.prompt}}\nend"}

      result = render_command(phase, nil, %{"prompt" => "line1\nline2\nline3"})

      assert result["command"] == "code:\nline1\nline2\nline3\nend"
    end

    test "render_command leaves command unchanged when input block is nil" do
      phase = %{"command" => "prompt: '{{input.prompt}}'"}

      result = render_command(phase, nil, nil)

      assert result["command"] == "prompt: '{{input.prompt}}'"
    end

    test "render_command leaves command unchanged when implementation block is nil" do
      phase = %{"command" => "skill: {{implementation.trd_path_argument}}"}

      result = render_command(phase, nil, nil)

      assert result["command"] == "skill: {{implementation.trd_path_argument}}"
    end

    test "render_command substitutes both implementation and input tokens independently" do
      phase = %{"command" => "{{implementation.trd_path_argument}} --prompt '{{input.prompt}}'"}

      result =
        render_command(phase, %{"trd_path_argument" => "docs/TRD/y.md"}, %{"prompt" => "do it"})

      assert result["command"] == "docs/TRD/y.md --prompt 'do it'"
    end

    test "render_command does not substitute missing input tokens (leaves placeholder)" do
      phase = %{"command" => "{{input.prompt}}"}

      result = render_command(phase, nil, %{})

      assert result["command"] == "{{input.prompt}}"
    end

    # TRD-020: input.prompt_argument is built as Jason.encode!(input.prompt)
    test "render_strict_fields derives input.prompt_argument via Jason.encode! (simple string)" do
      snapshot = %{
        "input" => %{"prompt" => "hello"},
        "phases" => [
          %{"command" => "run {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      assert result["phases"] == [
               %{"command" => "run \"hello\""}
             ]
    end

    test "render_strict_fields derives input.prompt_argument via Jason.encode! (special chars)" do
      snapshot = %{
        "input" => %{"prompt" => "multi\nline"},
        "phases" => [
          %{"command" => "run {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      # Jason.encode!("multi\nline") => "\"multi\\nline\""
      assert result["phases"] == [
               %{"command" => "run \"multi\\nline\""}
             ]
    end

    test "render_strict_fields derives input.prompt_argument via Jason.encode! (empty string)" do
      snapshot = %{
        "input" => %{"prompt" => ""},
        "phases" => [
          %{"command" => "run {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      # Jason.encode!("") => "\"\""  (a JSON string containing empty string)
      assert result["phases"] == [
               %{"command" => "run \"\""}
             ]
    end

    test "render_strict_fields preserves explicit input.prompt_argument (TRD-019 override)" do
      # When prompt_argument is already present it must NOT be overwritten
      snapshot = %{
        "input" => %{"prompt" => "hello", "prompt_argument" => "--spec test"},
        "phases" => [
          %{"command" => "run {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      assert result["phases"] == [
               %{"command" => "run --spec test"}
             ]
    end

    test "render_command substitutes pre-built input.prompt_argument in command template" do
      # When prompt_argument is pre-built (as Jason.encode!(prompt)) it substitutes directly
      input = %{"prompt" => "hello", "prompt_argument" => Jason.encode!("hello")}
      phase = %{"command" => "arg={{input.prompt_argument}}"}

      result = render_command(phase, nil, input)

      assert result["command"] == "arg=\"hello\""
    end

    # AC-008-2: a token in neither allow-list survives intact
    test "render_command leaves unknown tokens intact (allow-list enforcement)" do
      phase = %{
        "command" =>
          "/skill:foo --prompt '{{input.prompt}}' --unknown '{{unknown.token}}' --impl '{{implementation.trd_path_argument}}'"
      }

      result =
        render_command(phase, %{"trd_path_argument" => "docs/x.md"}, %{"prompt" => "hello"})

      # Known tokens substituted
      assert result["command"] =~ "hello"
      assert result["command"] =~ "docs/x.md"
      # Unknown token survives verbatim
      assert result["command"] =~ "{{unknown.token}}"
    end

    test "render_strict_fields renders input-only snapshot with input.prompt_argument substitution" do
      # TRD-019-TEST: phase with {{input.prompt_argument}} is frozen already-expanded
      snapshot = %{
        "input" => %{"prompt" => "hello world"},
        "phases" => [
          %{"command" => "/skill:foo {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      # prompt_argument is Jason.encode!("hello world") => "\"hello world\""
      assert result["phases"] == [
               %{"command" => "/skill:foo \"hello world\""}
             ]
    end

    # AC-008-4: a prompt containing shell metacharacters yields exactly one additional argv word
    test "render_strict_fields prompt_argument treats shell metacharacters as data (exactly one argv word)" do
      # The prompt_argument is JSON-encoded, so the shell sees it as a single quoted string.
      # "echo $HOME" -> "\"echo $HOME\"" which is ONE additional argv word when split.
      snapshot = %{
        "input" => %{"prompt" => "echo $HOME"},
        "phases" => [
          %{"command" => "run {{input.prompt_argument}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      # The rendered command has the JSON-encoded prompt as a single unit
      assert result["phases"] == [
               %{"command" => "run \"echo $HOME\""}
             ]

      # Verify the entire prompt-with-metacharacters is preserved as one unit
      rendered = result["phases"] |> hd() |> Map.get("command")
      assert rendered =~ ~s("echo $HOME)
    end

    # AC-008-3: plan.yaml-shaped snapshot with input block and no implementation is now rendered
    test "plan.yaml with input block (no implementation) is rendered, not passed through (TRD-019-TEST)" do
      # This is the core TRD-019 fix: before TRD-019, this would pass through unchanged
      # because render_strict_fields early-returned when impl was nil/empty.
      # After TRD-019, it renders when input is present.
      snapshot = %{
        "name" => "plan",
        "input" => %{"prompt" => "Write the spec", "prompt_argument" => "\"Write the spec\""},
        "phases" => [
          %{"command" => "/skill:ensemble {{input.prompt_argument}}"},
          %{"command" => "/skill:verify {{input.prompt}}"}
        ]
      }

      result = render_strict_fields(snapshot)

      # Before TRD-019: phases would be unchanged (pass-through)
      # After TRD-019: phases are rendered
      refute result["phases"] == snapshot["phases"],
             "snapshot with input block should be rendered, not passed through"

      assert result["phases"] == [
               %{"command" => "/skill:ensemble \"Write the spec\""},
               %{"command" => "/skill:verify Write the spec"}
             ]
    end
  end

  describe "task.retry validation" do
    setup do
      ForemanServer.CommandGatewayTestHelper.reset_projection_store()

      on_exit(fn ->
        ForemanServer.CommandGatewayTestHelper.reset_projection_store()
      end)

      :ok
    end

    test "rejects missing task_id" do
      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.retry",
                 payload: %{}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.retry",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects nonexistent task" do
      assert {:error, {:task_not_found, "missing-task"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:missing-task",
                 type: "task.retry",
                 payload: %{task_id: "missing-task"}
               })
    end

    test "rejects when task has no bound run" do
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-orphan",
                     project_id: "project-x",
                     title: "orphan",
                     status: "open",
                     task_type: "plan"
                   }
                 }
               ])

      assert {:error, {:missing_or_invalid, :run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-orphan",
                 type: "task.retry",
                 payload: %{task_id: "task-orphan"}
               })
    end

    test "rejects nonterminal bound run (active spoof)" do
      # Operator sends task.retry, but the bound run is still awaiting_worker.
      # Gateway MUST refuse to enrich — a client cannot synthesize
      # acknowledgement by hand.
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "run-active",
                     task_id: "task-active",
                     project_id: "project-x",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-active",
                     project_id: "project-x",
                     title: "active",
                     status: "in_progress",
                     task_type: "plan"
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-active",
                     run_id: "run-active",
                     approval_id: "approval-active",
                     approved_by: "alice",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "TaskDispatched",
                   payload: %{
                     task_id: "task-active",
                     run_id: "run-active",
                     approval_id: "approval-active"
                   }
                 }
               ])

      assert {:error, {:run_not_terminal, "awaiting_worker"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-active",
                 type: "task.retry",
                 payload: %{task_id: "task-active"}
               })
    end

    test "rejects when run projection is missing despite task binding" do
      # Task says run-bound, but the run projection never landed (or
      # has been deleted). Gateway MUST refuse rather than enrich
      # against a stale or absent run.
      # We simulate by registering the run, then wiping the run map.
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "run-ghost",
                     task_id: "task-ghost",
                     project_id: "project-x",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-ghost",
                     project_id: "project-x",
                     title: "ghost",
                     status: "open",
                     task_type: "plan"
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-ghost",
                     run_id: "run-ghost",
                     approval_id: "approval-ghost",
                     approved_by: "alice",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: %{}
                   }
                 }
               ])

      # Wipe the run projection but keep the task's run_id binding.
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{state | runs: Map.delete(state.runs, "run-ghost")}
      end)

      assert {:error, {:run_not_found, "run-ghost"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-ghost",
                 type: "task.retry",
                 payload: %{task_id: "task-ghost"}
               })
    end

    test "rejects when run.task_id drifts from the task being retried" do
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "run-drift",
                     task_id: "task-other",
                     project_id: "project-x",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "RunFlaggedStuck",
                   payload: %{
                     run_id: "run-drift",
                     task_id: "task-other",
                     project_id: "project-x",
                     flagged_at: "2026-08-10T00:00:00Z"
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-claimed",
                     project_id: "project-x",
                     title: "claimed",
                     status: "open",
                     task_type: "plan"
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-claimed",
                     run_id: "run-drift",
                     approval_id: "approval-drift",
                     approved_by: "alice",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: %{}
                   }
                 }
               ])

      assert {:error, {:run_task_binding_drift, "run-drift", "task-other", "task-claimed"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-claimed",
                 type: "task.retry",
                 payload: %{task_id: "task-claimed"}
               })
    end
  end

  describe "dispatch_system" do
    test "bypasses operator whitelist (does not enforce allowed types)" do
      # dispatch_system routes through CommandRouter.dispatch/1 directly.
      # We send project.archive (NOT in the operator whitelist) against a
      # non-existent project. The test confirms dispatch_system does NOT
      # short-circuit with {:error, :command_not_allowed, _} - the
      # Aggregate handles the rejection itself with
      # {:error, :project_not_found}.
      result =
        CommandGateway.dispatch_system(%{
          command_id: "cid-1",
          aggregate_id: "project:does-not-exist",
          type: "project.archive",
          payload: %{project_id: "does-not-exist"}
        })

      assert match?({:error, _}, result)
      refute match?({:error, {:command_not_allowed, _}}, result)
    end
  end

  describe "project lifecycle telemetry" do
    test "dispatch_operator emits project.register telemetry" do
      project_id = unique_id("project")
      handler_id = attach_telemetry(self(), [[:foreman_server, :project, :register]])

      try do
        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   command_id: unique_id("command"),
                   aggregate_id: "project:#{project_id}",
                   type: "project.register",
                   payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
                 })

        assert_receive {
          :telemetry_event,
          [:foreman_server, :project, :register],
          %{duration_ms: duration_ms},
          %{project_id: ^project_id, outcome: :ok}
        }

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "dispatch_operator emits project.update telemetry" do
      project_id = unique_id("project")

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })

      handler_id = attach_telemetry(self(), [[:foreman_server, :project, :update]])

      try do
        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   command_id: unique_id("command"),
                   aggregate_id: "project:#{project_id}",
                   type: "project.update",
                   payload: %{project_id: project_id, path: "/tmp/#{project_id}/updated"}
                 })

        assert_receive {
          :telemetry_event,
          [:foreman_server, :project, :update],
          %{duration_ms: duration_ms},
          %{project_id: ^project_id, outcome: :ok}
        }

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "dispatch_operator emits project.archive telemetry with code and retryable on active-run conflict" do
      project_id = unique_id("project")
      run_id = unique_id("run")

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: unique_id("reserve"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.reserve_run",
                 payload: %{
                   project_id: project_id,
                   run_id: run_id,
                   command_id: unique_id("run-start"),
                   sequence: 1,
                   run_start_payload: %{
                     project_id: project_id,
                     run_id: run_id,
                     task_id: unique_id("task"),
                     workflow_snapshot: %{}
                   }
                 }
               })

      handler_id = attach_telemetry(self(), [[:foreman_server, :project, :archive]])

      try do
        assert {:error, :project_has_active_runs, [^run_id]} =
                 CommandGateway.dispatch_operator(%{
                   command_id: unique_id("command"),
                   aggregate_id: "project:#{project_id}",
                   type: "project.archive",
                   payload: %{project_id: project_id}
                 })

        assert_receive {
          :telemetry_event,
          [:foreman_server, :project, :archive],
          %{duration_ms: duration_ms},
          %{
            project_id: ^project_id,
            outcome: :error,
            code: "project_has_active_runs",
            retryable: false
          }
        }

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "external_id boundary invariant (AC-020-7)" do
    setup do
      project_id = unique_id("project")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
               })

      %{project_id: project_id}
    end

    test "dispatch_operator task.create with external_id: nil is accepted", %{
      project_id: project_id
    } do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "implement",
                   title: "boundary test",
                   external_id: nil
                 }
               })
    end

    test "dispatch_operator task.create with non-nil external_id is rejected before Actor", %{
      project_id: project_id
    } do
      task_id = unique_id("task")

      assert {:error, :external_id_not_allowed_via_operator} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "implement",
                   title: "boundary test",
                   external_id: "foreman-abc"
                 }
               })

      assert ProjectionStore.task_projection(task_id) == nil
    end

    test "dispatch_system task.create with non-nil external_id is accepted (watcher path)", %{
      project_id: project_id
    } do
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "implement",
                   title: "watcher import",
                   external_id: "foreman-abc"
                 }
               })
    end

  end
  describe "task.create auto_approve" do
    setup do
      project_id = unique_id("project")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
               })

      %{project_id: project_id}
    end

    test "dispatches task.approve automatically and returns its result", %{
      project_id: project_id
    } do
      task_id = unique_id("task")

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "implement",
                   title: "auto approve test",
                   prompt: "echo hello",
                   provider_tracked: false,
                   auto_approve: true
                 }
               })

      assert payload["task_id"] == task_id
      assert is_binary(payload["approval_id"])
      assert is_binary(payload["run_id"])

      task = ProjectionStore.task_projection(task_id)
      assert task.status == "ready"
      assert task.provider_tracked == false
      assert task.prompt == "echo hello"
    end

    test "a retried task.create does not mint a second approval", %{project_id: project_id} do
      task_id = unique_id("task")
      command_id = unique_id("command")

      payload = %{
        task_id: task_id,
        project_id: project_id,
        task_type: "implement",
        title: "auto approve retry test",
        prompt: "echo hello",
        provider_tracked: false,
        auto_approve: true
      }

      assert {:ok, %{"payload" => first_payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: payload
               })

      assert {:ok, %{"payload" => second_payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: command_id,
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: payload
               })

      assert first_payload["approval_id"] == second_payload["approval_id"]
      assert first_payload["run_id"] == second_payload["run_id"]
    end

    test "does not auto-approve when auto_approve is absent", %{project_id: project_id} do
      task_id = unique_id("task")

      assert {:ok, %{"payload" => payload}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   task_type: "implement",
                   title: "no auto approve"
                 }
               })

      assert payload["task_id"] == task_id
      refute Map.has_key?(payload, "approval_id")

      task = ProjectionStore.task_projection(task_id)
      assert task.status == "open"
    end
  end

  defp attach_telemetry(test_pid, events) do
    handler_id = "command-gateway-telemetry-#{unique_id("handler")}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
