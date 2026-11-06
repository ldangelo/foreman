# ops/otel-collector/

A small OpenTelemetry Collector that bridges Foreman's OTLP exporter to a
Langfuse instance. This is the dev-side observability piece; the prod path
(configured via `packages/foreman_server/config/prod.exs`) sends spans
directly to Langfuse.

## Why this exists

`ForemanServer.AgentRuntime.OtelSpanEmitter` (the bridge between
`ForemanServer.Telemetry` and the OpenTelemetry SDK) ships every emitted
span through `opentelemetry_exporter`'s batch processor. In dev, that
exporter needs an OTLP endpoint. Two paths are wired:

| Path | Where | What for |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318` | dev | Send to this collector, which forwards to Langfuse |
| `OTEL_EXPORTER_OTLP_ENDPOINT=http://langfuse-web:3000/api/public/otel` | direct | Ship spans straight to Langfuse (the OTLP HTTP exporter appends `/v1/traces`) |

This collector is the dev path. It adds:
- batching and retries so a Langfuse restart doesn't drop spans,
- one place to set the Langfuse auth header (HTTP Basic with
  public:secret base64-encoded),
- a single config knob for pointing at a remote Langfuse via
  `LANGFUSE_HOST=https://cloud.langfuse.com`.

## Architecture

```
foreman_server
    │  OTLP/HTTP
    │  POST /v1/traces
    ▼
otel-collector:4318  ◄── this repo, ops/otel-collector/
    ├─ HTTP Basic (public:secret) POST /api/public/otel/v1/traces
    │    ▼
    │  langfuse-web:3000    ◄── external: ~/Development/Sunstone/litellm-langfuse-stack/
    └─ Bearer (LITELLM_TRACING_KEY) POST /v1/traces
         ▼
       lens:4318
```

## Files

- `Dockerfile` — multi-stage (alpine + contrib) with healthcheck on :13133.
- `config.template.yaml` — single `pipelines:` map (traces + logs),
  receivers `otlp` (http + grpc), exporters `debug` (verbosity `basic`:
  counts only, so message text in span attributes never reaches the container
  log; read a span's attributes in the Lens UI, or temporarily set `detailed`,
  which writes message text to the log), `otlphttp/langfuse` and
  `otlphttp/lens`, batch processor, health extension. **Envsubst at container start.**
- `entrypoint.sh` — envsubst's `${LANGFUSE_HOST}` and computes
  `LANGFUSE_BASIC_AUTH = base64(public:secret)`, then execs
  `/otelcol-contrib --config=$CONF`. The `--config` flag is required in
  contrib 0.104.x; omitting it produces an immediate restart loop.
- `docker-compose.yml` — runs the collector only; attaches to the
  `litellm-langfuse-stack_default` external network so `langfuse-web:3000`
  resolves by name.

## Usage

```bash
# From the foreman repo root, via devbox:
devbox run up                    # bring up Langfuse stack + collector
devbox run logs                  # tail collector stdout
devbox run test:langfuse         # send a synthetic OTLP trace and verify
devbox run down                  # tear down collector + stack

# Without devbox:
docker compose -f ops/otel-collector/docker-compose.yml up -d --build
docker compose -f ops/otel-collector/docker-compose.yml logs -f otel-collector
docker compose -f ops/otel-collector/docker-compose.yml down

# Validate the rendered config without booting the collector:
docker compose -f ops/otel-collector/docker-compose.yml \
  run --rm --profile check validate
```

## Required env

The collector reads:

- `LANGFUSE_HOST` (optional, default `langfuse-web:3000`)
- `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` (from the stack's `.env`)
- `LITELLM_TRACING_KEY` (optional): the dedicated Lens tracing key, created in
  Lens Home under "Tracing key" and saved in this repo's git-ignored `.env`.
  It authorises trace uploads only; never use a Lens admin or gateway secret.
  When it is empty or wrong the `otlphttp/lens` exporter gets `401` from Lens
  (Langfuse delivery is unaffected). `entrypoint.sh` must export it, because
  `envsubst` only substitutes exported variables.

The template is baked into the image: after changing it, rebuild and recreate
the collector (`docker compose up -d --build otel-collector`), with BOTH the
stack's `.env` and this repo's `.env` sourced (the devbox scripts do this).
Sourcing only one leaves the other exporter's header empty. The compose file
lives in `ops/otel-collector/`, so it does not read the repo-root `.env` by
itself.

The devbox scripts source the stack's `.env` automatically. If you invoke
docker compose directly, set them yourself.

## Known limitations

- `otlphttp/langfuse` is required instead of the older `otlp` exporter in
  contrib 0.104.x because the latter rejects URLs with paths after `:port`
  (parses them as invalid ports). The newer exporter accepts full URLs.
- A duplicate top-level `service.pipelines:` key in `config.template.yaml`
  silently overwrites the first map (verified empirically 2026-08-21).
  Don't add a second.
- The collector attaches to the **stack's** network; it cannot run without
  that compose being up. Bring the full stack up first via `devbox run up`
  (which starts `~/Development/Sunstone/litellm-langfuse-stack/` and then
  this collector) — or start both compose projects directly.
