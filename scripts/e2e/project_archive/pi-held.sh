#!/bin/sh
# Template of the `pi` shim scripts/e2e/project_archive_flow.sh puts first on the server's PATH
# (E2E_PATH_PREFIX). The flow copies it to <shim dir>/pi, replacing the three __PLACEHOLDERS__.
#
# - A call whose arguments contain the marker (the prompt of the flow's held jobsite) never reaches the
#   real pi: it reports a pi-shaped session, records its pid in $STARTED, blocks until $RELEASE exists,
#   then emits the assistant message pi's `--mode json` stream ends with and exits 0 (same event shapes as
#   packages/foreman_server/test/foreman_server/jobsite/support/fake_agent.sh).
# - Every other call (the server's own `pi --list-models` / `--help` / `--version` probes, workflow runs,
#   the coordinator) is forwarded untouched to the real pi: this shim's directory is dropped from PATH
#   and pi is exec'd by name.

SHIM_DIR=__SHIM_DIR__
RELEASE=__RELEASE_FILE__
STARTED=__STARTED_FILE__
MARKER=JOBSITE-HOLD

held=0
for a in "$@"; do
  case "$a" in *"$MARKER"*) held=1 ;; esac
done

if [ "$held" = 1 ]; then
  echo "held agent $$ started $(date -u +%H:%M:%S)" >> agent-log.txt
  printf '{"type":"session","id":"e2e-held-session-%s"}\n' "$$"
  echo "$$" > "$STARTED.tmp" && mv "$STARTED.tmp" "$STARTED"
  while [ ! -e "$RELEASE" ]; do sleep 1; done
  echo "held agent $$ released $(date -u +%H:%M:%S)" >> agent-log.txt
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"held jobsite released"}}\n'
  printf '{"type":"message_end","message":{"role":"assistant","content":"held jobsite released","usage":{"input_tokens":1,"output_tokens":1}}}\n'
  exit 0
fi

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
exec pi "$@"
