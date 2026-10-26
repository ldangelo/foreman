#!/usr/bin/env bash
# scripts/e2e/live_input_failure.sh
#
# Real pi through the real Jido.Harness, no LLM tokens spent: a live-input (streaming, `pi --mode rpc`)
# agent run whose turn can never succeed must END as failed, promptly, instead of idling on its open
# stdin for ever. That was the hang scripts/e2e/claude_projects_flow.sh step 4 hit (a steered thread
# `in_progress` for the whole 600 s wait, pi idle, no end event): an rpc CLI exits only when its stdin
# closes, and the harness closed it only on `agent_settled`, which it dropped once the failed turn had
# recorded its terminal event. See docs/lessons/run-logs-known-issues.md.
#
#   bogus-key-live   an API key the provider rejects: the turn fails (HTTP 401), pi sends `agent_end`
#                    with stopReason "error" and THEN `agent_settled`
#   no-key-live      no credentials at all: pi answers the `prompt` with `response {success:false}` and
#                    then sends no agent_* event of any kind
#   bogus-key-plain  control: the same failed turn without live input (`pi --mode json`), which always
#                    ended because pi exits by itself
#
# Each scenario asserts the run ENDED `failed` before E2E_LIVE_FAILURE_DEADLINE seconds (default 45)
# and prints the provider's own error. Against a harness that predates the fix the two live scenarios
# print HUNG and FAIL (the run is still `running`), the control still passes.
#
#     devbox run -- bash scripts/e2e/live_input_failure.sh
#
# Needs `pi` on PATH and, for the bogus-key scenarios, network access to the model's provider (one
# request that is refused at once). Environment (optional): E2E_MODEL (default
# minimax/MiniMax-M2.7-highspeed; the API key variable is derived from the provider, MINIMAX_API_KEY),
# E2E_LIVE_FAILURE_DEADLINE, E2E_WORK_DIR (default <repo>/tmp/live-input-failure-<pid>; never /tmp),
# E2E_KEEP=1 to keep it. Exit: 0 all passed, 1 environment problem, 3 one or more assertions failed.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_MODEL=${E2E_MODEL:-minimax/MiniMax-M2.7-highspeed}
DEADLINE=${E2E_LIVE_FAILURE_DEADLINE:-45}
WORK=${E2E_WORK_DIR:-$ROOT/tmp/live-input-failure-$$}

command -v pi >/dev/null 2>&1 || { echo "pi is required on PATH (run inside 'devbox run --')" >&2; exit 1; }
command -v mix >/dev/null 2>&1 || { echo "mix is required on PATH (run inside 'devbox run --')" >&2; exit 1; }
mkdir -p "$WORK" || { echo "cannot create $WORK" >&2; exit 1; }
cleanup() { if [ "${E2E_KEEP:-0}" != 1 ]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

passed=0
failed=0
for scenario in bogus-key-live no-key-live bogus-key-plain; do
  out=$(cd "$ROOT/packages/jido_harness" && mix run "$ROOT/scripts/e2e/live_input_failure/probe.exs" \
    "$scenario" "$DEADLINE" "$WORK" "$E2E_MODEL" 2>&1)
  status=$?
  result=$(printf '%s\n' "$out" | grep '^RESULT ' | tail -n 1)
  if [ "$status" -eq 0 ] && [ -n "$result" ]; then
    echo "  PASS        $scenario: the run ended failed (${result#RESULT scenario=$scenario })"
    passed=$((passed + 1))
  else
    echo "  FAIL        $scenario: expected the run to end failed within ${DEADLINE}s, got: ${result:-no RESULT line}"
    [ -n "$result" ] || printf '%s\n' "$out" | tail -n 15 | sed 's/^/              /'
    failed=$((failed + 1))
  fi
done

echo
echo "== summary =="
echo "   passed=$passed failed=$failed"
[ "$failed" -eq 0 ] || exit 3
