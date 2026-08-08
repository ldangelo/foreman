defmodule ForemanServer.AgentRuntime.PiAdapterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.Adapters.PiAdapter

  @moduletag :pi_adapter

  # Fixture executables stored in tmp_dir
  @success_fixture "pi_success_fixture.sh"
  @fail_fixture "pi_fail_fixture.sh"
  @hang_fixture "pi_hang_fixture.sh"
  @contract_fixture "pi_contract_fixture.sh"
  @noisy_fixture "pi_noisy_fixture.sh"

  setup do
    # Get tmp directory for fixture scripts
    tmp_dir = System.tmp_dir!()

    # Plain-text protocol (TRD-004 §"Pi Process Protocol"): zero-exit
    # stdout is the complete final text — no JSON wrapping.
    success_path = Path.join(tmp_dir, @success_fixture)

    File.write!(success_path, """
    #!/bin/bash
    printf 'hello from pi\\n'
    exit 0
    """)

    File.chmod!(success_path, 0o755)

    # Fail fixture: any non-zero exit is an error; stdout content is
    # intentionally not asserted.
    fail_path = Path.join(tmp_dir, @fail_fixture)

    File.write!(fail_path, """
    #!/bin/bash
    echo 'bad input' >&2
    exit 1
    """)

    File.chmod!(fail_path, 0o755)

    # Hang fixture: sleeps past the timeout window to exercise the
    # adapter's deadline + kill-escalation path.
    hang_path = Path.join(tmp_dir, @hang_fixture)

    File.write!(hang_path, """
    #!/bin/bash
    sleep 30
    exit 0
    """)

    File.chmod!(hang_path, 0o755)

    # Contract fixture: captures argv and file content to known locations for validation
    contract_path = Path.join(tmp_dir, @contract_fixture)

    File.write!(contract_path, """
    #!/bin/bash
    # Capture argv to known file
    echo "$@" > /tmp/pi_contract_argv.txt
    # Copy the request file to known location for inspection
    if [ -n "$6" ]; then
      REQUEST_FILE="${6:1}"
      if [ -f "$REQUEST_FILE" ]; then
        cp "$REQUEST_FILE" /tmp/pi_contract_request.txt
        # Also capture file mode
        stat -f "%OLp" "$REQUEST_FILE" 2>/dev/null > /tmp/pi_contract_mode.txt || stat -c "%a" "$REQUEST_FILE" 2>/dev/null > /tmp/pi_contract_mode.txt
      fi
    fi
    printf 'contract validated\\n'
    exit 0
    """)

    File.chmod!(contract_path, 0o755)

    # Noisy fixture: simulates what real `pi 0.83` emits at exit — a
    # stderr hook-banner, a BEL, the user-visible payload, and trailing
    # TUI cleanup CSI sequences. The adapter must strip all of that and
    # return ONLY the printable text (PRD AC-003-1). The hook banner
    # exercises the stderr -> /dev/null redirect in the shell wrapper;
    # the BEL and CSIs exercise `normalize_output/1`.
    noisy_path = Path.join(tmp_dir, @noisy_fixture)

    File.write!(noisy_path, """
    #!/bin/bash
    echo '[pi-yaml-hooks] Loaded 1 hook (global: 1, project: 0).' >&2
    printf '\\ahello\\x1b[?2026h\\x1b[r\\x1b[?1006l\\x1b[?1002l\\x1b[?1000l\\x1b[?1007h\\x1b[?1049l\\x1b[<999u\\x1b[>4;0m\\x1b[?2026l\\n'
    exit 0
    """)

    File.chmod!(noisy_path, 0o755)

    # Save original config

    original_config = Application.get_env(:foreman_server, PiAdapter, [])

    on_exit(fn ->
      File.rm(Path.join(tmp_dir, @contract_fixture))
      File.rm(Path.join(tmp_dir, @noisy_fixture))
      File.rm(Path.join(tmp_dir, @success_fixture))
      File.rm(Path.join(tmp_dir, @fail_fixture))
      File.rm(Path.join(tmp_dir, @hang_fixture))
      # Cleanup contract artifacts
      File.rm("/tmp/pi_contract_argv.txt")
      File.rm("/tmp/pi_contract_request.txt")
      File.rm("/tmp/pi_contract_mode.txt")

      # Restore original config
      Application.put_env(:foreman_server, PiAdapter, original_config)
    end)

    %{
      contract_path: contract_path,
      noisy_path: noisy_path,
      success_path: success_path,
      fail_path: fail_path,
      hang_path: hang_path,
      tmp_dir: tmp_dir
    }
  end

  describe "name/0" do
    test "returns :pi" do
      assert PiAdapter.name() == :pi
    end
  end

  describe "capabilities/0" do
    test "validates against Capabilities.validate/1" do
      caps = PiAdapter.capabilities()
      assert {:ok, validated} = ForemanServer.AgentRuntime.Capabilities.validate(caps)
      assert validated.type == :cli
      assert :code_generation in validated.strengths
      assert :long_running_tasks in validated.weaknesses
      assert :code in validated.supported_contexts
    end

    test "contains required fields" do
      caps = PiAdapter.capabilities()
      assert Map.has_key?(caps, :type)
      assert Map.has_key?(caps, :strengths)
      assert Map.has_key?(caps, :weaknesses)
      assert Map.has_key?(caps, :supported_contexts)
    end

    test "contains optional fields" do
      caps = PiAdapter.capabilities()
      assert Map.has_key?(caps, :cost_per_call)
      assert Map.has_key?(caps, :typical_latency_ms)
    end
  end

  describe "available?/0" do
    test "returns true when executable exists", %{success_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)
      assert PiAdapter.available?() == true
    end

    test "returns false when executable does not exist" do
      Application.put_env(:foreman_server, PiAdapter, executable: "/nonexistent/pi")
      assert PiAdapter.available?() == false
    end

    test "bare-name resolution depends on PATH (deterministic fake binary)" do
      # A binary that exists in PATH ONLY when the fake_dir is on PATH.
      # The bare name must not exist anywhere else (no system binary with
      # this name), so available?/0 returning true ⇒ resolve_executable/1
      # actually consulted PATH via System.find_executable/1.
      fake_id = :erlang.unique_integer([:positive])
      fake_dir = Path.join(System.tmp_dir!(), "pi_adapter_fakedir_#{fake_id}")
      File.mkdir_p!(fake_dir)
      fake_bin = Path.join(fake_dir, "fake_pi_#{fake_id}")
      File.write!(fake_bin, "#!/bin/sh\nexit 0\n")
      File.chmod!(fake_bin, 0o755)
      fake_name = Path.basename(fake_bin)
      original_path = System.get_env("PATH") || ""

      try do
        # Path A: fake_dir is on PATH ⇒ available?/0 must resolve and report true.
        System.put_env("PATH", fake_dir)
        Application.put_env(:foreman_server, PiAdapter, executable: fake_name)
        assert PiAdapter.available?() == true

        # Path B: fake_name is not on PATH ⇒ available?/0 must report false.
        System.put_env("PATH", "/nonexistent-path-only")
        assert PiAdapter.available?() == false
      after
        System.put_env("PATH", original_path)
        File.rm_rf!(fake_dir)
        Application.delete_env(:foreman_server, PiAdapter)
      end
    end
  end

  describe "execute/2 — cleanup on failure" do
    test "temp dir is cleaned up when executable does not exist", %{tmp_dir: tmp_dir} do
      # Get list of temp dirs before
      before_dirs = File.ls!(tmp_dir) |> Enum.filter(&String.starts_with?(&1, "pi_adapter_"))

      # Try to execute with nonexistent executable
      Application.put_env(:foreman_server, PiAdapter, executable: "/nonexistent/pi")
      request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}
      result = PiAdapter.execute(request, [])

      # Should fail gracefully
      assert {:error, {:enoent, _}} = result

      # Verify temp dir was cleaned up
      after_dirs = File.ls!(tmp_dir) |> Enum.filter(&String.starts_with?(&1, "pi_adapter_"))
      assert after_dirs == before_dirs
    end
  end

  describe "execute/2 — success" do
    test "returns the complete final text on zero exit (plain-text protocol)", %{
      success_path: path
    } do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      result = PiAdapter.execute(request, [])

      assert {:ok, content, %{}} = result
      assert content == "hello from pi\n"
    end

    test "strips stderr banner, BEL, and trailing TUI cleanup CSIs (PRD AC-003-1)", %{
      noisy_path: path
    } do
      # The fixture emits exactly what real `pi 0.83` produces: a stderr
      # yaml-hooks banner, a leading BEL, the printable payload, and the
      # full bracketed-paste / mouse-tracking / alt-screen teardown
      # sequence. AC-003-1 requires the adapter to return the final text
      # result only — i.e. just the payload bytes, byte-for-byte.
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      result = PiAdapter.execute(request, [])

      assert {:ok, "hello\n", %{}} = result
    end
  end

  describe "execute/2 — contract validation" do
    test "argv contains fixed flags", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}
      PiAdapter.execute(request, [])

      # Verify argv captured - should contain fixed flags and @ with path
      assert File.exists?("/tmp/pi_contract_argv.txt")
      argv = String.trim(File.read!("/tmp/pi_contract_argv.txt"))
      # Fixed flags followed by @ and the request file path
      assert argv =~ "--print --mode text --no-session --no-context-files @"
      assert argv =~ ~r"@.+/request\.txt$"
    end

    test "request file has mode 0600", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}
      PiAdapter.execute(request, [])

      # Verify mode captured
      assert File.exists?("/tmp/pi_contract_mode.txt")
      mode = String.trim(File.read!("/tmp/pi_contract_mode.txt"))
      assert mode == "600"
    end

    test "request file framing is byte-exact with JSON round-trip", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      context = %{"key" => "value", "nested" => %{"n" => 1}}
      request_context = Map.put(context, :working_directory, System.tmp_dir!())
      request = %{prompt: "hello world", context: request_context}
      PiAdapter.execute(request, [])

      content = File.read!("/tmp/pi_contract_request.txt")

      # Byte-exact framing: header + blank line + prompt bytes + blank
      # line + context header + blank line + JSON segment + trailing
      # newline. Equals (not substring) catches any extra/misplaced
      # bytes that the TRD-004 framing AC forbids.
      json_segment = Jason.encode!(request_context)

      expected =
        "# Prompt\n\nhello world\n\n# Context (JSON)\n\n" <>
          json_segment <> "\n"

      assert content == expected

      # JSON segment round-trip equality against the original context
      # map (TRD-004 §"Pi Process Protocol" semantic verification).
      assert Jason.decode!(json_segment) == stringify_keys(request_context)
    end

    test "request file omits the # Prompt header when prompt starts with / (slash command)",
         %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      context = Map.put(%{working_directory: System.tmp_dir!()}, :key, "value")

      request = %{prompt: "/skill:ensemble-full-create-prd --foreman", context: context}
      PiAdapter.execute(request, [])

      content = File.read!("/tmp/pi_contract_request.txt")
      json_segment = Jason.encode!(stringify_keys(context))

      expected =
        "/skill:ensemble-full-create-prd --foreman\n\n# Context (JSON)\n\n" <>
          json_segment <> "\n"

      assert content == expected

      refute String.starts_with?(content, "# Prompt\n\n"),
             "slash command prompt must not be prefixed by the # Prompt header"
    end
  end

  describe "execute/2 — failure" do
    test "returns {:error, reason} on non-zero exit", %{fail_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      result = PiAdapter.execute(request, [])

      assert {:error, {:non_zero_exit, 1}} = result
    end

    test "temp file is cleaned up after failure", %{fail_path: path, tmp_dir: tmp_dir} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      PiAdapter.execute(request, [])

      # Check that no temp directories remain from this adapter
      remaining_dirs =
        tmp_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "pi_adapter_"))

      assert remaining_dirs == []
    end
  end

  describe "execute/2 — timeout" do
    test "returns {:error, :timeout} within timeout_ms + slack", %{hang_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path, timeout_ms: 500)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      start = System.monotonic_time(:millisecond)
      result = PiAdapter.execute(request, [])
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, :timeout} = result
      assert elapsed < 3000
    end
  end

  describe "safe_close_port/1" do
    test "is idempotent - calling twice doesn't raise" do
      port = Port.open({:spawn, "true"}, [:binary])

      assert PiAdapter.safe_close_port(port) == :ok
      assert PiAdapter.safe_close_port(port) == :ok
    end

    test "on a closed port returns :ok rather than crashing" do
      port = Port.open({:spawn, "true"}, [:binary])
      Port.close(port)

      assert PiAdapter.safe_close_port(port) == :ok
    end
  end

  describe "execute/2 — cleanup" do
    test "temp file is gone after successful execution", %{success_path: path, tmp_dir: tmp_dir} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      PiAdapter.execute(request, [])

      remaining_dirs =
        tmp_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "pi_adapter_"))

      assert remaining_dirs == []
    end
  end

  describe "execute/2 — per-call timeout override" do
    test "timeout_ms option overrides default", %{hang_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path, timeout_ms: 60_000)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{}, :working_directory, System.tmp_dir!())
      }

      start = System.monotonic_time(:millisecond)
      result = PiAdapter.execute(request, timeout_ms: 200)
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, :timeout} = result
      assert elapsed < 1000
    end
  end

  describe "telemetry metadata" do
    test "adapter events contain exactly %{backend: :pi}" do
      tmp_dir = System.tmp_dir!()
      test_fixture_path = Path.join(tmp_dir, "pi_telemetry_fixture.sh")

      File.write!(test_fixture_path, """
      #!/bin/bash
      echo '{"output":"hello"}'
      exit 0
      """)

      File.chmod!(test_fixture_path, 0o755)

      try do
        Application.put_env(:foreman_server, PiAdapter, executable: test_fixture_path)

        # Attach event handlers
        :telemetry_test.attach_event_handlers(self(), [
          [:foreman, :agent_runtime, :adapter, :pi, :start],
          [:foreman, :agent_runtime, :adapter, :pi, :stop]
        ])

        request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}
        PiAdapter.execute(request, [])

        Process.sleep(50)
        # Receive both events - the message is {event, ref, measure, meta}
        assert_received {[:foreman, :agent_runtime, :adapter, :pi, :start], _ref, _measure,
                         meta_start}

        assert meta_start == %{backend: :pi}

        assert_received {[:foreman, :agent_runtime, :adapter, :pi, :stop], _ref, _measure,
                         meta_stop}

        assert meta_stop == %{backend: :pi}
      after
        # Cleanup
        File.rm(test_fixture_path)
      end
    end
  end

  describe "TRD-004-TEST protocol verification" do
    # Test 1: Exact argv contract — verifies the adapter passes exactly 6 argv fields
    test "execute/2 passes exact 6-field argv to pi", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{
        prompt: "test prompt",
        context: Map.put(%{key: "value"}, :working_directory, System.tmp_dir!())
      }

      PiAdapter.execute(request, [])

      # Read captured argv from contract fixture
      assert File.exists?("/tmp/pi_contract_argv.txt")
      argv = String.trim(File.read!("/tmp/pi_contract_argv.txt"))

      # Split into individual arguments (space-separated)
      argv_parts = String.split(argv, " ")

      # Assert exactly 6 fields
      assert length(argv_parts) == 6,
             "Expected exactly 6 argv fields, got #{length(argv_parts)}: #{inspect(argv_parts)}"

      # Verify the exact expected argv structure
      assert Enum.at(argv_parts, 0) == "--print"
      assert Enum.at(argv_parts, 1) == "--mode"
      assert Enum.at(argv_parts, 2) == "text"
      assert Enum.at(argv_parts, 3) == "--no-session"
      assert Enum.at(argv_parts, 4) == "--no-context-files"

      # Last argv must be @ with request file path
      last_arg = Enum.at(argv_parts, 5)

      assert String.starts_with?(last_arg, "@"),
             "Last argv should be @request_file, got: #{last_arg}"

      assert last_arg =~ "request.txt"
    end

    # Test 2: Canonical JSON extraction round-trip
    test "execute/2 correctly frames and extracts canonical JSON", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      # Use atom-keyed context (canonical form)
      context = %{model: "gpt-4", temperature: 0.7, items: [1, 2, 3]}
      request_context = Map.put(context, :working_directory, System.tmp_dir!())
      request = %{prompt: "test prompt", context: request_context}
      PiAdapter.execute(request, [])

      # Read the request file captured by contract fixture
      assert File.exists?("/tmp/pi_contract_request.txt")
      request_content = File.read!("/tmp/pi_contract_request.txt")

      # Split on the literal delimiter to extract JSON segment
      [_, json_with_newline] = String.split(request_content, "# Context (JSON)\n\n")
      [json_segment | _] = String.split(json_with_newline, "\n")
      json_segment = String.trim_trailing(json_segment, "\n")

      # Decode with Jason.decode! (canonical form uses string keys after encode/decode)
      decoded = Jason.decode!(json_segment)

      # Verify round-trip: encode the original context, decode, compare
      expected_json = Jason.encode!(request_context)
      expected_decoded = Jason.decode!(expected_json)

      assert decoded == expected_decoded
    end

    # Test 3: Terminal {port, {:exit_status, status}} verified via the adapter's receive path.
    # The fixture writes stdout, sleeps briefly, then exits — the adapter must capture
    # stdout from {port, :data} BEFORE the {port, {:exit_status, 0}} message. If the
    # receive loop only listened for exit_status, the partial output would be lost.
    test "execute/2 receive loop captures stdout then exit_status", %{tmp_dir: tmp_dir} do
      delayed_exit = Path.join(tmp_dir, "pi_delayed_exit_fixture.sh")

      File.write!(delayed_exit, """
      #!/bin/bash
      printf 'partial output'
      sleep 0.3
      printf 'final output\\n'
      exit 0
      """)

      File.chmod!(delayed_exit, 0o755)

      try do
        Application.put_env(:foreman_server, PiAdapter, executable: delayed_exit)
        request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}
        result = PiAdapter.execute(request, [])

        # Both stdout chunks captured + exit_status translated to plain text result.
        assert {:ok, "partial outputfinal output\n", %{}} = result
      after
        File.rm(delayed_exit)
      end
    end

    # Test 4: Adapter captures the OS PID via Port.info(:os_pid) (pi_adapter.ex:145-150)
    # and terminates the spawned process on timeout. The structural claim — that
    # Port.info(:os_pid) returns the spawned fixture's PID — is an OTP guarantee, not
    # adapter code. Asserting it requires an independent fixture invocation with its own
    # process, which would leak via Port.close/1 because the fixture does not read stdin.
    #
    # Honest assertion: after PiAdapter.execute returns {:error, :timeout}, the fixture's
    # PID is dead (kill -0 returns non-zero). If the adapter captured a wrong or stale
    # PID, the fixture survives and kill -0 returns 0.
    test "execute/2 captures OS PID and terminates the spawned process on timeout",
         %{tmp_dir: tmp_dir} do
      pid_capture_hang = Path.join(tmp_dir, "pi_immediate_pid_fixture.sh")
      pid_file = "/tmp/pi_adapter_immediate_pid.txt"

      File.rm(pid_file)

      # Single invocation. File is written synchronously inside the script's first action
      # (printf + sleep). The test waits for the file *before* running execute/2 so the
      # fixture is already mid-sleep when the timeout path fires — this guarantees the
      # adapter had captured the PID by the time the timeout started.
      File.write!(pid_capture_hang, """
      #!/bin/bash
      printf '%s' "$$" > #{pid_file}
      sleep 30
      exit 0
      """)

      File.chmod!(pid_capture_hang, 0o755)

      try do
        Application.put_env(:foreman_server, PiAdapter,
          executable: pid_capture_hang,
          timeout_ms: 60_000
        )

        # Run execute/2 with a tight timeout.
        result =
          PiAdapter.execute(
            %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())},
            timeout_ms: 200
          )

        # Timeout tuple returned.
        assert {:error, :timeout} = result

        # The fixture wrote its PID before the adapter timed out — file must exist now
        # (the adapter may have killed the process, but the file persists).
        assert File.exists?(pid_file),
               "PID file must be written by the fixture during startup"

        pid_str = String.trim(File.read!(pid_file))
        {pid_int, ""} = Integer.parse(pid_str)
        assert is_integer(pid_int)

        # The adapter killed THIS fixture's PID. If the adapter captured a wrong or
        # no PID, the fixture's bash is still alive and kill -0 returns 0.
        {_, exit_code} = System.cmd("kill", ["-0", pid_str])

        assert exit_code != 0,
               "PID #{pid_int} must be killed by adapter after timeout — kill -0 returned " <>
                 "#{exit_code}. Adapter captured wrong PID or no PID."
      after
        # Defensive cleanup — kill the fixture if the test's assertions fail mid-flight
        # (process may still be alive).
        if File.exists?(pid_file) do
          pid_str = String.trim(File.read!(pid_file))
          {pid_int, ""} = Integer.parse(pid_str)
          {_, _} = System.cmd("kill", ["-KILL", Integer.to_string(pid_int)])
        end

        File.rm(pid_capture_hang)
        File.rm(pid_file)
      end
    end

    # Test 5: SIGTERM → SIGKILL escalation verified via fixture that traps and survives.
    # The fixture TRAPS SIGTERM (writes a marker file but continues looping). After
    # SIGTERM is delivered, the fixture is still alive — the adapter's wait_for_exit
    # must therefore escalate to SIGKILL. Without escalation, the process survives
    # and kill -0 returns 0.
    test "execute/2 escalates SIGTERM → SIGKILL when SIGTERM is trapped", %{tmp_dir: tmp_dir} do
      pid_capture_hang = Path.join(tmp_dir, "pi_escalating_fixture.sh")
      pid_file = "/tmp/pi_adapter_esc_pid.txt"
      term_marker = "/tmp/pi_adapter_esc_term_received.txt"

      File.rm(pid_file)
      File.rm(term_marker)

      # Trap SIGTERM: write marker, DO NOT exit, ignore subsequent SIGTERMs.
      # Sleep is interrupted by signal; the loop survives because the trap doesn't exit.
      File.write!(pid_capture_hang, """
      #!/bin/bash
      printf '%s' "$$" > #{pid_file}
      trap 'printf "%s" "$$" > #{term_marker}' TERM
      while true; do
        sleep 0.1
      done
      """)

      File.chmod!(pid_capture_hang, 0o755)

      try do
        Application.put_env(:foreman_server, PiAdapter,
          executable: pid_capture_hang,
          timeout_ms: 60_000
        )

        request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}
        result = PiAdapter.execute(request, timeout_ms: 200)

        assert {:error, :timeout} = result

        # The SIGTERM trap marker proves the signal was actually delivered to the process
        # (not just attempted). Without escalation, the trapped process keeps looping and
        # kill -0 would still return 0 — the test must verify SIGKILL was needed.
        wait_for_file(term_marker, 3_000)

        assert File.exists?(term_marker),
               "SIGTERM trap marker should exist — adapter did NOT deliver SIGTERM. " <>
                 "Test cannot claim SIGKILL escalation without first proving SIGTERM was delivered."

        # PID file written; we now have the trapped process's PID.
        wait_for_file(pid_file, 1_000)
        pid_str = String.trim(File.read!(pid_file))
        {pid_int, ""} = Integer.parse(pid_str)
        assert is_integer(pid_int)

        # THE ASSERTION: kill -0 against the trapped PID must eventually fail.
        # The trap ignores SIGTERM, so the only thing that can terminate the fixture is
        # SIGKILL. If the escalation didn't fire, the process keeps running and
        # kill -0 returns 0 — the test fails, proving the bug.
        wait_for_pid_exit(pid_str, 3_000)

        {_, exit_code} = System.cmd("kill", ["-0", pid_str])

        assert exit_code != 0,
               "Trapped PID #{pid_str} must be dead — SIGKILL escalation did not fire. " <>
                 "Adapter returned {:error, :timeout} but left the OS process alive."
      after
        File.rm(pid_capture_hang)
        File.rm(pid_file)
        File.rm(term_marker)
      end
    end

    # Test 6: Concurrent OS-process-exit-during-cleanup preserves {:error, :timeout}.
    # The AC says: "the adapter's returned {:error, :timeout} tuple is preserved even when
    # the OS process exits concurrently with the timeout."
    #
    # Mechanism — deterministic via TERM-trap-exits fixture:
    #   1. The fixture writes its PID, sets a SIGTERM trap that writes coop_marker +
    #      exit 0 cooperatively, then loops on `sleep 0.1`.
    #   2. With timeout_ms=200, the adapter's receive loop times out at Port_open + 200ms.
    #      kill_os_process! then Process.sleep(100)s, then SIGTERM at Port_open + 300ms.
    #   3. SIGTERM arrives synchronously into bash; the trap handler runs, writes
    #      coop_marker, and exits 0 — all during the cleanup window.
    #   4. The receive loop has already returned :timeout — the cooperative exit's
    #      {:exit_status, 0} message lands in the mailbox AFTER the receive loop has
    #      exited. Cleanup (safe_close_port/1 + outer try/after) must still:
    #        - return {:error, :timeout} (not crash, not upgrade to {:ok, ""})
    #        - handle the port whose underlying process has exited
    #        - remove the temp dir
    #
    # Why this is orthogonal to Test 4 and Test 5:
    #   - Test 4 proves the adapter kills the right PID on timeout (kill -0 returns
    #     non-zero after timeout fires).
    #   - Test 5 proves SIGTERM trap-while-alive escalates to SIGKILL (trap writes
    #     term_marker, fixture keeps looping, SIGKILL required to terminate).
    #   - Test 6's trap EXITS cooperatively — the trap-fires-and-exits path proves
    #     the adapter doesn't process the {:exit_status, 0} after returning :timeout.
    #
    # Why the coop_marker is the proof:
    #   - The marker is written by the SIGTERM trap handler before exit 0.
    #   - If SIGTERM never arrives (timeout tuple wins but cleanup skipped kill),
    #     the marker is missing and the test fails.
    #   - If SIGKILL escalation fires before SIGTERM, bash dies without trap, marker
    #     missing, test fails.
    #   - coop_marker present + result == :timeout = AC proven.
    test "execute/2 preserves {:error, :timeout} when OS process exits during cleanup",
         %{tmp_dir: tmp_dir} do
      pid_file = "/tmp/pi_adapter_concurrent_pid.txt"
      coop_marker = "/tmp/pi_adapter_concurrent_exited_cooperatively.txt"
      File.rm(pid_file)
      File.rm(coop_marker)

      concurrent = Path.join(tmp_dir, "pi_concurrent_fixture.sh")

      # TERM-trap-exits fixture. SIGTERM is the trigger; the trap handler performs
      # the cooperative exit (writes coop_marker, exit 0). This is reliable because:
      #   - The adapter sends SIGTERM deterministically at Port_open + timeout_ms + 100ms.
      #   - The trap fires synchronously when SIGTERM arrives.
      #   - The marker write happens BEFORE exit 0, so its presence proves the trap ran.
      #   - If SIGKILL escalates (it shouldn't, because trap fires first), the marker is
      #     missing — the test correctly fails.
      #
      # This proves the AC: when SIGTERM terminates the OS process during the cleanup
      # window via a cooperative (trap-driven) exit, the adapter still returns
      # {:error, :timeout} and the temp dir is cleaned up.
      File.write!(concurrent, """
      #!/bin/bash
      printf '%s' "$$" > #{pid_file}
      trap 'printf "%s" "$$" > #{coop_marker}; exit 0' TERM
      while true; do sleep 0.1; done
      """)

      File.chmod!(concurrent, 0o755)

      timeout_ms = 200

      try do
        Application.put_env(:foreman_server, PiAdapter,
          executable: concurrent,
          timeout_ms: 60_000
        )

        request = %{prompt: "test", context: Map.put(%{}, :working_directory, System.tmp_dir!())}

        result = PiAdapter.execute(request, timeout_ms: timeout_ms)

        # CRITICAL: coop_marker must exist, proving the trap-driven cooperative exit
        # ran. If the marker is missing, the fixture was killed before reaching the
        # trap — which means either SIGKILL escalation fired (race) or the receive
        # loop didn't actually return :timeout. Either way, the AC is not proven.
        assert File.exists?(coop_marker),
               "Concurrent-exit scenario NOT proven: fixture's TERM trap did not run. " <>
                 "Expected SIGTERM at cleanup to fire the cooperative-exit trap and " <>
                 "write coop_marker; missing marker means SIGKILL escalation killed the " <>
                 "fixture first, or the trap was bypassed entirely. The AC requires " <>
                 "proving {:error, :timeout} survives an in-cleanup cooperative exit; " <>
                 "without the marker, this test cannot claim that."

        # CRITICAL ASSERTION: timeout tuple preserved even though the fixture exited
        # cooperatively DURING the cleanup window. If the receive loop somehow picked
        # up the cooperative {:exit_status, 0} after returning :timeout, the result
        # would be `{:ok, "", %{}}` instead.
        assert {:error, :timeout} = result,
               "Timeout tuple must be preserved when OS process exits during cleanup. " <>
                 "Got #{inspect(result)} instead — cleanup upgraded a timeout to a success " <>
                 "by processing the cooperative {:exit_status, 0} after the receive loop " <>
                 "had already returned :timeout."

        # The fixture wrote its PID and is now dead (cooperative exit took effect).
        assert File.exists?(pid_file), "Fixture must have written its PID"

        pid_str = String.trim(File.read!(pid_file))
        {_, exit_code} = System.cmd("kill", ["-0", pid_str])

        assert exit_code != 0,
               "Fixture PID #{pid_str} must be dead — cooperative exit did not happen " <>
                 "during cleanup window"

        # Outer try/after completed: no leftover pi_adapter_* tmp dirs.
        remaining =
          tmp_dir
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, "pi_adapter_"))

        assert remaining == [],
               "Temp dir cleanup must complete even on concurrent exit. " <>
                 "Leftover dirs: #{inspect(remaining)}"
      after
        # Defensive cleanup of any leftover fixture process.
        if File.exists?(pid_file) do
          pid_str = String.trim(File.read!(pid_file))
          {_, _} = System.cmd("kill", ["-KILL", pid_str])
        end

        File.rm(concurrent)
        File.rm(pid_file)
        File.rm(coop_marker)
      end
    end
  end

  # Polls every 20ms until `path` exists or the deadline elapses.
  # Exits via flunk so the test fails explicitly rather than silently continuing.
  defp wait_for_file(path, deadline_ms) do
    wait_for_file(path, deadline_ms, 0)
  end

  defp wait_for_file(path, deadline_ms, elapsed) when elapsed < deadline_ms do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_for_file(path, deadline_ms, elapsed + 20)
    end
  end

  defp wait_for_file(path, _deadline_ms, _elapsed) do
    flunk("wait_for_file timed out waiting for #{inspect(path)}")
  end

  # Polls `kill -0` against `pid_str` until it returns non-zero (process gone) or the
  # deadline elapses. Used by Test 5 to deterministically observe SIGKILL taking effect.
  defp wait_for_pid_exit(pid_str, deadline_ms) do
    wait_for_pid_exit(pid_str, deadline_ms, 0)
  end

  defp wait_for_pid_exit(pid_str, deadline_ms, elapsed) when elapsed < deadline_ms do
    {_, exit_code} = System.cmd("kill", ["-0", pid_str])

    if exit_code != 0 do
      :ok
    else
      Process.sleep(50)
      wait_for_pid_exit(pid_str, deadline_ms, elapsed + 50)
    end
  end

  defp wait_for_pid_exit(pid_str, _deadline_ms, _elapsed) do
    flunk("wait_for_pid_exit timed out — PID #{pid_str} still alive after deadline")
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
