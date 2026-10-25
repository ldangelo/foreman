#!/usr/bin/env bash
# Wait for the thread a freshly created bead should start (foreman-3ll3t: the br-down scenario of
# scripts/e2e/failure_injection.sh once saw no thread within its wait). Sourced after lib.sh. Executed directly
# it runs only the self-test, which needs no stack:
#
#     bash scripts/e2e/claude_projects/bead_thread.sh
#
# The wait polls, prints read-only capped diagnostics that tell the candidate causes apart (BeadsWatcher never
# imported the bead / Dispatcher did not admit it / slots held by leftover runs / br stub interference), and
# records a thread that only appeared late as UNVERIFIED, never as a clean pass.

# bead_thread_diagnostics <bead id>: printed once, every line capped to 300 columns, read-only
bead_thread_diagnostics() {
  bd_id=$1
  note "diagnostics (foreman-3ll3t) for bead $bd_id:"
  # (a) was the bead imported at all? (404 = BeadsWatcher never made the task; 000 = no answer)
  bd_code=$(api_status "/api/tasks/beads:$PROJECT:$bd_id")
  if [ "$bd_code" = 200 ]; then
    bd_status=$(api_get "/api/tasks/beads:$PROJECT:$bd_id" | jq -r '.task.status // empty' 2>/dev/null)
    note "  (a) task beads:$PROJECT:$bd_id IS imported, status=${bd_status:-?}" | cut -c1-300
  else
    note "  (a) task beads:$PROJECT:$bd_id is NOT imported (BeadsWatcher): GET answered HTTP ${bd_code:-?}" | cut -c1-300
  fi
  # (b) imported but not run: project status, overview counts, working threads (slots)
  bd_proj=$(api_get "/api/projects/$PROJECT" 2>/dev/null | jq -r '.project.status // .status // empty' 2>/dev/null)
  note "  (b) project status=${bd_proj:-?}" | cut -c1-300
  bd_ov=$(api_get "/api/projects/$PROJECT/overview" 2>/dev/null || true)
  note "  (b) overview counts: $(printf '%s' "$bd_ov" | jq -c '.counts // empty' 2>/dev/null)" | cut -c1-300
  printf '%s' "$bd_ov" | jq -r '.groups.working[]? | "  (b) working: \(.thread_id) status=\(.status // "?")"' 2>/dev/null | head -n 10 | cut -c1-300 |
    while IFS= read -r l; do note "$l"; done
  # (c) server log evidence
  if [ -f "${SERVER_LOG:-}" ]; then
    grep -F -- "$bd_id" "$SERVER_LOG" | tail -n 10 | cut -c1-300 | while IFS= read -r l; do note "  (c) log[bead]: $l"; done
    grep -E 'BeadsWatcher|admission failed|slot_state_unknown|run_limit|deferr' "$SERVER_LOG" | tail -n 10 | cut -c1-300 |
      while IFS= read -r l; do note "  (c) log[dispatch]: $l"; done
  else
    note "  (c) no server log at '${SERVER_LOG:-}'"
  fi
  # (d) did the br write-stub see calls?
  if [ -f "$WORK/nobr/br.log" ]; then
    tail -n 10 "$WORK/nobr/br.log" | cut -c1-300 | while IFS= read -r l; do note "  (d) br stub: $l"; done
  fi
}

# bead_thread_nudge: what a user could do to make the BeadsWatcher look again: re-flush the JSONL it tails
# (a function so the self-test can replace it).
bead_thread_nudge() { (cd "$REPO" && br sync --flush-only >/dev/null 2>&1); }

# await_bead_thread <bead id> <what> [first_timeout s=180] [nudge_timeout s=120] [slow_after s=60] -> THREAD
# Returns 0 with THREAD set (UNVERIFIED when it appeared later than slow_after, or only after a second
# `br sync --flush-only`), 1 after recording a FAIL.
await_bead_thread() {
  bt_id=$1; bt_what=$2; bt_first=${3:-180}; bt_nudge=${4:-120}; bt_slow=${5:-60}
  bt_n=0; THREAD=""
  while [ -z "$THREAD" ] && [ "$bt_n" -lt "$bt_first" ]; do
    THREAD=$(api_get "/api/projects/$PROJECT/threads" | jq -r --arg b "$bt_id" '[.threads[]? | select((.task_id // "") | endswith($b))][0].id // empty' 2>/dev/null)
    [ -n "$THREAD" ] || { sleep 2; bt_n=$((bt_n + 2)); }
  done
  if [ -n "$THREAD" ]; then
    note "thread $THREAD for bead $bt_id appeared after ${bt_n}s"
    if [ "$bt_n" -gt "$bt_slow" ]; then
      unverified "$bt_what: the thread appeared promptly" "it appeared only after ${bt_n}s (nominal <= ${bt_slow}s): BeadsWatcher/Dispatcher latency, foreman-3ll3t"
      bead_thread_diagnostics "$bt_id"
    fi
    return 0
  fi
  bead_thread_diagnostics "$bt_id"
  note "no thread after ${bt_n}s: re-touching the JSONL once (br sync --flush-only)"
  bead_thread_nudge
  bt_m=0
  while [ -z "$THREAD" ] && [ "$bt_m" -lt "$bt_nudge" ]; do
    THREAD=$(api_get "/api/projects/$PROJECT/threads" | jq -r --arg b "$bt_id" '[.threads[]? | select((.task_id // "") | endswith($b))][0].id // empty' 2>/dev/null)
    [ -n "$THREAD" ] || { sleep 2; bt_m=$((bt_m + 2)); }
  done
  if [ -n "$THREAD" ]; then
    unverified "$bt_what: the thread appeared without a nudge" "it needed a second flush: appeared ${bt_m}s after it, $((bt_n + bt_m))s in total (foreman-3ll3t)"
    return 0
  fi
  fail "$bt_what: no thread appeared for bead $bt_id within $((bt_n + bt_m))s"
  return 1
}

# bead_thread_scenario <first|slow|nudged|never>: await_bead_thread in a SUBSHELL against stubbed api_get, br,
# sleep, with pass/fail/unverified/note replaced by counters. Prints "pass=P fail=F unverified=U polls=N nudges=K diag=D"
# (diag = how many times the diagnostics printed their header).
bead_thread_scenario() {
  (
    BT_MODE=$1; NP=0; NF=0; NU=0; POLLS=0; NUDGES=0; DIAG=0; BT_NUDGED=0
    PROJECT=p; WORK=/nonexistent; SERVER_LOG=/nonexistent; REPO=/nonexistent
    sleep() { POLLS=$((POLLS + 1)); }
    bead_thread_nudge() { NUDGES=$((NUDGES + 1)); BT_NUDGED=1; }
    api_status() { echo 404; }
    note() { case "$*" in "diagnostics (foreman-3ll3t)"*) DIAG=$((DIAG + 1)) ;; esac; }
    pass() { NP=$((NP + 1)); }
    fail() { NF=$((NF + 1)); }
    unverified() { NU=$((NU + 1)); }
    api_get() {
      case "$1" in
        /api/projects/p/threads)
          case "$BT_MODE" in
            first) printf '{"threads":[{"id":"run:r1","task_id":"beads:p:b1"}]}' ;;
            slow) if [ "$POLLS" -ge 40 ]; then printf '{"threads":[{"id":"run:r1","task_id":"beads:p:b1"}]}'; else printf '{"threads":[{"id":"run:x","task_id":"beads:p:other"}]}'; fi ;;
            nudged) if [ "$BT_NUDGED" = 1 ]; then printf '{"threads":[{"id":"run:r1","task_id":"beads:p:b1"}]}'; else printf '{"threads":[]}'; fi ;;
            *) printf '{"threads":[{"id":"run:x","task_id":"beads:p:other"}]}' ;;
          esac ;;
        /api/tasks/beads:p:b1) printf '{"error":"task_not_found"}'; return 1 ;;
        /api/projects/p) printf '{"project":{"status":"active"}}' ;;
        /api/projects/p/overview) printf '{"counts":{"working":1},"groups":{"working":[{"thread_id":"run:x","status":"running"}]}}' ;;
        *) printf '{}' ;;
      esac
    }
    await_bead_thread b1 "stub bead thread" 120 20 60 >/dev/null 2>&1
    printf 'pass=%s fail=%s unverified=%s polls=%s nudges=%s diag=%s' "$NP" "$NF" "$NU" "$POLLS" "$NUDGES" "$DIAG"
  )
}

# bead_thread_selftest: proves the wait can fail and that a late thread is never a clean pass
bead_thread_selftest() {
  say "bead-thread wait self-test (the check must be able to fail)"
  assert_eq "stub: thread present at the first poll -> clean, nothing unverified, no nudge" \
    "$(bead_thread_scenario first)" "pass=0 fail=0 unverified=0 polls=0 nudges=0 diag=0"
  assert_eq "stub: thread appears after the slow threshold -> UNVERIFIED, diagnostics once, no nudge" \
    "$(bead_thread_scenario slow)" "pass=0 fail=0 unverified=1 polls=40 nudges=0 diag=1"
  assert_eq "stub: thread appears only after the nudge -> UNVERIFIED, exactly one nudge" \
    "$(bead_thread_scenario nudged)" "pass=0 fail=0 unverified=1 polls=60 nudges=1 diag=1"
  assert_eq "stub: thread never appears -> FAIL, diagnostics, exactly one nudge, both windows polled" \
    "$(bead_thread_scenario never)" "pass=0 fail=1 unverified=0 polls=70 nudges=1 diag=1"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
  # shellcheck source=lib.sh
  . "$(dirname "$0")/lib.sh"
  bead_thread_selftest
  summary
  exit $?
fi
