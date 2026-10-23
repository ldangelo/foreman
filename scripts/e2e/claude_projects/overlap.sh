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
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
  # shellcheck source=lib.sh
  . "$(dirname "$0")/lib.sh"
  overlap_selftest
  summary
  exit $?
fi
