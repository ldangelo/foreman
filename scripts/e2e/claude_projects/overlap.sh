#!/usr/bin/env bash
# Helpers of the parallel-runs assertions of scripts/e2e/claude_projects_flow.sh (step 5b): run intervals, the
# paste to the coordinator, and the read of a thread's file on its branch. Sourced by the flow after lib.sh.
# Executed directly it runs only the self-test, which needs no stack:
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

# thread_file_read <thread id> <file>: reads <file> at the tip of the branch the thread projection names, in
# $REPO. Status 0 only when git read it: $tf_content then holds it (trailing newlines stripped, which every
# comparison here ignores anyway). On failure $tf_err says why. $tf_branch is the projection's branch either way.
# An empty branch is never handed to git: `git show ":<file>"` reads the INDEX of the main checkout, which would
# report an unrelated file (or nothing) as the thread's.
thread_file_read() {
  tf_branch=""; tf_content=""; tf_err=""
  if ! tf_json=$(api_get "/api/threads/$1"); then
    tf_err="GET /api/threads/$1 failed"
    return 1
  fi
  tf_branch=$(printf '%s' "$tf_json" | jq -r '.thread.branch // empty' 2>/dev/null)
  if [ -z "$tf_branch" ]; then
    tf_err="the thread projection names no branch"
    return 1
  fi
  if tf_content=$(git -C "$REPO" show "$tf_branch:$2" 2>/dev/null); then
    return 0
  fi
  tf_content=""
  tf_err=$(git -C "$REPO" show "$tf_branch:$2" 2>&1 >/dev/null | tr '\n' ' ' | cut -c1-300)
  return 1
}

# thread_file_diagnostics <thread id> <file>: what tells the candidate causes of foreman-2onq1 apart, printed once
# per thread whose file could not be confirmed (it reads $tf_branch and $tf_err of the last thread_file_read).
# Read-only, every line capped. Which candidate each line separates:
#   thread projection / read error   no branch in the projection, or git could not read the file
#   commits ahead of HEAD            0: Foreman committed nothing for the thread (a clean worktree is not a failure)
#   foreman branches, main checkout  the work landed on another branch, or in the main checkout (the agent was told
#                                    its absolute path by the project context) instead of the worktree
#   file under $WORK                 where the agent actually wrote it
#   task prompt, agent text          what the coordinator asked and what the thread agent answered
#   server log                       whether the phase committed ("committed the worktree" / "nothing to commit")
thread_file_diagnostics() {
  tfd_tid=$1; tfd_file=$2
  tfd_json=$(api_get "/api/threads/$tfd_tid" 2>/dev/null)
  tfd_run=$(printf '%s' "$tfd_json" | jq -r '.thread.run_ids[0] // empty' 2>/dev/null)
  tfd_task=$(printf '%s' "$tfd_json" | jq -r '.thread.task_id // empty' 2>/dev/null)
  note "diagnostics for $tfd_tid: read error: ${tf_err:-none}; thread projection: $(printf '%s' "$tfd_json" | jq -c '.thread' 2>&1 | cut -c1-600)"
  if [ -n "$tf_branch" ]; then
    note "diagnostics: branch '$tf_branch': tip $(git -C "$REPO" log --format='%h %s' -n 3 "$tf_branch" 2>&1 | tr '\n' ';' | cut -c1-300) commits ahead of HEAD: $(git -C "$REPO" rev-list --count "HEAD..$tf_branch" 2>&1 | cut -c1-100); files: $(git -C "$REPO" ls-tree -r --name-only "$tf_branch" 2>&1 | tr '\n' ' ' | cut -c1-300)"
  fi
  note "diagnostics: foreman branches: $(git -C "$REPO" for-each-ref --format='%(refname:short)@%(objectname:short)' refs/heads/foreman/ 2>&1 | tr '\n' ' ' | cut -c1-900)"
  note "diagnostics: main checkout $REPO: HEAD $(git -C "$REPO" log --format='%h %s' -n 3 2>&1 | tr '\n' ';' | cut -c1-200) status: $(git -C "$REPO" status --porcelain 2>&1 | tr '\n' ';' | cut -c1-300)"
  note "diagnostics: $tfd_file on disk under $WORK: $(find "$WORK" -name "$tfd_file" -not -path '*/.git/*' 2>/dev/null | head -n 5 | tr '\n' ' ')"
  if [ -n "$tfd_task" ]; then
    note "diagnostics: task $tfd_task: $(api_get "/api/tasks/$tfd_task" | jq -c '.task | {title, prompt}' 2>/dev/null | cut -c1-700)"
  fi
  note "diagnostics: what the agent said: $(api_get "/api/threads/$tfd_tid/transcript" | jq -r '[.turns[]? | select(.role == "agent") | .text] | join(" | ")' 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
  if [ -n "$tfd_run" ] && [ -f "$SERVER_LOG" ]; then
    grep -F "$tfd_run" "$SERVER_LOG" | grep -iE 'commit|worktree|clean|finaliz|auto-?pr' | tail -n 10 | cut -c1-260 | while IFS= read -r l; do note "server log: $l"; done
  fi
}

# await_thread_file <thread id> <file> <word> <what> [tries] [step s]: PASS when <file> on the thread's branch is
# exactly <word>. RunCompleted is dispatched after the phase's commit step, so a `completed` thread's file is
# readable on the first read; while it is NOT (no branch in the projection, or git cannot find the file) the read
# is repeated, `tries` times `step` seconds (default 30 x 1 s). A file that only turns up after waiting is
# recorded UNVERIFIED, never a clean pass: a commit landing after `completed` would be a server defect that the
# wait must not hide. A file that is readable but wrong is a FAIL at once (nothing to wait for). Every FAIL is
# followed by thread_file_diagnostics.
await_thread_file() {
  atf_tid=$1; atf_file=$2; atf_word=$3; atf_what=$4; atf_tries=${5:-30}; atf_step=${6:-1}; atf_n=0
  thread_file_read "$atf_tid" "$atf_file"; atf_rc=$?
  while [ "$atf_rc" != 0 ] && [ "$atf_n" -lt "$atf_tries" ]; do
    sleep "$atf_step"; atf_n=$((atf_n + 1))
    thread_file_read "$atf_tid" "$atf_file"; atf_rc=$?
  done
  if [ "$atf_rc" = 0 ]; then
    assert_content_exactly "$atf_what" "$tf_content" "$atf_word"
    if content_exactly "$tf_content" "$atf_word"; then
      if [ "$atf_n" -gt 0 ]; then
        unverified "$atf_what: readable on the branch at the first read" \
          "the thread was completed but the file became readable only after $((atf_n * atf_step))s of polling (foreman-2onq1)"
      fi
      return 0
    fi
  else
    fail "$atf_what: not readable on branch '$tf_branch' after $((atf_n * atf_step))s of polling: $tf_err"
  fi
  thread_file_diagnostics "$atf_tid" "$atf_file"
  return 1
}

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

# branch_read_scenario <exact|wrong|missing|nobranch|late>: await_thread_file in a SUBSHELL against a throwaway
# repository and a stubbed thread projection, with pass/fail/unverified/note/sleep replaced by counters, so
# nothing leaks into the real tally. The repository's main branch tracks alpha.txt = ALPHA-7, so a read that fell
# through to the index or to HEAD (an empty branch handed to git) would PASS: `nobranch` must refute that.
# Prints "pass=P fail=F unverified=U polls=N" (polls = how often the wait slept).
branch_read_scenario() {
  (
    BR_MODE=$1; NP=0; NF=0; NU=0; POLLS=0
    mkdir -p "$ROOT/tmp" || exit 1
    REPO=$(mktemp -d "$ROOT/tmp/branch-read-selftest.XXXXXX") || exit 1
    trap 'rm -rf "$REPO"' EXIT
    {
      git init -q -b main "$REPO" &&
        git -C "$REPO" config user.name e2e && git -C "$REPO" config user.email e2e@example.com &&
        git -C "$REPO" config commit.gpgsign false &&
        printf 'ALPHA-7\n' > "$REPO/alpha.txt" && git -C "$REPO" add alpha.txt && git -C "$REPO" commit -q -m base &&
        git -C "$REPO" branch foreman/t/exact &&
        git -C "$REPO" checkout -q -b foreman/t/wrong && printf 'ALPHA -7\n' > "$REPO/alpha.txt" &&
        git -C "$REPO" commit -q -am wrong &&
        git -C "$REPO" checkout -q -b foreman/t/missing main && git -C "$REPO" rm -q alpha.txt &&
        git -C "$REPO" commit -q -m missing && git -C "$REPO" checkout -q main
    } >/dev/null 2>&1 || exit 1
    sleep() {
      POLLS=$((POLLS + 1))
      if [ "$BR_MODE" = late ] && [ "$POLLS" -eq 2 ]; then git -C "$REPO" branch foreman/t/late foreman/t/exact; fi
    }
    note() { :; }
    pass() { NP=$((NP + 1)); }
    fail() { NF=$((NF + 1)); }
    unverified() { NU=$((NU + 1)); }
    api_get() {
      case "$1" in
        /api/threads/t1)
          case "$BR_MODE" in nobranch) br_branch="" ;; *) br_branch="foreman/t/$BR_MODE" ;; esac
          jq -nc --arg b "$br_branch" '{thread: {id: "t1", status: "completed", branch: (if $b == "" then null else $b end), run_ids: ["run-1"], task_id: "task-1"}}' ;;
        *) printf '{}' ;;
      esac
    }
    await_thread_file t1 alpha.txt ALPHA-7 "stub thread: alpha.txt on its branch" 3 0 >/dev/null 2>&1
    printf 'pass=%s fail=%s unverified=%s polls=%s' "$NP" "$NF" "$NU" "$POLLS"
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
  # the branch read behind the three file checks (stubbed thread projection, throwaway repository; "pass fail unverified polls")
  assert_eq "stub: file exact on the thread's branch -> PASS at the first read, nothing unverified" \
    "$(branch_read_scenario exact)" "pass=1 fail=0 unverified=0 polls=0"
  assert_eq "stub: file readable but wrong -> FAIL at once, no waiting" \
    "$(branch_read_scenario wrong)" "pass=0 fail=1 unverified=0 polls=0"
  assert_eq "stub: file missing on the branch -> polled 3 times, then FAIL" \
    "$(branch_read_scenario missing)" "pass=0 fail=1 unverified=0 polls=3"
  assert_eq "stub: projection names no branch -> polled, then FAIL (an index read would have found the file on main)" \
    "$(branch_read_scenario nobranch)" "pass=0 fail=1 unverified=0 polls=3"
  assert_eq "stub: branch appears after 2 polls -> PASS but recorded UNVERIFIED (not a clean pass)" \
    "$(branch_read_scenario late)" "pass=1 fail=0 unverified=1 polls=2"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
  # shellcheck source=lib.sh
  . "$(dirname "$0")/lib.sh"
  overlap_selftest
  summary
  exit $?
fi
