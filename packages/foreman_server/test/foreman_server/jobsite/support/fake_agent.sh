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
#   FAKE_AGENT_FAIL_WITH    - when set, print it to stderr and exit 1 without emitting
#                             any events (an agent that dies, e.g. bad credentials).

set -e

COUNTER_FILE="agent-invocations.count"
COUNT=0
[ -f "$COUNTER_FILE" ] && COUNT=$(cat "$COUNTER_FILE")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

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

printf '{"type":"session","id":"%s"}\n' "$SESSION_ID"
printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"%s"}}\n' "$TEXT"
printf '{"type":"message_end","message":{"role":"assistant","content":"%s","usage":{"input_tokens":1,"output_tokens":1}}}\n' "$TEXT"

exit 0
