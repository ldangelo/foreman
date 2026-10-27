#!/usr/bin/env bash
# partition-tests.sh <partition> <total>   print the test files of one CI leg, one per line
# partition-tests.sh --check <total>       prove the legs cover every test file exactly once
#
# Run from packages/foreman_server. Replaces `mix test --partitions N`, which deals the sorted
# files round-robin and ignores how long they take (a leg ended up 25-35 s behind the others).
#
# Assignment: files by weight, heaviest first (ties by path), each to the leg with the least
# weight so far (ties to the lowest leg number). The weights are `scripts/ci/test-weights.txt`
# (`path weight_ms`, regenerate with ForemanServer.TestSupport.FileWeights); a file with no entry
# weighs DEFAULT_WEIGHT_MS, an entry for a file that no longer exists is ignored. The result is a
# pure function of the file list and the weights file, so every leg computes the same split, and
# adding a file moves only that file (and what its weight displaces), not everything after it.
#
# FAIL SAFE: `--check` is run by every leg before its tests; a file that no leg runs would make
# the required `foreman_server` check green without having tested it.
set -euo pipefail

DEFAULT_WEIGHT_MS=${DEFAULT_WEIGHT_MS:-150}
weights_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-weights.txt"

assign() {
  local total=$1
  find test -name '*_test.exs' | LC_ALL=C sort | awk -v total="$total" -v dflt="$DEFAULT_WEIGHT_MS" '
    NR == FNR { weight[$1] = $2; next }
    { w = ($1 in weight) ? weight[$1] : dflt; printf "%d\t%s\n", w, $1 }
  ' "$weights_file" - |
    LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 |
    awk -F '\t' -v total="$total" '
      BEGIN { for (i = 1; i <= total; i++) load[i] = 0 }
      {
        best = 1
        for (i = 2; i <= total; i++) if (load[i] < load[best]) best = i
        load[best] += $1
        print best "\t" $2
      }
    '
}

case "${1:-}" in
  --check)
    total=${2:?usage: partition-tests.sh --check <total>}
    expected=$(find test -name '*_test.exs' | LC_ALL=C sort)
    [ -n "$expected" ] || { echo "partition-tests: no test files found (run from packages/foreman_server)" >&2; exit 1; }
    got=$(assign "$total" | cut -f2 | LC_ALL=C sort)
    if [ "$expected" != "$got" ]; then
      echo "partition-tests: the $total legs do not cover each test file exactly once" >&2
      exit 1
    fi
    echo "partition-tests: $(printf '%s\n' "$expected" | wc -l | tr -d ' ') files, each in exactly one of $total legs"
    ;;
  ''|-*)
    echo "usage: partition-tests.sh <partition> <total> | --check <total>" >&2
    exit 2
    ;;
  *)
    partition=$1
    total=${2:?usage: partition-tests.sh <partition> <total>}
    if ! [ "$partition" -ge 1 ] 2>/dev/null || [ "$partition" -gt "$total" ]; then
      echo "partition-tests: partition must be 1..$total, got '$partition'" >&2
      exit 2
    fi
    assign "$total" | awk -F '\t' -v p="$partition" '$1 == p { print $2 }'
    ;;
esac
