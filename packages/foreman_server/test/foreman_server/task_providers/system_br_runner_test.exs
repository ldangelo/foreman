defmodule ForemanServer.TaskProviders.SystemBrRunnerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.SystemBrRunner

  @source_path "lib/foreman_server/task_providers/system_br_runner.ex"
  @temp_glob Path.join(System.tmp_dir!(), "system_br_runner_*")
  @leaked_event [:foreman_server, :task_provider, :beads, :temp_file, :leaked]

  setup do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "system_br_runner_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    :ok = ensure_telemetry_started()

    original_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir, baseline_temp_files: snapshot_temp_files()}
  end

  test "shell_quote helper is defined in source" do
    source = File.read!(@source_path)

    assert source =~ "defp shell_quote(arg) when is_binary(arg) do"
    assert source =~ "~r/\\A[A-Za-z0-9_.\\/@-]+\\z/"
  end

  test "shell_quote handles whitespace and special chars", %{temp_dir: temp_dir} do
    flags = [
      "two words",
      "single'quote",
      ~s(double"quote),
      "semi;colon",
      "amp&ersand",
      "pipe|value"
    ]

    with_fake_br(
      temp_dir,
      "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n",
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:where, %{flags: flags}}, %{database_path: "/tmp/db"})

        assert String.split(stdout, "\n", trim: true) ==
                 ["where", "--db", "/tmp/db"] ++ flags ++ ["--json"]
      end
    )
  end

  test "absolute path with spaces passes through unchanged", %{temp_dir: temp_dir} do
    {temp_dir, 0} = System.cmd("pwd", ["-P"], cd: temp_dir)
    temp_dir = String.trim(temp_dir)
    db_dir = Path.join(temp_dir, "abs space")
    db_path = Path.join(db_dir, "test db.sqlite3")

    File.mkdir_p!(db_dir)

    with_fake_br(
      temp_dir,
      "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n",
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})

        assert String.split(stdout, "\n", trim: true) ==
                 ["where", "--db", db_path, "--json"]
      end
    )
  end

  test "set_priority request translates to br update --priority using cached payload database_path",
       %{temp_dir: temp_dir} do
    with_fake_br(
      temp_dir,
      "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n",
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd(
                   {:set_priority,
                    %{id: "issue-7", priority: 4, database_path: "/tmp/cached.db"}},
                   %{}
                 )

        assert String.split(stdout, "\n", trim: true) ==
                 ["update", "--db", "/tmp/cached.db", "issue-7", "--priority", "4", "--json"]
      end
    )
  end

  test "coordination_status request translates to br coordination status with cached database_path",
       %{temp_dir: temp_dir} do
    with_fake_br(
      temp_dir,
      "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n",
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd(
                   {:coordination_status, %{}},
                   %{database_path: "/tmp/cached.db"}
                 )

        assert String.split(stdout, "\n", trim: true) ==
                 ["coordination", "status", "--db", "/tmp/cached.db", "--json"]
      end
    )
  end

  test "version request translates to br --version", %{temp_dir: temp_dir} do
    with_fake_br(
      temp_dir,
      "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n",
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:version, %{}}, %{})

        assert String.split(stdout, "\n", trim: true) == ["--version"]
      end
    )
  end

  test "capabilities request translates to br capabilities --json", %{temp_dir: temp_dir} do
    with_fake_br(
      temp_dir,
      "for arg in \"$@\"; do\n  printf '%s\\n' \"$arg\"\ndone\n",
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:capabilities, %{}}, %{})

        assert String.split(stdout, "\n", trim: true) == ["capabilities", "--json"]
      end
    )
  end

  test "Port.info captures OS PID and timeout escalation runs SIGTERM then SIGKILL", %{
    temp_dir: temp_dir
  } do
    with_fake_br(
      temp_dir,
      "echo starting\nsleep 30\necho done\n",
      fn ->
        assert {:error, %{stdout: stdout, reason: :timeout, exit_code: exit_code}} =
                 SystemBrRunner.cmd(
                   {:ready, %{}},
                   %{database_path: Path.join(temp_dir, "fake.db")},
                   timeout_ms: 200
                 )

        assert exit_code in [143, 137],
               "expected SIGTERM (143) or SIGKILL (137), got: #{inspect(exit_code)}"

        assert is_binary(stdout)
      end
    )
  end

  test "temp files are removed in try/after", %{baseline_temp_files: baseline_temp_files} do
    assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
             SystemBrRunner.cmd(
               {:schema, %{schema: "error"}},
               %{},
               stdin_payload: "payload"
             )

    assert stdout != ""
    assert_temp_file_delta_empty(baseline_temp_files)
  end

  test "leaked-temp telemetry event fires when leak is forced", %{
    baseline_temp_files: baseline_temp_files
  } do
    handler_id = "system-br-runner-leak-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @leaked_event,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    try do
      assert_raise ArgumentError, fn ->
        SystemBrRunner.cmd({:where, :invalid_payload}, %{database_path: "/tmp/db"},
          stdin_payload: "payload"
        )
      end

      leaked_kinds =
        for _ <- 1..2 do
          assert_receive {:telemetry, @leaked_event, %{count: 1}, %{kind: kind}}, 1_000
          kind
        end

      assert Enum.sort(leaked_kinds) == [:stderr, :stdin]
      assert_temp_file_delta_empty(baseline_temp_files)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp ensure_telemetry_started do
    case Application.load(:telemetry) do
      :ok -> :ok
      {:error, {:already_loaded, :telemetry}} -> :ok
    end

    case Application.ensure_all_started(:telemetry) do
      {:ok, _} -> :ok
      {:error, {:already_started, :telemetry}} -> :ok
    end
  end

  defp snapshot_temp_files do
    @temp_glob
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp assert_temp_file_delta_empty(baseline_temp_files) do
    assert MapSet.difference(snapshot_temp_files(), baseline_temp_files) == MapSet.new()
  end

  describe "concurrency serialization" do
    test "two concurrent calls with same database_path serialize via global trans backstop",
         %{temp_dir: temp_dir} do
      log_file = Path.join(temp_dir, "ordering.log")
      counter_file = Path.join(temp_dir, "concurrency.counter")
      max_file = Path.join(temp_dir, "concurrency.max")

      fake_br_body = [
        "echo \"CALL:$$\" >> \"#{log_file}\"",
        "n=$(cat \"#{counter_file}\" 2>/dev/null || echo 0)",
        "n=$((n + 1))",
        "echo $n > \"#{counter_file}\"",
        "max=$(cat \"#{max_file}\" 2>/dev/null || echo 0)",
        "if [ $n -gt $max ]; then echo $n > \"#{max_file}\"; fi",
        "sleep 0.5",
        "n=$(cat \"#{counter_file}\")",
        "n=$((n - 1))",
        "echo $n > \"#{counter_file}\"",
        "echo \"DONE:$$\" >> \"#{log_file}\""
      ]
      |> Enum.join("\n")

    with_fake_br(temp_dir, fake_br_body, fn ->
        db_path = "/tmp/test.db"
        parent = self()

        spawn(fn ->
          SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})
          send(parent, :call1_done)
        end)

        spawn(fn ->
          SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})
          send(parent, :call2_done)
        end)

        receive do
          :call1_done -> :ok
        after
          5000 -> flunk("timeout waiting for call1")
        end

        receive do
          :call2_done -> :ok
        after
          5000 -> flunk("timeout waiting for call2")
        end

        log = File.read!(log_file)
        lines = String.split(log, "\n", trim: true)
        call_lines = Enum.filter(lines, &String.starts_with?(&1, "CALL:"))
        done_lines = Enum.filter(lines, &String.starts_with?(&1, "DONE:"))

        assert length(call_lines) == 2,
               "Expected 2 CALL markers, got #{length(call_lines)}: #{inspect(lines)}"
        assert length(done_lines) == 2,
               "Expected 2 DONE markers, got #{length(done_lines)}: #{inspect(lines)}"

        max_concurrency =
          case File.read(max_file) do
            {:ok, val} -> String.trim(val) |> String.to_integer()
            _ -> 0
          end

        assert max_concurrency == 1,
               "Expected max concurrency 1, got #{max_concurrency}"
      end)
    end
  end

  describe "lock identity per action — all operations share the same database_path lock" do
    test ":create uses project_config database_path and enters global trans",
         %{temp_dir: temp_dir} do
      # Parse --db flag to confirm the correct database path was received.
      fake_br_body = [
        "while [ $# -gt 0 ]; do",
        "  case \"$1\" in",
        "    --db) echo \"DB_PATH=$2\" && shift 2 ;;",
        "    *) shift ;;",
        "  esac",
        "done",
        "echo ACTION=create"
      ]
      |> Enum.join("\n")

      db_path = "/tmp/serialized.db"

      with_fake_br(temp_dir, fake_br_body, fn ->
        # :create requires :title, :type, :description, :agent_context, and :priority
        assert {:ok, %{stdout: stdout, exit_code: 0}} =
                 SystemBrRunner.cmd(
                   {:create,
                    %{
                      id: "issue-1",
                      title: "test issue",
                      type: "task",
                      description: "Test description",
                      agent_context: "Test context",
                      priority: 2
                    }},
                   %{database_path: db_path}
                 )

        assert stdout =~ "DB_PATH=#{db_path}"
        assert stdout =~ "ACTION=create"
      end)
    end

    test ":update uses project_config database_path and enters global trans",
         %{temp_dir: temp_dir} do
      # :update appends --json, so Port stdout is available and fake_br succeeds.
      fake_br_body = [
        "while [ $# -gt 0 ]; do",
        "  case \"$1\" in",
        "    --db) echo \"DB_PATH=$2\" && shift 2 ;;",
        "    --json) echo HAS_JSON=1 && shift ;;",
        "    *) shift ;;",
        "  esac",
        "done"
      ]
      |> Enum.join("\n")

      db_path = "/tmp/serialized.db"

      with_fake_br(temp_dir, fake_br_body, fn ->
        assert {:ok, %{stdout: stdout, exit_code: 0}} =
                 SystemBrRunner.cmd(
                   {:update, %{flags: ["issue-99", "--status", "in_progress"]}},
                   %{database_path: db_path}
                 )

        assert stdout =~ "DB_PATH=#{db_path}"
        assert stdout =~ "HAS_JSON=1"
      end)
    end

    test "three concurrent calls to different operations on same DB path are fully serialized",
         %{temp_dir: temp_dir} do
      # All three use database_path from project_config and are serialized by the
      # same :global.trans lock key.
      counter_file = Path.join(temp_dir, "all_ops.counter")
      max_file = Path.join(temp_dir, "all_ops.max")

      fake_br_body = [
        "n=$(cat \"#{counter_file}\" 2>/dev/null || echo 0)",
        "n=$((n + 1))",
        "echo $n > \"#{counter_file}\"",
        "max=$(cat \"#{max_file}\" 2>/dev/null || echo 0)",
        "if [ $n -gt $max ]; then echo $n > \"#{max_file}\"; fi",
        "sleep 0.3",
        "n=$(cat \"#{counter_file}\")",
        "n=$((n - 1))",
        "echo $n > \"#{counter_file}\""
      ]
      |> Enum.join("\n")

      with_fake_br(temp_dir, fake_br_body, fn ->
        db_path = "/tmp/mixed_ops.db"
        parent = self()

        spawn(fn ->
          SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})
          send(parent, :op1_done)
        end)

        spawn(fn ->
          SystemBrRunner.cmd(
            {:update, %{flags: ["issue-2", "--status", "in_progress"]}},
            %{database_path: db_path}
          )
          send(parent, :op2_done)
        end)

        spawn(fn ->
          SystemBrRunner.cmd(
            {:create,
             %{
               id: "issue-3",
               title: "test",
               type: "task",
               description: "desc",
               agent_context: "ctx",
               priority: 2
             }},
            %{database_path: db_path}
          )
          send(parent, :op3_done)
        end)

        for op <- [:op1_done, :op2_done, :op3_done] do
          receive do
            ^op -> :ok
          after
            30_000 -> flunk("timeout waiting for #{op}")
          end
        end

        max_concurrency =
          case File.read(max_file) do
            {:ok, val} -> String.trim(val) |> String.to_integer()
            _ -> 0
          end

        assert max_concurrency == 1,
               "Expected max concurrency 1, got #{max_concurrency}"
      end)
    end
  end

  describe "lock release after error — global trans releases lock when function returns" do
    test "lock is released after br returns error tuple; second call succeeds",
         %{temp_dir: temp_dir} do
      # Strategy: call 1 exits 1 and writes a marker. Call 2 sees the marker and exits 0.
      # If the lock is held by call 1, call 2 blocks indefinitely on :global.trans.
      marker = Path.join(temp_dir, "call1.flag")
      success_log = Path.join(temp_dir, "success.log")

      # No "set -eu": explicit exit must not crash the shell.
      fake_br_body = [
        "if [ -f \"#{marker}\" ]; then",
        "  echo CALLER2 >> \"#{success_log}\"",
        "  exit 0",
        "else",
        "  echo CALLER1 > \"#{marker}\"",
        "  exit 1",
        "fi"
      ]
      |> Enum.join("\n")

      with_fake_br(temp_dir, fake_br_body, fn ->
        db_path = "/tmp/error_unlock.db"

        # First call fails
        assert {:error, %{exit_code: 1}} =
                 SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})

        # Second call succeeds — proves lock was released after call 1 returned.
        # Without lock release, call 2 would block on the held lock indefinitely.
        assert {:ok, %{exit_code: 0}} =
                 SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})

        assert File.read!(success_log) =~ "CALLER2"
      end)
    end
  end

  describe "lock release after timeout — global trans releases lock after SIGTERM" do
    test "lock is released after command times out; second call succeeds",
         %{temp_dir: temp_dir} do
      # Strategy: call 1 sleeps and times out (SIGTERM kill). Call 2 succeeds immediately.
      # If the lock is held by call 1, call 2 blocks indefinitely on :global.trans.
      marker = Path.join(temp_dir, "timeout.flag")
      success_log = Path.join(temp_dir, "success.log")

      fake_br_body = [
        "echo START >> \"#{marker}\"",
        "sleep 30",
        "echo DONE >> \"#{marker}\""
      ]
      marker = Path.join(temp_dir, "timeout.flag")
      success_log = Path.join(temp_dir, "success.log")

      # Both calls write to success_log so we can verify both ran.
      fake_br_body = [
        "echo START >> \"#{success_log}\"",
        "sleep 30",
        "echo DONE >> \"#{success_log}\""
      ]
      |> Enum.join("\n")

      with_fake_br(temp_dir, fake_br_body, fn ->
        db_path = "/tmp/timeout_unlock.db"

        assert {:error, %{exit_code: exit_code, reason: :timeout}} =
                 SystemBrRunner.cmd({:ready, %{}}, %{database_path: db_path}, timeout_ms: 200)

        assert exit_code in [143, 137]

        # Wait for first spawned process to fully exit before attempting second call.
        :timer.sleep(500)

        assert {:ok, %{exit_code: 0, stdout: _stdout}} =
                 SystemBrRunner.cmd({:ready, %{}}, %{database_path: db_path})

        # success_log contains START from both calls (first call ran, second ran)
        assert File.read!(success_log) =~ "START"
      end)
    end
  end
  describe "invalid and missing database paths" do
    test "non-binary database_path raises ArgumentError", %{temp_dir: temp_dir} do
      with_fake_br(temp_dir, "echo done", fn ->
        # nil is not a binary — raises immediately in fetch_database_path!
        assert_raise ArgumentError, fn ->
          SystemBrRunner.cmd({:where, %{}}, %{database_path: nil})
        end
      end)
    end

    test "missing database_path key raises ArgumentError", %{temp_dir: temp_dir} do
      with_fake_br(temp_dir, "echo done", fn ->
        # Map without :database_path: fetch_database_path! raises with the project_config in the message.
        assert_raise ArgumentError,
                    ~r"expected project_config with binary :database_path",
                    fn ->
                      SystemBrRunner.cmd({:where, %{}}, %{other_key: "value"})
                    end
      end)
    end

    test "nil database_path bypasses global trans — :version has no DB to lock",
         %{temp_dir: temp_dir} do
      # :version (and :capabilities/:schema) pass nil database_path to with_database_lock,
      # which calls fun.() directly without acquiring a :global.trans lock.
      with_fake_br(temp_dir, "echo BR_WAS_CALLED=1\n", fn ->
        assert {:ok, %{stdout: stdout, exit_code: 0}} =
                 SystemBrRunner.cmd({:version, %{}}, %{})

        assert stdout =~ "BR_WAS_CALLED=1"
      end)
    end
  end

  defp with_fake_br(temp_dir, body, fun) when is_binary(body) do
    script_path = Path.join(temp_dir, "br")
    original_path = System.get_env("PATH") || ""

    File.write!(script_path, "#!/bin/sh\nset -eu\n" <> body <> "\n")
    File.chmod!(script_path, 0o755)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end
end
