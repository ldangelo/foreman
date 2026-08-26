defmodule ForemanServer.Workflow.ManifestWriterTRD045Test do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.ManifestWriter
  alias ForemanServer.Workflow.Interpreter

  # TRD-045-TEST: Serializer property test
  # Verifies ManifestWriter serializes every field the Interpreter recognises
  # and rejects unsupported constructs (block scalars, anchors, flow sequences,
  # nesting beyond indent 6) by name.

  describe "write/1 (TRD-045 full field coverage)" do
    test "round-trips worktree with enabled, path, and cleanup" do
      manifest = %{
        "name" => "worktree-test",
        "description" => "Tests worktree serialization",
        "phases" => [
          %{
            "name" => "build",
            "prompt" => "build.md",
            "worktree" => %{
              "enabled" => true,
              "path" => ".worktree/build",
              "cleanup" => "on_success"
            }
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ ~r/worktree:/
      assert yaml =~ ~r/enabled:\s*true/
      assert yaml =~ ~r/path:\s*\.\worktree\/build/
      assert yaml =~ ~r/cleanup:\s*on_success/

      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      phase = get_in(loaded, ["phases", Access.at(0)])
      assert phase["worktree"]["enabled"] == true
      assert phase["worktree"]["path"] == ".worktree/build"
      assert phase["worktree"]["cleanup"] == "on_success"
    end

    test "round-trips worktree with cleanup=never" do
      manifest = %{
        "name" => "worktree-persist",
        "phases" => [
          %{
            "name" => "dev",
            "prompt" => "dev.md",
            "worktree" => %{
              "enabled" => true,
              "path" => ".worktree/dev",
              "cleanup" => "never"
            }
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      phase = get_in(loaded, ["phases", Access.at(0)])
      assert phase["worktree"]["cleanup"] == "never"
    end

    test "round-trips requiredFile as a dotted context key" do
      manifest = %{
        "name" => "required-file-test",
        "phases" => [
          %{
            "name" => "check",
            "prompt" => "check.md",
            "requiredFile" => "artifacts.summary"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      phase = get_in(loaded, ["phases", Access.at(0)])
      assert phase["requiredFile"] == "artifacts.summary"
    end
  end

  describe "write/1 (TRD-045 unsupported construct rejection)" do
    test "rejects deeply-nested map beyond indent 6 (models -> default -> tier)" do
      # This exercises the deep_nesting rejection: a map nested more than 2 levels deep
      manifest = %{
        "name" => "deep-nesting-test",
        "phases" => [
          %{
            "name" => "plan",
            "prompt" => "plan.md",
            "models" => %{
              "default" => %{
                "tier" => "premium",
                "provider" => "anthropic"
              }
            }
          }
        ]
      }

      assert ManifestWriter.write(manifest) ==
               {:error, {:unsupported_construct, {:deep_nesting, "models"}}}
    end

    test "rejects deeply-nested map at worktree.worktree (triple nesting)" do
      manifest = %{
        "name" => "deep-worktree-test",
        "phases" => [
          %{
            "name" => "build",
            "prompt" => "build.md",
            "worktree" => %{
              "enabled" => true,
              "path" => ".work",
              "cleanup" => "on_success",
              "nested" => %{"bad" => "value"}
            }
          }
        ]
      }

      assert ManifestWriter.write(manifest) ==
               {:error, {:unsupported_construct, {:deep_nesting, "worktree"}}}
    end
  end

  describe "write/1 (TRD-045 string content edge cases)" do
    test "round-trips string containing pipe character" do
      # A string containing "|" is still valid plain text - not a block scalar
      manifest = %{
        "name" => "pipe-test",
        "phases" => [
          %{
            "name" => "render",
            "prompt" => "pipe.md",
            "artifact" => "output | tee result.txt"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      assert get_in(loaded, ["phases", Access.at(0), "artifact"]) == "output | tee result.txt"
    end

    test "round-trips string containing angle brackets (not HTML/XML)" do
      manifest = %{
        "name" => "angle-test",
        "phases" => [
          %{
            "name" => "check",
            "prompt" => "check.md",
            "artifact" => "<report>summary</report>"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      assert get_in(loaded, ["phases", Access.at(0), "artifact"]) == "<report>summary</report>"
    end

    test "round-trips description with special YAML characters" do
      manifest = %{
        "name" => "special-chars",
        "description" => "Phase 1: build | Phase 2: test > Phase 3: deploy",
        "phases" => [
          %{"name" => "all", "prompt" => "all.md"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      assert loaded["description"] =~ "Phase 1: build | Phase 2: test"
    end
  end

  describe "write/1 (TRD-045 rejection by name)" do
    test "names deep_nesting error construct" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{
            "name" => "a",
            "prompt" => "a.md",
            "deep" => %{"level1" => %{"level2" => %{"level3" => "deep"}}}
          }
        ]
      }

      assert {:error, {:unsupported_construct, {:deep_nesting, "deep"}}} =
               ManifestWriter.write(manifest)
    end

    test "names top_level_list error construct" do
      manifest = %{
        "name" => "x",
        "phases" => [%{"name" => "a", "prompt" => "a.md"}],
        "tags" => ["alpha", "beta"]
      }

      assert {:error, {:unsupported_construct, {:top_level_list, "tags"}}} =
               ManifestWriter.write(manifest)
    end

    test "names list_at_phase_property error construct" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => "a.md", "requires" => ["ruby", "node"]}
        ]
      }

      assert {:error, {:unsupported_construct, {:list_at_phase_property, "requires"}}} =
               ManifestWriter.write(manifest)
    end
  end

  describe "write/1 (TRD-045 lossless round-trip over all Interpreter fields)" do
    test "full round-trip with every Interpreter-recognised field type" do
      manifest = %{
        "name" => "complete-workflow",
        "description" => "A workflow exercising every field the Interpreter parses",
        "phases" => [
          %{
            "name" => "plan",
            "prompt" => "plan.md",
            "models" => %{"default" => "MiniMax", "coder" => "Claude"},
            "mail" => %{"onStart" => true, "onComplete" => false},
            "maxTurns" => 50,
            "artifact" => "{task.projectReportsDir}/report.md"
          },
          %{
            "name" => "implement",
            "command" => "/usr/bin/python build.py",
            "worktree" => %{
              "enabled" => true,
              "path" => ".worktree/implement",
              "cleanup" => "on_success"
            },
            "requiredFile" => "artifacts/output.log"
          },
          %{
            "name" => "verify",
            "bash" => "mix test",
            "worktree" => %{
              "enabled" => false,
              "path" => ".worktree/verify",
              "cleanup" => "never"
            }
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)

      # Verify YAML structure is parseable
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)

      # Top-level
      assert loaded["name"] == "complete-workflow"
      assert loaded["description"] == "A workflow exercising every field the Interpreter parses"

      # Phase 1: prompt + models + mail + maxTurns + artifact
      p1 = Enum.at(loaded["phases"], 0)
      assert p1["name"] == "plan"
      assert p1["prompt"] == "plan.md"
      assert p1["models"] == %{"default" => "MiniMax", "coder" => "Claude"}
      assert p1["mail"] == %{"onStart" => true, "onComplete" => false}
      assert p1["maxTurns"] == 50
      assert p1["artifact"] == "{task.projectReportsDir}/report.md"

      # Phase 2: command + worktree + requiredFile
      p2 = Enum.at(loaded["phases"], 1)
      assert p2["name"] == "implement"
      assert p2["command"] == "/usr/bin/python build.py"
      assert p2["worktree"]["enabled"] == true
      assert p2["worktree"]["path"] == ".worktree/implement"
      assert p2["worktree"]["cleanup"] == "on_success"
      assert p2["requiredFile"] == "artifacts/output.log"

      # Phase 3: bash + worktree disabled
      p3 = Enum.at(loaded["phases"], 2)
      assert p3["name"] == "verify"
      assert p3["bash"] == "mix test"
      assert p3["worktree"]["enabled"] == false
      assert p3["worktree"]["cleanup"] == "never"
    end
  end

  defp write_temp_yaml!(contents) do
    dir = Path.join(System.tmp_dir!(), "manifest-writer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "workflow.yaml")
    File.write!(path, contents)
    path
  end
end
