defmodule ForemanServer.Workflow.RunExecutorGatesTest do
  # The `build/1` cases below seed the process-wide ProjectionStore —
  # `PlanContext` resolves the project projection through it and offers no
  # injection seam — so this file cannot run beside the projection-resetting
  # suites.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.PlanContext

  @run_id "run-bad71b752c776f855fbcaeb8fe571bb6"
  @approved_at "2026-08-27T17:18:46.413454Z"

  describe "PlanContext.build/1 discrimination" do
    test "non-plan workflow returns {:not_applicable, %{}}" do
      assert PlanContext.build(%{task_type: "implement"}) == {:not_applicable, %{}}
      assert PlanContext.build(%{"type" => "ticket"}) == {:not_applicable, %{}}
      assert PlanContext.build(%{}) == {:not_applicable, %{}}

      assert PlanContext.build(%{task_type: "feature", workflow_type: "implement-trd"}) ==
               {:not_applicable, %{}}
    end

    test "legacy plan issue type still routes to the planning path" do
      assert {:error, {:project_not_found, "tf-1"}} =
               PlanContext.build(%{task_type: "plan", project_id: "tf-1", run_id: "run-abcdef"})
    end

    test "the work.submit snapshot's workflow key routes to the planning path" do
      assert {:error, {:project_not_found, "tf-2"}} =
               PlanContext.build(%{
                 task_type: "feature",
                 workflow_snapshot: %{workflow: "plan"},
                 project_id: "tf-2",
                 run_id: "run-abcdef"
               })
    end
  end

  describe "PlanContext.build/1 against a registered project" do
    setup do
      project_id = "plan-ctx-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects[project_id], %{
          project_id: project_id,
          path: System.tmp_dir!(),
          status: "active"
        })
      end)

      on_exit(fn ->
        :sys.replace_state(ProjectionStore, fn state ->
          %{state | projects: Map.delete(state.projects, project_id)}
        end)
      end)

      %{project_id: project_id}
    end

    # Regression for run-bad71b752c776f855fbcaeb8fe571bb6: the task was
    # registered with task_type "feature" — Beads rejects "plan" with
    # INVALID_ISSUE_TYPE, so no plan run on a beads-backed project can carry
    # it — and workflow_type "plan". The old issue-type gate answered
    # :not_applicable, leaving plan.yaml's `requiredFile: planning.prd_path`
    # to fail with {:required_file_unknown_key, "planning"} after phase 1
    # had already written a complete PRD.
    test "plan workflow with a Beads-valid issue type yields the planning block", %{
      project_id: project_id
    } do
      assert {:ok, ctx} =
               PlanContext.build(%{
                 task_id: "run-details-prd-001",
                 project_id: project_id,
                 task_type: "feature",
                 workflow_type: "plan",
                 title: "Implement MCP run detail tools: run_logs and run_activity",
                 description: "Expose worker heartbeats through the MCP surface.",
                 approved_at: @approved_at,
                 run_id: @run_id
               })

      assert is_binary(ctx["planning"]["prd_path"])
      assert is_binary(ctx["planning"]["trd_path"])
      assert String.ends_with?(ctx["planning"]["prd_path"], ".md")
      assert String.ends_with?(ctx["planning"]["trd_path"], ".md")
      assert ctx["planning"]["correlation_id"] == "bad71b75"
      assert ctx["planning"]["document_year"] == 2026
      assert ctx["working_directory"] == System.tmp_dir!()

      # The `task` block still reports the issue tracker's own type.
      assert ctx["task"]["type"] == "feature"
    end

    test "the frozen snapshot's workflow_name alone is sufficient", %{project_id: project_id} do
      assert {:ok, ctx} =
               PlanContext.build(%{
                 project_id: project_id,
                 task_type: "feature",
                 workflow_snapshot: %{"workflow_name" => "plan"},
                 title: "Snapshot-only plan run",
                 approved_at: @approved_at,
                 run_id: @run_id
               })

      assert is_binary(ctx["planning"]["prd_path"])
      assert is_binary(ctx["planning"]["trd_path"])
    end

    test "a non-plan workflow stays :not_applicable with the project registered", %{
      project_id: project_id
    } do
      assert PlanContext.build(%{
               project_id: project_id,
               task_type: "feature",
               workflow_type: "implement-trd",
               workflow_snapshot: %{"workflow_name" => "implement-trd"},
               title: "Implement the TRD",
               approved_at: @approved_at,
               run_id: @run_id
             }) == {:not_applicable, %{}}
    end
  end

  describe "PlanContext.plan_workflow?/1" do
    test "true for every carrier of the plan workflow name" do
      assert PlanContext.plan_workflow?(%{workflow_type: "plan"})
      assert PlanContext.plan_workflow?(%{"workflow_type" => "plan"})
      assert PlanContext.plan_workflow?(%{workflow_name: "plan"})
      assert PlanContext.plan_workflow?(%{workflow_snapshot: %{"workflow_name" => "plan"}})
      assert PlanContext.plan_workflow?(%{"workflow_snapshot" => %{workflow: "plan"}})
    end

    test "true for a legacy plan issue type" do
      assert PlanContext.plan_workflow?(%{task_type: "plan"})
      assert PlanContext.plan_workflow?(%{"type" => "plan"})
    end

    test "the issue type no longer decides" do
      assert PlanContext.plan_workflow?(%{task_type: "feature", workflow_type: "plan"})
      refute PlanContext.plan_workflow?(%{task_type: "feature", workflow_type: "implement-trd"})
    end

    test "false for absent or non-map input" do
      refute PlanContext.plan_workflow?(%{})
      refute PlanContext.plan_workflow?(nil)
      refute PlanContext.plan_workflow?("plan")
    end

    test "a non-binary carrier does not mask a valid one below it" do
      assert PlanContext.plan_workflow?(%{
               workflow_snapshot: %{"workflow" => %{"name" => "implement"}},
               workflow_type: "plan"
             })
    end

    test "a nil workflow_snapshot falls through to the projection fields" do
      assert PlanContext.plan_workflow?(%{workflow_snapshot: nil, workflow_type: "plan"})
      refute PlanContext.plan_workflow?(%{workflow_snapshot: nil, task_type: "feature"})
    end
  end

  describe "required file gate key handling" do
    test "single-segment plan context key resolves to path" do
      ctx = %{"planning" => %{"prd_path" => "/tmp/PRD-x.md"}}
      assert traverse(ctx, "planning.prd_path") == {:ok, "/tmp/PRD-x.md"}
    end

    test "three-segment path resolves with deeper nesting" do
      ctx = %{"a" => %{"b" => %{"c" => "/x"}}}
      assert traverse(ctx, "a.b.c") == {:ok, "/x"}
    end

    test "missing nested key returns unknown_key" do
      assert traverse(%{"planning" => %{}}, "planning.prd_path") ==
               {:error, {:required_file_unknown_key, "prd_path"}}
    end

    test "top-level missing key returns unknown_key" do
      assert traverse(%{}, "missing") == {:error, {:required_file_unknown_key, "missing"}}
    end

    test "non-map intermediate rejected as unknown_key" do
      assert traverse(%{"a" => "not-a-map"}, "a.b") ==
               {:error, {:required_file_unknown_key, "a"}}
    end
  end

  defp traverse(ctx, key) when is_binary(key) do
    segments = String.split(key, ".", trim: true)
    traverse(ctx, segments)
  end

  defp traverse(_ctx, []), do: {:error, :required_file_traversal_failed}

  defp traverse(ctx, [segment]) when is_map(ctx) do
    case Map.get(ctx, segment) do
      nil -> {:error, {:required_file_unknown_key, segment}}
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, {:required_file_invalid_path, segment}}
    end
  end

  defp traverse(ctx, [segment | rest]) when is_map(ctx) do
    case Map.get(ctx, segment) do
      %{} = next ->
        traverse(next, rest)

      _ ->
        {:error, {:required_file_unknown_key, segment}}
    end
  end
end
