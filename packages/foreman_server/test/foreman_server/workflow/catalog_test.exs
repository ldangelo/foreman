defmodule ForemanServer.Workflow.CatalogTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog

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
      assert "assess.yaml" in Catalog.manifests()
      assert "assess.md" in Catalog.prompt_filenames()
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

      assert {:ok, wf} = Catalog.load("assess.yaml")
      assert wf.name == "assess"
      assert is_list(wf.phases)
    end

    test "returns {:error, {:workflow_not_loaded, filename}} for missing filenames",
         %{tmp: tmp, server_name: name} do
      start_catalog(tmp, name)

      assert {:error, {:workflow_not_loaded, "missing.yaml"}} =
               Catalog.load("missing.yaml")
    end
  end

  describe "command: phases with requiredFile" do
    test "loading a manifest with command phases yields requiredFile gates", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(Path.join(tmp, "prompts/noop.md"), "noop")

      File.write!(
        Path.join(tmp, "plan-test.yaml"),
        """
        name: plan-test
        phases:
          - name: create-prd
            command: "/skill:ensemble-full-create-prd --foreman"
            requiredFile: planning.prd_path
          - name: create-trd
            command: "/skill:ensemble-full-create-trd-foreman --foreman"
            requiredFile: planning.trd_path
        """
      )

      start_catalog(tmp, name)

      assert {:ok, wf} = Catalog.load("plan-test.yaml")
      assert wf.name == "plan-test"
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
    test "loading fix.yaml yields the fix phase followed by the two review phases", %{
      tmp: tmp,
      server_name: name
    } do
      start_catalog(tmp, name)

      assert {:ok, wf} = Catalog.load("fix.yaml")
      assert wf.name == "fix"
      assert is_list(wf.phases)
      assert length(wf.phases) == 3

      [fix_phase, coderabbit_phase, repo_rules_phase] = wf.phases

      assert fix_phase["name"] == "fix"
      assert fix_phase.action == :command
      assert fix_phase.command == "/skill:ensemble-fix-issue {{input.prompt}} --foreman"
      # The fix phase itself declares no routing requirement.
      assert fix_phase.required_file in [nil, ""]

      assert coderabbit_phase["name"] == "coderabbit-review"
      assert repo_rules_phase["name"] == "repo-rules-review"
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

  describe "AC-018-1 controller integration installs and Catalog reloads bundled manifests" do
    test "POST /api/admin/workflows/install with isolated target installs the fix and prd manifests and Catalog reloads them",
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
      assert "fix.yaml" in installed_names
      assert "prd.yaml" in installed_names

      assert File.regular?(Path.join(workflows_dir, "fix.yaml"))
      assert File.regular?(Path.join(workflows_dir, "prd.yaml"))

      catalog = AssetCatalog.new(workflows_dir)
      start_supervised!({Catalog, name: name, catalog: catalog}, id: name)

      assert "fix.yaml" in Catalog.manifests()
      assert "prd.yaml" in Catalog.manifests()

      assert {:ok, wf_fix} = Catalog.load("fix.yaml")
      assert wf_fix.name == "fix"
      assert is_list(wf_fix.phases)
      assert wf_fix.phases != []

      assert {:ok, wf_prd} = Catalog.load("prd.yaml")
      assert wf_prd.name == "prd"
      assert is_list(wf_prd.phases)
      assert wf_prd.phases != []
    end
  end

  describe "AC-001-1: Collision detection for task_types" do
    test "raises ArgumentError when two workflows declare the same task_type", %{
      tmp: tmp,
      server_name: name
    } do
      # Create first workflow with task_type
      File.write!(
        Path.join(tmp, "prompts/p.md"),
        "prompt"
      )

      File.write!(
        Path.join(tmp, "workflow1.yaml"),
        "name: workflow1\ntask_types: [foreman_type_a]\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      # Create second workflow with same task_type
      File.write!(
        Path.join(tmp, "workflow2.yaml"),
        "name: workflow2\ntask_types: [foreman_type_a]\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      # `start_supervised!/2` wraps an `init/1` crash as `RuntimeError`
      # ("failed to start child ... Reason: an exception was raised: **
      # (ArgumentError) ..."), so the raw `ArgumentError` never propagates
      # to the caller — assert on the wrapper, matching the underlying
      # message via the regex.
      assert_raise(RuntimeError, ~r/workflow collision.*foreman_type_a/, fn ->
        start_catalog(tmp, name)
      end)
    end
  end

  describe "AC-001-2: Omitted task_types field handling" do
    test "workflow without task_types field loads without error", %{
      tmp: tmp,
      server_name: name
    } do
      # Create workflow without task_types
      File.write!(
        Path.join(tmp, "prompts/p.md"),
        "prompt"
      )

      File.write!(
        Path.join(tmp, "no_types.yaml"),
        "name: no_types\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      # This should start without errors
      start_catalog(tmp, name)

      # Verify it loaded
      assert "no_types.yaml" in Catalog.manifests()
      assert {:ok, wf} = Catalog.load("no_types.yaml")
      assert wf.name == "no_types"
    end

    test "workflow with empty task_types array loads without error", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(
        Path.join(tmp, "prompts/p.md"),
        "prompt"
      )

      File.write!(
        Path.join(tmp, "empty_types.yaml"),
        "name: empty_types\ntask_types: []\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      start_catalog(tmp, name)

      assert "empty_types.yaml" in Catalog.manifests()
      assert {:ok, wf} = Catalog.load("empty_types.yaml")
      assert wf.name == "empty_types"
    end
  end

  describe "AC-001-3: Hot-reload and fan-in for task_types" do
    test "hot-reload rebuilds type_to_workflow map when manifest changes", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(Path.join(tmp, "prompts/p.md"), "prompt")

      # Create workflow with one type
      File.write!(
        Path.join(tmp, "dynamic.yaml"),
        "name: dynamic\ntask_types: [type_v1]\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      start_catalog(tmp, name)

      # Verify initial mapping
      assert {:ok, "dynamic"} == Catalog.type_to_workflow("type_v1")

      # Modify the manifest to change the type
      File.write!(
        Path.join(tmp, "dynamic.yaml"),
        "name: dynamic\ntask_types: [type_v2]\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      # Trigger reload
      Catalog.reload()

      # Old type should no longer map
      assert {:error, :unmapped_type} == Catalog.type_to_workflow("type_v1")
      # New type should map
      assert {:ok, "dynamic"} == Catalog.type_to_workflow("type_v2")
    end

    test "multiple types in one workflow all map to that workflow (fan-in)", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(Path.join(tmp, "prompts/p.md"), "prompt")

      File.write!(
        Path.join(tmp, "multi.yaml"),
        "name: multi\ntask_types: [type_a, type_b, type_c]\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      start_catalog(tmp, name)

      # All three types should map to the same workflow
      assert {:ok, "multi"} == Catalog.type_to_workflow("type_a")
      assert {:ok, "multi"} == Catalog.type_to_workflow("type_b")
      assert {:ok, "multi"} == Catalog.type_to_workflow("type_c")
    end
  end

  describe "TRD-003: Catalog.doctor type coverage report" do
    test "doctor returns coverage report with type_to_workflow map", %{
      tmp: tmp,
      server_name: name
    } do
      File.write!(Path.join(tmp, "prompts/p.md"), "prompt")

      File.write!(
        Path.join(tmp, "w1.yaml"),
        "name: w1\ntask_types: [type_a, type_b]\nphases:\n  - name: p1\n    prompt: p.md\n"
      )

      start_catalog(tmp, name)

      # Verify type_to_workflow_map works
      type_map = Catalog.type_to_workflow_map()
      assert type_map["type_a"] == "w1"
      assert type_map["type_b"] == "w1"
    end
  end
end
