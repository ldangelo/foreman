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
      """
      for arg in "$@"; do
        printf '%s\\n' "$arg"
      done
      """,
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:where, %{flags: flags}}, %{database_path: "/tmp/db"})

        assert String.split(stdout, "\n", trim: true) ==
                 ["where", "--db", "/tmp/db"] ++ flags ++ ["--json"]
      end
    )
  end

  test "absolute path with spaces passes through unchanged", %{temp_dir: temp_dir} do
    # br refuses to operate on databases whose parent path contains a symlink,
    # which macOS temp dirs do. Canonicalize so the test exercises a real path.
    {temp_dir, 0} = System.cmd("pwd", ["-P"], cd: temp_dir)
    temp_dir = String.trim(temp_dir)
    db_dir = Path.join(temp_dir, "abs space")
    db_path = Path.join(db_dir, "test db.sqlite3")

    File.mkdir_p!(db_dir)

    with_fake_br(
      temp_dir,
      """
      for arg in "$@"; do
        printf '%s\\n' "$arg"
      done
      """,
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})

        assert String.split(stdout, "\n", trim: true) ==
                 ["where", "--db", db_path, "--json"]
      end
    )
  end

  test "set_priority request translates to br update --priority using cached payload database_path",
       %{
         temp_dir: temp_dir
       } do
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
       %{
         temp_dir: temp_dir
       } do
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
      """
      for arg in "$@"; do
        printf '%s\\n' "$arg"
      done
      """,
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
      """
      for arg in "$@"; do
        printf '%s\\n' "$arg"
      done
      """,
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
    # The fake `br` sleeps 30s — far longer than the 200 ms cmd timeout — so the impl
    # must observe the timeout, send SIGTERM, wait, then SIGKILL. exit_code 143 means
    # SIGTERM landed; 137 means SIGKILL was needed after the grace window.
    with_fake_br(
      temp_dir,
      """
      echo starting
      sleep 30
      echo done
      """,
      fn ->
        # The cmd timeout (200 ms) is well under the SIGTERM grace window (5000 ms),
        # so SIGTERM must land and the fake `br` exits with 143 — proving Port.info
        # captured a real OS PID and terminate_os_process/1 actually invoked kill -TERM.
        assert {:error, %{stdout: stdout, reason: :timeout, exit_code: exit_code}} =
                 SystemBrRunner.cmd(
                   {:ready, %{}},
                   %{database_path: Path.join(temp_dir, "fake.db")},
                   timeout_ms: 200
                 )

        assert exit_code in [143, 137],
               "expected SIGTERM (143) or SIGKILL (137) exit_code, got: #{inspect(exit_code)}"

        # stdout may or may not contain "starting" depending on timing, but the
        # timeout path MUST have flushed whatever it captured before the kill.
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
      # Use a lock file to prove ordering: first call creates lock_file, does work,
      # deletes it. Second call spins waiting for lock_file to disappear, then proceeds.
      # If :global.trans works: call1 creates file, holds lock through completion,
      # call2 waits and sees the file appear and disappear in correct order.
      # If :global.trans is broken: both calls run concurrently, file operations race.
      log_file = Path.join(temp_dir, "ordering.log")

      counter_file = Path.join(temp_dir, "concurrency.counter")
      max_file = Path.join(temp_dir, "concurrency.max")

      fake_br_body = """
      echo "CALL:$$" >> "#{log_file}"
      n=$(cat "#{counter_file}" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo $n > "#{counter_file}"
      max=$(cat "#{max_file}" 2>/dev/null || echo 0)
      if [ $n -gt $max ]; then echo $n > "#{max_file}"; fi
      sleep 0.5
      n=$(cat "#{counter_file}")
      n=$((n - 1))
      echo $n > "#{counter_file}"
      echo "DONE:$$" >> "#{log_file}"
      """

      with_fake_br(temp_dir, fake_br_body, fn ->
        db_path = "/tmp/test.db"
        parent = self()

        spawn(fn ->
          SystemBrRunner.cmd({:version, %{}}, %{database_path: db_path})
          send(parent, :call1_done)
        end)

        spawn(fn ->
          SystemBrRunner.cmd({:version, %{}}, %{database_path: db_path})
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

        # Both calls must have run (2 CALL: + 2 DONE: in log)
        log = File.read!(log_file)
        lines = String.split(log, "\n", trim: true)
        call_lines = Enum.filter(lines, &String.starts_with?(&1, "CALL:"))
        done_lines = Enum.filter(lines, &String.starts_with?(&1, "DONE:"))

        assert length(call_lines) == 2,
               "Expected 2 CALL markers, got #{length(call_lines)}: #{inspect(lines)}"
        assert length(done_lines) == 2,
               "Expected 2 DONE markers, got #{length(done_lines)}: #{inspect(lines)}"

        # Key assertion: max concurrency must be 1 (serialized by :global.trans)
        max_concurrency =
          case File.read(max_file) do
            {:ok, val} -> String.trim(val) |> String.to_integer()
            _ -> 0
          end

        assert max_concurrency == 1,
               "Expected max concurrency 1 (serialized), got #{max_concurrency}: calls may have run in parallel"
      end)
    end
  end

  defp with_fake_br(temp_dir, body, fun) do
    script_path = Path.join(temp_dir, "br")
    original_path = System.get_env("PATH") || ""

    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end
end
