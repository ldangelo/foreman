defmodule ForemanServer.TaskProviders.SystemKataRunnerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.SystemKataRunner

  @spawned_event [:foreman_server, :task_provider, :kata, :subprocess, :spawned]

  setup do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "system_kata_runner_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    {:ok, _} = Application.ensure_all_started(:telemetry)

    original_path = System.get_env("PATH") || ""
    original_tmpdir = System.get_env("TMPDIR")

    # The runner creates its stderr temp file under System.tmp_dir!/0. Point that at a
    # private directory so the cleanup assertions only ever see this test's files.
    private_tmp = Path.join(temp_dir, "tmp")
    File.mkdir_p!(private_tmp)
    System.put_env("TMPDIR", private_tmp)

    on_exit(fn ->
      System.put_env("PATH", original_path)

      if original_tmpdir,
        do: System.put_env("TMPDIR", original_tmpdir),
        else: System.delete_env("TMPDIR")

      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir, private_tmp: private_tmp}
  end

  describe "argv delivery (AC-008-1)" do
    test "shell-quote cases reach the child as one unchanged argv element each", %{
      temp_dir: temp_dir
    } do
      cases = [
        "two words",
        "single'quote",
        ~s(double"quote),
        "dollar $HOME $(echo injected)",
        "back`tick`",
        "line one\nline two",
        "",
        "semi;colon && amp | pipe > redirect",
        "plain-arg_1.2/@x"
      ]

      with_fake_kata(temp_dir, ~S|printf '%s\0' "$@"|, fn ->
        assert {:ok, stdout} = SystemKataRunner.cmd(cases, temp_dir)

        # printf terminates every element with NUL, so the final split piece is empty.
        assert stdout |> String.split(<<0>>) |> Enum.drop(-1) == cases
      end)

      refute File.exists?(Path.join(temp_dir, "injected"))
    end

    test "metacharacters never reach a shell as commands", %{temp_dir: temp_dir} do
      marker = Path.join(temp_dir, "pwned")

      with_fake_kata(temp_dir, ~S|printf '%s\0' "$@"|, fn ->
        assert {:ok, _stdout} =
                 SystemKataRunner.cmd(["x; touch #{marker}", "$(touch #{marker})"], temp_dir)
      end)

      refute File.exists?(marker)
    end

    test "the command runs in the given cwd and stdout excludes stderr", %{temp_dir: temp_dir} do
      workdir = Path.join(temp_dir, "work dir")
      File.mkdir_p!(workdir)

      with_fake_kata(temp_dir, "pwd -P\necho this-is-stderr >&2", fn ->
        assert {:ok, stdout} = SystemKataRunner.cmd(["ready"], workdir)
        assert String.trim(stdout) == Path.join(real_path(temp_dir), "work dir")
      end)
    end

    test "a missing cwd returns a typed WORKSPACE_NOT_FOUND error without spawning", %{
      temp_dir: temp_dir
    } do
      with_fake_kata(temp_dir, "echo should-not-run", fn ->
        assert {:error, %ProviderError{code: "WORKSPACE_NOT_FOUND", retryable?: false}} =
                 SystemKataRunner.cmd(["ready"], Path.join(temp_dir, "missing"))
      end)
    end

    test "malformed arguments raise instead of reaching the CLI", %{temp_dir: temp_dir} do
      assert_raise ArgumentError, fn -> SystemKataRunner.cmd(["ok", :atom], temp_dir) end
      not_a_list = Enum.join(["rea", "dy"])
      assert_raise ArgumentError, fn -> SystemKataRunner.cmd(not_a_list, temp_dir) end
      assert_raise ArgumentError, fn -> SystemKataRunner.cmd(["ready"], "") end

      assert_raise ArgumentError, fn ->
        SystemKataRunner.cmd(["ready"], temp_dir, timeout_ms: -1)
      end

      assert_raise ArgumentError, fn -> SystemKataRunner.cmd(["ready"], temp_dir, bogus: 1) end
    end
  end

  describe "failure mapping" do
    test "a non-zero exit is a typed error carrying the exit code and stderr byte count only",
         %{temp_dir: temp_dir} do
      with_fake_kata(temp_dir, ~S|printf 'SECRET-OWNER-TEXT' >&2; exit 5|, fn ->
        assert {:error, %ProviderError{} = error} = SystemKataRunner.cmd(["claim", "a"], temp_dir)

        assert error.code == "BR_ERROR_ENVELOPE"
        assert error.retryable? == false

        assert error.context == %{
                 id: "BR_ERROR_ENVELOPE",
                 command: %{binary: "kata"},
                 exit_code: 5,
                 stderr_byte_count: byte_size("SECRET-OWNER-TEXT"),
                 sanitized?: true,
                 redacted_fields: ["assignee", "description"],
                 missing_fields: []
               }

        refute inspect(error) =~ "SECRET-OWNER-TEXT"
      end)
    end

    test "a missing kata binary is a non-zero exit, not a raise", %{temp_dir: temp_dir} do
      empty_bin = Path.join(temp_dir, "empty_bin")
      File.mkdir_p!(empty_bin)
      System.put_env("PATH", empty_bin)

      assert {:error, %ProviderError{code: "BR_ERROR_ENVELOPE", context: %{exit_code: 127}}} =
               SystemKataRunner.cmd(["--version"], temp_dir)
    end
  end

  describe "timeout escalation (AC-008-2)" do
    test "a call over the timeout is terminated and returns the retryable timeout error", %{
      temp_dir: temp_dir
    } do
      # `exec` makes the sleep the OS process the runner signals.
      with_fake_kata(temp_dir, "exec sleep 30", fn ->
        started = System.monotonic_time(:millisecond)

        assert {:error, %ProviderError{code: "BR_TIMEOUT_SUBPROCESS", retryable?: true} = error} =
                 SystemKataRunner.cmd(["ready"], temp_dir, timeout_ms: 200)

        assert error.context.exit_code == nil
        assert error.context.command == %{binary: "kata"}
        # SIGTERM is enough for a well-behaved child: no 5 s grace wait.
        assert System.monotonic_time(:millisecond) - started < 2_500
      end)
    end

    test "a child that ignores SIGTERM is killed with SIGKILL after the 5 s grace period", %{
      temp_dir: temp_dir
    } do
      pid_file = Path.join(temp_dir, "stubborn.pid")

      body = """
      echo $$ > "#{pid_file}"
      trap '' TERM
      while :; do sleep 1; done
      """

      with_fake_kata(temp_dir, body, fn ->
        started = System.monotonic_time(:millisecond)

        assert {:error, %ProviderError{code: "BR_TIMEOUT_SUBPROCESS", retryable?: true}} =
                 SystemKataRunner.cmd(["ready"], temp_dir, timeout_ms: 300)

        elapsed_ms = System.monotonic_time(:millisecond) - started
        stubborn_pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()

        refute os_pid_alive?(stubborn_pid), "SIGTERM-ignoring child survived the timeout"
        # 300 ms timeout + the 5 s grace before SIGKILL.
        assert elapsed_ms >= 5_000
        assert elapsed_ms < 9_000
      end)
    end

    test "a timeout kills the whole process tree, not only the process the port started", %{
      temp_dir: temp_dir
    } do
      child_pids = Path.join(temp_dir, "child.pids")

      body =
        [
          "sh -c 'sleep 30 & echo $! >> \"#{child_pids}\"; wait' &",
          "echo $! >> \"#{child_pids}\"",
          "wait"
        ]
        |> Enum.join("\n")

      with_fake_kata(temp_dir, body, fn ->
        assert {:error, %ProviderError{code: "BR_TIMEOUT_SUBPROCESS"}} =
                 SystemKataRunner.cmd(["ready"], temp_dir, timeout_ms: 500)

        pids = child_pids |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)
        assert length(pids) == 2

        survivors = Enum.filter(pids, &os_pid_alive?/1)
        Enum.each(survivors, &System.cmd("kill", ["-KILL", Integer.to_string(&1)]))
        assert survivors == [], "descendants survived the timeout kill: #{inspect(survivors)}"
      end)
    end

    test "the default timeout is overridable per call and a fast call is unaffected", %{
      temp_dir: temp_dir
    } do
      with_fake_kata(temp_dir, "echo done", fn ->
        assert {:ok, "done\n"} = SystemKataRunner.cmd(["ready"], temp_dir, timeout_ms: 5_000)
        assert {:ok, "done\n"} = SystemKataRunner.cmd(["ready"], temp_dir)
      end)
    end
  end

  describe "temp-file cleanup (AC-008-3)" do
    test "the temp file is removed after a successful call", %{
      temp_dir: temp_dir,
      private_tmp: private_tmp
    } do
      with_fake_kata(temp_dir, "echo ok; echo noise >&2", fn ->
        assert {:ok, "ok\n"} = SystemKataRunner.cmd(["ready"], temp_dir)
      end)

      assert leftover_temp_files(private_tmp) == []
    end

    test "the temp file is removed after a failing call", %{
      temp_dir: temp_dir,
      private_tmp: private_tmp
    } do
      with_fake_kata(temp_dir, "echo noise >&2; exit 3", fn ->
        assert {:error, %ProviderError{context: %{exit_code: 3}}} =
                 SystemKataRunner.cmd(["ready"], temp_dir)
      end)

      assert leftover_temp_files(private_tmp) == []
    end

    test "the temp file is removed after a timed-out call", %{
      temp_dir: temp_dir,
      private_tmp: private_tmp
    } do
      with_fake_kata(temp_dir, "exec sleep 30", fn ->
        assert {:error, %ProviderError{code: "BR_TIMEOUT_SUBPROCESS"}} =
                 SystemKataRunner.cmd(["ready"], temp_dir, timeout_ms: 200)
      end)

      assert leftover_temp_files(private_tmp) == []
    end

    test "the temp file is owner-only while the child runs", %{
      temp_dir: temp_dir,
      private_tmp: private_tmp
    } do
      mode_file = Path.join(temp_dir, "mode")

      body = """
      for f in "#{private_tmp}"/system_kata_runner_*; do
        ls -l "$f" | cut -c1-10 > "#{mode_file}"
      done
      """

      with_fake_kata(temp_dir, body, fn ->
        assert {:ok, _} = SystemKataRunner.cmd(["ready"], temp_dir)
      end)

      assert String.trim(File.read!(mode_file)) == "-rw-------"
    end
  end

  describe "OS pid surfacing (AC-008-4)" do
    test "the spawned child's OS pid is emitted on telemetry and nothing else is attached", %{
      temp_dir: temp_dir
    } do
      handler_id = "system-kata-runner-spawn-#{System.unique_integer([:positive, :monotonic])}"

      :ok =
        :telemetry.attach(
          handler_id,
          @spawned_event,
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          self()
        )

      try do
        with_fake_kata(temp_dir, ~S|echo "pid=$$"; echo secret-body|, fn ->
          assert {:ok, stdout} = SystemKataRunner.cmd(["ready"], temp_dir)
          assert_receive {:telemetry, @spawned_event, measurements, metadata}, 1_000

          assert measurements == %{}
          assert Map.keys(metadata) == [:os_pid]
          assert stdout =~ "pid=#{metadata.os_pid}\n"
          refute inspect(metadata) =~ "secret-body"
        end)
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  defp with_fake_kata(temp_dir, body, fun) when is_binary(body) do
    script_path = Path.join(temp_dir, "kata")
    original_path = System.get_env("PATH") || ""

    File.write!(script_path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(script_path, 0o755)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp leftover_temp_files(private_tmp) do
    private_tmp |> Path.join("system_kata_runner_*") |> Path.wildcard()
  end

  defp os_pid_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  # `pwd -P` resolves symlinks (macOS /var -> /private/var).
  defp real_path(path) do
    {out, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", path])
    String.trim(out)
  end
end
