defmodule ForemanServer.Observability.DocsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  @signoz_env_vars [
    "FOREMAN_SIGNOZ_LOGS_ENABLED",
    "FOREMAN_SIGNOZ_OTLP_ENDPOINT",
    "FOREMAN_SIGNOZ_OTLP_HEADERS",
    "FOREMAN_SIGNOZ_LOG_LEVEL"
  ]

  # The five-file documentation gate (AGENTS.md "Documentation Discipline"):
  # every externally-visible identifier a fix/feature adds must be findable
  # in all five. A test that reads only one of them (as this file used to)
  # would pass while README.md/CLAUDE.md/AGENTS.md/docs/cli-reference.md
  # silently dropped or never gained a var name.
  @doc_gate_files [
    "README.md",
    "docs/user-guide.md",
    "docs/cli-reference.md",
    "AGENTS.md",
    "CLAUDE.md"
  ]

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

  test "all five documentation-gate files name every SigNoz env var" do
    for path <- @doc_gate_files do
      contents = File.read!(Path.join(@repo_root, path))

      for var <- @signoz_env_vars do
        assert contents =~ var, "#{path} is missing #{var}"
      end
    end
  end

  test "collector example keeps logs pipeline separate from traces" do
    config = File.read!(Path.join(@repo_root, "ops/otel-collector/signoz-logs.example.yaml"))

    assert config =~ "otlphttp/signoz_logs"
    assert config =~ "logs:"
    refute config =~ "otlphttp/langfuse"

    # Pin the *logs* pipeline's own exporters list (not just "these strings
    # appear somewhere in the file") so a SigNoz exporter declared but wired
    # into a different pipeline, or a `logs:` pipeline quietly repointed at
    # Langfuse, fails this test instead of passing on substring presence.
    [_, after_logs] = String.split(config, ~r/\blogs:[ \t]*\n/, parts: 2)
    [logs_pipeline | _] = String.split(after_logs, ~r/\n\S/, parts: 2)

    assert logs_pipeline =~ ~r{exporters:\s*\[[^\]\n]*\botlphttp/signoz_logs\b[^\]\n]*\]}
    refute logs_pipeline =~ "langfuse"
  end
end
