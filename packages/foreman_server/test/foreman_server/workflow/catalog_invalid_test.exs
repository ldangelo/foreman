defmodule ForemanServer.Workflow.CatalogInvalidTest do
  @moduledoc """
  An invalid manifest is still refused, but it must never vanish (foreman-gl3nu):
  the catalog records a typed `LoadError` for it, logs it once per distinct file
  content, and every surface that lists workflows reports it with the reason.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Coordinator.Context.Sources.Live
  alias ForemanServer.MCP.Tools
  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.Workflow.LoadError

  @moduletag :tmp_dir

  @bad_models """
  name: lvclaude
  phases:
    - name: a
      command: /skill:x
      provider: claude
      models:
        default: litellm-stack/smart_router
  """

  setup %{tmp_dir: tmp} do
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 600_000)

    server_name = :"catalog_invalid_test_#{System.unique_integer([:positive])}"
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

    on_exit(fn ->
      if prev_server,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
        else: Application.delete_env(:foreman_server, :workflow_catalog)

      if prev_poll,
        do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll),
        else: Application.delete_env(:foreman_server, :workflow_catalog_poll_ms)
    end)

    File.mkdir_p!(Path.join(tmp, "prompts"))
    # A valid manifest keeps the catalog from auto-installing the bundled set
    # into an otherwise empty root.
    File.write!(
      Path.join(tmp, "good.yaml"),
      "name: good\nphases:\n  - name: p1\n    command: /skill:x\n"
    )

    {:ok, server_name: server_name}
  end

  defp start_catalog(tmp, server_name) do
    start_supervised!({Catalog, name: server_name, catalog: AssetCatalog.new(tmp)},
      id: server_name
    )
  end

  defp write_invalid!(tmp, contents \\ @bad_models),
    do: File.write!(Path.join(tmp, "lvclaude.yaml"), contents)

  describe "Catalog.invalid/0" do
    test "lists a refused manifest with file, stage and reason; it is still not loaded",
         %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)
      capture_log(fn -> start_catalog(tmp, name) end)

      assert ["good.yaml"] == Catalog.manifests()

      assert [%LoadError{} = error] = Catalog.invalid()
      assert error.filename == "lvclaude.yaml"
      assert error.path == Path.join(tmp, "lvclaude.yaml")
      assert error.stage == :validation
      assert error.message =~ "must be a bare model alias or id"
      assert error.serving_previous == false
      assert is_binary(error.file_digest)

      # The refusal is unchanged; only its error is richer than "not loaded".
      assert {:error, {:workflow_invalid, ^error}} = Catalog.load("lvclaude.yaml")
      assert {:error, {:workflow_not_loaded, "nope.yaml"}} = Catalog.load("nope.yaml")
    end

    test "is empty when every manifest is valid", %{tmp_dir: tmp, server_name: name} do
      start_catalog(tmp, name)
      assert [] == Catalog.invalid()
    end

    test "a refused manifest becomes valid once fixed, and disappears when deleted",
         %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)
      capture_log(fn -> start_catalog(tmp, name) end)
      assert [%LoadError{filename: "lvclaude.yaml"}] = Catalog.invalid()

      File.write!(
        Path.join(tmp, "lvclaude.yaml"),
        "name: lvclaude\nphases:\n  - name: a\n    command: /skill:x\n"
      )

      :ok = Catalog.reload()
      assert [] == Catalog.invalid()
      assert {:ok, %{name: "lvclaude"}} = Catalog.load("lvclaude.yaml")

      write_invalid!(
        tmp,
        "name: lvclaude\nphases:\n  - name: a\n    command: /skill:x\n    models: x\n"
      )

      capture_log(fn -> :ok = Catalog.reload() end)
      assert [%LoadError{serving_previous: true}] = Catalog.invalid()

      File.rm!(Path.join(tmp, "lvclaude.yaml"))
      :ok = Catalog.reload()
      assert [] == Catalog.invalid()
      refute "lvclaude.yaml" in Catalog.manifests()
    end

    test "a failed edit of a loaded manifest says the previous version is still served",
         %{tmp_dir: tmp, server_name: name} do
      start_catalog(tmp, name)
      assert {:ok, %{name: "good"}} = Catalog.load("good.yaml")

      File.write!(Path.join(tmp, "good.yaml"), "name: good\nphases:\n  - bogus line\n")
      capture_log(fn -> :ok = Catalog.reload() end)

      assert [%LoadError{filename: "good.yaml", serving_previous: true} = error] =
               Catalog.invalid()

      assert LoadError.describe(error) =~ "previous valid version is still being served"
      assert {:ok, %{name: "good"}} = Catalog.load("good.yaml")
    end

    test "a manifest the loader cannot parse is reported at the validation stage",
         %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp, "name: broken\nphases:\n  - not a mapping entry\n")
      capture_log(fn -> start_catalog(tmp, name) end)

      assert [%LoadError{stage: :validation, message: message}] = Catalog.invalid()
      assert message =~ "unsupported phase entry"
    end
  end

  describe "logging" do
    test "warns once per distinct content, not on every poll", %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)

      log = capture_log(fn -> start_catalog(tmp, name) end)
      assert log =~ "lvclaude.yaml"
      assert log =~ "INVALID"
      assert log =~ "must be a bare model alias or id"

      repeated =
        capture_log(fn ->
          :ok = Catalog.reload()
          :ok = Catalog.reload()
        end)

      refute repeated =~ "lvclaude.yaml"

      write_invalid!(tmp, String.replace(@bad_models, "smart_router", "other_router"))
      changed = capture_log(fn -> :ok = Catalog.reload() end)
      assert changed =~ "lvclaude.yaml"
      assert changed =~ "other_router"
    end

    test "logs at warning level", %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)
      assert capture_log([level: :warning], fn -> start_catalog(tmp, name) end) =~ "INVALID"
    end
  end

  describe "surfaces that list workflows" do
    test "foreman_workflow_list reports the refused manifest beside the loaded ones",
         %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)
      capture_log(fn -> start_catalog(tmp, name) end)

      assert {:ok, %{workflows: ["good.yaml"], invalid: [invalid]}} =
               Tools.call_tool("foreman_workflow_list", %{})

      assert invalid["filename"] == "lvclaude.yaml"
      assert invalid["stage"] == "validation"
      assert invalid["reason"] =~ "must be a bare model alias or id"
      assert invalid["serving_previous"] == false
    end

    test "foreman_workflow_get answers INVALID_MANIFEST with the reason, not NOT_FOUND",
         %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)
      capture_log(fn -> start_catalog(tmp, name) end)

      assert {:error, %ForemanServer.MCP.ToolError{code: "INVALID_MANIFEST", message: message}} =
               Tools.call_tool("foreman_workflow_get", %{name: "lvclaude"})

      assert message =~ "lvclaude is invalid and was not loaded"
      assert message =~ "must be a bare model alias or id"

      assert {:error, %ForemanServer.MCP.ToolError{code: "NOT_FOUND"}} =
               Tools.call_tool("foreman_workflow_get", %{name: "never-existed"})
    end

    test "foreman_workflow_get returns the served snapshot WITH the pending refusal",
         %{tmp_dir: tmp, server_name: name} do
      start_catalog(tmp, name)
      assert {:ok, result} = Tools.call_tool("foreman_workflow_get", %{name: "good"})
      refute Map.has_key?(result, :refused_edit)

      File.write!(Path.join(tmp, "good.yaml"), "name: good\nphases:\n  - bogus line\n")
      capture_log(fn -> :ok = Catalog.reload() end)

      # The workflow still starts from its last good snapshot, so it is not an error...
      assert {:ok, %{name: "good"}} = Catalog.load("good.yaml")
      assert {:ok, result} = Tools.call_tool("foreman_workflow_get", %{name: "good"})
      assert result.name == "good"

      # ...but the refused edit is reported next to it, typed.
      assert %{"serving_previous" => true, "stage" => "validation", "reason" => reason} =
               result.refused_edit

      assert reason =~ "unsupported phase entry"
    end

    test "the coordinator source flags a refused edit as serving its previous version",
         %{tmp_dir: tmp, server_name: name} do
      start_catalog(tmp, name)
      File.write!(Path.join(tmp, "good.yaml"), "name: good\nphases:\n  - bogus line\n")
      capture_log(fn -> :ok = Catalog.reload() end)

      assert [%{name: "good", serving_previous: true, reason: reason}] = Live.invalid_workflows()
      assert reason =~ "unsupported phase entry"
      # Still a startable workflow, so it stays in the normal list too.
      assert Enum.map(Live.workflows(), & &1.name) == ["good"]
    end

    test "the coordinator source lists the refused manifest under its file name",
         %{tmp_dir: tmp, server_name: name} do
      write_invalid!(tmp)
      capture_log(fn -> start_catalog(tmp, name) end)

      assert [%{name: "lvclaude", reason: reason, serving_previous: false}] =
               Live.invalid_workflows()

      assert reason =~ "must be a bare model alias or id"
      assert Enum.map(Live.workflows(), & &1.name) == ["good"]
    end
  end

  describe "flow-style manifests load through the catalog (foreman-diiqo)" do
    test "a flow worktree: block yields the same snapshot and digest as the block form",
         %{tmp_dir: tmp, server_name: name} do
      phases = "phases:\n  - name: a\n    command: /skill:x\n"

      File.write!(
        Path.join(tmp, "blockwt.yaml"),
        "name: wt\nworktree:\n  enabled: false\n  base: main\n#{phases}"
      )

      File.write!(
        Path.join(tmp, "flowwt.yaml"),
        "name: wt\nworktree: {enabled: false, base: main}\n#{phases}"
      )

      start_catalog(tmp, name)

      assert [] == Catalog.invalid()
      assert {:ok, block} = Catalog.load("blockwt.yaml")
      assert {:ok, flow} = Catalog.load("flowwt.yaml")
      assert block.worktree == %{"enabled" => false, "base" => "main"}

      assert flow.worktree == block.worktree
      assert flow.digest == block.digest
    end
  end
end
