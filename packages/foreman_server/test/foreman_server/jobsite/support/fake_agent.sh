#!/bin/sh
# Fake Pi-shaped agent CLI for Jobsite tests. Emits `--mode json` line-delimited
# events matching Jido.Harness.Adapters.Pi.map_event/1's expected shapes, writes
# one file into its cwd (proving the agent "did work"), and exits 0.
#
# Controlled by env vars (set via Agent.env, merged into the spawned process's
# environment):
#   FAKE_AGENT_SESSION_ID   - session id to report (default: a stable constant)
#   FAKE_AGENT_TEXT         - assistant text to report (default: "did some work")
#   FAKE_AGENT_SLEEP_ON_RUN - invocation number (1-based, counted via a file in
#                             cwd) on which to sleep for FAKE_AGENT_SLEEP_SECS
#                             before emitting anything, so a test can reliably
#                             observe + interrupt an iteration still in flight.
#   FAKE_AGENT_SLEEP_SECS   - sleep duration (default: 10).
#   FAKE_AGENT_SPAWN_FAIL_FIRST - for the first N invocations print erlexec's
#                             child-setup failure line to stderr and exit 1 without
#                             running, as the macOS setpgid race does.
#   FAKE_AGENT_SPAWN_FAIL_ON - the same failure, only on that one invocation number.
#   FAKE_AGENT_ECHO_ENV     - name of an env var; the assistant text becomes
#                             "env:NAME=<value the agent process received>", proving
#                             what environment was delivered.
#   FAKE_AGENT_FAIL_WITH    - when set, print it to stderr and exit 1 without emitting
#                             any events (an agent that dies, e.g. bad credentials).

set -e

COUNTER_FILE="agent-invocations.count"
COUNT=0
[ -f "$COUNTER_FILE" ] && COUNT=$(cat "$COUNTER_FILE")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

if { [ -n "$FAKE_AGENT_SPAWN_FAIL_FIRST" ] && [ "$COUNT" -le "$FAKE_AGENT_SPAWN_FAIL_FIRST" ]; } ||
   { [ -n "$FAKE_AGENT_SPAWN_FAIL_ON" ] && [ "$COUNT" = "$FAKE_AGENT_SPAWN_FAIL_ON" ]; }; then
  echo "Cannot set effective group to 0: Operation not permitted" >&2
  exit 1
fi

echo "fake agent ran (invocation $COUNT)" >> agent-log.txt

if [ -n "$FAKE_AGENT_SLEEP_ON_RUN" ] && [ "$COUNT" = "$FAKE_AGENT_SLEEP_ON_RUN" ]; then
  sleep "${FAKE_AGENT_SLEEP_SECS:-10}"
fi

if [ -n "$FAKE_AGENT_FAIL_WITH" ]; then
  echo "$FAKE_AGENT_FAIL_WITH" >&2
  exit 1
fi

SESSION_ID="${FAKE_AGENT_SESSION_ID:-fake-session-stable-1}"
TEXT="${FAKE_AGENT_TEXT:-did some work}"
if [ -n "$FAKE_AGENT_ECHO_ENV" ]; then
  TEXT="env:$FAKE_AGENT_ECHO_ENV=$(printenv "$FAKE_AGENT_ECHO_ENV")"
fi

printf '{"type":"session","id":"%s"}\n' "$SESSION_ID"
printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"%s"}}\n' "$TEXT"
printf '{"type":"message_end","message":{"role":"assistant","content":"%s","usage":{"input_tokens":1,"output_tokens":1}}}\n' "$TEXT"

exit 0
