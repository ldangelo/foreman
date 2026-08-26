defmodule ForemanServer.Work.SubmissionTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Work.Submission

  setup do
    {:ok, _} = Application.ensure_all_started(:telemetry)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "foreman_submission_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "prompts"))

    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    server_name = :"submission_catalog_#{System.unique_integer([:positive])}"
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

    catalog = AssetCatalog.new(tmp)
    start_supervised!({Catalog, name: server_name, catalog: catalog}, id: server_name)

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

  describe "prepare/1" do
    test "valid submission returns {:ok, %{submission_id, run_id, workflow_snapshot, ...}}",
         %{tmp: tmp} do
      manifest_path = Path.join(tmp, "demo.yaml")
      prompt_path = Path.join(tmp, "prompts/demo.md")

      File.write!(prompt_path, "do the demo thing")

      File.write!(manifest_path, """
      name: demo
      phases:
        - name: plan
          prompt: demo.md
        - name: implement
          prompt: demo.md
      """)

      :ok = Catalog.reload()

      input = %{
        work_id: "work-abc",
        project_id: "proj-123",
        workflow: "demo",
        prompt: "build a demo"
      }

      assert {:ok, result} = Submission.prepare(input)

      assert is_binary(result.submission_id)
      assert result.submission_id != ""
      assert is_binary(result.run_id)
      assert result.run_id != ""
      assert result.work_id == "work-abc"
      assert result.project_id == "proj-123"
      assert result.workflow == "demo"

      workflow_snapshot = result.workflow_snapshot
      assert is_map(workflow_snapshot)
      assert is_list(workflow_snapshot.phases)
      assert length(workflow_snapshot.phases) == 2

      assert workflow_snapshot.input["prompt"] == "build a demo"
      assert workflow_snapshot.input["prompt_argument"] == Jason.encode!("build a demo")
    end

    test "workflow_snapshot has index and phase_id stamped on each phase", %{tmp: tmp} do
      manifest_path = Path.join(tmp, "demo2.yaml")

      File.write!(manifest_path, """
      name: demo2
      phases:
        - name: first
          prompt: demo2.md
        - name: second
          prompt: demo2.md
      """)

      :ok = Catalog.reload()

      {:ok, result} =
        Submission.prepare(%{
          work_id: "work-abc",
          project_id: "proj-123",
          workflow: "demo2",
          prompt: "hello"
        })

      phases = result.workflow_snapshot.phases

      assert Enum.map(phases, & &1.index) == [1, 2]

      # phase_id format: "run-<hex_digest>-pNNN"
      assert Enum.at(phases, 0).phase_id =~ ~r"^run-[a-f0-9]{32}-p001$"
      assert Enum.at(phases, 1).phase_id =~ ~r"^run-[a-f0-9]{32}-p002$"
    end

    test "invalid submission (missing required fields) returns {:error, {:invalid_submission, :missing_required_fields}}" do
      assert Submission.prepare(%{}) ==
               {:error, {:invalid_submission, :missing_required_fields}}

      assert Submission.prepare(%{work_id: "work-1"}) ==
               {:error, {:invalid_submission, :missing_required_fields}}

      assert Submission.prepare(%{
               work_id: "work-1",
               project_id: "proj-1"
             }) ==
               {:error, {:invalid_submission, :missing_required_fields}}

      assert Submission.prepare(%{
               work_id: "",
               project_id: "proj-1",
               workflow: "demo",
               prompt: "hi"
             }) ==
               {:error, {:invalid_submission, :missing_required_fields}}
    end

    test "workflow not found returns {:error, {:workflow_load_failed, name, reason}}" do
      assert {:error,
              {:workflow_load_failed, "nonexistent", {:workflow_not_loaded, "nonexistent.yaml"}}} =
               Submission.prepare(%{
                 work_id: "work-1",
                 project_id: "proj-1",
                 workflow: "nonexistent",
                 prompt: "hi"
               })
    end
  end
end
