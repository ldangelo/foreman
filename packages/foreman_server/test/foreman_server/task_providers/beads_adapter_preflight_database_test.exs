defmodule ForemanServer.TaskProviders.BeadsAdapterPreflightDatabaseTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError

  @preflight_ok_event [:foreman_server, :task_provider, :beads_adapter, :preflight, :ok]
  @preflight_error_event [:foreman_server, :task_provider, :beads_adapter, :preflight, :error]
  @missing_database_stderr ~s({"code":"DATABASE_NOT_FOUND","message":"raw","hint":"raw hint","retryable?":true})

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    :ok
  end

  test "preflight_database calls br where with exact argv via :where request" do
    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:where, %{database_path: "/abs/path"}}
      assert project_config == %{database_path: "/abs/path"}
      assert opts == [timeout_ms: 30_000]
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.preflight_database("/abs/path")
    assert :ok == Mox.verify!()
  end

  test "preflight_database translates :where request to br where --db <path> --json argv" do
    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:where, %{database_path: "/abs/path"}}
      assert project_config == %{database_path: "/abs/path"}
      assert opts == [timeout_ms: 123]
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.preflight_database("/abs/path", timeout_ms: 123)
    assert :ok == Mox.verify!()
  end

  test "missing-file path returns ProviderError{DATABASE_NOT_FOUND, retryable?: false}" do
    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:where, %{database_path: "/abs/path"}}
      assert project_config == %{database_path: "/abs/path"}
      assert opts == [timeout_ms: 30_000]

      {:error, %{stdout: "", stderr: @missing_database_stderr, exit_code: 2}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.preflight_database("/abs/path")

    assert provider_error.code == "DATABASE_NOT_FOUND"
    assert provider_error.retryable? == false
    assert provider_error.message == "Configured Beads database was not found."
    assert provider_error.hint == "Verify the configured database path before retrying."
    refute provider_error.message == "raw"
    refute provider_error.hint == "raw hint"

    assert provider_error.context == %{
             id: "DATABASE_NOT_FOUND",
             command: "br where",
             exit_code: 2,
             stderr_byte_count: byte_size(@missing_database_stderr),
             sanitized?: true,
             redacted_fields: [],
             missing_fields: []
           }

    assert :ok == Mox.verify!()
  end

  test "preflight_database makes exactly one br call" do
    expect(BrRunnerMock, :cmd, 1, fn request, project_config, opts ->
      assert request == {:where, %{database_path: "/abs/path"}}
      assert project_config == %{database_path: "/abs/path"}
      assert opts == [timeout_ms: 30_000]
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.preflight_database("/abs/path")
    assert :ok == Mox.verify!()
  end

  test "preflight_database emits telemetry on success" do
    handler_id = attach_telemetry(@preflight_ok_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: "/abs/path"}},
                                     %{database_path: "/abs/path"},
                                     [timeout_ms: 30_000] ->
      {:ok, %{stdout: "{}", stderr: "", exit_code: 0}}
    end)

    assert :ok == BeadsAdapter.preflight_database("/abs/path")

    assert_receive {:telemetry, @preflight_ok_event, %{system_time: system_time}, metadata}, 1_000
    assert is_integer(system_time)
    assert metadata == %{argv: ["where", "--db", "/abs/<redacted:9>", "--json"]}
    assert :ok == Mox.verify!()
  end

  test "preflight_database emits telemetry on error" do
    handler_id = attach_telemetry(@preflight_error_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    expect(BrRunnerMock, :cmd, 1, fn {:where, %{database_path: "/abs/path"}},
                                     %{database_path: "/abs/path"},
                                     [timeout_ms: 30_000] ->
      {:error, %{stdout: "", stderr: @missing_database_stderr, exit_code: 2}}
    end)

    assert {:error, %ProviderError{} = provider_error} =
             BeadsAdapter.preflight_database("/abs/path")

    assert_receive {:telemetry, @preflight_error_event, %{system_time: system_time}, metadata},
                   1_000

    assert is_integer(system_time)
    assert metadata.argv == ["where", "--db", "/abs/<redacted:9>", "--json"]
    refute Map.has_key?(metadata, :database_path)
    assert metadata.error == provider_error
    assert provider_error.code == "DATABASE_NOT_FOUND"
    assert provider_error.retryable? == false
    assert provider_error.context.command == "br where"
    assert provider_error.context.exit_code == 2
    assert :ok == Mox.verify!()
  end

  defp attach_telemetry(event) do
    handler_id = "beads-adapter-preflight-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    handler_id
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
