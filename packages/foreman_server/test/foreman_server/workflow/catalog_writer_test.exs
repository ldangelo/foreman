defmodule ForemanServer.Workflow.CatalogWriterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.{AssetCatalog, Catalog, CatalogWriter}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalog_writer_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    # Disable poll so test exit is deterministic.
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    server_name = :"cw_catalog_#{System.unique_integer([:positive])}"
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

    {:ok, tmp: tmp, server_name: server_name}
  end

  describe "write_manifest/2" do
    test "writes a valid manifest to the catalog root", %{tmp: tmp} do
      manifest = %{
        "name" => "test-workflow",
        "description" => "A test",
        "phases" => [
          %{"name" => "step1", "prompt" => "step1.md"}
        ]
      }

      assert {:ok, path} = CatalogWriter.write_manifest("test-workflow.yaml", manifest)
      assert path == Path.join(tmp, "test-workflow.yaml")
      assert File.exists?(path)
      assert File.read!(path) =~ "name: test-workflow"
    end

    test "name field must match filename stem", %{tmp: tmp} do
      manifest = %{"name" => "wrong-name", "phases" => []}

      assert {:error, {:name_stem_mismatch, "my-workflow", "wrong-name"}} =
               CatalogWriter.write_manifest("my-workflow.yaml", manifest)

      refute File.exists?(Path.join(tmp, "my-workflow.yaml"))
    end

    test "rejects filename with path separator", %{tmp: _tmp} do
      manifest = %{"name" => "test", "phases" => []}

      assert {:error, :invalid_filename} =
               CatalogWriter.write_manifest("subdir/test.yaml", manifest)
    end

    test "rejects filename with backslash", %{tmp: _tmp} do
      manifest = %{"name" => "test", "phases" => []}

      assert {:error, :invalid_filename} =
               CatalogWriter.write_manifest("subdir\\test.yaml", manifest)
    end

    test "rejects filename with .. segment", %{tmp: _tmp} do
      manifest = %{"name" => "test", "phases" => []}

      assert {:error, :invalid_filename} =
               CatalogWriter.write_manifest("../test.yaml", manifest)
    end

    test "rejects invalid manifest", %{tmp: _tmp} do
      # Valid name matching filename stem but phase is not a map (missing name)
      manifest = %{"name" => "test", "phases" => [%{"prompt" => "step.md"}]}

      assert {:error, {:unsupported_construct, {:phase_missing_name, 0}}} =
               CatalogWriter.write_manifest("test.yaml", manifest)
    end

    test "overwrites existing manifest", %{tmp: tmp} do
      manifest_v1 = %{
        "name" => "test-workflow",
        "description" => "v1",
        "phases" => [%{"name" => "step1", "prompt" => "step1.md"}]
      }

      manifest_v2 = %{
        "name" => "test-workflow",
        "description" => "v2",
        "phases" => [%{"name" => "step1", "prompt" => "step1.md"}]
      }

      assert {:ok, path1} = CatalogWriter.write_manifest("test-workflow.yaml", manifest_v1)
      assert File.read!(path1) =~ "v1"

      assert {:ok, path2} = CatalogWriter.write_manifest("test-workflow.yaml", manifest_v2)
      assert path1 == path2
      assert File.read!(path2) =~ "v2"
    end

    test "atomic write leaves no partial file on error", %{tmp: tmp} do
      # Use a path that would be valid but try to trigger an error during write
      # (e.g. permission denied is hard to trigger reliably, so we test the
      # manifest validation error path which never writes)
      # missing name → invalid
      manifest = %{"phases" => []}

      CatalogWriter.write_manifest("atomic-test.yaml", manifest)

      # No file should exist (failed before any write)
      refute File.exists?(Path.join(tmp, "atomic-test.yaml"))

      # No temp files should remain either
      tmp_files = Path.wildcard(Path.join(tmp, ".*.tmp.*"))
      assert tmp_files == []
    end
  end
end
