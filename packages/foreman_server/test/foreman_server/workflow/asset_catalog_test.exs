defmodule ForemanServer.Workflow.AssetCatalogTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.AssetCatalog

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "foreman_asset_catalog_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "prompts"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, catalog: AssetCatalog.new(tmp), tmp: tmp}
  end

  describe "load/2" do
    test "returns {:error, {:manifest_load_failed, ...}} when the file is missing", %{catalog: catalog} do
      assert {:error, {:manifest_load_failed, "missing.yaml", "workflow template not found: " <> _}} =
               AssetCatalog.load(catalog, "missing.yaml")
    end

    test "returns {:error, {:manifest_load_failed, ...}} when the manifest is missing required keys",
         %{catalog: catalog, tmp: tmp} do
      # Manifest with no `name` and no `phases` — triggers MissingRequiredPhaseError
      File.write!(Path.join(tmp, "broken.yaml"), "description: oops\n")
      # Markdown is not a valid YAML mapping — but the interpreter expects a mapping
      File.write!(Path.join(tmp, "bad.yaml"), "this: that\nphases: nope\n")

      assert {:error, {:manifest_load_failed, "broken.yaml", _}} =
               AssetCatalog.load(catalog, "broken.yaml")

      assert {:error, {:manifest_load_failed, "bad.yaml", _}} =
               AssetCatalog.load(catalog, "bad.yaml")
    end
  end
end
