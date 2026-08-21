# Build context is ./otel-collector/ in the foreman repo.
#
# Custom image so we can run envsubst at container start (the base image does
# not expand ${VAR} inside the YAML config in all versions of contrib). Keep
# the image lean — `alpine` base + envsubst (via `gettext`) + the contrib
# collector binary.
#
# Note: contrib 0.104.x ships the binary at /otelcol-contrib and the default
# config at /etc/otelcol-contrib/config.yaml. We template the latter.

FROM otel/opentelemetry-collector-contrib:0.104.0 AS collector
FROM alpine:3.19

RUN apk add --no-cache bash gettext

# Collector binary + bundled default config dir from the contrib image.
COPY --from=collector /otelcol-contrib /otelcol-contrib
COPY --from=collector /etc/otelcol-contrib /etc/otelcol-contrib

# Replace the bundled config with our template + entrypoint. The rendered
# config lands at /etc/otelcol-contrib/config.yaml, which is the path the
# collector finds when started with --config=...
COPY config.template.yaml /etc/otelcol-contrib/config.template.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4317 4318 13133

# Health check: contrib exposes JSON status on /status when the
# health_check extension is enabled (it is, see config.template.yaml).
HEALTHCHECK --interval=5s --timeout=5s --start-period=10s --retries=20 \
    CMD wget -qO- http://localhost:13133/status | grep -q '"status":"Server available"' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
