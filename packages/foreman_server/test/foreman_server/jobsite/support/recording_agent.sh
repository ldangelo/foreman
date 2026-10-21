#!/bin/sh
# Fake Pi-shaped agent CLI that records every argument it was invoked with
# (the prompt travels as an argument) to $FAKE_AGENT_PROMPT_LOG, one invocation
# per line group delimited by "--invocation--". Otherwise behaves like
# fake_agent.sh (same env vars, same sleep-on-run hook).
set -e

if [ -n "$FAKE_AGENT_PROMPT_LOG" ]; then
  {
    echo "--invocation--"
    for arg in "$@"; do printf '%s\n' "$arg"; done
  } >> "$FAKE_AGENT_PROMPT_LOG"
fi

exec "$(dirname "$0")/fake_agent.sh" "$@"
