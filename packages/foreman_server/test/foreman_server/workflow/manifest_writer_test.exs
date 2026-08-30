defmodule ForemanServer.Workflow.ManifestWriterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.ManifestWriter

  describe "write/1" do
    test "round-trips a minimal valid manifest" do
      manifest = %{
        "name" => "test-workflow",
        "description" => "A test workflow",
        "phases" => [
          %{"name" => "step1", "prompt" => "prompt.md"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert is_binary(yaml)
      assert yaml =~ ~r/name:\s*test-workflow/
      assert yaml =~ ~r/phases:/
      assert yaml =~ ~r/-\s+name:\s*step1/
      assert yaml =~ ~r/prompt:\s*prompt\.md/

      # Should parse back through the Interpreter
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert loaded["name"] == "test-workflow"
      assert is_list(loaded["phases"])
      assert hd(loaded["phases"])["name"] == "step1"
    end

    test "round-trips a manifest with all allowed phase properties" do
      manifest = %{
        "name" => "full-workflow",
        "description" => "Full featured",
        "phases" => [
          %{
            "name" => "plan",
            "prompt" => "plan.md",
            "models" => %{"default" => "MiniMax", "coder" => "Claude"},
            "mail" => %{"onStart" => true, "onComplete" => false},
            "maxTurns" => 50,
            "artifact" => "{task.projectReportsDir}/report.md"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert loaded["name"] == "full-workflow"

      phase = hd(loaded["phases"])
      assert phase["models"] == %{"default" => "MiniMax", "coder" => "Claude"}
      assert phase["mail"] == %{"onStart" => true, "onComplete" => false}
    end

    test "round-trips a multi-phase manifest" do
      manifest = %{
        "name" => "multi",
        "description" => "Two phases",
        "phases" => [
          %{"name" => "phase1", "prompt" => "p1.md"},
          %{"name" => "phase2", "command" => "/bin/echo hello"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert length(loaded["phases"]) == 2
    end

    test "emits phases: at indent 0" do
      manifest = %{"name" => "x", "phases" => [%{"name" => "a", "prompt" => "a.md"}]}
      assert {:ok, yaml} = ManifestWriter.write(manifest)
      lines = String.split(yaml, "\n")
      assert Enum.any?(lines, fn l -> l =~ ~r/^phases:/ end)
    end

    test "emits phase entries at indent 2" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => "a.md"},
          %{"name" => "b", "prompt" => "b.md"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      lines = String.split(yaml, "\n")
      name_lines = Enum.filter(lines, fn l -> l =~ ~r/^\s+-\s+name:/ end)
      assert length(name_lines) == 2
    end

    test "emits properties at indent 4" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md", "maxTurns" => 10}]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      lines = String.split(yaml, "\n")
      prompt_lines = Enum.filter(lines, fn l -> l =~ ~r/^\s{4}prompt:/ end)
      assert length(prompt_lines) == 1
    end

    test "emits nested maps at indent 6" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => "a.md", "models" => %{"default" => "X"}}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      lines = String.split(yaml, "\n")
      model_lines = Enum.filter(lines, fn l -> l =~ ~r/^\s{4}models:/ end)
      default_lines = Enum.filter(lines, fn l -> l =~ ~r/^\s{6}default:/ end)
      assert length(model_lines) == 1
      assert length(default_lines) == 1
    end

    test "boolean values are emitted as plain true/false" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => "a.md", "mail" => %{"onComplete" => true}}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ ~r/onComplete:\s*true/
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert get_in(loaded, ["phases", Access.at(0), "mail", "onComplete"]) == true
    end

    test "integer values are emitted without quotes" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md", "maxTurns" => 80}]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ ~r/maxTurns:\s*80/
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert loaded["phases"] |> hd() |> Map.get("maxTurns") == 80
    end

    test "rejects a manifest with a list-valued phase property" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => "a.md", "bad_list" => ["a", "b"]}
        ]
      }

      assert {:error, {:unsupported_construct, {:list_at_phase_property, "bad_list"}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a manifest with a deeply-nested map (beyond indent 6)" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{
            "name" => "a",
            "prompt" => "a.md",
            "deep" => %{"level1" => %{"level2" => "value"}}
          }
        ]
      }

      assert {:error, {:unsupported_construct, {:deep_nesting, "deep"}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a manifest with a top-level list (not phases)" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md"}],
        "tags" => ["tag1", "tag2"]
      }

      assert {:error, {:unsupported_construct, {:top_level_list, "tags"}}} =
               ManifestWriter.write(manifest)
    end

    # This premise is obsolete, not merely misplaced. A top-level mapping is
    # LEGAL now — the workflow-level `worktree:` block is one — so the writer
    # accepts one nesting level and emits it. Only deeper nesting is rejected,
    # symmetric with the phase-property rule, because the root parser
    # (`Interpreter.parse_root_entries/3`) reads exactly one level.
    test "accepts and emits a map at top level beyond name/description/phases" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md"}],
        "metadata" => %{"key" => "value"}
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ "metadata:"
      assert yaml =~ "  key: value"
    end

    test "rejects a top-level map nested more than one level deep" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md"}],
        "metadata" => %{"key" => %{"deeper" => "value"}}
      }

      assert {:error, {:unsupported_construct, {:deep_nesting, "metadata"}}} =
               ManifestWriter.write(manifest)
    end

    # A top-level scalar used to pass validation and then be dropped by
    # `build_yaml/1`, so `write/1` reported success having lost data. Every
    # bundled manifest carries `operator_timeout_ms`.
    test "emits top-level scalars instead of silently dropping them" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md"}],
        "operator_timeout_ms" => 300_000
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ "operator_timeout_ms: 300000"
    end

    test "rejects a manifest missing required name key" do
      manifest = %{"phases" => [%{"name" => "a", "prompt" => "a.md"}]}

      assert {:error, {:unsupported_construct, {:missing_required, "name"}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a manifest missing required phases key" do
      manifest = %{"name" => "x"}

      assert {:error, {:unsupported_construct, {:missing_required, "phases"}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a phase entry that is not a map" do
      manifest = %{"name" => "x", "phases" => ["not a map"]}

      assert {:error, {:unsupported_construct, {:phase_not_map, 0}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a phase entry missing required name" do
      manifest = %{"name" => "x", "phases" => [%{"prompt" => "a.md"}]}

      assert {:error, {:unsupported_construct, {:phase_missing_name, 0}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a phase with an action that is a list" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => ["a.md", "b.md"]}]
      }

      assert {:error, {:unsupported_construct, {:list_at_phase_property, "prompt"}}} =
               ManifestWriter.write(manifest)
    end

    test "rejects a phase with an empty name" do
      manifest = %{"name" => "x", "phases" => [%{"name" => "", "prompt" => "a.md"}]}

      assert {:error, {:unsupported_construct, {:phase_empty_name, 0}}} =
               ManifestWriter.write(manifest)
    end

    test "round-trips bash phase" do
      manifest = %{
        "name" => "bash-workflow",
        "phases" => [
          %{"name" => "build", "bash" => "mix format"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert hd(loaded["phases"])["bash"] == "mix format"
    end

    test "round-trips command phase" do
      manifest = %{
        "name" => "cmd-workflow",
        "phases" => [
          %{"name" => "run", "command" => "/usr/bin/python test.py"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert hd(loaded["phases"])["command"] == "/usr/bin/python test.py"
    end

    test "rejects a phase with both prompt and command (list value)" do
      # This is about a list value in a phase property, not multiple properties
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => ["a.md", "b.md"]}
        ]
      }

      assert {:error, {:unsupported_construct, {:list_at_phase_property, "prompt"}}} =
               ManifestWriter.write(manifest)
    end
  end

  defp write_temp_yaml!(contents) do
    directory =
      Path.join(System.tmp_dir!(), "manifest-writer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    path = Path.join(directory, "workflow.yaml")
    File.write!(path, contents)
    path
  end
end
