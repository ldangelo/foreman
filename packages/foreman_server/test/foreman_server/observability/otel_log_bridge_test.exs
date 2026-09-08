defmodule ForemanServer.Observability.OtelLogBridgeTest do
  use ExUnit.Case, async: false

  require Logger

  alias ForemanServer.Observability.OtelLogBridge

  setup do
    on_exit(fn -> OtelLogBridge.uninstall() end)
    :ok
  end

  test "pins current dependency contract and absent direct logs exporter fallback" do
    source =
      File.read!(
        Path.expand(
          "../../../deps/opentelemetry_exporter/src/opentelemetry_exporter.erl",
          __DIR__
        )
      )

    assert source =~ "export(logs, Logs, Resource, State)"
    assert source =~ "otel_exporter_logs_otlp:export(Logs, Resource, State)"

    assert File.exists?(
             Path.expand(
               "../../../deps/opentelemetry_exporter/src/opentelemetry_exporter_logs_service_pb.erl",
               __DIR__
             )
           )

    refute File.exists?(
             Path.expand(
               "../../../deps/opentelemetry_exporter/src/otel_exporter_logs_otlp.erl",
               __DIR__
             )
           )

    assert {:error, reason} = OtelLogBridge.export(%{resource_logs: []}, %{exporter: :otel})
    assert reason in [:otel_logs_protobuf_unavailable, :missing_endpoint]
  end

  test "payload preserves severity/module/message and redacts sensitive metadata" do
    payload =
      OtelLogBridge.otel_payload(:error, "failed DATABASE_URL=postgres://u:p@host/db", %{
        run_id: "run-1",
        mfa: {__MODULE__, :sample, 1},
        line: 42,
        output: "secret output"
      })

    [resource_logs] = payload.resource_logs
    [scope_logs] = resource_logs.scope_logs
    [record] = scope_logs.log_records

    assert record.severity_text == "ERROR"
    assert record.severity_number == 17
    assert record.body.string_value =~ "DATABASE_URL=[REDACTED]"
    attrs = Map.new(record.attributes, &{&1.key, &1.value})
    assert attrs["run_id"].string_value == "run-1"
    assert attrs["module"].string_value =~ "OtelLogBridgeTest"
    assert attrs["line"].int_value == 42
    refute Map.has_key?(attrs, "output")
  end

  test "installed handler captures one exported record and preserves console handler" do
    {:ok, original} = :logger.get_handler_config(:default)
    assert :ok = OtelLogBridge.install(enabled: true, exporter: {:capture, self()}, level: :info)
    assert {:ok, ^original} = :logger.get_handler_config(:default)

    Logger.info("foreman signoz capture", run_id: "run-capture", operation: "test")

    assert_receive {:foreman_signoz_log, payload}, 500
    [resource_logs] = payload.resource_logs
    [scope_logs] = resource_logs.scope_logs
    assert [_record] = scope_logs.log_records
    refute_receive {:foreman_signoz_log, _duplicate}, 100
  end
end
