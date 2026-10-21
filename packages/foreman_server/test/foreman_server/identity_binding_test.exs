defmodule ForemanServer.IdentityBindingTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectionStore}

  setup do
    reset_projection_store()
    :ok
  end

  describe "gateway allowlist" do
    test "project.update and project.archive are admitted to the operator boundary" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:project-1",
                 type: "project.update",
                 payload: %{}
               })

      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:project-1",
                 type: "project.archive",
                 payload: %{}
               })
    end

    test "non-allowlisted operator commands are still rejected at the gateway" do
      assert {:error, {:command_not_allowed, "run.complete"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:project-1",
                 type: "run.complete",
                 payload: %{project_id: "project-1"}
               })
    end
  end

  describe "identity binding" do
    test "project.update rejects a mismatched aggregate_id before any project mutation" do
      project_id = unique_id("project")
      other_project_id = unique_id("project")

      assert {:ok, _} = register_project(project_id)

      original_projection = ProjectionStore.project_projection(project_id)

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.update",
                 payload: %{project_id: other_project_id, path: "/tmp/#{other_project_id}"}
               })

      assert ProjectionStore.project_projection(project_id) == original_projection
      assert ProjectionStore.project_projection(other_project_id) == nil
    end

    test "project.archive rejects a mismatched aggregate_id before any project mutation" do
      project_id = unique_id("project")
      other_project_id = unique_id("project")

      assert {:ok, _} = register_project(project_id)

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.archive",
                 payload: %{project_id: other_project_id}
               })

      refute ProjectionStore.project_projection(project_id).archived?
      assert ProjectionStore.project_projection(other_project_id) == nil
    end

    @tag :tmp_dir
    test "matching operator identity reaches the actor for project.update", %{tmp_dir: tmp_dir} do
      project_id = unique_id("project")
      updated_path = Path.join(tmp_dir, "updated")
      File.mkdir_p!(updated_path)
      {_, 0} = System.cmd("git", ["init", "--quiet", updated_path], stderr_to_stdout: true)

      assert {:ok, _} = register_project(project_id)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.update",
                 payload: %{project_id: project_id, path: updated_path}
               })

      # The gateway dispatches the canonical path (a path that moves the primary repo is validated);
      # git reports the work-tree root in canonical form.
      {toplevel, 0} = System.cmd("git", ["-C", updated_path, "rev-parse", "--show-toplevel"])
      assert ProjectionStore.project_projection(project_id).path == String.trim(toplevel)
    end
  end

  describe "operator vs system routing" do
    test "project.reactivate reactivates an archived project through either boundary" do
      project_id = unique_id("project")

      assert {:ok, _} = register_project(project_id)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.archive",
                 payload: %{project_id: project_id}
               })

      assert ProjectionStore.project_projection(project_id).archived?

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: unique_id("system-command"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.reactivate",
                 payload: %{project_id: project_id}
               })

      refute ProjectionStore.project_projection(project_id).archived?

      operator_project_id = unique_id("project")

      assert {:ok, _} = register_project(operator_project_id)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{operator_project_id}",
                 type: "project.archive",
                 payload: %{project_id: operator_project_id}
               })

      assert ProjectionStore.project_projection(operator_project_id).archived?

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: unique_id("command"),
                 aggregate_id: "project:#{operator_project_id}",
                 type: "project.reactivate",
                 payload: %{project_id: operator_project_id}
               })

      refute ProjectionStore.project_projection(operator_project_id).archived?
    end
  end

  defp register_project(project_id) do
    CommandGateway.dispatch_operator(%{
      command_id: unique_id("command"),
      aggregate_id: "project:#{project_id}",
      type: "project.register",
      payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
    })
  end

  defp reset_projection_store do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
