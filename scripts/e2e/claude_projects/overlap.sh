#!/usr/bin/env bash
# Interval helpers for the parallel-runs assertion of scripts/e2e/claude_projects_flow.sh (step 5b).
# Sourced by the flow after lib.sh. Executed directly it runs only the self-test, which needs no
# stack:
#
#     bash scripts/e2e/claude_projects/overlap.sh
#
# An interval is one line "<id> <start_ms> <finish_ms>" (epoch milliseconds). Two intervals overlap
# when start_i < finish_j AND start_j < finish_i: intervals that merely touch do not overlap.

# intervals_overlap_pairs: stdin intervals -> one "<idA> <idB>" line per overlapping pair
intervals_overlap_pairs() {
  awk 'BEGIN { n = 0 } NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { id[n] = $1; s[n] = $2 + 0; f[n] = $3 + 0; n++ }
       END { for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (s[i] < f[j] && s[j] < f[i]) print id[i], id[j] }'
}

# intervals_peak: stdin intervals -> the largest number running at the same instant
intervals_peak() {
  awk 'BEGIN { n = 0 } NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { s[n] = $2 + 0; f[n] = $3 + 0; n++ }
       END { peak = 0
             for (i = 0; i < n; i++) { c = 0; for (j = 0; j < n; j++) if (s[j] <= s[i] && s[i] < f[j]) c++; if (c > peak) peak = c }
             print peak }'
}

# intervals_render: stdin intervals -> a human line per interval, offsets in seconds from the earliest start
intervals_render() {
  awk 'BEGIN { n = 0 } NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { id[n] = $1; s[n] = $2 + 0; f[n] = $3 + 0; if (n == 0 || s[n] < t0) t0 = s[n]; n++ }
       END { for (i = 0; i < n; i++) printf "%s  start +%.1fs  finish +%.1fs  (ran %.1fs)\n", id[i], (s[i] - t0) / 1000, (f[i] - t0) / 1000, (f[i] - s[i]) / 1000 }'
}

# run_interval <run id> -> "<run id> <start_ms> <finish_ms|-> <terminal type|->", read from the run's event stream
run_interval() {
  ri_code=$(cat "$ASSETS/run_interval.exs")
  rpc "run_id = \"$1\"
$ri_code" 2>/dev/null | grep -E "^$1 " | tail -n 1
}

# three_titles <tag>: "<thread id><TAB><title>" per project thread whose title contains the tag
three_titles() {
  api_get "/api/projects/$PROJECT/threads" | jq -r --arg t "$1" '[.threads[]? | select(.title | contains($t))] | map("\(.id)\t\(.title)") | .[]' 2>/dev/null
}
thread_count() { three_titles "$1" | grep -c .; }

# send_paste <text>: one message to the coordinator; leaves its reply in $chat and the exit status in $chat_rc
send_paste() {
  chat=$(fm project chat --timeout 6m -m "$1" "$PROJECT" 2>&1)
  chat_rc=$?
}

# paste_three_tasks <tag> <paste>: sends the paste, waits for the threads, asserts exactly three. Sets $titles
# and $nudged. `project chat` may return on the answer to an earlier system report, so the project's threads
# are polled (240 s). If none appeared the user's remedy is a second paste: it is sent, both replies are
# printed and an UNVERIFIED line is recorded, so a flaky coordinator is never a clean pass. Duplicates are
# caught by the 'exactly three' assertion.
paste_three_tasks() {
  ptt_tag=$1; ptt_paste=$2
  send_paste "$ptt_paste"
  assert_eq "coordinator chat with the three-item paste exits 0" "$chat_rc" "0"
  note "coordinator reply: $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-600)"
  titles=""; nudged=0; tn=0
  while :; do
    titles=$(three_titles "$ptt_tag")
    [ "$(printf '%s' "$titles" | grep -c .)" -ge 3 ] && break
    if [ "$tn" -ge 240 ]; then
      if [ "$nudged" = 0 ] && [ -z "$titles" ]; then
        note "no thread appeared 240s after the paste; sending the same paste once more (a second nudge, as a user would)"
        note "first paste, coordinator reply: $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-600)"
        note "conversation tail: $(fm project chat --history 4 --format json "$PROJECT" 2>&1 | jq -c '[.[] | {role, kind, text: (.text[0:160])}]' 2>/dev/null | cut -c1-900)"
        nudged=1; tn=0
        send_paste "$ptt_paste"
        note "second paste, coordinator reply: $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-600)"
        continue
      fi
      break
    fi
    sleep 5; tn=$((tn + 5))
  done
  if [ "$nudged" = 1 ]; then
    unverified "the coordinator started the three threads from the first paste" \
      "coordinator needed a second paste: the first paste produced no thread within 240s (replies above); a flaky coordinator turn, not a clean pass"
  fi
  sleep 10
  titles=$(three_titles "$ptt_tag")
  assert_eq "the coordinator started exactly three threads for the three items" "$(printf '%s' "$titles" | grep -c .)" "3"
  if [ "$(printf '%s' "$titles" | grep -c .)" -ne 3 ]; then
    note "conversation tail: $(fm project chat --history 6 --format json "$PROJECT" 2>&1 | jq -c '[.[] | {role, kind, text: (.text[0:300])}]' 2>/dev/null | cut -c1-1800)"
  fi
}

# nudge_scenario <first|second|never|four>: runs paste_three_tasks in a SUBSHELL against a stubbed coordinator
# and thread list, with pass/fail/unverified/assert_eq/note/sleep replaced by counters, so nothing leaks
# into the real tally. Prints "pastes=N pass=P fail=F unverified=U".
nudge_scenario() {
  (
    MODE=$1; PASTES=0; NP=0; NF=0; NU=0
    sleep() { :; }
    note() { :; }
    pass() { NP=$((NP + 1)); }
    fail() { NF=$((NF + 1)); }
    unverified() { NU=$((NU + 1)); }
    assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; fi; }
    fm() { printf '[]'; }
    send_paste() { PASTES=$((PASTES + 1)); chat="stub reply $PASTES"; chat_rc=0; }
    api_get() {
      ns_n=0
      case "$MODE" in
        first) [ "$PASTES" -ge 1 ] && ns_n=3 ;;
        second) [ "$PASTES" -ge 2 ] && ns_n=3 ;;
        four) [ "$PASTES" -ge 1 ] && ns_n=4 ;;
      esac
      jq -nc --argjson n "$ns_n" '{threads: [range($n) | {id: "t\(.)", title: ("x todo " + (["A","B","C","D"][.]))}]}'
    }
    paste_three_tasks "x todo" "stub paste"
    printf 'pastes=%s pass=%s fail=%s unverified=%s' "$PASTES" "$NP" "$NF" "$NU"
  )
}

# overlap_selftest: proves the assertion can fail. Serial and merely touching intervals must report no
# overlap, a real overlap must be found, and a run with no finish time must be ignored.
overlap_selftest() {
  say "5b.0 overlap assertion self-test (the check must be able to fail)"
  serial=$(printf 'a 1000 2000\nb 2000 3000\nc 3500 4000\n' | intervals_overlap_pairs | tr '\n' ';')
  assert_eq "serial/touching intervals report no overlap" "$serial" ""
  assert_eq "serial intervals peak at 1" "$(printf 'a 1000 2000\nb 2000 3000\nc 3500 4000\n' | intervals_peak)" "1"
  overlapping=$(printf 'a 1000 5000\nb 2000 6000\nc 7000 8000\n' | intervals_overlap_pairs | tr '\n' ';')
  assert_eq "overlapping intervals are found" "$overlapping" "a b;"
  assert_eq "three simultaneous intervals peak at 3" "$(printf 'a 1000 5000\nb 2000 6000\nc 3000 7000\n' | intervals_peak)" "3"
  assert_eq "an unfinished run (finish '-') is ignored" "$(printf 'a 1000 5000\nb 2000 -\n' | intervals_overlap_pairs | tr '\n' ';')" ""
  exact_content_selftest
  # the final re-count must be able to fail: a fourth matching thread is counted (stubbed thread list)
  ps_saved_api_get=$(declare -f api_get)
  api_get() { printf '%s' '{"threads":[{"id":"t1","title":"x todo A"},{"id":"t2","title":"x todo B"},{"id":"t3","title":"x todo C"},{"id":"t4","title":"x todo C"},{"id":"t5","title":"other"}]}'; }
  assert_eq "a fourth matching thread is counted (the final three-thread assertion would FAIL)" "$(thread_count "x todo")" "4"
  eval "$ps_saved_api_get"
  # the wait/nudge branch of the paste, driven against a stubbed coordinator (a result is "pastes pass fail unverified")
  assert_eq "stub: threads appear after the first paste -> one paste, clean pass, nothing unverified" \
    "$(nudge_scenario first)" "pastes=1 pass=2 fail=0 unverified=0"
  assert_eq "stub: threads appear only after the second paste -> nudged, recorded UNVERIFIED (not a clean pass)" \
    "$(nudge_scenario second)" "pastes=2 pass=2 fail=0 unverified=1"
  assert_eq "stub: no thread ever appears -> nudged, UNVERIFIED, and 'exactly three threads' FAILS" \
    "$(nudge_scenario never)" "pastes=2 pass=1 fail=1 unverified=1"
  assert_eq "stub: four threads appear -> 'exactly three threads' FAILS" \
    "$(nudge_scenario four)" "pastes=1 pass=1 fail=1 unverified=0"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
  # shellcheck source=lib.sh
  . "$(dirname "$0")/lib.sh"
  overlap_selftest
  summary
  exit $?
fi
