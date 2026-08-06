defmodule ForemanServer.Workflow.CatalogTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "foreman_catalog_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "prompts"))

    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    server_name = :"catalog_test_#{System.unique_integer([:positive])}"
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

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

  defp start_catalog(tmp, server_name) do
    catalog = AssetCatalog.new(tmp)
    start_supervised!({Catalog, name: server_name, catalog: catalog}, id: server_name)
  end

  defp write_manifest(tmp, name, prompt \\ "p.md") do
    File.write!(Path.join(tmp, "prompts/#{prompt}"), name)

    File.write!(
      Path.join(tmp, "#{name}.yaml"),
      "name: #{name}\nphases:\n  - name: p1\n    prompt: #{prompt}\n"
    )
  end

  describe "start_link/1" do
    test "auto-installs bundled templates into an empty root", %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      assert Catalog.installed?()
      assert "implement.yaml" in Catalog.manifests()
      assert "implement.md" in Catalog.prompt_filenames()
    end

    test "does not auto-install when the root already has manifests", %{
      tmp: tmp,
      server_name: name
    } do
      write_manifest(tmp, "preset", "preset.md")

      start_catalog(tmp, name)

      # The pre-existing manifest is loaded but the bundled templates are
      # not copied on top of operator files.
      assert Catalog.manifests() == ["preset.yaml"]
    end
  end

  describe "load/1" do
    test "returns the parsed workflow for a known manifest", %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      assert {:ok, wf} = Catalog.load("implement.yaml")
      assert wf.name == "implement"
      assert is_list(wf.phases)
    end

    test "returns {:error, {:workflow_not_loaded, filename}} for missing filenames",
         %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      assert {:error, {:workflow_not_loaded, "missing.yaml"}} =
               Catalog.load("missing.yaml")
    end
  end

  describe "read_prompt/1" do
    test "returns the tracked prompt content", %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      path = Path.join([tmp, "prompts", "implement.md"])

      assert {:ok, content} = Catalog.read_prompt(path)
      assert is_binary(content)
      assert content != ""
    end

    test "returns {:error, :prompt_not_tracked} for unknown prompts",
         %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      assert {:error, :prompt_not_tracked} =
               Catalog.read_prompt("/tmp/does-not-exist.md")
    end
  end

  describe "reload/0" do
    test "picks up a freshly written manifest after reload", %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      assert {:error, {:workflow_not_loaded, "first.yaml"}} = Catalog.load("first.yaml")

      write_manifest(tmp, "first", "first.md")

      :ok = Catalog.reload()

      assert {:ok, wf} = Catalog.load("first.yaml")
      assert wf.name == "first"
      assert [phase] = wf.phases
      assert phase["prompt"] == "first.md"
    end

    test "removes vanished manifests from the in-memory map", %{tmp: tmp, server_name: name} do
      write_manifest(tmp, "g", "g.md")

      start_catalog(tmp, name)

      assert "g.yaml" in Catalog.manifests()

      File.rm!(Path.join(tmp, "g.yaml"))

      :ok = Catalog.reload()

      refute "g.yaml" in Catalog.manifests()
    end

    test "refreshes prompt content when the body changes", %{tmp: tmp, server_name: name} do
      prompt_path = Path.join(tmp, "prompts/p.md")
      File.write!(prompt_path, "version one")

      start_catalog(tmp, name)

      assert {:ok, "version one"} = Catalog.read_prompt(prompt_path)

      File.write!(prompt_path, "version two")

      :ok = Catalog.reload()

      assert {:ok, "version two"} = Catalog.read_prompt(prompt_path)
    end

    test "keeps existing manifests when nothing on disk changed", %{tmp: tmp, server_name: name} do
      write_manifest(tmp, "stable", "stable.md")

      start_catalog(tmp, name)
      assert {:ok, wf} = Catalog.load("stable.yaml")
      assert wf.name == "stable"

      :ok = Catalog.reload()
      assert {:ok, wf} = Catalog.load("stable.yaml")
      assert wf.name == "stable"
    end
  end

  describe "telemetry" do
    test "emits [:foreman_server, :workflow, :installed] on first install",
         %{tmp: tmp, server_name: name} do
      parent = self()

      handler_id = "catalog-installed-#{name}"

      :telemetry.attach(
        handler_id,
        [:foreman_server, :workflow, :installed],
        fn _event, %{count: count}, %{root: root}, _config ->
          send(parent, {:installed, count, root})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      start_catalog(tmp, name)

      assert_received {:installed, 1, ^tmp}
    end

    test "emits reload events when manifests change", %{tmp: tmp, server_name: name} do
      parent = self()

      handler_id = "catalog-reload-#{name}"

      events = [
        [:foreman_server, :workflow, :manifest, :loaded],
        [:foreman_server, :workflow, :manifest, :reload, :ok],
        [:foreman_server, :workflow, :manifest, :reload, :error],
        [:foreman_server, :workflow, :manifest, :removed]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _meas, %{filename: filename}, _config ->
          send(parent, {:event, event, filename})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      write_manifest(tmp, "seed", "seed.md")

      start_catalog(tmp, name)

      assert_received {:event, [:foreman_server, :workflow, :manifest, :loaded], "seed.yaml"}

      File.write!(
        Path.join(tmp, "seed.yaml"),
        "name: seed\nphases:\n  - name: p\n    prompt: seed.md\n"
      )

      File.write!(Path.join(tmp, "prompts/seed.md"), "seed v2")

      :ok = Catalog.reload()

      assert_received {:event, [:foreman_server, :workflow, :manifest, :reload, :ok], "seed.yaml"}
    end
  end
end
