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

# content_is_exactly <word>: stdin must equal the word; $(...) drops trailing newlines, nothing else is dropped
content_is_exactly() {
  ci_content=$(cat)
  [ "$ci_content" = "$1" ]
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
  # exact file content: only trailing newlines may differ from the requested word
  for probe in 'ALPHA-7|ALPHA-7|yes' 'ALPHA-7\n|ALPHA-7|yes' 'ALPHA -7|ALPHA-7|no' 'ALPHA-7\n\n extra|ALPHA-7|no' 'ALPHA-7 \n|ALPHA-7|no' '|ALPHA-7|no'; do
    ps_content=${probe%%|*}; ps_rest=${probe#*|}; ps_want=${ps_rest%%|*}; ps_expect=${ps_rest##*|}
    if printf "$ps_content" | content_is_exactly "$ps_want"; then ps_got=yes; else ps_got=no; fi
    assert_eq "file content '$ps_content' is exactly '$ps_want'" "$ps_got" "$ps_expect"
  done
  # the final re-count must be able to fail: a fourth matching thread is counted (stubbed thread list)
  ps_saved_api_get=$(declare -f api_get)
  api_get() { printf '%s' '{"threads":[{"id":"t1","title":"x todo A"},{"id":"t2","title":"x todo B"},{"id":"t3","title":"x todo C"},{"id":"t4","title":"x todo C"},{"id":"t5","title":"other"}]}'; }
  assert_eq "a fourth matching thread is counted (the final three-thread assertion would FAIL)" "$(thread_count "x todo")" "4"
  eval "$ps_saved_api_get"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
  # shellcheck source=lib.sh
  . "$(dirname "$0")/lib.sh"
  overlap_selftest
  summary
  exit $?
fi
