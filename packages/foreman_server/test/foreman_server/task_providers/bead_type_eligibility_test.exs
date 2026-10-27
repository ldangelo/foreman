defmodule ForemanServer.TaskProviders.BeadTypeEligibilityTest do
  # TRD-009-TEST (REQ-008, AC-008-1, AC-008-2). The report of which bead types
  # BeadsWatcher dispatches is derived from the catalog's own `task_types:`
  # declarations and the tracker's built-in types, so these tests check two
  # things: every type lands in exactly one half, and the report follows the
  # manifests with no edit to the reporter.
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BeadTypeEligibility
  alias ForemanServer.Workflow.{AssetCatalog, Catalog, Interpreter}

  @bundled_root Application.app_dir(:foreman_server, "priv/defaults/workflows")

  describe "build/2 (the pure derivation)" do
    test "mapped is the map itself, sorted; unmapped is the tracker's types it does not name" do
      report =
        BeadTypeEligibility.build(
          %{"feature" => "prd", "bug" => "fix"},
          ["task", "bug", "feature", "epic"]
        )

      assert report.mapped == [{"bug", "fix"}, {"feature", "prd"}]
      assert report.unmapped == ["epic", "task"]
    end

    test "a custom type no tracker enumerates is mapped and never listed as unmapped" do
      report =
        BeadTypeEligibility.build(%{"implement_trd" => "implement-trd"}, ["task", "bug"])

      assert report.mapped == [{"implement_trd", "implement-trd"}]
      assert report.unmapped == ["bug", "task"]
    end

    test "every tracker type lands in exactly one half" do
      tracker_types = BeadsAdapter.task_types()
      map = %{"bug" => "fix", "docs" => "writer", "custom" => "c"}

      report = BeadTypeEligibility.build(map, tracker_types)
      mapped_types = Enum.map(report.mapped, &elem(&1, 0))

      for type <- tracker_types do
        in_mapped = type in mapped_types
        in_unmapped = type in report.unmapped

        assert in_mapped != in_unmapped,
               "#{type} must be mapped xor unmapped (mapped=#{in_mapped} unmapped=#{in_unmapped})"
      end
    end

    test "nothing mapped leaves every tracker type held; nothing held when all are mapped" do
      none = BeadTypeEligibility.build(%{}, ["task", "bug"])
      assert none.mapped == [] and none.unmapped == ["bug", "task"]

      all = BeadTypeEligibility.build(%{"task" => "t", "bug" => "b"}, ["task", "bug"])
      assert all.unmapped == []
    end
  end

  describe "summarize/1" do
    test "names each mapped type with its workflow and each held type, and says why they are held" do
      text =
        BeadTypeEligibility.summarize(%BeadTypeEligibility{
          mapped: [{"bug", "fix"}, {"feature", "prd"}],
          unmapped: ["epic", "task"]
        })

      assert text =~ "dispatched: bug -> fix, feature -> prd"
      assert text =~ "held (no workflow maps them, so a labelled bead of these types"
      assert text =~ "epic, task"
    end

    test "an empty half is said, not left blank" do
      assert BeadTypeEligibility.summarize(%BeadTypeEligibility{mapped: [], unmapped: ["task"]}) =~
               "dispatched: none"

      assert BeadTypeEligibility.summarize(%BeadTypeEligibility{
               mapped: [{"a", "b"}],
               unmapped: []
             }) =~
               "held: none"
    end
  end

  describe "report/0 against a live catalog" do
    setup do
      {:ok, _} = Application.ensure_all_started(:telemetry)

      tmp =
        Path.join(
          System.tmp_dir!(),
          "bead_type_eligibility_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp, "prompts"))

      prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
      Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

      server_name = :"bead_type_eligibility_#{System.unique_integer([:positive])}"
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

    # `skills_target_dir` keeps the catalog's boot-time skill install inside the
    # temporary root instead of the operator's real `~/.foreman/skills`.
    defp start_catalog(tmp, server_name) do
      start_supervised!(
        {Catalog,
         name: server_name,
         catalog: AssetCatalog.new(tmp),
         skills_target_dir: Path.join(tmp, "skills")},
        id: server_name
      )
    end

    defp write_manifest(tmp, name, task_types) do
      File.write!(Path.join(tmp, "prompts/p.md"), "prompt")

      File.write!(
        Path.join(tmp, "#{name}.yaml"),
        "name: #{name}\ntask_types: [#{Enum.join(task_types, ", ")}]\n" <>
          "phases:\n  - name: p1\n    prompt: p.md\n"
      )
    end

    # What the bundled manifests declare, read straight off disk through the
    # workflow parser (as bundled_workflow_models_test does), with no help from
    # the catalog or the reporter under test.
    defp bundled_declarations do
      for file <- @bundled_root |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".yaml")),
          {:ok, doc} = Interpreter.load!(Path.join(@bundled_root, file)),
          type <- doc["task_types"] || [],
          into: %{},
          do: {type, doc["name"]}
    end

    test "is complete over the bundled set: every declared type is mapped, every other tracker type is held",
         %{tmp: tmp, server_name: name} do
      # An empty root auto-installs the bundled workflows (catalog_test.exs).
      start_catalog(tmp, name)

      declared = bundled_declarations()
      assert declared != %{}, "the bundled set declares no task_types at all"

      report = BeadTypeEligibility.report()

      assert report.mapped == Enum.sort(declared)
      assert report.unmapped == (BeadsAdapter.task_types() -- Map.keys(declared)) |> Enum.sort()

      # Every tracker type is accounted for, whichever half it is in.
      accounted = Enum.map(report.mapped, &elem(&1, 0)) ++ report.unmapped

      for type <- BeadsAdapter.task_types() do
        assert type in accounted, "#{type} is in neither half of the report"
      end
    end

    test "a manifest that declares a new task_types entry changes the report with no edit to the reporter",
         %{tmp: tmp, server_name: name} do
      write_manifest(tmp, "writer", ["docs", "research"])
      start_catalog(tmp, name)

      before = BeadTypeEligibility.report()
      assert {"docs", "writer"} in before.mapped
      assert {"research", "writer"} in before.mapped
      refute "docs" in before.unmapped
      # `chore` is a tracker type no manifest names yet.
      assert "chore" in before.unmapped

      # A second manifest now maps it. The reporter is untouched; only a manifest
      # file changed, then a reload (the catalog's own hot-reload path).
      write_manifest(tmp, "housekeeping", ["chore"])
      :ok = Catalog.reload()

      after_reload = BeadTypeEligibility.report()
      assert {"chore", "housekeeping"} in after_reload.mapped
      refute "chore" in after_reload.unmapped
      assert after_reload.mapped -- before.mapped == [{"chore", "housekeeping"}]
    end

    test "agrees with the lookup BeadsWatcher dispatches by, type for type",
         %{tmp: tmp, server_name: name} do
      write_manifest(tmp, "writer", ["docs"])
      start_catalog(tmp, name)

      report = BeadTypeEligibility.report()

      for {type, workflow} <- report.mapped do
        assert {:ok, ^workflow} = Catalog.type_to_workflow(type)
      end

      for type <- report.unmapped do
        assert {:error, :unmapped_type} = Catalog.type_to_workflow(type)
      end
    end
  end
end
