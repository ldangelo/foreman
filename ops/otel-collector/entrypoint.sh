#!/bin/sh
# Templates the collector config from env vars (LANGFUSE_PUBLIC_KEY +
# LANGFUSE_SECRET_KEY + LANGFUSE_HOST), then execs the collector binary.
#
# The base image is `otel/opentelemetry-collector-contrib:0.104.x`, which
# ships the binary at /otelcol-contrib and the default config at
# /etc/otelcol-contrib/config.yaml. We must rewrite ${LANGFUSE_*}
# placeholders BEFORE the collector parses the file because contrib 0.x
# does NOT expand env vars inside YAML on its own (the
# `unifyEnvVarExpansion` feature gate covers some vars but not exporter
# headers in all versions). envsubst is the canonical portable substitute.
#
# Two config-side guards we resolve here, not in the YAML:
#   1. ${LANGFUSE_BASIC_AUTH} is computed from PUBLIC_KEY + SECRET_KEY,
#      base64-encoded. The template references this var so we don't have to
#      teach envsubst multi-line shell expansions.
#   2. ${LANGFUSE_HOST} defaults to the compose-network hostname:port form
#      ("langfuse-web:3000"). The YAML wraps it as http://${LANGFUSE_HOST}/...
#      so an operator who overrides LANGFUSE_HOST to a remote URL gets a
#      working URL without editing the template.
#
# Contrib 0.104.x's --config flag has no implicit default — it MUST be
# passed explicitly (verified with `otelcol-contrib --help` 2026-08-21).
# Passing --config here; otherwise the binary errors with
#   "at least one config flag must be provided"
# and the container restart loop never recovers.

set -eu

# Paths match the contrib 0.104.x image layout:
#   /otelcol-contrib                         — binary
#   /etc/otelcol-contrib/config.yaml         — default config (overwritten)
#   /etc/otelcol-contrib/config.template.yaml— envsubst source (read-only mount)
CONF=/etc/otelcol-contrib/config.yaml
TEMPLATE=/etc/otelcol-contrib/config.template.yaml

# Defaults: for the local compose stack, langfuse-web is on the internal
# compose network at port 3000. Operators can override via compose env: or
# `docker run -e LANGFUSE_HOST=...`.
LANGFUSE_HOST="${LANGFUSE_HOST:-langfuse-web:3000}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"

# Compute the HTTP Basic auth header value (empty string if either key is
# missing — the collector will then omit the header entirely). Base64 must
# NOT include a trailing newline; `base64` (without -w 0 on GNU coreutils)
# appends one, so we strip it explicitly. `printf` (not `echo`) avoids the
# trailing newline that `echo` adds on some shells.
if [ -n "$LANGFUSE_PUBLIC_KEY" ] && [ -n "$LANGFUSE_SECRET_KEY" ]; then
  LANGFUSE_BASIC_AUTH="$(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64 | tr -d '\n')"
else
  LANGFUSE_BASIC_AUTH=""
fi
export LANGFUSE_HOST LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_BASIC_AUTH

envsubst < "$TEMPLATE" > "$CONF"

exec /otelcol-contrib --config="$CONF" "$@"
