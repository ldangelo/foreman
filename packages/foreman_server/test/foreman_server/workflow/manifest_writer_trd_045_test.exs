defmodule ForemanServer.Workflow.ManifestWriterTRD045Test do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.ManifestWriter
  alias ForemanServer.Workflow.Interpreter

  # TRD-045-TEST: Serializer property test
  # Verifies ManifestWriter serializes every field the Interpreter recognises
  # and rejects unsupported constructs (block scalars, anchors, flow sequences,
  # nesting beyond indent 6) by name.
  #
  # The `worktree:` block moved from PHASE level to WORKFLOW level (top of the
  # manifest, beside `name:` and `phases:`). These fixtures used to declare it
  # inside a phase, which was wrong twice over: `PhaseSpec.normalize/1` no
  # longer emits a `:worktree` key at all, and `Interpreter.load/1` validates
  # the block once at workflow level. A manifest the writer emitted with a
  # phase-level block would therefore round-trip "successfully" with its
  # worktree never validated and never read by `RunExecutor` — silently inert.
  # So the fixtures below supply `worktree` at the manifest top level and the
  # round-trip assertions read `loaded["worktree"]`, not `phase["worktree"]`.

  describe "write/1 (TRD-045 full field coverage)" do
    test "round-trips workflow-level worktree with enabled, path, and cleanup" do
      manifest = %{
        "name" => "worktree-test",
        "description" => "Tests worktree serialization",
        "worktree" => %{
          "enabled" => true,
          "path" => ".worktree/build",
          "cleanup" => "on_success"
        },
        "phases" => [
          %{
            "name" => "build",
            "prompt" => "build.md"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ ~r/^worktree:$/m
      assert yaml =~ ~r/enabled:\s*true/
      assert yaml =~ ~r{path:\s*\.worktree/build}
      assert yaml =~ ~r/cleanup:\s*on_success/

      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      assert loaded["worktree"]["enabled"] == true
      assert loaded["worktree"]["path"] == ".worktree/build"
      assert loaded["worktree"]["cleanup"] == "on_success"

      # The block is workflow-level: it must NOT leak onto the phase.
      phase = get_in(loaded, ["phases", Access.at(0)])
      refute Map.has_key?(phase, "worktree")
    end

    test "round-trips workflow-level worktree with cleanup=never" do
      manifest = %{
        "name" => "worktree-persist",
        "worktree" => %{
          "enabled" => true,
          "path" => ".worktree/dev",
          "cleanup" => "never"
        },
        "phases" => [
          %{
            "name" => "dev",
            "prompt" => "dev.md"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      assert loaded["worktree"]["cleanup"] == "never"
    end

    test "round-trips a workflow-level worktree that is explicitly disabled" do
      # A present `false` is meaningful (it survives normalization), so the
      # serializer must not drop it the way an absent key is dropped. This
      # coverage used to ride on a third phase carrying its own worktree.
      manifest = %{
        "name" => "worktree-disabled",
        "worktree" => %{
          "enabled" => false,
          "path" => ".worktree/verify",
          "cleanup" => "never"
        },
        "phases" => [
          %{
            "name" => "verify",
            "bash" => "mix test"
          }
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ ~r/enabled:\s*false/

      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = Interpreter.load(path)
      assert loaded["worktree"]["enabled"] == false
      assert loaded["worktree"]["cleanup"] == "never"
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
      # Now a TOP-LEVEL worktree: a single-level nested mapping is legal there,
      # but a map inside it is not — the Interpreter's root parser only reads
      # one nesting level (scalars at indent 2).
      manifest = %{
        "name" => "deep-worktree-test",
        "worktree" => %{
          "enabled" => true,
          "path" => ".work",
          "cleanup" => "on_success",
          "nested" => %{"bad" => "value"}
        },
        "phases" => [
          %{
            "name" => "build",
            "prompt" => "build.md"
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
        # One worktree block for the whole workflow, carrying the fields the
        # CommandGateway and RunExecutor read: `base` is rendered at approval
        # time, `branch` keeps `{task_id}/{run_id}` and `path` keeps `{run_id}` for runtime.
        "worktree" => %{
          "enabled" => true,
          "base" => "{{implementation.source_revision}}",
          "branch" => "foreman/{task_id}/{run_id}",
          "path" => "workspace",
          "cleanup" => "on_success"
        },
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
            "requiredFile" => "artifacts/output.log"
          },
          %{
            "name" => "verify",
            "bash" => "mix test"
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

      # Top-level worktree
      assert loaded["worktree"]["enabled"] == true
      assert loaded["worktree"]["base"] == "{{implementation.source_revision}}"
      assert loaded["worktree"]["branch"] == "foreman/{task_id}/{run_id}"
      assert loaded["worktree"]["path"] == "workspace"
      assert loaded["worktree"]["cleanup"] == "on_success"

      # Phase 1: prompt + models + mail + maxTurns + artifact
      p1 = Enum.at(loaded["phases"], 0)
      assert p1["name"] == "plan"
      assert p1["prompt"] == "plan.md"
      assert p1["models"] == %{"default" => "MiniMax", "coder" => "Claude"}
      assert p1["mail"] == %{"onStart" => true, "onComplete" => false}
      assert p1["maxTurns"] == 50
      assert p1["artifact"] == "{task.projectReportsDir}/report.md"

      # Phase 2: command + requiredFile
      p2 = Enum.at(loaded["phases"], 1)
      assert p2["name"] == "implement"
      assert p2["command"] == "/usr/bin/python build.py"
      assert p2["requiredFile"] == "artifacts/output.log"

      # Phase 3: bash
      p3 = Enum.at(loaded["phases"], 2)
      assert p3["name"] == "verify"
      assert p3["bash"] == "mix test"
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
