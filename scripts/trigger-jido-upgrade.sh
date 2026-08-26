#!/usr/bin/env bash
# JRM-T003 trigger — send repository_dispatch type=jido_release to
# .github/workflows/jido-upstream-upgrade.yml.
#
# Usage:
#   scripts/trigger-jido-upgrade.sh                        # defaults: Sunstone-Partners/foreman
#   scripts/trigger-jido-upgrade.sh --dry-run             # print gh command without running
#   scripts/trigger-jido-upgrade.sh --owner Acme --repo my-fork   # custom target
#
# Prerequisites:
#   gh CLI authenticated: gh auth status
set -euo pipefail

OWNER="Sunstone-Partners"
REPO="foreman"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --owner)   OWNER="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [--dry-run] [--owner OWNER] [--repo REPO]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

TARGET="${OWNER}/${REPO}"

echo "[JRM-T003] Triggering jido-upstream-upgrade on ${TARGET}..."

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would run:"
  echo "  gh api repos/${TARGET}/dispatches --method POST --field event_type=jido_release"
  exit 0
fi

gh api repos/"${TARGET}"/dispatches \
  --method POST \
  --field event_type=jido_release

echo "[JRM-T003] repository_dispatch dispatched successfully."
echo "Watch at: https://github.com/${TARGET}/actions/workflows/jido-upstream-upgrade.yml"
