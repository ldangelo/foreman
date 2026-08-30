defmodule ForemanServer.Workflow.PhaseSpecTest do
  @moduledoc """
  Pins the normalization contract that lets every consumer read atom keys.

  The bug these tests defend against: a phase reaches the executor either fresh
  from `Workflow.Catalog` (hybrid — both `"command"` and `:command`) or replayed
  out of a JSON-serialized `workflow_snapshot` (string keys only). Consumers
  compensated per read with `Map.get(spec, :k) || Map.get(spec, "k")`. If
  normalization silently drops a field or returns the wrong convention, those
  reads now return `nil` instead of falling back, so the field must be covered.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PhaseSpec

  @canonical_keys [
    :action,
    :artifact_template,
    :bash,
    :command,
    :context,
    :index,
    :mail,
    :max_turns,
    :models,
    :name,
    :prompt,
    :prompt_path,
    :required_file
  ]

  describe "both key conventions converge" do
    test "a string-keyed (replayed) phase and its atom-keyed twin normalize identically" do
      string_keyed = %{
        "name" => "implement",
        "command" => "/skill:do-it",
        "index" => 1,
        "artifact" => "REPORT.md",
        "requiredFile" => "docs/TRD/x.md",
        "maxTurns" => 40
      }

      atom_keyed = %{
        name: "implement",
        command: "/skill:do-it",
        index: 1,
        artifact_template: "REPORT.md",
        required_file: "docs/TRD/x.md",
        max_turns: 40
      }

      assert PhaseSpec.normalize(string_keyed) == PhaseSpec.normalize(atom_keyed)
    end

    test "a hybrid Catalog phase resolves without the duplicate key disagreeing" do
      # Catalog does `Map.put(:command, phase["command"])`, so both exist.
      hybrid = %{"name" => "implement", "command" => "/skill:go", :command => "/skill:go"}

      assert PhaseSpec.normalize(hybrid)[:command] == "/skill:go"
    end

    test "camelCase YAML keys map onto their snake_case canonical names" do
      spec = PhaseSpec.normalize(%{"requiredFile" => "a.md", "maxTurns" => 12, "artifact" => "b"})

      assert spec[:required_file] == "a.md"
      assert spec[:max_turns] == 12
      assert spec[:artifact_template] == "b"
    end
  end

  describe "canonical output shape" do
    test "every canonical key is present even when the phase declares almost nothing" do
      spec = PhaseSpec.normalize(%{"name" => "bare"})

      assert Enum.sort(Map.keys(spec)) == @canonical_keys
    end

    test "no string keys survive normalization" do
      spec = PhaseSpec.normalize(%{"name" => "x", "command" => "y", "unknown" => "z"})

      assert Enum.all?(Map.keys(spec), &is_atom/1)
    end

    test "normalize_all preserves phase order" do
      specs =
        PhaseSpec.normalize_all([
          %{"name" => "first"},
          %{"name" => "second"},
          %{"name" => "third"}
        ])

      assert Enum.map(specs, & &1[:name]) == ["first", "second", "third"]
    end
  end

  describe "action is derived, never trusted" do
    test "a command phase is :command" do
      assert PhaseSpec.normalize(%{"command" => "/skill:go"})[:action] == :command
    end

    test "a bash phase is :bash" do
      assert PhaseSpec.normalize(%{"bash" => "echo hi"})[:action] == :bash
    end

    test "a phase with neither is :prompt" do
      assert PhaseSpec.normalize(%{"prompt" => "implement.md"})[:action] == :prompt
    end

    test "an empty-string command does not count as a command" do
      assert PhaseSpec.normalize(%{"command" => "", "prompt" => "p.md"})[:action] == :prompt
    end

    test "a stale inbound :action that contradicts the fields is overridden" do
      # A replayed snapshot could carry an action that no longer matches.
      spec = PhaseSpec.normalize(%{"bash" => "echo hi", "action" => "prompt"})

      assert spec[:action] == :bash
    end
  end

  # The `worktree:` block moved to the workflow level; its normalization and
  # tests live in `ForemanServer.Workflow.WorktreeSpecTest`.
  describe "worktree is not a phase field" do
    test "a declared phase-level worktree block is dropped" do
      spec =
        PhaseSpec.normalize(%{
          "name" => "x",
          "worktree" => %{"enabled" => true, "cleanup" => "never"}
        })

      refute Map.has_key?(spec, :worktree)
      assert spec[:name] == "x"
    end
  end

  describe "atom safety" do
    test "unrecognized keys are dropped rather than minting atoms" do
      spec = PhaseSpec.normalize(%{"name" => "x", "totallyNovelKeyNeverSeenBefore" => "v"})

      refute Enum.any?(Map.keys(spec), &(Atom.to_string(&1) =~ "totallyNovel"))
    end
  end
end
