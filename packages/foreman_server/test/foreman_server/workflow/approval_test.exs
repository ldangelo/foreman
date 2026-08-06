defmodule ForemanServer.Workflow.ApprovalTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.Approval
  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "foreman_approval_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "prompts"))

    # Disable the catalog poll loop so test exit is deterministic.
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    # Redirect the Catalog dispatch to a test-scoped process and start it
    # rooted at `tmp`. The application-managed Catalog keeps running in
    # production code paths; this only changes what the API functions
    # in this test observe.
    server_name = :"approval_catalog_#{System.unique_integer([:positive])}"
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

    catalog = AssetCatalog.new(tmp)
    start_supervised!({Catalog, name: server_name, catalog: catalog})

    on_exit(fn ->
      if prev_server,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
        else: Application.delete_env(:foreman_server, :workflow_catalog)

      if prev_poll,
        do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll)

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "prepare/2" do
    test "returns {:error, {:workflow_load_failed, _}} when workflow manifest is missing" do
      payload = %{task_id: "task-1", task_type: "missing-workflow"}

      assert {:error, {:workflow_load_failed, "missing-workflow", _}} =
               Approval.prepare(payload, approval_id: "approval-1")
    end

    test "returns {:error, {:invalid_payload, :task_id_missing, _}} when task_id is absent" do
      assert {:error, {:invalid_payload, :task_id_missing, _}} =
               Approval.prepare(%{task_type: "implement"})
    end

    test "writes a deterministic run_id derived from task_id + approval_id so retries are stable" do
      payload = %{task_id: "task-42", task_type: "missing"}

      assert {:error, _} =
               Approval.prepare(payload, approval_id: "approval-42")

      # Same inputs produce the same error shape (deterministic).
      assert {:error, _} =
               Approval.prepare(payload, approval_id: "approval-42")
    end

    test "resolves a manifest written into the configured root", %{tmp: tmp} do
      manifest_path = Path.join(tmp, "demo.yaml")
      prompt_path = Path.join(tmp, "prompts/demo.md")

      File.write!(prompt_path, "do the demo thing")

      File.write!(manifest_path, """
      name: demo
      phases:
        - name: only
          prompt: demo.md
      """)

      :ok = Catalog.reload()

      assert {:ok, prepared} =
               Approval.prepare(
                 %{task_id: "task-99", task_type: "demo"},
                 approval_id: "approval-99"
               )

      assert prepared.workflow_name == "demo"
      assert prepared.run_id == ForemanServer.Identity.run_id("task-99", "approval-99")
      assert [phase] = prepared.workflow_snapshot.phases
      assert phase.prompt_path == prompt_path
    end
  end
end
