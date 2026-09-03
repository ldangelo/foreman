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
    test "fake br evidence parser derives intervals and max concurrency", %{temp_dir: temp_dir} do
      log_file = Path.join(temp_dir, "events.log")
      File.write!(log_file, "ENTER|a\nDONE|a\nENTER|b\nDONE|b\n")

      assert %{events: events, max_concurrency: 1, overlap?: false} =
               parse_fake_br_events!(log_file)

      assert Enum.map(events, & &1.phase) == [:enter, :done, :enter, :done]

      File.write!(log_file, "ENTER|a\nENTER|b\nDONE|a\nDONE|b\n")

      assert %{max_concurrency: 2, overlap?: true} = parse_fake_br_events!(log_file)
    end

    test "missing evidence failures name the missing artifact", %{temp_dir: temp_dir} do
      missing_log = Path.join(temp_dir, "missing-events.log")

      assert_raise ExUnit.AssertionError, ~r/missing fake-br evidence file/, fn ->
        parse_fake_br_events!(missing_log)
      end
    end

    test "two concurrent calls with same database_path serialize for the whole fake br body",
         %{temp_dir: temp_dir} do
      log_file = Path.join(temp_dir, "same-db-events.log")

      with_fake_br(temp_dir, fake_br_event_body(log_file), fn ->
        db_path = Path.join(temp_dir, "same.beads.db")

        tasks =
          run_concurrent_br_calls([
            {:same_a, %{database_path: db_path}},
            {:same_b, %{database_path: db_path}}
          ])

        assert_attempted!([:same_a, :same_b])
        assert_calls_finished!(tasks)

        evidence = parse_fake_br_events!(log_file)

        # Same Beads database path is the critical invariant: :global.trans must keep
        # max fake-br concurrency at 1 from ENTER through DONE. If this fails, the
        # ordered event log below shows the exact overlap/missing-evidence sequence.
        assert evidence.max_concurrency == 1,
               concurrency_failure_message(
                 "same database_path br calls overlapped; expected serialization",
                 evidence
               )

        refute evidence.overlap?,
               concurrency_failure_message(
                 "same database_path br calls overlapped before the first DONE marker",
                 evidence
               )
      end)
    end

    test "different database_path calls may overlap because the lock key is per DB path",
         %{temp_dir: temp_dir} do
      log_file = Path.join(temp_dir, "different-db-events.log")

      with_fake_br(temp_dir, fake_br_event_body(log_file), fn ->
        tasks =
          run_concurrent_br_calls([
            {:db_a, %{database_path: Path.join(temp_dir, "a.beads.db")}},
            {:db_b, %{database_path: Path.join(temp_dir, "b.beads.db")}}
          ])

        assert_attempted!([:db_a, :db_b])
        assert_calls_finished!(tasks)

        evidence = parse_fake_br_events!(log_file)

        assert evidence.overlap?,
               concurrency_failure_message(
                 "different database_path br calls did not overlap; lock scope may be too broad or scheduler did not contend",
                 evidence
               )

        assert evidence.max_concurrency >= 2,
               concurrency_failure_message(
                 "different database_path br calls never had two active fake-br bodies",
                 evidence
               )
      end)
    end

    test "missing and empty database_path keep no-lock command behavior", %{temp_dir: temp_dir} do
      log_file = Path.join(temp_dir, "no-db-events.log")

      with_fake_br(temp_dir, fake_br_event_body(log_file), fn ->
        assert {:ok, %{stdout: stdout_missing, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:version, %{}}, %{})

        assert String.trim(stdout_missing) == "ok"

        assert {:ok, %{stdout: stdout_empty, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd({:version, %{}}, %{database_path: ""})

        assert String.trim(stdout_empty) == "ok"

        evidence = parse_fake_br_events!(log_file)
        assert length(evidence.events) == 4
        assert evidence.max_concurrency == 1
      end)
    end
  end

  defp run_concurrent_br_calls(call_specs) do
    parent = self()

    Enum.map(call_specs, fn {label, project_config} ->
      Task.async(fn ->
        send(parent, {:br_call_attempted, label})
        result = SystemBrRunner.cmd({:version, %{}}, project_config)
        send(parent, {:br_call_finished, label, result})
        result
      end)
    end)
  end

  defp assert_attempted!(labels) do
    Enum.each(labels, fn label ->
      assert_receive {:br_call_attempted, ^label},
                     1_000,
                     "missing caller attempt marker for #{inspect(label)}"
    end)
  end

  defp assert_calls_finished!(tasks) do
    Enum.each(tasks, fn task ->
      assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} = Task.await(task, 5_000)
      assert String.trim(stdout) == "ok"
    end)
  end

  defp fake_br_event_body(log_file) do
    """
    printf 'ENTER|%s|%s\n' "$$" "$*" >> "#{log_file}"
    sleep 0.4
    printf 'DONE|%s|%s\n' "$$" "$*" >> "#{log_file}"
    printf 'ok\n'
    """
  end

  defp parse_fake_br_events!(log_file) do
    assert File.exists?(log_file),
           "missing fake-br evidence file #{log_file}; fake command did not run or PATH setup failed"

    events =
      log_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, index} -> parse_fake_br_event!(line, index) end)

    assert events != [], "fake-br evidence file #{log_file} is empty"

    {max_concurrency, overlap?} =
      events
      |> Enum.reduce({0, 0, false}, fn event, {active, max_seen, overlap_seen?} ->
        active =
          case event.phase do
            :enter -> active + 1
            :done -> active - 1
          end

        {active, max(max_seen, active), overlap_seen? or active > 1}
      end)
      |> then(fn {_active, max_seen, overlap_seen?} -> {max_seen, overlap_seen?} end)

    %{
      events: events,
      max_concurrency: max_concurrency,
      overlap?: overlap?,
      log: File.read!(log_file)
    }
  end

  defp parse_fake_br_event!(line, index) do
    case String.split(line, "|", parts: 3) do
      ["ENTER", pid, argv] -> %{index: index, phase: :enter, pid: pid, argv: argv, raw: line}
      ["DONE", pid, argv] -> %{index: index, phase: :done, pid: pid, argv: argv, raw: line}
      _ -> flunk("malformed fake-br evidence row #{index}: #{inspect(line)}")
    end
  end

  defp concurrency_failure_message(reason, evidence) do
    """
    #{reason}
    observed max concurrency: #{evidence.max_concurrency}
    ordered fake-br event log:
    #{evidence.log}
    """
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
