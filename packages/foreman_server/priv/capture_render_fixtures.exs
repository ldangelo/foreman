# Capture freeze-time rendering fixtures for bundled manifests with command phases.
# Run: cd packages/foreman_server && mix run priv/capture_render_fixtures.exs

defmodule CaptureFixtures do
  alias ForemanServer.Workflow.{Catalog, AssetCatalog}

  def run do
    # Start the Catalog with bundled manifests (no external registry needed).
    catalog_name = String.to_atom("fixture_catalog_#{System.unique_integer([:positive])}")
    Application.put_env(:foreman_server, :workflow_catalog, catalog_name)

    {:ok, _} = GenServer.start_link(Catalog, [catalog: AssetCatalog.default()], name: catalog_name)
    :timer.sleep(300)

    # Get current git SHA as source_revision
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"], cd: Path.expand("../../", __DIR__))
    root = String.trim(root)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    source_revision = String.trim(sha)

    # Identify manifests that have command phases
    all_manifests = Catalog.manifests()
    IO.puts("All manifests: #{inspect(all_manifests)}")

    manifests_with_commands =
      all_manifests
      |> Enum.map(fn filename ->
        {:ok, wf} = Catalog.load(filename)
        command_phases =
          wf.phases
          |> Enum.filter(fn phase ->
            (is_binary(phase["command"]) and phase["command"] != "") or
              (is_binary(phase.command) and phase.command != "")
          end)
        %{filename: filename, workflow: wf, command_phases: command_phases}
      end)
      |> Enum.filter(fn m -> length(m.command_phases) > 0 end)

    IO.puts("\nFound #{length(manifests_with_commands)} manifests with command phases:")
    Enum.each(manifests_with_commands, fn m ->
      IO.puts("  #{m.filename}: #{length(m.command_phases)} command phase(s)")
    end)

    # Capture fixture for each manifest
    fixtures_list = for %{filename: filename, workflow: wf, command_phases: command_phases} <- manifests_with_commands do
      # Build a clean snapshot (strip internal fields; wf is a plain map, not a struct)
      snapshot = Map.drop(wf, [:__struct__, :manifest_path])

      # For implement-trd* workflows, add implementation context
      needs_impl = filename in ["implement-trd.yaml", "implement-trd-beads.yaml"]

      final_snapshot = if needs_impl do
        impl_context = %{
          "trd_path" => "docs/TRD-018.md",
          "trd_path_argument" => Jason.encode!("docs/TRD-018.md"),
          "project_root" => root,
          "source_revision" => source_revision,
          "implementation_key" => compute_impl_key("foreman-test-project", "docs/TRD-018.md")
        }
        Map.put(snapshot, "implementation", impl_context)
      else
        snapshot
      end

      # Apply render_strict_fields logic
      rendered = case get_val(final_snapshot, "implementation") do
        nil ->
          final_snapshot
        impl when is_map(impl) ->
          phases = get_val(final_snapshot, :phases) || get_val(final_snapshot, "phases") || []
          rendered_phases = Enum.map(phases, fn phase -> render_phase(phase, impl) end)
          final_snapshot
          |> Map.delete(:phases)
          |> Map.put("phases", rendered_phases)
      end

      rendered_phases = get_val(rendered, "phases") || get_val(rendered, :phases) || []

      IO.puts("\n--- #{filename} ---")
      IO.puts("  implementation present: #{needs_impl}")
      IO.puts("  source_revision: #{source_revision}")

      command_phase_summaries = for cp <- command_phases do
        orig_name = get_val(cp, :name) || get_val(cp, "name") || "unknown"
        cmd = get_val(cp, "command") || get_val(cp, :command) || ""
        rendered_cmd = case Enum.find(rendered_phases, fn rp -> get_val(rp, :name) == orig_name or get_val(rp, "name") == orig_name end) do
          nil -> cmd
          rp -> get_val(rp, "command") || get_val(rp, :command) || cmd
        end
        IO.puts("  phase: #{orig_name}")
        IO.puts("    original:  #{cmd}")
        IO.puts("    rendered:  #{rendered_cmd}")
        %{
          "phase_name" => orig_name,
          "original_command" => cmd,
          "rendered_command" => rendered_cmd
        }
      end

      # Serialize phases to JSON-friendly format: convert atom keys to string keys
      serialized_phases = for phase <- rendered_phases do
        for {k, v} <- phase, into: %{} do
          {to_string(k), v}
        end
      end

      serialized_snapshot = for {k, v} <- rendered, into: %{} do
        {to_string(k), v}
      end
      serialized_snapshot = Map.put(serialized_snapshot, "phases", serialized_phases)

      {filename, %{
        "command_phases" => command_phase_summaries,
        "snapshot" => serialized_snapshot
      }}
    end

    fixtures = Map.new(fixtures_list)

    # Write fixture file
    fixture_content = %{
      "metadata" => %{
        "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "git_sha" => source_revision,
        "project_root" => root,
        "description" => "Freeze-time rendering regression fixtures for bundled manifests with command phases. See TRD-018."
      },
      "manifests" => fixtures
    }

    json = Jason.encode!(fixture_content, pretty: true)
    fixture_path = Path.expand("../test/fixtures/foreman_server/command_rendering_fixtures.json", __DIR__)
    File.mkdir_p!(Path.dirname(fixture_path))
    File.write!(fixture_path, json)
    IO.puts("\nFixture written to: #{fixture_path}")
    IO.puts("Done.")
  end

  # Helper: get value from map with atom or string key
  defp get_val(map, key) when is_map(map), do: Map.get(map, key)

  # Substitution (mirrors CommandGateway.substitute/3)
  defp substitute(string, _placeholder, nil), do: string
  defp substitute(string, _placeholder, ""), do: string
  defp substitute(string, placeholder, value) when is_binary(string) and is_binary(placeholder) and is_binary(value) do
    String.replace(string, placeholder, value)
  end

  # Compute implementation_key from project_id and trd_path
  defp compute_impl_key(project_id, trd_path) do
    digest =
      :crypto.hash(:sha256, "#{project_id}\0#{trd_path}")
      |> Base.encode16(case: :lower)
    digest
  end

  # Render a single phase using the implementation context
  defp render_phase(phase, impl) do
    # render_command
    template = get_val(phase, "command") || get_val(phase, :command)
    rendered_phase = case template do
      value when is_binary(value) ->
        rendered =
          value
          |> substitute("{{implementation.trd_path_argument}}", get_val(impl, "trd_path_argument"))
          |> substitute("{{implementation.source_revision}}", get_val(impl, "source_revision"))
        phase
        |> Map.delete(:command)
        |> Map.put("command", rendered)
      _ ->
        phase
    end

    # render_worktree_base
    worktree = get_val(rendered_phase, "worktree") || get_val(rendered_phase, :worktree)
    case worktree do
      block when is_map(block) ->
        base = get_val(block, "base") || get_val(block, :base)
        case base do
          value when is_binary(value) ->
            rendered_base =
              substitute(value, "{{implementation.source_revision}}", get_val(impl, "source_revision"))
            rendered_worktree =
              block
              |> Map.delete(:base)
              |> Map.put("base", rendered_base)
            rendered_phase
            |> Map.delete(:worktree)
            |> Map.put("worktree", rendered_worktree)
          _ ->
            rendered_phase
        end
      _ ->
        rendered_phase
    end
  end
end

CaptureFixtures.run()
