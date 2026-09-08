import Config

# TRD-022 owns importing this file from config/config.exs.
# Production secrets are injected at release boot by
# ForemanServer.ConfigProviders.Secrets.

phx_host = System.get_env("PHX_HOST", "localhost")
secret_source = System.get_env("FOREMAN_SERVER_SECRET_SOURCE", "auto")

config :foreman_server, ForemanServer.EventStore,
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public"

config :foreman_server, ForemanServer.Repo, []

config :foreman_server, ForemanServerWeb.Endpoint,
  server: true,
  debug_errors: false,
  check_origin: ["//#{phx_host}", "https://#{phx_host}"]

# Plan workflow phases are long-running (ensemble full PRD/TRD/implementation
# skill invocations can exceed 10 minutes on first run with cold pi skill cache
# and a large implementation surface; implement-trd-beads for the MCP server
# has 48 tasks over ~90h of estimated work). Without this block, prod falls
# through to FailurePolicy's built-in default of timeout_ms: 60_000 which
# aborts every phase mid-skill. Mirrors dev.exs verbatim.
config :foreman_server, :agent_runtime,
  default_timeout_ms: 1_800_000,
  failure_policies: %{
    "create-prd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "create-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "refine-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "refine-prd" => %{fallback: false, max_attempts: 1, timeout_ms: 600_000},
    "implement-trd" => %{fallback: false, max_attempts: 1, timeout_ms: 3_600_000},
    "implement-trd-beads" => %{fallback: false, max_attempts: 1, timeout_ms: 3_600_000}
  }

config :foreman_server, :prod_secret_provider,
  provider: ForemanServer.ConfigProviders.Secrets,
  source: secret_source,
  mappings: [
    [
      app: :foreman_server,
      key: ForemanServer.EventStore,
      config_key: :url,
      env: "EVENTSTORE_URL",
      secret_key: :eventstore_url
    ],
    [
      app: :foreman_server,
      key: ForemanServer.Repo,
      config_key: :url,
      env: "DATABASE_URL",
      secret_key: :database_url
    ],
    [
      app: :foreman_server,
      key: :secrets,
      config_key: :database_password,
      env: "DATABASE_PASSWORD",
      secret_key: :database_password,
      required: false
    ],
    [
      app: :foreman_server,
      key: ForemanServerWeb.Endpoint,
      config_key: :secret_key_base,
      env: "SECRET_KEY_BASE",
      secret_key: :secret_key_base
    ],
    [
      app: :foreman_server,
      key: ForemanServerWeb.Endpoint,
      config_key: :signing_salt,
      env: "SIGNING_SALT",
      secret_key: :signing_salt,
      nested: :live_view
    ],
    [
      app: :foreman_server,
      key: :api_bearer_token,
      config_key: nil,
      env: "FOREMAN_API_TOKEN",
      secret_key: :api_bearer_token,
      required: false
    ]
  ]

# Jido checkpoint store (TRD-2026-4212be7e, JCR-T004) — off in prod
# by default. Operators enable via
#   JIDO_CHECKPOINT_DATABASE_URL=postgres://... \
#   FOREMAN_JIDO_ECTO_ENABLED=true \
#   elixir --no-halt -S mix run --no-compile
# (or by setting config :foreman_server, :jido_ecto, enabled: true).
config :foreman_server, :jido_ecto, enabled: false
# TRD-2026-4212be7e JOT-T001: jido_otel runtime OTLP endpoint for
# Langfuse-compatible ingestion. Endpoint comes from the standard
# OTEL env var; Langfuse OTLP ingest uses HTTP Basic auth with the
# public:secret key pair.
otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
langfuse_public_key = System.get_env("LANGFUSE_PUBLIC_KEY", "")
langfuse_secret_key = System.get_env("LANGFUSE_SECRET_KEY", "")
# Langfuse v3 OTLP ingest uses HTTP Basic auth with the public:secret
# key pair (verified empirically 2026-08-21 against
# /api/public/otel/v1/traces on the local litellm-langfuse stack:
# Bearer with public-only returns 403, Basic with both keys returns
# 400-on-empty-payload which is the expected post-auth response).
# Earlier this session shipped Bearer-with-public-only which is the
# standard Langfuse SDK error case; this fixes it.
#
# opentelemetry_exporter expects otlp_headers as a list of {binary, binary}
# tuples (per opentelemetry_exporter.erl doc comment), not a map.
otlp_headers =
  if langfuse_public_key != "" and langfuse_secret_key != "" do
    encoded = Base.encode64("#{langfuse_public_key}:#{langfuse_secret_key}")
    [{"Authorization", "Basic " <> encoded}]
  else
    []
  end

config :jido_otel, otlp_endpoint: otlp_endpoint, otlp_headers: otlp_headers

# OpenTelemetry OTLP exporter override (TRD-2026-4212be7e / JOT-T001).
# Base config sets http://localhost:4318 + http_protobuf; in prod we read
# the standard OTEL env var and add Langfuse's auth header so the SDK's
# batch processor ships spans to the configured collector.
config :opentelemetry_exporter,
  otlp_endpoint: otlp_endpoint,
  otlp_protocol: :http_protobuf,
  otlp_headers: otlp_headers

# SigNoz operational-log config (FOREMAN_SIGNOZ_*) is parsed once in
# config.exs for every MIX_ENV, including prod — no production-specific
# override is needed here. See config.exs for the validation contract.

config :foreman_server, ForemanServer.Agents.JidoCheckpointStore.Repo,
  url: System.get_env("JIDO_CHECKPOINT_DATABASE_URL", "")
