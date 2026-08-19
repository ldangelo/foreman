#!/usr/bin/env bash
# JRM-T004 — Evaluate upstream Jido release and adopt-or-reject.
#
# Per TRD-2026-4212be7e / JRM-T004: when upstream Jido release detected,
# run the action + signal test suite. Pass → adopt upstream release;
# fail → do NOT adopt. This script is invoked by
# `.github/workflows/jido-upstream-upgrade.yml` after deps have been
# refreshed against the candidate upstream pin.
#
# Exit codes:
#   0  — tests passed, ADOPT upstream release
#   1  — tests failed, REJECT upstream release
#   2  — non-retryable evaluation error (e.g. deps.get failed)
set -euo pipefail

# Resolve foreman_server package directory relative to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKAGE_DIR="${REPO_ROOT}/packages/foreman_server"

if [[ ! -d "${PACKAGE_DIR}" ]]; then
  echo "[JRM-T004] FATAL: package directory not found at ${PACKAGE_DIR}" >&2
  exit 2
fi

echo "[JRM-T004] Starting upgrade evaluation at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
cd "${PACKAGE_DIR}"

# Refresh deps against the upstream pin recorded in mix.lock.
if ! mix deps.get; then
  echo "[JRM-T004] mix deps.get failed — non-retryable evaluation error" >&2
  exit 2
fi

# Run the action + signal test suites. These are the suites that cover
# the Jido action/signal contract (TRD-083 representative action + TRD-061
# LLM call site + TRD-062 signal dispatch).
if mix test test/foreman_server/agents/ test/foreman_server/agent_runtime/; then
  echo "[JRM-T004] Action and signal tests PASSED — adopt upstream release"
  exit 0
else
  echo "[JRM-T004] Action and signal tests FAILED — do NOT adopt upstream release"
  exit 1
fi
