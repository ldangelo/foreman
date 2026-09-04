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

    test "round-trips explicit stack_pr values without inventing absent values" do
      manifest = %{
        "name" => "x",
        "phases" => [
          %{"name" => "a", "prompt" => "a.md", "stack_pr" => true},
          %{"name" => "b", "prompt" => "b.md", "stack_pr" => false},
          %{"name" => "c", "prompt" => "c.md"}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ ~r/stack_pr:\s*true/
      assert yaml =~ ~r/stack_pr:\s*false/

      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      [first, second, third] = loaded["phases"]
      assert first["stack_pr"] == true
      assert second["stack_pr"] == false
      refute Map.has_key?(third, "stack_pr")
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

    test "round-trips phase timeout_minutes" do
      manifest = %{
        "name" => "timeout-workflow",
        "phases" => [
          %{"name" => "run", "command" => "/skill:run", "timeout_minutes" => 15}
        ]
      }

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ "timeout_minutes: 15"
      path = write_temp_yaml!(yaml)
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(path)
      assert hd(loaded["phases"])["timeout_minutes"] == 15
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

  describe "write/1 float rejection" do
    # Floats are reachable only through `foreman_workflow_put`'s manifest-object
    # form, where JSON decoding produces them; the YAML parse path cannot yield
    # one. Before this, `is_number/1` guards admitted a float that `scalar/1`
    # had no clause for, so every case below raised FunctionClauseError from
    # inside the serializer instead of returning an error.
    @base %{
      "name" => "wf",
      "description" => "d",
      "phases" => [%{"name" => "p", "prompt" => "x.md"}]
    }

    test "refuses a float at the top level, naming the key" do
      assert {:error, {:unsupported_construct, {:float_value, "timeout"}}} =
               ManifestWriter.write(Map.put(@base, "timeout", 1.5))
    end

    test "refuses a float on a phase property, naming the key" do
      manifest = %{@base | "phases" => [%{"name" => "p", "prompt" => "x.md", "weight" => 0.25}]}

      assert {:error, {:unsupported_construct, {:float_value, "weight"}}} =
               ManifestWriter.write(manifest)
    end

    # The case guard-narrowing alone would have missed: `validate_nested_map/1`
    # accepted every non-map value, so a float one level down reached `scalar/1`.
    test "refuses a float nested inside a top-level mapping, naming both keys" do
      manifest = Map.put(@base, "worktree", %{"enabled" => true, "ttl" => 2.5})

      assert {:error, {:unsupported_construct, {:float_value, "worktree.ttl"}}} =
               ManifestWriter.write(manifest)
    end

    test "refuses a float nested inside a phase mapping, naming both keys" do
      manifest = %{
        @base
        | "phases" => [%{"name" => "p", "prompt" => "x.md", "commit" => %{"after" => 1.25}}]
      }

      assert {:error, {:unsupported_construct, {:float_value, "commit.after"}}} =
               ManifestWriter.write(manifest)
    end

    test "still accepts integers and booleans at every depth" do
      # `worktree` keys are restricted to enabled/base/branch/path/cleanup, so
      # the integer under test rides a phase property instead.
      manifest =
        %{@base | "phases" => [%{"name" => "p", "prompt" => "x.md", "retries" => 3}]}
        |> Map.put("worktree", %{"enabled" => true, "cleanup" => "never"})

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ "retries: 3"
      assert yaml =~ "enabled: true"
      assert yaml =~ "cleanup: never"

      # and the round-trip the float rule exists to protect still holds:
      # 3 must come back as the integer 3, not the string "3"
      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(write_temp_yaml!(yaml))
      assert hd(loaded["phases"])["retries"] == 3
      assert loaded["worktree"]["enabled"] == true
    end
  end

  describe "write/1 required-field types" do
    # `validate_top_level_structure/1` drops the required keys before its float
    # clauses run, and `build_yaml/1`/`build_phase/2` call `scalar/1` on
    # "name" directly — so the required fields bypassed every type check the
    # float fix added and still raised FunctionClauseError from the serializer.
    @base %{
      "name" => "wf",
      "description" => "d",
      "phases" => [%{"name" => "p", "prompt" => "x.md"}]
    }

    test "refuses a float top-level name" do
      assert {:error, {:unsupported_construct, {:float_value, "name"}}} =
               ManifestWriter.write(%{@base | "name" => 1.5})
    end

    test "refuses a non-string top-level name" do
      assert {:error, {:unsupported_construct, {:name_not_string, 7}}} =
               ManifestWriter.write(%{@base | "name" => 7})
    end

    test "refuses phases that is neither nil nor a list" do
      assert {:error, {:unsupported_construct, {:phases_not_list, 1.5}}} =
               ManifestWriter.write(%{@base | "phases" => 1.5})

      assert {:error, {:unsupported_construct, {:phases_not_list, %{"a" => 1}}}} =
               ManifestWriter.write(%{@base | "phases" => %{"a" => 1}})
    end

    test "refuses a float phase name, naming its index" do
      manifest = %{@base | "phases" => [%{"name" => 2.5, "prompt" => "x.md"}]}

      assert {:error, {:unsupported_construct, {:float_value, "phases[0].name"}}} =
               ManifestWriter.write(manifest)
    end

    test "refuses a non-string phase name, naming its index" do
      manifest = %{
        @base
        | "phases" => [%{"name" => "ok", "prompt" => "x.md"}, %{"name" => 9, "prompt" => "y.md"}]
      }

      assert {:error, {:unsupported_construct, {:phase_name_not_string, 1}}} =
               ManifestWriter.write(manifest)
    end

    test "still accepts a valid manifest" do
      assert {:ok, yaml} = ManifestWriter.write(@base)
      assert yaml =~ "name: wf"
    end
  end

  describe "write/1 validates every phase, not just the first" do
    # Found by a two-phase test that unexpectedly returned {:ok, _}.
    # `Enum.find_value/3` stops at the first truthy value and a valid
    # `validate_phase/2` answered `:ok`, which is truthy — so validation
    # returned as soon as phase 1 passed. Every defect in phases 2..n fell
    # through to the serializer as a raw CaseClauseError/FunctionClauseError,
    # making four documented error codes unreachable past the first phase.
    @ok_phase %{"name" => "ok", "prompt" => "x.md"}
    defp two(second),
      do: %{"name" => "wf", "description" => "d", "phases" => [@ok_phase, second]}

    test "a float property on a later phase is refused, not serialized" do
      assert {:error, {:unsupported_construct, {:float_value, "weight"}}} =
               ManifestWriter.write(two(%{"name" => "p2", "weight" => 0.5}))
    end

    test "a later phase that is not a map is refused, naming its index" do
      assert {:error, {:unsupported_construct, {:phase_not_map, 1}}} =
               ManifestWriter.write(two("not-a-map"))
    end

    test "a later phase missing its name is refused, naming its index" do
      assert {:error, {:unsupported_construct, {:phase_missing_name, 1}}} =
               ManifestWriter.write(two(%{"prompt" => "y.md"}))
    end

    test "a list property on a later phase is refused" do
      assert {:error, {:unsupported_construct, {:list_at_phase_property, "x"}}} =
               ManifestWriter.write(two(%{"name" => "p2", "x" => [1, 2]}))
    end

    test "several valid phases still serialize" do
      manifest = two(%{"name" => "p2", "prompt" => "y.md"})

      assert {:ok, yaml} = ManifestWriter.write(manifest)
      assert yaml =~ "- name: ok"
      assert yaml =~ "- name: p2"

      assert {:ok, loaded} = ForemanServer.Workflow.Interpreter.load(write_temp_yaml!(yaml))
      assert Enum.map(loaded["phases"], & &1["name"]) == ["ok", "p2"]
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
