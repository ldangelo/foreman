defmodule ForemanServer.Workflow.InterpreterTest do
  use ExUnit.Case, async: false

  @template_names ~w(discover assess plan implement implement-trd implement-trd-beads verify release)

  test "load!/1 loads each bundled workflow template" do
    Enum.each(@template_names, fn template_name ->
      path = Application.app_dir(:foreman_server, "priv/defaults/workflows/#{template_name}.yaml")

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert workflow["name"] == template_name
      assert is_binary(workflow["description"])
      assert is_list(workflow["phases"])

      assert Enum.any?(workflow["phases"], fn phase ->
               is_map(phase) and is_binary(phase["name"]) and phase["name"] != ""
             end)
    end)
  end

  test "load!/1 raises when phases are missing" do
    path = write_temp_yaml!("name: broken\ndescription: phases missing\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define top-level keys \"name\" and \"phases\"/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 raises when no phase has a name" do
    path = write_temp_yaml!("name: nameless\nphases:\n  - prompt: discover.md\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/at least one phase entry with a \"name\" key/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 raises when a phase defines no action" do
    path = write_temp_yaml!("name: empty-action\nphases:\n  - name: only\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define exactly one of: prompt, command, bash/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 raises when a phase defines two actions" do
    path =
      write_temp_yaml!("""
      name: dual-action
      phases:
        - name: only
          prompt: discover.md
          command: "/skill:x"
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define exactly one of: prompt, command, bash \(found 2\)/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 accepts a command: phase with a leading slash and requiredFile" do
    path =
      write_temp_yaml!("""
      name: command-only
      phases:
        - name: create-prd
          command: "/skill:ensemble-full-create-prd --foreman"
          requiredFile: planning.prd_path
      """)

    assert {:ok, workflow} = Workflow.Interpreter.load!(path)

    [phase] = workflow["phases"]
    assert phase["name"] == "create-prd"
    assert phase["command"] == "/skill:ensemble-full-create-prd --foreman"
    assert phase["requiredFile"] == "planning.prd_path"
  end

  test "load!/1 rejects a command: phase without a leading slash" do
    path =
      write_temp_yaml!("""
      name: bad-command
      phases:
        - name: only
          command: "skill:ensemble-full-create-prd"
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/\"command\" must be a non-empty slash invocation beginning with \"\/\"/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 rejects an empty command: value" do
    path =
      write_temp_yaml!("""
      name: empty-command
      phases:
        - name: only
          command: ""
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define exactly one of: prompt, command, bash/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 accepts a bash: phase syntactically" do
    path =
      write_temp_yaml!("""
      name: bash-phase
      phases:
        - name: only
          bash: "echo hello"
      """)

    assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
  end

  test "load!/1 rejects a non-mapping phase entry at the parser level" do
    path = write_temp_yaml!("name: bad-shape\nphases:\n  - \"not-a-map\"\n")

    assert_raise ArgumentError, ~r/not-a-map/, fn ->
      Workflow.Interpreter.load!(path)
    end
  end

  test "load!/1 rejects a malformed requiredFile dotted key" do
    path =
      write_temp_yaml!("""
      name: bad-required-file
      phases:
        - name: only
          command: "/skill:x"
          requiredFile: "planning..prd_path"
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/\"requiredFile\" must be a non-empty dotted context key/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 rejects an empty requiredFile value" do
    path =
      write_temp_yaml!("""
      name: empty-required-file
      phases:
        - name: only
          command: "/skill:x"
          requiredFile: ""
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/\"requiredFile\" must be a non-empty dotted context key/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  describe "worktree validation" do
    test "accepts a phase without a worktree block (legacy compatible)" do
      path =
        write_temp_yaml!("""
        name: legacy
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      refute Map.has_key?(hd(workflow["phases"]), "worktree")
    end

    test "parses a top-level nested mapping into a string-keyed map" do
      # The workflow-level `worktree:` block only works because the root parser
      # learned to nest. Previously only `phases:` could introduce a nested
      # mapping, so `worktree:` parsed as the empty string and its own indented
      # lines were left unconsumed. Nothing covered that, so pin the parse
      # result verbatim: the block reaches Catalog/Approval raw and
      # string-keyed.
      path =
        write_temp_yaml!("""
        name: wt-toplevel
        description: workflow-level worktree block
        worktree:
          enabled: true
          base: "{{implementation.source_revision}}"
          branch: foreman/{run_id}
          path: workspace
          cleanup: never
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)

      assert workflow["worktree"] == %{
               "enabled" => true,
               "base" => "{{implementation.source_revision}}",
               "branch" => "foreman/{run_id}",
               "path" => "workspace",
               "cleanup" => "never"
             }

      assert workflow["phases"] == [%{"name" => "only", "command" => "/skill:x"}]
    end

    test "accepts a partial worktree block (absent keys keep their defaults)" do
      path =
        write_temp_yaml!("""
        name: wt-default
        worktree:
          base: main
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts worktree with all valid fields" do
      path =
        write_temp_yaml!("""
        name: wt-full
        worktree:
          enabled: true
          base: main
          branch: feature/x
          path: implement
          cleanup: always
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts enabled: false (other fields must still validate)" do
      path =
        write_temp_yaml!("""
        name: wt-disabled
        worktree:
          enabled: false
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "rejects absolute path even when enabled: false" do
      path =
        write_temp_yaml!("""
        name: wt-disabled-abs
        worktree:
          enabled: false
          path: /abs/should/be/rejected
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must be relative \(absolute paths rejected\)/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects non-boolean enabled" do
      path =
        write_temp_yaml!("""
        name: wt-enabled-bad
        worktree:
          enabled: maybe
        phases:
          - name: only
            command: "/skill:x"
        """)

      error =
        assert_raise Workflow.MissingRequiredPhaseError,
                     ~r/\"worktree\.enabled\" must be a boolean/,
                     fn -> Workflow.Interpreter.load!(path) end

      # The block is validated ONCE at workflow level, so the message must not
      # blame a phase. It used to be validated per phase and name an index,
      # which pointed operators at the wrong part of the manifest.
      refute error.message =~ "phase"
    end

    test "rejects blank base" do
      path =
        write_temp_yaml!("""
        name: wt-blank-base
        worktree:
          base: ""
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.base\" must be a non-empty string/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects absolute path" do
      path =
        write_temp_yaml!("""
        name: wt-abs
        worktree:
          path: /tmp/abs
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must be relative \(absolute paths rejected\)/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects path with .. traversal" do
      path =
        write_temp_yaml!("""
        name: wt-traverse
        worktree:
          path: ../escape
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must not contain "\.\." traversal/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects invalid cleanup enum value" do
      path =
        write_temp_yaml!("""
        name: wt-cleanup
        worktree:
          cleanup: sometimes
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.cleanup\" must be one of: always, never, on_success/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "accepts cleanup: never" do
      path =
        write_temp_yaml!("""
        name: wt-never
        worktree:
          cleanup: never
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts cleanup: on_success" do
      # `on_success` is the third legal value and reclaims the worktree only on
      # a successful finalize. It was schema-legal from the start but the
      # executor collapsed it into `always`, so nothing asserted the schema
      # accepted it.
      path =
        write_temp_yaml!("""
        name: wt-on-success
        worktree:
          cleanup: on_success
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert workflow["worktree"]["cleanup"] == "on_success"
    end
  end


  defp write_temp_yaml!(contents) do
    directory =
      Path.join(System.tmp_dir!(), "workflow-interpreter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    path = Path.join(directory, "workflow.yaml")
    File.write!(path, contents)
    path
  end
end
