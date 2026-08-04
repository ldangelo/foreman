defmodule ForemanServer.AgentRuntime.PiAdapterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.Adapters.PiAdapter

  @moduletag :pi_adapter

  # Fixture executables stored in tmp_dir
  @success_fixture "pi_success_fixture.sh"
  @fail_fixture "pi_fail_fixture.sh"
  @hang_fixture "pi_hang_fixture.sh"
  @contract_fixture "pi_contract_fixture.sh"

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

    # Save original config
    original_config = Application.get_env(:foreman_server, PiAdapter, [])

    on_exit(fn ->
      # Cleanup fixture files
      File.rm(Path.join(tmp_dir, @success_fixture))
      File.rm(Path.join(tmp_dir, @fail_fixture))
      File.rm(Path.join(tmp_dir, @hang_fixture))
      File.rm(Path.join(tmp_dir, @contract_fixture))
      # Cleanup contract artifacts
      File.rm("/tmp/pi_contract_argv.txt")
      File.rm("/tmp/pi_contract_request.txt")
      File.rm("/tmp/pi_contract_mode.txt")

      # Restore original config
      Application.put_env(:foreman_server, PiAdapter, original_config)
    end)

    %{
      success_path: success_path,
      fail_path: fail_path,
      hang_path: hang_path,
      contract_path: contract_path,
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
      request = %{prompt: "test", context: %{}}
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

      request = %{prompt: "test prompt", context: %{}}
      result = PiAdapter.execute(request, [])

      assert {:ok, content, %{}} = result
      assert content == "hello from pi\n"
    end
  end

  describe "execute/2 — contract validation" do
    test "argv contains fixed flags", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{prompt: "test", context: %{}}
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

      request = %{prompt: "test", context: %{}}
      PiAdapter.execute(request, [])

      # Verify mode captured
      assert File.exists?("/tmp/pi_contract_mode.txt")
      mode = String.trim(File.read!("/tmp/pi_contract_mode.txt"))
      assert mode == "600"
    end

    test "request file framing is byte-exact with JSON round-trip", %{contract_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      context = %{"key" => "value", "nested" => %{"n" => 1}}
      request = %{prompt: "hello world", context: context}
      PiAdapter.execute(request, [])

      content = File.read!("/tmp/pi_contract_request.txt")

      # Byte-exact framing: header + blank line + prompt bytes + blank
      # line + context header + blank line + JSON segment + trailing
      # newline. Equals (not substring) catches any extra/misplaced
      # bytes that the TRD-004 framing AC forbids.
      json_segment = Jason.encode!(context)

      expected =
        "# Prompt\n\nhello world\n\n# Context (JSON)\n\n" <>
          json_segment <> "\n"

      assert content == expected

      # JSON segment round-trip equality against the original context
      # map (TRD-004 §"Pi Process Protocol" semantic verification).
      assert Jason.decode!(json_segment) == context
    end
  end

  describe "execute/2 — failure" do
    test "returns {:error, reason} on non-zero exit", %{fail_path: path} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{prompt: "test prompt", context: %{}}
      result = PiAdapter.execute(request, [])

      assert {:error, {:non_zero_exit, 1}} = result
    end

    test "temp file is cleaned up after failure", %{fail_path: path, tmp_dir: tmp_dir} do
      Application.put_env(:foreman_server, PiAdapter, executable: path)

      request = %{prompt: "test prompt", context: %{}}
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

      request = %{prompt: "test prompt", context: %{}}
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

      request = %{prompt: "test prompt", context: %{}}
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

      request = %{prompt: "test prompt", context: %{}}
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

        request = %{prompt: "test", context: %{}}
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
end
