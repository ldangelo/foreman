defmodule ForemanServer.Workflow.CatalogTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog
  alias ForemanServer.WorkflowTemplate.Installer

  setup do
    {:ok, _} = Application.ensure_all_started(:telemetry)

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

  describe "plan workflow (command: phases)" do
    test "loading plan.yaml yields two command phases with requiredFile", %{
      tmp: tmp,
      server_name: name
    } do
      start_catalog(tmp, name)

      assert {:ok, wf} = Catalog.load("plan.yaml")
      assert wf.name == "plan"
      assert is_list(wf.phases)
      assert length(wf.phases) == 2

      [create_prd, create_trd] = wf.phases

      assert create_prd["name"] == "create-prd"
      assert create_prd.action == :command
      assert create_prd.command == "/skill:ensemble-full-create-prd --foreman"
      assert create_prd.required_file == "planning.prd_path"
      assert create_prd.prompt_path in [nil, ""]

      assert create_trd["name"] == "create-trd"
      assert create_trd.action == :command
      assert create_trd.command == "/skill:ensemble-full-create-trd-foreman --foreman"
      assert create_trd.required_file == "planning.trd_path"
      assert create_trd.prompt_path in [nil, ""]
    end
  end

  describe "fix workflow (WFD-T006 / TRD-069)" do
    test "loading fix.yaml yields single command phase with ensemble-fix-issue and --foreman", %{
      tmp: tmp,
      server_name: name
    } do
      start_catalog(tmp, name)

      assert {:ok, wf} = Catalog.load("fix.yaml")
      assert wf.name == "fix"
      assert is_list(wf.phases)
      assert length(wf.phases) == 1

      [fix_phase] = wf.phases

      assert fix_phase["name"] == "fix"
      assert fix_phase.action == :command
      assert fix_phase.command == "/skill:ensemble-fix-issue {{input.prompt}} --foreman"
      # Single-phase workflow has no routing requirement
      assert fix_phase.required_file in [nil, ""]
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

  describe "workflow-level worktree block" do
    test "legacy manifest without worktree block leaves resolved shape unchanged", %{
      tmp: tmp,
      server_name: name
    } do
      write_manifest(tmp, "legacy")
      start_catalog(tmp, name)

      assert {:ok, workflow} = Catalog.load("legacy.yaml")
      phase = hd(workflow.phases)
      refute Map.has_key?(phase, :worktree)
      # No top-level block declared, so the catalog carries no `:worktree` key
      # at all and leaves the digest alone.
      refute Map.has_key?(workflow, :worktree)
      assert workflow.digest == nil
    end

    test "worktree block is carried verbatim with no injected defaults", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(
        Path.join(tmp, "with-wt.yaml"),
        """
        name: with-wt
        worktree:
          enabled: true
        phases:
          - name: p1
            prompt: p.md
        """
      )

      File.write!(Path.join(tmp, "prompts/p.md"), "p")
      start_catalog(tmp, name)

      assert {:ok, workflow} = Catalog.load("with-wt.yaml")

      # This test used to assert the catalog re-keyed the block to atoms and
      # filled in `branch: "foreman/{run_id}/{phase}"`, `cleanup: "always"` and
      # `path: nil`. That was wrong: it made the catalog a third normalizer for
      # one block, with defaults that disagreed with both `PhaseSpec` and the
      # executor's own reads. Normalization now happens exactly once, at the
      # executor boundary, via `WorktreeSpec.normalize/1`.
      #
      # Injecting defaults here would also destroy information the executor
      # needs: it would make "declared nothing" indistinguishable from
      # "declared the default". That distinction is load-bearing for `enabled`.
      assert workflow.worktree == %{"enabled" => true}

      refute Map.has_key?(workflow.worktree, "branch")
      refute Map.has_key?(workflow.worktree, "cleanup")
      refute Map.has_key?(workflow.worktree, "path")
      refute Map.has_key?(workflow.worktree, "base")

      # Phases carry no worktree of their own any more.
      refute Map.has_key?(hd(workflow.phases), :worktree)

      # A top-level `worktree` key switches the resolved workflow to the
      # computed canonical digest.
      assert is_binary(workflow.digest) and byte_size(workflow.digest) == 16
    end

    test "worktree.enabled: false still declares worktree and changes digest", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(
        Path.join(tmp, "disabled-wt.yaml"),
        """
        name: disabled-wt
        worktree:
          enabled: false
          branch: custom
        phases:
          - name: p1
            prompt: p.md
        """
      )

      File.write!(Path.join(tmp, "prompts/p.md"), "p")
      start_catalog(tmp, name)

      assert {:ok, workflow} = Catalog.load("disabled-wt.yaml")

      # A present `false` is a declaration, not an absence — it must survive the
      # trip through the catalog verbatim rather than being defaulted away.
      assert workflow.worktree == %{"enabled" => false, "branch" => "custom"}
      assert is_binary(workflow.digest) and byte_size(workflow.digest) == 16
    end

    test "digest changes when worktree config changes", %{tmp: tmp, server_name: name} do
      base = """
      name: digest-wt
      worktree:
        base: main
      phases:
        - name: p1
          prompt: p.md
      """

      modified = """
      name: digest-wt
      worktree:
        base: develop
      phases:
        - name: p1
          prompt: p.md
      """

      File.write!(Path.join(tmp, "prompts/p.md"), "p")
      File.write!(Path.join(tmp, "digest-wt.yaml"), base)
      start_catalog(tmp, name)

      assert {:ok, workflow_v1} = Catalog.load("digest-wt.yaml")
      digest_v1 = workflow_v1.digest

      File.write!(Path.join(tmp, "digest-wt.yaml"), modified)
      :ok = Catalog.reload()

      assert {:ok, workflow_v2} = Catalog.load("digest-wt.yaml")
      digest_v2 = workflow_v2.digest

      # The block moved out of `phases`, so `canonical_digest/1` has to fold it
      # in explicitly — otherwise a `base`/`branch`/`cleanup` edit would be
      # invisible to the digest.
      assert is_binary(digest_v1) and is_binary(digest_v2)
      assert digest_v1 != digest_v2
    end

    test "digest stable across re-loads of identical manifest", %{tmp: tmp, server_name: name} do
      File.write!(
        Path.join(tmp, "stable-wt.yaml"),
        """
        name: stable-wt
        worktree:
          base: main
          branch: feat/x
        phases:
          - name: p1
            prompt: p.md
        """
      )

      File.write!(Path.join(tmp, "prompts/p.md"), "p")
      start_catalog(tmp, name)

      assert {:ok, w1} = Catalog.load("stable-wt.yaml")
      :ok = Catalog.reload()
      assert {:ok, w2} = Catalog.load("stable-wt.yaml")
      assert w1.digest == w2.digest
    end
  end

  describe "AC-018-1 controller integration installs and Catalog reloads both implement-trd manifests" do
    test "POST /api/admin/workflows/install with isolated target installs both implement-trd manifests and Catalog reloads them",
         %{server_name: name} do
      home = Path.join(System.tmp_dir!(), "foreman_ac0181_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(home) end)

      # Isolated target — never the developer's ~/.foreman/workflows. The CLI's
      # empty-body contract (which resolves the real home) is covered separately
      # by `init_test.go`; this server-side test verifies the controller →
      # Installer → Catalog reload pipeline end-to-end without clobbering state.
      workflows_dir = Path.join(home, "workflows")
      File.mkdir_p!(workflows_dir)

      conn = build_conn() |> post("/api/admin/workflows/install", %{target_dir: workflows_dir})

      assert json_response(conn, 201)["status"] == "installed"

      installed_paths = json_response(conn, 201)["paths"]
      installed_names = Enum.map(installed_paths, &Path.basename/1)
      assert "implement-trd.yaml" in installed_names
      assert "implement-trd-beads.yaml" in installed_names

      assert File.regular?(Path.join(workflows_dir, "implement-trd.yaml"))
      assert File.regular?(Path.join(workflows_dir, "implement-trd-beads.yaml"))

      catalog = AssetCatalog.new(workflows_dir)
      start_supervised!({Catalog, name: name, catalog: catalog}, id: name)

      assert "implement-trd.yaml" in Catalog.manifests()
      assert "implement-trd-beads.yaml" in Catalog.manifests()

      assert {:ok, wf_trd} = Catalog.load("implement-trd.yaml")
      assert wf_trd.name == "implement-trd"
      assert is_list(wf_trd.phases)
      assert wf_trd.phases != []

      assert {:ok, wf_beads} = Catalog.load("implement-trd-beads.yaml")
      assert wf_beads.name == "implement-trd-beads"
      assert is_list(wf_beads.phases)
      assert wf_beads.phases != []
    end
  end
end
