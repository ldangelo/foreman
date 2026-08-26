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

  describe "manifests/1" do
    test "returns sorted yaml filenames excluding non-yaml files", %{catalog: catalog, tmp: tmp} do
      File.write!(Path.join(tmp, "alpha.yaml"), "name: alpha\nphases: []\n")
      File.write!(Path.join(tmp, "beta.yaml"), "name: beta\nphases: []\n")
      File.write!(Path.join(tmp, "README.md"), "hi\n")

      assert AssetCatalog.manifests(catalog) == [
               Path.join(tmp, "alpha.yaml"),
               Path.join(tmp, "beta.yaml")
             ]
    end

    test "returns [] when the root directory is empty", %{catalog: catalog} do
      assert AssetCatalog.manifests(catalog) == []
    end
  end

  describe "prompts/1" do
    test "returns sorted markdown filenames from the prompts directory", %{
      catalog: catalog,
      tmp: tmp
    } do
      File.write!(Path.join(tmp, "prompts/explorer.md"), "explorer prompt")
      File.write!(Path.join(tmp, "prompts/implementer.md"), "implementer prompt")
      File.write!(Path.join(tmp, "prompts/notes.txt"), "not a prompt")

      assert AssetCatalog.prompts(catalog) == [
               Path.join(tmp, "prompts/explorer.md"),
               Path.join(tmp, "prompts/implementer.md")
             ]
    end

    test "returns [] when the prompts directory does not exist", %{catalog: catalog, tmp: tmp} do
      File.rm_rf!(Path.join(tmp, "prompts"))
      assert AssetCatalog.prompts(catalog) == []
    end
  end

  describe "resolve_prompt/2" do
    test "returns absolute path under catalog prompts_dir", %{catalog: catalog, tmp: tmp} do
      File.write!(Path.join(tmp, "prompts/explorer.md"), "x")
      resolved = AssetCatalog.resolve_prompt(catalog, "explorer.md")
      assert resolved == Path.join([tmp, "prompts", "explorer.md"])
    end

    test "returns nil for nil prompt reference", %{catalog: catalog} do
      assert AssetCatalog.resolve_prompt(catalog, nil) == nil
    end
  end

  describe "digest/1" do
    test "returns a stable 16-char hex digest for the same content", %{tmp: tmp} do
      path = Path.join(tmp, "d.yaml")
      File.write!(path, "name: x\nphases: []\n")

      assert AssetCatalog.digest(path) == AssetCatalog.digest(path)
      assert byte_size(AssetCatalog.digest(path)) == 16
    end
  end
end
