defmodule ForemanServer.Observability.DocsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  test "operator docs list SigNoz env vars, retention, and Langfuse boundary" do
    docs = File.read!(Path.join(@repo_root, "docs/user-guide.md"))

    assert docs =~ "FOREMAN_SIGNOZ_LOGS_ENABLED"
    assert docs =~ "FOREMAN_SIGNOZ_OTLP_ENDPOINT"
    assert docs =~ "FOREMAN_SIGNOZ_OTLP_HEADERS"
    assert docs =~ "FOREMAN_SIGNOZ_LOG_LEVEL"
    assert docs =~ "Langfuse traces"
    assert docs =~ "30-day default"
    assert docs =~ "retention policy"
  end

  test "collector example keeps logs pipeline separate from traces" do
    config = File.read!(Path.join(@repo_root, "ops/otel-collector/signoz-logs.example.yaml"))

    assert config =~ "otlphttp/signoz_logs"
    assert config =~ "logs:"
    refute config =~ "otlphttp/langfuse"
  end
end
