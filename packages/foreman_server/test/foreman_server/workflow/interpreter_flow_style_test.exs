defmodule ForemanServer.Workflow.InterpreterFlowStyleTest do
  @moduledoc """
  Block-style and flow-style YAML mappings are the same mapping and must load to
  the same workflow (foreman-diiqo). The loader is a hand-rolled YAML subset
  parser, so "the same" is a property of that parser, not of YAML itself: each
  block/flow pair below is parsed through the real `Interpreter.load/1` and the
  results compared whole, not field by field.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.Interpreter

  @moduletag :tmp_dir

  defp load(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, "#{name}.yaml")
    File.write!(path, contents)
    Interpreter.load(path)
  end

  defp refusal_message(result) do
    assert {:error, {:manifest_load_failed, _path, message}} = result
    message
  end

  describe "workflow-level worktree: block" do
    test "flow and block styles load to the identical workflow", %{tmp_dir: tmp} do
      block = """
      name: wt
      worktree:
        enabled: false
        base: main
        branch: foreman/{task_id}
        path: workspace
        cleanup: never
      phases:
        - name: only
          command: "/skill:x"
      """

      flow = """
      name: wt
      worktree: {enabled: false, base: main, branch: foreman/{task_id}, path: workspace, cleanup: never}
      phases:
        - name: only
          command: "/skill:x"
      """

      assert {:ok, from_block} = load(tmp, "block", block)
      assert {:ok, from_flow} = load(tmp, "flow", flow)

      assert from_flow == from_block

      assert from_flow["worktree"] == %{
               "enabled" => false,
               "base" => "main",
               "branch" => "foreman/{task_id}",
               "path" => "workspace",
               "cleanup" => "never"
             }
    end

    test "the typed values survive: enabled is a boolean, not the string", %{tmp_dir: tmp} do
      assert {:ok, %{"worktree" => %{"enabled" => false}}} =
               load(tmp, "typed", """
               name: wt
               worktree: {enabled: false}
               phases:
                 - name: only
                   command: "/skill:x"
               """)
    end

    test "quoted flow values stay strings and keep embedded commas and colons", %{tmp_dir: tmp} do
      assert {:ok, %{"worktree" => worktree}} =
               load(tmp, "quoted", """
               name: wt
               worktree: {base: "{{implementation.source_revision}}", branch: 'a,b: c'}
               phases:
                 - name: only
                   command: "/skill:x"
               """)

      assert worktree == %{
               "base" => "{{implementation.source_revision}}",
               "branch" => "a,b: c"
             }
    end

    test "an empty flow mapping is an empty worktree declaration", %{tmp_dir: tmp} do
      assert {:ok, %{"worktree" => %{}}} =
               load(tmp, "empty", """
               name: wt
               worktree: {}
               phases:
                 - name: only
                   command: "/skill:x"
               """)
    end

    test "a single trailing comma is accepted, like YAML", %{tmp_dir: tmp} do
      assert {:ok, %{"worktree" => %{"base" => "main"}}} =
               load(tmp, "trailing", """
               name: wt
               worktree: {base: main,}
               phases:
                 - name: only
                   command: "/skill:x"
               """)
    end

    test "the same validators judge both styles: unknown key, bad boolean", %{tmp_dir: tmp} do
      for {flow, block} <- [
            {"{enabeld: false}", "\n  enabeld: false"},
            {"{enabled: maybe}", "\n  enabled: maybe"},
            {"{path: /abs/dir}", "\n  path: /abs/dir"}
          ] do
        flow_message =
          refusal_message(
            load(
              tmp,
              "f",
              "name: wt\nworktree: #{flow}\nphases:\n  - name: a\n    command: /skill:x\n"
            )
          )

        block_message =
          refusal_message(
            load(
              tmp,
              "b",
              "name: wt\nworktree:#{block}\nphases:\n  - name: a\n    command: /skill:x\n"
            )
          )

        # The path in the message differs (f.yaml vs b.yaml); the verdict must not.
        assert String.replace(flow_message, "f.yaml", "X.yaml") ==
                 String.replace(block_message, "b.yaml", "X.yaml")

        refute flow_message =~ "must be a mapping"
      end
    end

    test "text that only looks like a flow mapping stays a refused non-mapping", %{tmp_dir: tmp} do
      # No `key: value` entries, so it is not a flow mapping: it keeps being the
      # plain string it always was and the worktree validator refuses it.
      message =
        refusal_message(
          load(
            tmp,
            "notmap",
            "name: wt\nworktree: {run_id}\nphases:\n  - name: a\n    command: /skill:x\n"
          )
        )

      assert message =~ "\"worktree\" must be a mapping"
    end
  end

  describe "what is not a flow mapping" do
    test "an unquoted key holding flow delimiters keeps the value a plain (refused) string",
         %{tmp_dir: tmp} do
      message =
        refusal_message(
          load(
            tmp,
            "badkey",
            "name: wt\nworktree: {a}: b}\nphases:\n  - name: a\n    command: /skill:x\n"
          )
        )

      assert message =~ "\"worktree\" must be a mapping"
    end

    test "a quoted key may hold flow delimiters", %{tmp_dir: tmp} do
      assert {:error, {:manifest_load_failed, _path, message}} =
               load(tmp, "quotedkey", """
               name: wt
               worktree: {"a,b": 1}
               phases:
                 - name: a
                   command: /skill:x
               """)

      # Parsed as a mapping, so the failure is the unknown-key refusal, not "must be a mapping".
      assert message =~ ~s(unrecognized key "a,b")
    end
  end

  describe "phase-level flow mappings" do
    test "models: flow mapping equals the block mapping", %{tmp_dir: tmp} do
      block = """
      name: m
      phases:
        - name: a
          command: /skill:x
          provider: pi
          models:
            default: minimax/MiniMax-M2.7
      """

      flow = """
      name: m
      phases:
        - name: a
          command: /skill:x
          provider: pi
          models: {default: minimax/MiniMax-M2.7}
      """

      assert {:ok, from_block} = load(tmp, "block", block)
      assert {:ok, from_flow} = load(tmp, "flow", flow)
      assert from_flow == from_block
    end

    test "a phase written as a flow mapping equals the block phase", %{tmp_dir: tmp} do
      block = """
      name: h
      phases:
        - name: a
          command: /skill:x
          timeout_minutes: 5
        - name: b
          command: /skill:y
      """

      flow = """
      name: h
      phases:
        - {name: a, command: /skill:x, timeout_minutes: 5}
        - {name: b, command: /skill:y}
      """

      assert {:ok, from_block} = load(tmp, "block", block)
      assert {:ok, from_flow} = load(tmp, "flow", flow)
      assert from_flow == from_block
    end

    test "a flow mapping holding a flow list keeps the list intact", %{tmp_dir: tmp} do
      assert {:ok, %{"phases" => [phase]}} =
               load(tmp, "nested", """
               name: n
               phases:
                 - name: a
                   command: /skill:x
                   mail: {to: [ops, dev], note: hi}
               """)

      assert phase["mail"] == %{"to" => ["ops", "dev"], "note" => "hi"}
    end
  end

  describe "template placeholders are not flow mappings" do
    test "a scalar opening with {{ ... }} stays a plain string", %{tmp_dir: tmp} do
      assert {:ok, %{"phases" => [phase]}} =
               load(tmp, "tmpl", """
               name: t
               phases:
                 - name: a
                   command: /skill:x
                   artifact: {{task_id}}
               """)

      assert phase["artifact"] == "{{task_id}}"
    end
  end
end
