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

      # No document paths. Foreman names neither document; the planning
      # block only carries the naming inputs, and the paths appear once
      # `capture_document/3` records what a phase actually produced.
      refute Map.has_key?(ctx["planning"], "prd_path")
      refute Map.has_key?(ctx["planning"], "trd_path")
      assert ctx["planning"]["correlation_id"] == "bad71b75"
      assert ctx["planning"]["document_year"] == 2026
      assert ctx["planning"]["slug"] == "implement-mcp-run-detail-tools-run-logs-and-run"
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

      assert ctx["planning"]["correlation_id"] == "bad71b75"
      refute Map.has_key?(ctx["planning"], "prd_path")
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

  describe "PlanContext.document_dir/1" do
    test "maps only the two planning gates" do
      assert PlanContext.document_dir("planning.prd_path") == "docs/PRD"
      assert PlanContext.document_dir("planning.trd_path") == "docs/TRD"
    end

    # Every other `requiredFile` key keeps resolving through the context,
    # so a nil here is what routes `trd_path` to the existing-file check.
    test "nil for any other key" do
      assert PlanContext.document_dir("trd_path") == nil
      assert PlanContext.document_dir("planning.slug") == nil
      assert PlanContext.document_dir(nil) == nil
    end
  end

  describe "PlanContext.discover_document/2" do
    setup do
      repo = Path.join(System.tmp_dir!(), "discover-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(repo, "docs/PRD"))
      git!(repo, ["init", "--initial-branch=main"])
      git!(repo, ["config", "user.email", "d@test"])
      git!(repo, ["config", "user.name", "Discover Test"])
      File.write!(Path.join(repo, "README.md"), "seed")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "--no-gpg-sign", "-m", "seed"])

      on_exit(fn -> File.rm_rf(repo) end)
      %{repo: repo}
    end

    test "one new document is captured whatever the agent named it", %{repo: repo} do
      write!(repo, "docs/PRD/PRD-2026-c57dc188-curated-ensemble-workflow-dispatch.md")

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:ok, "docs/PRD/PRD-2026-c57dc188-curated-ensemble-workflow-dispatch.md"}
    end

    test "a staged-but-uncommitted document still counts", %{repo: repo} do
      write!(repo, "docs/PRD/PRD-2026-aaaaaaaa-staged.md")
      git!(repo, ["add", "docs/PRD"])

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:ok, "docs/PRD/PRD-2026-aaaaaaaa-staged.md"}
    end

    test "a name needing shell quoting survives intact", %{repo: repo} do
      write!(repo, ~s(docs/PRD/PRD-2026-aaaaaaaa-a "quoted" name.md))

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:ok, ~s(docs/PRD/PRD-2026-aaaaaaaa-a "quoted" name.md)}
    end

    test "nothing produced is its own error", %{repo: repo} do
      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:error, {:planning_document_absent, "docs/PRD", repo}}
    end

    test "several produced is a distinct error naming every candidate", %{repo: repo} do
      write!(repo, "docs/PRD/PRD-2026-bbbbbbbb-second.md")
      write!(repo, "docs/PRD/PRD-2026-aaaaaaaa-first.md")

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:error,
                {:planning_document_ambiguous, "docs/PRD",
                 ["docs/PRD/PRD-2026-aaaaaaaa-first.md", "docs/PRD/PRD-2026-bbbbbbbb-second.md"]}}
    end

    test "edits to a tracked document are not a new document", %{repo: repo} do
      write!(repo, "docs/PRD/PRD-2026-aaaaaaaa-existing.md")
      git!(repo, ["add", "docs/PRD"])
      git!(repo, ["commit", "--no-gpg-sign", "-m", "existing prd"])
      write!(repo, "docs/PRD/PRD-2026-aaaaaaaa-existing.md", "rewritten")

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:error, {:planning_document_absent, "docs/PRD", repo}}
    end

    test "a rename is not a new document, and does not swallow the real one", %{repo: repo} do
      write!(repo, "docs/PRD/PRD-2026-aaaaaaaa-existing.md")
      git!(repo, ["add", "docs/PRD"])
      git!(repo, ["commit", "--no-gpg-sign", "-m", "existing prd"])
      git!(repo, ["mv", "docs/PRD/PRD-2026-aaaaaaaa-existing.md", "docs/PRD/renamed.md"])
      write!(repo, "docs/PRD/PRD-2026-bbbbbbbb-fresh.md")

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:ok, "docs/PRD/PRD-2026-bbbbbbbb-fresh.md"}
    end

    test "documents outside the gate's directory are ignored", %{repo: repo} do
      write!(repo, "docs/TRD/TRD-2026-aaaaaaaa-other.md")
      write!(repo, "docs/PRD/PRD-2026-aaaaaaaa-mine.md")

      assert PlanContext.discover_document(repo, "docs/PRD") ==
               {:ok, "docs/PRD/PRD-2026-aaaaaaaa-mine.md"}
    end

    test "a directory git cannot read is neither absent nor ambiguous" do
      not_a_repo = Path.join(System.tmp_dir!(), "no-repo-#{System.unique_integer([:positive])}")

      assert {:error, {:planning_document_scan_failed, ^not_a_repo, status, output}} =
               PlanContext.discover_document(not_a_repo, "docs/PRD")

      assert status != 0
      assert output =~ "fatal"
    end
  end

  describe "PlanContext.capture_document/3" do
    test "the captured PRD becomes planning.prd_path" do
      captured =
        PlanContext.capture_document(
          %{"planning" => %{"slug" => "s"}},
          "planning.prd_path",
          "docs/PRD/PRD-2026-c57dc188-curated.md"
        )

      assert captured["planning"]["prd_path"] == "docs/PRD/PRD-2026-c57dc188-curated.md"
      assert captured["planning"]["slug"] == "s"
    end

    # Pairing rides on the correlation id in the filename. The run-derived
    # id belongs to a PRD that was never written, so it must not survive.
    test "the captured PRD re-keys the correlation id off its own filename" do
      captured =
        PlanContext.capture_document(
          %{"planning" => %{"correlation_id" => "d6cdefe6"}},
          "planning.prd_path",
          "docs/PRD/PRD-2026-c57dc188-curated.md"
        )

      assert captured["planning"]["correlation_id"] == "c57dc188"
    end

    test "a PRD name carrying no correlation id drops the run-derived one" do
      captured =
        PlanContext.capture_document(
          %{"planning" => %{"correlation_id" => "d6cdefe6"}},
          "planning.prd_path",
          "docs/PRD/product-requirements.md"
        )

      refute Map.has_key?(captured["planning"], "correlation_id")
    end

    test "capturing the TRD records the path and leaves the pairing key alone" do
      captured =
        PlanContext.capture_document(
          %{"planning" => %{"correlation_id" => "c57dc188"}},
          "planning.trd_path",
          "docs/TRD/TRD-2026-99999999-whatever.md"
        )

      assert captured["planning"]["trd_path"] == "docs/TRD/TRD-2026-99999999-whatever.md"
      assert captured["planning"]["correlation_id"] == "c57dc188"
    end
  end

  defp git!(repo, args) do
    {_output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    :ok
  end

  defp write!(repo, relative, body \\ "document body") do
    target = Path.join(repo, relative)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, body)
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
