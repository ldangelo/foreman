defmodule ForemanServer.TaskProviders.SystemBrRunnerCreateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.SystemBrRunner

  @temp_dir_root Path.join(System.tmp_dir!(), "system_br_runner_create_test_")

  setup do
    temp_dir = @temp_dir_root <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    File.mkdir_p!(temp_dir)

    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  describe ":create action argv construction" do
    test "happy-path argv matches canonical br create fixture", %{temp_dir: temp_dir} do
      agent_context =
        ~s({"foreman":{"task_id":"tsk-1","command_id":"cmd-1","origin":"foreman","linked_at":"2026-08-11T06:39:00Z"}})

      with_fake_br(
        temp_dir,
        """
        for arg in "$@"; do
          printf '%s\\n' "$arg"
        done
        """,
        fn ->
          assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                   SystemBrRunner.cmd(
                     {:create,
                      %{
                        title: "Add login",
                        type: "feature",
                        priority: 2,
                        description: "OAuth flow",
                        agent_context: agent_context
                      }},
                     %{database_path: "/abs/beads.db"},
                     []
                   )

          assert String.split(stdout, "\n", trim: true) == [
                   "create",
                   "--db",
                   "/abs/beads.db",
                   "--title",
                   "Add login",
                   "--type",
                   "feature",
                   "--priority",
                   "2",
                   "--description",
                   "OAuth flow",
                   "--agent-context",
                   agent_context,
                   "--json"
                 ]
        end
      )
    end

    test "argv does not include unrelated action flags", %{temp_dir: temp_dir} do
      with_fake_br(
        temp_dir,
        """
        for arg in "$@"; do
          printf '%s\\n' "$arg"
        done
        """,
        fn ->
          assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                   SystemBrRunner.cmd(
                     {:create,
                      %{
                        title: "T",
                        type: "task",
                        priority: 0,
                        description: "d",
                        agent_context: "{}"
                      }},
                     %{database_path: "/tmp/x.db"},
                     []
                   )

          argv = String.split(stdout, "\n", trim: true)

          refute "--version" in argv
          refute "capabilities" in argv
          refute "ready" in argv
          refute "show" in argv
          refute "update" in argv
          refute "dep" in argv
          refute "coordination" in argv
          refute "close" in argv
          refute "where" in argv
          refute "schema" in argv

          assert "--title" in argv
          assert "--type" in argv
          assert "--priority" in argv
          assert "--description" in argv
          assert "--agent-context" in argv
          assert List.last(argv) == "--json"
        end
      )
    end

    test "priority is rendered as a decimal integer string", %{temp_dir: temp_dir} do
      with_fake_br(
        temp_dir,
        """
        for arg in "$@"; do
          printf '%s\\n' "$arg"
        done
        """,
        fn ->
          assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                   SystemBrRunner.cmd(
                     {:create,
                      %{
                        title: "T",
                        type: "task",
                        priority: 4,
                        description: "d",
                        agent_context: "{}"
                      }},
                     %{database_path: "/tmp/x.db"},
                     []
                   )

          argv = String.split(stdout, "\n", trim: true)
          priority_index = Enum.find_index(argv, &(&1 == "--priority"))
          assert priority_index != nil
          assert Enum.at(argv, priority_index + 1) == "4"
        end
      )
    end
  end

  describe ":create payload shape validation" do
    test ":title missing raises ArgumentError referencing :title" do
      assert_raise ArgumentError, ~r/:title/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             type: "feature",
             priority: 2,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":title empty string raises ArgumentError referencing :title" do
      assert_raise ArgumentError, ~r/:title/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "",
             type: "feature",
             priority: 2,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":priority out of range raises ArgumentError referencing :priority and 0..4" do
      assert_raise ArgumentError, ~r/:priority.*0\.\.4|0\.\.4.*:priority/s, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: 5,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":priority negative raises ArgumentError referencing :priority" do
      assert_raise ArgumentError, ~r/:priority/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: -1,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":type missing raises ArgumentError referencing :type" do
      assert_raise ArgumentError, ~r/:type/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             priority: 2,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":type empty string raises ArgumentError referencing :type" do
      assert_raise ArgumentError, ~r/:type/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "",
             priority: 2,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":description missing raises ArgumentError referencing :description" do
      assert_raise ArgumentError, ~r/:description/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: 2,
             agent_context: "{}"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":description empty string is allowed (binary shape only)" do
      with_fake_br(
        Path.join(@temp_dir_root, "noop"),
        "printf '%s\\n' ok",
        fn ->
          assert {:ok, %{stdout: "ok\n", stderr: "", exit_code: 0}} =
                   SystemBrRunner.cmd(
                     {:create,
                      %{
                        title: "T",
                        type: "feature",
                        priority: 2,
                        description: "",
                        agent_context: "{}"
                      }},
                     %{database_path: "/tmp/db"}
                   )
        end
      )
    end

    test ":agent_context missing raises ArgumentError referencing :agent_context" do
      assert_raise ArgumentError, ~r/:agent_context/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: 2,
             description: "x"
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end

    test ":agent_context empty string raises ArgumentError referencing :agent_context" do
      assert_raise ArgumentError, ~r/:agent_context/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: 2,
             description: "x",
             agent_context: ""
           }},
          %{database_path: "/tmp/db"}
        )
      end
    end
  end

  describe ":create boundary contract" do
    test "unknown action rejected by validate_request!" do
      assert_raise ArgumentError, ~r/unknown br action: :bogus/, fn ->
        SystemBrRunner.cmd({:bogus, %{}}, %{database_path: "/tmp/db"})
      end
    end

    test "missing :database_path in project_config raises ArgumentError" do
      assert_raise ArgumentError, ~r/database_path/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: 2,
             description: "x",
             agent_context: "{}"
           }},
          %{}
        )
      end
    end

    test "project_config :database_path must be a binary" do
      assert_raise ArgumentError, ~r/database_path/, fn ->
        SystemBrRunner.cmd(
          {:create,
           %{
             title: "T",
             type: "feature",
             priority: 2,
             description: "x",
             agent_context: "{}"
           }},
          %{database_path: 123}
        )
      end
    end

    test "request payload must be a map (not a bare keyword list)" do
      assert_raise ArgumentError, ~r/{:atom_action, payload_map}/, fn ->
        SystemBrRunner.cmd({:create, [:not_a_map]}, %{database_path: "/tmp/db"})
      end
    end

    test "non-tuple request raises ArgumentError referencing expected shape" do
      assert_raise ArgumentError, ~r/{:atom_action, payload_map}/, fn ->
        SystemBrRunner.cmd(:create, %{database_path: "/tmp/db"})
      end
    end

    test ":create is registered in @action_subcommands (validate_request! accepts it)" do
      # If :create were missing from @action_subcommands, build_argv would
      # raise "unknown br action: :create" before any I/O. Verify by ensuring
      # the validate-and-build path runs (it will only get as far as the fake
      # br script after the subcommand registration check passes).
      with_fake_br(
        Path.join(@temp_dir_root, "noop"),
        "printf '%s\\n' \"$@\"",
        fn ->
          assert {:ok, _} =
                   SystemBrRunner.cmd(
                     {:create,
                      %{
                        title: "T",
                        type: "feature",
                        priority: 2,
                        description: "x",
                        agent_context: "{}"
                      }},
                     %{database_path: "/tmp/db"}
                   )
        end
      )
    end
  end

  defp with_fake_br(_temp_dir_marker, body, fun) do
    # The fake `br` script must live on PATH (System.cmd("br", ...) is invoked
    # by build_shell_command/2). Build a fresh script under a unique tempdir
    # rather than reusing the setup :temp_dir, so nested describes do not
    # race on PATH writes.
    temp_dir = @temp_dir_root <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    File.mkdir_p!(temp_dir)

    script_path = Path.join(temp_dir, "br")
    original_path = System.get_env("PATH") || ""

    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end
  end
end
