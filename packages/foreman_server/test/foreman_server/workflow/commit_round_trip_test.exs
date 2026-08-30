defmodule ForemanServer.Workflow.CommitRoundTripTest do
  @moduledoc """
  Pins REQ-009: a phase's `commit:` value survives every hop between the
  manifest on disk and the executor's read.

  The value crosses three boundaries, and each one has independently lost it
  before: the hand-rolled YAML parse (`Interpreter`), the JSON serialization the
  run record performs on `workflow_snapshot`, and `PhaseSpec.normalize/1`. A
  boolean that degrades to the STRING "false" anywhere along that path is the
  worst possible outcome, because every downstream read of `"false"` is truthy —
  the phase would commit while the manifest says it defers, with no error.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.{Interpreter, ManifestWriter, PhaseSpec, RunExecutor}

  @bundled Path.wildcard(Path.join(:code.priv_dir(:foreman_server), "defaults/workflows/*.yaml"))

  defp temp_yaml!(body) do
    dir = Path.join(System.tmp_dir!(), "commit-round-trip-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "workflow.yaml")
    File.write!(path, body)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp manifest(phases) do
    body =
      phases
      |> Enum.map(fn {name, extra} ->
        "  - name: #{name}\n    command: \"/skill:s-#{name}\"\n#{extra}"
      end)
      |> Enum.join()

    temp_yaml!("name: rt\ndescription: d\nphases:\n" <> body)
  end

  describe "JSON snapshot round-trip" do
    test "commit: false survives as boolean false, not the string \"false\"" do
      path = manifest([{"a", "    commit: false\n"}, {"b", "    commit: true\n"}])
      assert {:ok, workflow} = Interpreter.load!(path)

      # Exactly what the run record does to workflow_snapshot.
      replayed = workflow |> Jason.encode!() |> Jason.decode!()

      [deferring, committing] = replayed["phases"]
      assert deferring["commit"] === false
      refute deferring["commit"] == "false"
      assert committing["commit"] === true

      # And the value the executor actually reads, after normalization.
      refute RunExecutor.__phase_commits_for_test__(PhaseSpec.normalize(deferring))
      assert RunExecutor.__phase_commits_for_test__(PhaseSpec.normalize(committing))
    end

    test "an absent commit key stays absent across the round-trip" do
      # Absent must not be backfilled at any hop. If serialization synthesized
      # `commit: true`, "declared nothing" and "declared the default" would
      # become indistinguishable — and REQ-002's default would no longer be
      # changeable in one place.
      path = manifest([{"a", ""}])
      assert {:ok, workflow} = Interpreter.load!(path)

      replayed = workflow |> Jason.encode!() |> Jason.decode!()
      phase = hd(replayed["phases"])

      refute Map.has_key?(phase, "commit")
      spec = PhaseSpec.normalize(phase)
      refute Map.has_key?(spec, :commit)
      assert RunExecutor.__phase_commits_for_test__(spec)
    end
  end

  describe "ManifestWriter round-trip" do
    test "every bundled manifest preserves each phase's commit value" do
      # Includes phases where `commit:` is ABSENT: the writer must not invent a
      # key, and the re-read must not invent a value. Guards the
      # `foreman_workflow_put` path, which serializes a manifest object back to
      # YAML — a writer that dropped or coerced `commit:` would silently rewrite
      # an operator's committing phase into a deferring one, or the reverse.
      assert length(@bundled) == 11

      for source <- @bundled do
        assert {:ok, original} = Interpreter.load!(source)
        assert {:ok, yaml} = ManifestWriter.write(original)

        written = temp_yaml!(yaml)
        assert {:ok, reloaded} = Interpreter.load!(written)

        expected = Enum.map(original["phases"], &Map.get(&1, "commit", :absent))
        actual = Enum.map(reloaded["phases"], &Map.get(&1, "commit", :absent))

        assert expected == actual,
               "#{Path.basename(source)}: commit values changed across write/read — " <>
                 "#{inspect(expected)} became #{inspect(actual)}"
      end
    end

    test "an explicit commit: false survives the writer" do
      path = manifest([{"a", "    commit: false\n"}, {"b", "    commit: true\n"}])
      assert {:ok, original} = Interpreter.load!(path)
      assert {:ok, yaml} = ManifestWriter.write(original)

      assert {:ok, reloaded} = Interpreter.load!(temp_yaml!(yaml))
      assert Enum.map(reloaded["phases"], & &1["commit"]) == [false, true]
    end
  end
end
