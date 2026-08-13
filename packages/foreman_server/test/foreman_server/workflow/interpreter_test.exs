defmodule ForemanServer.Workflow.InterpreterTest do
  use ExUnit.Case, async: false

  @template_names ~w(discover assess plan implement verify release)

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

    test "accepts an empty worktree block (defaults to enabled)" do
      path =
        write_temp_yaml!("""
        name: wt-default
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              base: main
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts worktree with all valid fields" do
      path =
        write_temp_yaml!("""
        name: wt-full
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              enabled: true
              base: main
              branch: feature/x
              path: implement
              cleanup: always
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts enabled: false (other fields must still validate)" do
      path =
        write_temp_yaml!("""
        name: wt-disabled
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              enabled: false
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "rejects absolute path even when enabled: false" do
      path =
        write_temp_yaml!("""
        name: wt-disabled-abs
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              enabled: false
              path: /abs/should/be/rejected
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must be relative/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects non-boolean enabled" do
      path =
        write_temp_yaml!("""
        name: wt-enabled-bad
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              enabled: maybe
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree.enabled\" must be a boolean/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects blank base" do
      path =
        write_temp_yaml!("""
        name: wt-blank-base
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              base: ""
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree.base\" must be a non-empty string/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects absolute path" do
      path =
        write_temp_yaml!("""
        name: wt-abs
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              path: /tmp/abs
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree.path\" must be relative/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects path with .. traversal" do
      path =
        write_temp_yaml!("""
        name: wt-traverse
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              path: ../escape
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must not contain "\.\." traversal/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects invalid cleanup enum value" do
      path =
        write_temp_yaml!("""
        name: wt-cleanup
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              cleanup: on_success
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree.cleanup\" must be one of: always, never/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "accepts cleanup: never" do
      path =
        write_temp_yaml!("""
        name: wt-never
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              cleanup: never
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
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
