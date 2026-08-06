defmodule ForemanServer.TaskProviders.SystemBrRunnerTest do
  use ExUnit.Case, async: true

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
    db_dir = Path.join(temp_dir, "abs space")
    db_path = Path.join(db_dir, "test db.sqlite3")

    File.mkdir_p!(db_dir)

    assert {_, 0} =
             System.cmd("br", ["init", "--db", db_path, "--force", "--json"], cd: temp_dir)

    assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
             SystemBrRunner.cmd({:where, %{}}, %{database_path: db_path})

    assert %{"database_path" => ^db_path} = Jason.decode!(stdout)
  end

  test "Port.info and timeout escalation are implemented in source" do
    source = File.read!(@source_path)

    assert source =~ "case Port.info(port, :os_pid) do"
    assert source =~ "{:os_pid, os_pid} when is_integer(os_pid) -> os_pid"
    assert source =~ "run_kill(os_pid, \"-TERM\")"
    assert source =~ "if wait_for_exit(os_pid, @max_kill_wait_ms) do"
    assert source =~ "run_kill(os_pid, \"-KILL\")"
    assert source =~ "wait_for_exit(os_pid, @max_kill_wait_ms)"
    assert source =~ "143"
    assert source =~ "137"
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
