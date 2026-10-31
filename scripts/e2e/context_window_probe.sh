#!/usr/bin/env bash
# Zero-spend probe of how the claude CLI treats the context window of a GATEWAY model name (bead foreman-gppjx,
# docs/acceptance/context-window-probe.md).
#
#   devbox run -- bash scripts/e2e/context_window_probe.sh
#
# NO provider is contacted and nothing is spent: the claude CLI is pointed (ANTHROPIC_BASE_URL) at a stand-in gateway on 127.0.0.1
# (context_window_probe/fake_anthropic.py) with a fake API key and an empty private HOME (no login, no keychain, no ~/.claude is
# read). The stand-in answers every request with a tiny streamed reply but CLAIMS a chosen context size in the reply's `usage`: the
# number the CLI uses to decide when to auto-compact. It logs what the CLI sent, and whether a request is a compaction.
#
# What it measures, for the unrecognised model name `Minimax-M3` (override: CW_MODEL), with and without
# CLAUDE_CODE_MAX_CONTEXT_TOKENS=512000 (the model's declared 512000-token window):
#   1. the window the CLI assumes (`modelUsage.<model>.contextWindow` of its own result JSON);
#   2. the claimed context at which the NEXT turn of the session starts with a compaction request (auto-compaction), bracketed.
# It does NOT run Foreman, and it does not show that a real model accepts a >200k-token request: that is the live run this script
# only prepares (see the document).
#
# Prints PASS / FAIL / UNVERIFIED per assertion; exit 0 all passed, 1 environment problem, 3 a FAIL. Environment: CW_PORT (4960),
# CW_MODEL, CW_WORK_DIR (<checkout>/tmp/context-window-probe).
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PORT=${CW_PORT:-4960}
MODEL=${CW_MODEL:-Minimax-M3}
WORK=${CW_WORK_DIR:-$ROOT/tmp/context-window-probe}
WINDOW_DECLARED=512000
STARTED=$(date +%s)
PASSED=0; FAILED=0; UNVERIFIED=0; FAILURES=""

say() { printf '\n== %s ==\n' "$*"; }
note() { printf '   %s\n' "$*"; }
pass() { PASSED=$((PASSED + 1)); printf '  PASS        %s\n' "$*"; }
fail() { FAILED=$((FAILED + 1)); FAILURES="$FAILURES
  - $*"; printf '  FAIL        %s\n' "$*"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1: expected '$3', got '$2'"; fi; }
summary() {
  say "summary"
  printf '   passed=%s failed=%s unverified=%s wall=%ss\n' "$PASSED" "$FAILED" "$UNVERIFIED" "$(( $(date +%s) - STARTED ))"
  [ "$FAILED" -gt 0 ] && printf '   FAILED:%s\n' "$FAILURES"
  [ "$FAILED" -eq 0 ] && return 0 || return 3
}

for tool in claude python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "environment problem: '$tool' is not on PATH" >&2; exit 1; }
done
note "claude $(claude --version 2>&1 | head -n 1); stand-in gateway on 127.0.0.1:$PORT; model $MODEL"

rm -rf "$WORK"; mkdir -p "$WORK"
LOG="$WORK/requests.jsonl"; REPORT="$WORK/report"; : > "$LOG"; echo 1000 > "$REPORT"
python3 "$HERE/context_window_probe/fake_anthropic.py" --port "$PORT" --log "$LOG" --report-file "$REPORT" >"$WORK/gateway.log" 2>&1 &
GW_PID=$!
trap 'kill "$GW_PID" 2>/dev/null; rm -rf "$WORK/home-"*' EXIT
for _ in $(seq 1 40); do
  curl -s -m 1 -o /dev/null -X POST "http://127.0.0.1:$PORT/v1/messages/count_tokens" -d '{}' && break
  sleep 0.25
done
: > "$LOG"

# run_claude <home> <resume id or -> <prompt> <extra env...>: one `claude -p` turn against the stand-in; JSON on stdout, diagnostics in $WORK/stderr.txt
run_claude() {
  rc_home=$1; rc_resume=$2; rc_prompt=$3; shift 3
  mkdir -p "$rc_home"
  (
    cd "$rc_home" || exit 1
    env -i PATH="$PATH" HOME="$rc_home" ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=fake-key-local-probe \
      DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 "$@" \
      timeout 150 claude -p "$rc_prompt" --model "$MODEL" ${rc_resume:+--resume "$rc_resume"} --output-format json 2>"$WORK/stderr.txt"
  )
}

# probe <label> <claimed input tokens> <extra env...>: turn 1 (the stand-in claims N input tokens), then turn 2 of the same session.
# Sets PR_WINDOW (the window the CLI reported on turn 1), PR_DIAG (its unrecognized_model diagnostic, yes/no),
# PR_T2_REQUESTS and PR_T2_COMPACTIONS (the requests the CLI made on turn 2, and how many were compaction requests).
probe() {
  pr_label=$1; pr_tokens=$2; shift 2
  echo "$pr_tokens" > "$REPORT"
  pr_home="$WORK/home-$pr_label-$pr_tokens"
  pr_json=$(run_claude "$pr_home" "" "turn one: say hi" "$@")
  PR_WINDOW=$(printf '%s' "$pr_json" | jq -r --arg m "$MODEL" '.modelUsage[$m].contextWindow // empty' 2>/dev/null)
  PR_DIAG=$(grep -c 'unrecognized_model' "$WORK/stderr.txt" 2>/dev/null); [ "${PR_DIAG:-0}" -gt 0 ] && PR_DIAG=yes || PR_DIAG=no
  pr_sid=$(printf '%s' "$pr_json" | jq -r '.session_id // empty' 2>/dev/null)
  pr_n0=$(wc -l < "$LOG" | tr -d ' ')
  run_claude "$pr_home" "$pr_sid" "turn two: say hi again" "$@" >/dev/null
  PR_T2_REQUESTS=$(tail -n +$((pr_n0 + 1)) "$LOG" | jq -s '[.[] | select(.path | endswith("/messages"))] | length')
  PR_T2_COMPACTIONS=$(tail -n +$((pr_n0 + 1)) "$LOG" | jq -s '[.[] | select(.compaction)] | length')
  note "$pr_label, the stand-in claims $pr_tokens input tokens: window $PR_WINDOW, unrecognized_model diagnostic: $PR_DIAG, turn 2 made $PR_T2_REQUESTS request(s), $PR_T2_COMPACTIONS of them compaction"
}

say "$MODEL without CLAUDE_CODE_MAX_CONTEXT_TOKENS: the CLI assumes a 200000-token window"
probe plain 175000
assert_eq "the window the CLI reports for the unrecognised model name" "$PR_WINDOW" "200000"
assert_eq "the CLI says it does not recognise the model (stderr diagnostic)" "$PR_DIAG" "yes"
assert_eq "claimed context 175000: turn 2 makes no compaction request" "$PR_T2_COMPACTIONS" "0"
probe plain 177000
assert_eq "claimed context 177000: turn 2 starts with ONE compaction request (premature: the real window is $WINDOW_DECLARED)" "$PR_T2_COMPACTIONS" "1"
probe plain 190000
assert_eq "claimed context 190000: turn 2 starts with ONE compaction request" "$PR_T2_COMPACTIONS" "1"
assert_eq "...followed by the turn's own request (2 requests in all)" "$PR_T2_REQUESTS" "2"

say "$MODEL with CLAUDE_CODE_MAX_CONTEXT_TOKENS=$WINDOW_DECLARED"
probe var 190000 "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$WINDOW_DECLARED"
assert_eq "the window the CLI reports" "$PR_WINDOW" "$WINDOW_DECLARED"
assert_eq "claimed context 190000: turn 2 makes NO compaction request (one request)" "$PR_T2_COMPACTIONS/$PR_T2_REQUESTS" "0/1"
probe var 480000 "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$WINDOW_DECLARED"
assert_eq "claimed context 480000: turn 2 makes no compaction request" "$PR_T2_COMPACTIONS" "0"
probe var 490000 "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$WINDOW_DECLARED"
assert_eq "claimed context 490000: compaction starts again, near the declared window, not at 200k" "$PR_T2_COMPACTIONS" "1"

say "what the CLI sent"
note "largest request body the stand-in saw: $(jq -s '[.[] | select(.bytes) | .bytes] | max' "$LOG") bytes (a 2-message session: no prompt of 200k tokens is involved, the claimed size is only a number in the reply)"
note "no provider was contacted: every request went to 127.0.0.1:$PORT (requests logged: $(wc -l < "$LOG" | tr -d ' '))"
summary
exit $?
