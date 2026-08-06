defmodule ForemanServer.TaskProviders.JsonSchemaCacheTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.JsonSchemaCache.State

  @cache_name :foreman_server_json_schema_cache
  @source_file Path.expand(
                 "../../../lib/foreman_server/task_providers/json_schema_cache.ex",
                 __DIR__
               )
  @refresh_event [:foreman_server, :task_provider, :beads, :capabilities, :refreshed]

  setup_all do
    {:ok, _telemetry_apps} = Application.ensure_all_started(:telemetry)
    {:ok, _mox_apps} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    if pid = Process.whereis(@cache_name) do
      GenServer.stop(pid)
    end

    on_exit(fn ->
      if pid = Process.whereis(@cache_name) do
        GenServer.stop(pid)
      end
    end)

    {:ok, source: File.read!(@source_file)}
  end

  test "fetch at boot populates cache", %{source: _source} do
    expect_schema_boot_fetches("v1", 4)

    pid = start_supervised!(JsonSchemaCache)
    state = :sys.get_state(@cache_name)

    assert Process.whereis(@cache_name) == pid
    assert %State{} = state

    assert Map.keys(state.schemas) |> Enum.sort() == [
             :commands,
             :error,
             :issue_details,
             :ready_issue
           ]

    assert state.version == "v1"
    assert %DateTime{} = state.last_refresh
  end

  test "validate/2 reuses boot cache on repeated calls" do
    expect_schema_boot_fetches("v1", 4)
    start_supervised!(JsonSchemaCache)

    payload = %{"id" => "ready-1", "title" => "Ship it"}

    assert :ok == JsonSchemaCache.validate(:ready_issue, payload)
    assert :ok == JsonSchemaCache.validate(:ready_issue, payload)
  end

  test "24h refresh ticker uses default interval and send_after", %{source: source} do
    assert source =~ "@default_refresh_interval_ms 24 * 60 * 60 * 1000"
    assert source =~ "Process.send_after(self(), :refresh, refresh_interval_ms)"
  end

  test "contract-version refresh emits capabilities refreshed telemetry" do
    expect_schema_fetches_with_version_change()
    handler_id = attach_telemetry(@refresh_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_supervised!(JsonSchemaCache)
    send(Process.whereis(@cache_name), :refresh)

    assert_receive {:telemetry, @refresh_event, %{count: 1}, %{contract_version: "v2"} = meta},
                   1_000

    assert meta.schema_count == 4
    assert %DateTime{} = meta.refreshed_at

    assert %State{version: "v2"} = :sys.get_state(@cache_name)
  end

  test "validate/2 returns errors list for invalid payload" do
    expect_schema_boot_fetches("v1", 4)
    start_supervised!(JsonSchemaCache)

    assert :ok == JsonSchemaCache.validate(:ready_issue, %{"id" => "x", "title" => "y"})

    assert {:error, errors} = JsonSchemaCache.validate(:ready_issue, %{"id" => 123})

    assert Enum.any?(errors, &(&1 == %{path: ["title"], message: "is required"}))
    assert Enum.any?(errors, &(&1 == %{path: ["id"], message: "expected type string"}))
  end

  defp expect_schema_boot_fetches(version, count) do
    expect(BrRunnerMock, :cmd, count, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      {:ok, %{stdout: Jason.encode!(schema_document(schema_name, version))}}
    end)
  end

  defp expect_schema_fetches_with_version_change do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(BrRunnerMock, :cmd, 8, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      call_number = Agent.get_and_update(counter, fn current -> {current + 1, current + 1} end)
      version = if call_number <= 4, do: "v1", else: "v2"

      {:ok, %{stdout: Jason.encode!(schema_document(schema_name, version))}}
    end)
  end

  defp schema_document("ready-issue", _version) do
    %{
      "type" => "object",
      "required" => ["id", "title"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("issue-details", _version) do
    %{
      "type" => "object",
      "required" => ["id", "description"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("error", _version) do
    %{
      "type" => "object",
      "required" => ["code", "message"],
      "properties" => %{
        "code" => %{"type" => "string"},
        "message" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("commands", version) do
    %{
      "type" => "object",
      "metadata" => %{"contractVersion" => version},
      "properties" => %{
        "commands" => %{"type" => "array"}
      }
    }
  end

  defp attach_telemetry(event) do
    handler_id = "json-schema-cache-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    handler_id
  end

  def handle_telemetry(telemetry_event, measurements, metadata, pid) do
    send(pid, {:telemetry, telemetry_event, measurements, metadata})
  end
end
