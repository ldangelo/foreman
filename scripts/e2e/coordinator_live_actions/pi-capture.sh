#!/bin/bash
# Template of the `pi` shim scripts/e2e/coordinator_live_actions.sh puts first on the server's PATH (E2E_PATH_PREFIX) when the
# coordinator runs on pi (COORD_PROVIDER=pi). The script copies it to <shim dir>/pi, replacing the two __PLACEHOLDERS__.
#
# What it is for: Foreman reads pi's usage from pi's own `--mode json` event stream, and a coordinator turn (`no_session: true`)
# leaves no session file, so nothing else on disk says what pi reported. This shim keeps that raw stream (one file per pi
# `--mode json` run, the run's stdout byte for byte) so the harness can add up what pi itself reported and compare it with what
# Foreman recorded (`CoordinatorUsageRecorded`, `foreman usage --by role`).
#
# It changes nothing else: every call is forwarded to the real pi with its own arguments, stdin and stdout, and the shim exits
# with pi's exit status (pipefail). A call that is not a `--mode json` run (the server's `pi --list-models` / `--help` /
# `--version` probes) is exec'd untouched. This shim's directory is dropped from PATH, so pi is found by name as usual.

SHIM_DIR=__SHIM_DIR__
CAPTURE_DIR=__CAPTURE_DIR__

new=""
old_ifs=$IFS
IFS=:
for d in $PATH; do
  [ "$d" = "$SHIM_DIR" ] && continue
  new="${new:+$new:}$d"
done
IFS=$old_ifs
PATH=$new
export PATH

json=0
prev=""
for a in "$@"; do
  if [ "$prev" = "--mode" ] && [ "$a" = "json" ]; then json=1; fi
  prev=$a
done

if [ "$json" = 1 ]; then
  set -o pipefail
  # a unique name per run: epoch seconds, then this shim's pid
  f="$CAPTURE_DIR/$(date +%s)-$$.jsonl"
  pi "$@" | tee "$f"
  exit $?
fi

exec pi "$@"
