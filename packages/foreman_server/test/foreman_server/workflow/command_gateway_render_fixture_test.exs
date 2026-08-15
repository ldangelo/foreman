defmodule ForemanServer.Workflow.CommandGatewayRenderFixtureTest do
  # TRD-018 regression fixture: verify that CommandGateway.render_strict_fields/1
  # produces the same output for all bundled manifests with command: phases.
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.{Catalog, AssetCatalog}

  @fixture_path Path.join([
    __DIR__,
    "../../fixtures/foreman_server/command_rendering_fixtures.json"
  ])

  setup do
    # Start an isolated Catalog with the bundled manifests.
    server_name = :"render_fixture_catalog_#{System.unique_integer([:positive])}"
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

    {:ok, _} = start_supervised({Catalog, name: server_name}, id: server_name)
    :timer.sleep(100)

    # Use string keys to avoid needing pre-existing atoms
    fixture = Jason.decode!(File.read!(@fixture_path), keys: :strings)

    on_exit(fn ->
      if prev_server,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
        else: Application.delete_env(:foreman_server, :workflow_catalog)
    end)

    {:ok, fixture: fixture, server_name: server_name}
  end

  describe "TRD-018 regression: command-phase rendering fixtures" do
    test "plan.yaml command phases pass through unchanged (no implementation context)", %{
      fixture: fixture
    } do
      manifest_name = "plan.yaml"
      entry = fixture["manifests"][manifest_name]

      assert length(entry["command_phases"]) == 2

      for cp <- entry["command_phases"] do
        assert cp["original_command"] == cp["rendered_command"],
               "#{cp["phase_name"]}: command should not be substituted (no implementation context)"
      end
    end

    test "implement-trd.yaml command is rendered with implementation context", %{
      fixture: fixture
    } do
      manifest_name = "implement-trd.yaml"
      entry = fixture["manifests"][manifest_name]

      assert length(entry["command_phases"]) == 1
      [cp] = entry["command_phases"]

      # Placeholder should be substituted
      refute cp["original_command"] == cp["rendered_command"],
             "implement-trd command should have {{implementation.trd_path_argument}} substituted"

      # Rendered command should have the JSON-encoded trd_path
      trd_path_arg = entry["snapshot"]["implementation"]["trd_path_argument"]
      assert cp["rendered_command"] =~ trd_path_arg,
             "rendered command should contain trd_path_argument: #{trd_path_arg}"

      # No un-substituted placeholders remain
      refute cp["rendered_command"] =~ "{{implementation",
             "rendered command should not contain double-brace placeholders"
      refute cp["rendered_command"] =~ "{trd_path_argument}",
             "rendered command should not contain legacy placeholder"
    end

    test "implement-trd-beads.yaml command is rendered with implementation context", %{
      fixture: fixture
    } do
      manifest_name = "implement-trd-beads.yaml"
      entry = fixture["manifests"][manifest_name]

      assert length(entry["command_phases"]) == 1
      [cp] = entry["command_phases"]

      refute cp["original_command"] == cp["rendered_command"],
             "implement-trd-beads command should have placeholders substituted"

      trd_path_arg = entry["snapshot"]["implementation"]["trd_path_argument"]
      assert cp["rendered_command"] =~ trd_path_arg

      refute cp["rendered_command"] =~ "{{implementation",
             "no double-brace placeholders in rendered command"
      refute cp["rendered_command"] =~ "{trd_path_argument}",
             "no legacy placeholder in rendered command"
    end

    test "worktree.base is rendered with source_revision in implement-trd variants", %{
      fixture: fixture
    } do
      for manifest_name <- ["implement-trd.yaml", "implement-trd-beads.yaml"] do
        entry = fixture["manifests"][manifest_name]
        impl = entry["snapshot"]["implementation"]
        [phase] = entry["snapshot"]["phases"]

        assert phase["worktree"]["base"] == impl["source_revision"],
               "#{manifest_name}: worktree.base should equal source_revision"
        refute phase["worktree"]["base"] =~ "{{implementation",
               "#{manifest_name}: no unsubstituted placeholders in worktree.base"
      end
    end

    test "rendered snapshot survives JSON round-trip (structural regression)", %{
      fixture: fixture
    } do
      for {manifest_name, entry} <- fixture["manifests"] do
        snapshot_json = Jason.encode!(entry["snapshot"])
        decoded = Jason.decode!(snapshot_json, keys: :strings)

        # The decoded snapshot's phases must have string keys (the canonical persisted form).
        # Atom twins should not appear after round-trip.
        for phase <- decoded["phases"] do
          refute Map.has_key?(phase, :command),
                 "#{manifest_name}: phase should not have atom :command key after JSON round-trip"
          assert is_binary(phase["command"]),
                 "#{manifest_name}: phase.command should be a binary string"
        end

        # JSON round-trip must be identity
        assert Jason.decode!(Jason.encode!(decoded)) == decoded,
               "#{manifest_name}: snapshot should survive JSON round-trip"
      end
    end

    test "fixture metadata is present and valid", %{fixture: fixture} do
      meta = fixture["metadata"]
      assert is_binary(meta["git_sha"])
      assert byte_size(meta["git_sha"]) == 40, "git_sha should be a 40-char SHA"
      assert is_binary(meta["project_root"])
      assert is_binary(meta["captured_at"])
      assert is_binary(meta["description"])
    end
  end
end
