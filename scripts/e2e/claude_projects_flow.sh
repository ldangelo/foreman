#!/usr/bin/env bash
# scripts/e2e/claude_projects_flow.sh
#
# Live end-to-end acceptance of the Claude Projects flow (epic E16-S8), driven through the real
# Go CLI and HTTP API against a real, throwaway Foreman server:
#
#   project + goal + instructions -> memory -> library -> a thread started from a bead
#   -> the thread sees instructions/memory/library -> steer a running thread -> stop one
#   -> Overview groups -> coordinator chat -> three tasks pasted in ONE message start three
#   threads whose runs overlap in time -> approvals/questions surfaces
#   -> notifications reach a webhook sink -> the review archive and verdict are written.
#
# Optional stage 8 (real GitHub): with FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-<suffix>
# (an existing private scratch repo seeded from claude_projects/github-fixture/) the flow also
# drives a real PR end to end - PR from a run, check watching, a real webhook through a
# cloudflared tunnel (signature verified), failing CI -> Waiting on you -> Fix CI, a review
# comment -> Address comments, a merge conflict -> Resolve conflicts, force-push, check re-run,
# Ready for review and the operator merge. Unset, the stage prints an explicit SKIP and counts
# as UNVERIFIED. See claude_projects/github.sh. E2E_GH_ONLY=1 runs only setup + that stage.
#
# Every step asserts PASS / FAIL (or UNVERIFIED where this host cannot exercise it, e.g. pi has
# no tool-permission mechanism so no approval can be raised). Exit status: 0 all passed,
# 1 environment problem, 2 setup failed, 3 one or more assertions failed.
#
# Real: Foreman server (own port, own Postgres database), Go CLI, git, br, a real `pi` agent on
# minimax/MiniMax-M2.7-highspeed. Not real in steps 1-7: GitHub (nothing is pushed anywhere but a
# local bare origin; no PRs; stage 8 is the real-GitHub part), notification endpoints (a local HTTP sink). Idempotent: it owns a private
# database, port, scratch repo and work dir and removes only those (and only its own PIDs).
#
# Run from a devbox shell:
#
#     devbox run -- bash scripts/e2e/claude_projects_flow.sh
#
# Environment (all optional): E2E_MODEL, E2E_WORK_DIR (default <repo>/tmp/e2e-claude-projects-cp;
# never /tmp), E2E_DB_NAME, E2E_PG_HOST/PORT/USER/PASSWORD, E2E_PORT, E2E_HOOK_PORT,
# E2E_API_TOKEN, E2E_RUN_TIMEOUT (s, default 600), E2E_POLL_SECS, E2E_REVIEW=0 to skip the
# review-archive step, E2E_TRANSCRIPT=<file>, E2E_KEEP=1 to keep everything for a post-mortem.
# E2E_THREE_ONLY=1 runs only setup, step 1 and step 5b (the three-task paste and overlap assertion);
# E2E_THREE_TASK_MAX_RUNS=1 forces the project to one run at a time for step 5b, so the overlap
# assertion must FAIL (the evidence that it can). `bash claude_projects/overlap.sh` runs only the
# stack-free self-test of the interval helpers.
# E2E_GITHUB=1 is refused: the harness never creates a GitHub repository (use
# FOREMAN_E2E_GITHUB_REPO with an existing scratch repo instead).

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=cp
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/github.sh
. "$HERE/claude_projects/github.sh"
# shellcheck source=claude_projects/overlap.sh
. "$HERE/claude_projects/overlap.sh"

check_environment
github_prepare
install_traps

TOKEN_INSTR="INSTR-$SUFFIX-$(date +%s)"
TOKEN_MEMORY="MEMO-$SUFFIX-$(date +%s)"
TOKEN_LIBRARY="LIBR-$SUFFIX-$(date +%s)"

# wait_thread <thread_id> <status-regex> <timeout> -> THREAD_STATUS
wait_thread() {
  wt_start=$(date +%s); THREAD_STATUS=""
  while :; do
    THREAD_STATUS=$(api_get "/api/threads/$1" | jq -r '.thread.status // empty')
    if printf '%s' "$THREAD_STATUS" | grep -Eq "^($2)$"; then return 0; fi
    [ "$(elapsed "$wt_start")" -lt "$3" ] || return 1
    sleep "$E2E_POLL_SECS"
  done
}

# transcript_kinds <thread_id>: "role/kind" of every turn in the thread's structured transcript
transcript_kinds() {
  api_get "/api/threads/$1/transcript" 2>/dev/null | jq -r '.. | objects | select(has("role") and has("kind")) | "\(.role)/\(.kind)"' 2>/dev/null
}

# ---------------------------------------------------------------- 1. project

step_project() {
  say "1. project: create, goal, instructions, model/effort, limits"
  register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
  note "project $PROJECT registered (task provider beads, database $REPO/.beads/beads.db)"
  printf 'Always finish notes.txt with the exact line %s\n' "$TOKEN_INSTR" > "$WORK/instructions.md"
  if fm project update --goal "Acceptance scratch project: keep notes.txt files tidy" \
      --instructions-file "$WORK/instructions.md" --thread-model "$E2E_MODEL" \
      --coordinator-provider pi --coordinator-model "$E2E_MODEL" --max-concurrent-runs 3 \
      --notification-preference every_turn "$PROJECT" >"$WORK/project-update.out" 2>&1; then
    pass "project update accepted"
  else
    fail "project update rejected: $(head -c 300 "$WORK/project-update.out" | tr '\n' ' ')"
  fi
  got=$(fm project get --format json "$PROJECT" 2>/dev/null)
  assert_has "project get shows the goal" "$got" "Acceptance scratch project"
  assert_has "project get shows the instructions" "$got" "$TOKEN_INSTR"
  assert_has "project get shows max_concurrent_runs 3" "$(printf '%s' "$got" | jq -c '.')" '"max_concurrent_runs":3'
  ctx=$(fm project context --format json "$PROJECT" 2>/dev/null)
  assert_has "standing context an agent would receive carries the instructions" "$ctx" "$TOKEN_INSTR"
}

# ---------------------------------------------------------------- 2. memory + library

step_memory_library() {
  say "2. memory and library"
  printf 'The project code word for notes is %s.\n' "$TOKEN_MEMORY" > "$WORK/memory-house-style.md"
  fm project memory write --name house-style --description "house style code word" \
    --file "$WORK/memory-house-style.md" "$PROJECT" >"$WORK/memory-write.out" 2>&1 \
    && pass "memory topic house-style written" || fail "memory write: $(cut -c1-200 "$WORK/memory-write.out")"
  assert_has "memory read returns the content" "$(fm project memory read --name house-style "$PROJECT" 2>&1)" "$TOKEN_MEMORY"
  assert_has "memory list names the topic" "$(fm project memory list --format json "$PROJECT" 2>&1)" "house-style"

  printf 'The library secret for notes is %s.\n' "$TOKEN_LIBRARY" > "$WORK/facts.txt"
  fm project library add --name facts "$PROJECT" "$WORK/facts.txt" >"$WORK/library-add.out" 2>&1 \
    && pass "library file facts.txt added" || fail "library add: $(cut -c1-200 "$WORK/library-add.out")"
  assert_has "library list shows the file" "$(fm project library list --format json "$PROJECT" 2>&1)" "facts"
  assert_eq "library HTTP listing exits 200" "$(api_status "/api/projects/$PROJECT/library")" "200"
}

# ---------------------------------------------------------------- 3. thread from a bead

step_bead_thread() {
  say "3. a bead becomes a thread; the thread sees instructions, memory and library"
  T1_TITLE="e2e-$SUFFIX notes"
  new_bead "$T1_TITLE" "Create a file notes.txt in the current directory. It MUST contain (1) the project code word from the project memory topic house-style, (2) the library secret from the file facts.txt inside the directory named by the environment variable FOREMAN_LIBRARY_PATH, and (3) as its final line the exact line required by the project instructions. Copy the values verbatim."
  [ -n "${BEAD_ID:-}" ] || die "br create returned no bead id" 2
  note "bead $BEAD_ID created (label foreman-exec) in the scratch br database"
  thread_for_bead "$BEAD_ID" 180
  if [ -z "$THREAD" ]; then
    fail "no thread appeared for bead $BEAD_ID within 180s (BeadsWatcher did not import it)"
    grep -E 'BeadsWatcher|\[(error|warning)\]' "$SERVER_LOG" | tail -n 12 | cut -c1-240 | while IFS= read -r l; do note "$l"; done
    return 1
  fi
  pass "thread $THREAD created from bead $BEAD_ID"
  T1=$THREAD
  note "Overview counts, thread just created: $(overview_counts)"
  if wait_thread "$T1" "completed|ready_for_review|resolved|done" "$E2E_RUN_TIMEOUT"; then
    pass "thread $T1 reached terminal-success status '$THREAD_STATUS'"
    note "Overview counts, thread completed: $(overview_counts)"
  else
    fail "thread $T1 ended as '$THREAD_STATUS' (expected completed)"
    return 1
  fi
  T1_RUN=$(api_get "/api/threads/$T1" | jq -r '.thread.run_ids[0] // empty')
  T1_BRANCH=$(api_get "/api/threads/$T1" | jq -r '.thread.branch // empty')
  note "run $T1_RUN, branch $T1_BRANCH"
  notes=$(git -C "$REPO" show "$T1_BRANCH:notes.txt" 2>/dev/null)
  assert_has "notes.txt on the branch carries the memory token" "$notes" "$TOKEN_MEMORY"
  assert_has "notes.txt on the branch carries the library token" "$notes" "$TOKEN_LIBRARY"
  assert_has "notes.txt on the branch carries the instruction token" "$notes" "$TOKEN_INSTR"
}

# ---------------------------------------------------------------- 4. steer / stop / resolve

step_thread_control() {
  say "4. thread control: steer a running thread, stop one, resolve one"
  new_bead "e2e-$SUFFIX steer me" "Run the shell command 'sleep 45' and wait for it. Then create a file named steer-target.txt containing the single word PENDING."
  thread_for_bead "$BEAD_ID" 180; T_STEER=$THREAD
  new_bead "e2e-$SUFFIX stop me" "Run the shell command 'sleep 600' and wait for it. Then create a file named never.txt."
  thread_for_bead "$BEAD_ID" 180; T_STOP=$THREAD
  [ -n "$T_STEER" ] && [ -n "$T_STOP" ] || { fail "threads for steer/stop beads did not appear"; return 1; }
  pass "two more threads running ($T_STEER, $T_STOP)"
  wait_thread "$T_STEER" "working|running|in_progress" 120 && pass "steer target is working" || fail "steer target never showed as working (status '$THREAD_STATUS')"
  assert_eq "Overview shows running threads under Working" \
    "$(api_get "/api/projects/$PROJECT/overview" | jq -r '[.groups.working[]?] | length | if . >= 1 then "yes" else "no" end')" "yes"

  if fm thread steer --message "Also create a file named steer-marker.txt containing exactly STEERED-BY-OPERATOR." "$T_STEER" >"$WORK/steer.out" 2>&1; then
    pass "thread steer accepted"
  else
    fail "thread steer rejected: $(cut -c1-300 "$WORK/steer.out")"
  fi
  if wait_thread "$T_STEER" "completed|ready_for_review|resolved|done" "$E2E_RUN_TIMEOUT"; then
    STEER_RUN=$(api_get "/api/threads/$T_STEER" | jq -r '.thread.run_ids[0] // empty')
    STEER_BRANCH=$(api_get "/api/threads/$T_STEER" | jq -r '.thread.branch // empty')
    assert_eq "steered thread: the agent obeyed the steering message" \
      "$(git -C "$REPO" show "$STEER_BRANCH:steer-marker.txt" 2>/dev/null | tr -d ' \n\r')" "STEERED-BY-OPERATOR"
    kinds=$(transcript_kinds "$T_STEER" | sort | uniq -c | tr '\n' ';')
    note "steered thread transcript turns: $kinds"
    assert_has "transcript shows the operator steer turn" "$kinds" "operator/steer"
  else
    fail "steered thread ended as '$THREAD_STATUS'"
  fi

  if fm thread stop --reason "e2e stop" "$T_STOP" >"$WORK/stop.out" 2>&1; then pass "thread stop accepted"; else fail "thread stop: $(cut -c1-300 "$WORK/stop.out")"; fi
  if wait_thread "$T_STOP" "cancelled|stopped|failed" 90; then
    pass "stopped thread reached '$THREAD_STATUS'"
    note "Overview counts, one thread stopped: $(overview_counts)"
  else
    fail "stopped thread still '$THREAD_STATUS' after 90s"
  fi

  if fm thread resolve --reason "e2e resolve" "$T1" >"$WORK/resolve.out" 2>&1; then pass "thread resolve accepted"; else fail "thread resolve: $(cut -c1-300 "$WORK/resolve.out")"; fi
  assert_eq "resolved thread reads back resolved=true" "$(api_get "/api/threads/$T1" | jq -r '.thread.resolved')" "true"
  ov=$(api_get "/api/projects/$PROJECT/overview?include_resolved=true")
  assert_eq "Overview puts the resolved thread in the Resolved group" \
    "$(printf '%s' "$ov" | jq -r --arg t "$T1" '[.groups.resolved[]? | select(.thread_id == $t)] | length')" "1"
  note "Overview counts after resolve: $(printf '%s' "$ov" | jq -c '.counts')"
  fm thread reopen "$T1" >/dev/null 2>&1 && pass "thread reopen accepted" || fail "thread reopen failed"
  assert_eq "reopened thread reads back resolved=false" "$(api_get "/api/threads/$T1" | jq -r '.thread.resolved')" "false"
}

# ---------------------------------------------------------------- 5. overview, coordinator, approvals

step_overview_coordinator() {
  say "5. Overview groups, coordinator chat, approvals and questions"
  ov=$(api_get "/api/projects/$PROJECT/overview")
  assert_eq "overview endpoint answers with JSON" "$(printf '%s' "$ov" | jq -e 'type' 2>/dev/null)" '"object"'
  out "   overview: $(printf '%s' "$ov" | jq -c '.' | cut -c1-400)"
  assert_has "overview lists the first thread" "$ov" "$T1"
  chat=$(fm project chat --timeout 4m -m "Reply with the single word ACK. Do not start any thread." "$PROJECT" 2>&1)
  rc=$?
  assert_eq "coordinator chat exits 0" "$rc" "0"
  assert_has "coordinator replied" "$chat" "ACK"

  apr=$(fm approvals list --project "$PROJECT" 2>&1); arc=$?
  qst=$(fm questions list --project "$PROJECT" 2>&1); qrc=$?
  assert_eq "approvals list works (exit)" "$arc" "0"
  assert_eq "questions list works (exit)" "$qrc" "0"
  unverified "approve/deny a tool call and answer an agent question" \
    "pi has no tool-permission or ask mechanism, so no approval or question is ever raised; only the empty list surfaces are checked"
}

# ---------------------------------------------------------------- 5b. three tasks in one message, run in parallel

# project_runs_active: number of this project's runs that have not reached a terminal status
project_runs_active() {
  api_get "/api/runs?project_id=$PROJECT&limit=500" | jq '[.runs[]? | select(.["terminal?"] != true)] | length' 2>/dev/null
}

# The user's paste: a to-do list of three distinct small tasks in ONE message. Concurrency comes from
# the project cap (`max_concurrent_runs`, 3 here, set in step 1) and the global RunSlots cap
# (default 3): neither is below 3. `coordinator_max_active_threads` is left unset, so the coordinator
# imposes no cap of its own. E2E_THREE_TASK_MAX_RUNS=1 forces serial execution and must make the
# overlap assertion FAIL.
#
# `project chat` returns when the coordinator next goes idle, which can be after its answer to an
# earlier system report (a finished review) and before the turn for this message, so the threads
# are awaited by polling the project, not inferred from the chat output. If the coordinator started
# nothing, the user's remedy is a second nudge: the step sends one and says so.
three_titles() { # <tag> -> "<thread id><TAB><title>" per thread whose title contains the tag
  api_get "/api/projects/$PROJECT/threads" | jq -r --arg t "$1" '[.threads[]? | select(.title | contains($t))] | map("\(.id)\t\(.title)") | .[]' 2>/dev/null
}
step_three_tasks() {
  say "5b. three tasks pasted in one message start three threads that run in parallel"
  overlap_selftest
  cap=${E2E_THREE_TASK_MAX_RUNS:-3}
  qn=0
  while [ "$(project_runs_active)" != "0" ] && [ "$qn" -lt 300 ]; do sleep 5; qn=$((qn + 5)); done
  assert_eq "no run of the project is active before the paste (slots are free)" "$(project_runs_active)" "0"
  if [ "$cap" != 3 ]; then
    fm project update --max-concurrent-runs "$cap" "$PROJECT" >/dev/null 2>&1 \
      && note "project max_concurrent_runs forced to $cap for this step (E2E_THREE_TASK_MAX_RUNS)" \
      || fail "could not set max_concurrent_runs=$cap"
  fi
  tag="e2e-$SUFFIX todo"
  paste="Here is my to-do list for today, please start one thread for each of the three items, all in this one reply (exactly three threads). Title the threads exactly '$tag A', '$tag B' and '$tag C'.
A. Create a file alpha-$SUFFIX.txt containing exactly the single word ALPHA-$SUFFIX.
B. Create a file bravo-$SUFFIX.txt containing exactly the single word BRAVO-$SUFFIX.
C. Create a file charlie-$SUFFIX.txt containing exactly the single word CHARLIE-$SUFFIX."
  chat=$(fm project chat --timeout 6m -m "$paste" "$PROJECT" 2>&1); rc=$?
  assert_eq "coordinator chat with the three-item paste exits 0" "$rc" "0"
  note "coordinator reply: $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-600)"

  titles=""; nudged=0; tn=0
  while :; do
    titles=$(three_titles "$tag")
    [ "$(printf '%s' "$titles" | grep -c .)" -ge 3 ] && break
    if [ "$tn" -ge 240 ]; then
      if [ "$nudged" = 0 ] && [ -z "$titles" ]; then
        note "no thread appeared 240s after the paste; sending the same paste once more (a second nudge, as a user would)"
        note "conversation tail: $(fm project chat --history 4 --format json "$PROJECT" 2>&1 | jq -c '[.[] | {role, kind, text: (.text[0:160])}]' 2>/dev/null | cut -c1-900)"
        nudged=1; tn=0
        chat=$(fm project chat --timeout 6m -m "$paste" "$PROJECT" 2>&1)
        continue
      fi
      break
    fi
    sleep 5; tn=$((tn + 5))
  done
  sleep 10
  titles=$(three_titles "$tag")
  assert_eq "the coordinator started exactly three threads for the three items" "$(printf '%s' "$titles" | grep -c .)" "3"
  if [ "$(printf '%s' "$titles" | grep -c .)" -ne 3 ]; then
    note "conversation tail: $(fm project chat --history 6 --format json "$PROJECT" 2>&1 | jq -c '[.[] | {role, kind, text: (.text[0:300])}]' 2>/dev/null | cut -c1-1800)"
  fi
  printf '%s\n' "$titles" | while IFS= read -r l; do [ -n "$l" ] && note "thread $l"; done
  assert_eq "the three threads have three distinct titles" "$(printf '%s\n' "$titles" | cut -f2 | sort -u | grep -c .)" "3"
  [ "$(printf '%s' "$titles" | grep -c .)" -ge 1 ] || { fail "no thread to wait for"; return 1; }
  note "Overview counts while they run: $(overview_counts)"

  : > "$WORK/three-task-intervals.txt"
  for tid in $(printf '%s\n' "$titles" | cut -f1); do
    if wait_thread "$tid" "completed|ready_for_review|resolved|done" "$E2E_RUN_TIMEOUT"; then
      pass "thread $tid reached terminal-success status '$THREAD_STATUS'"
    else
      fail "thread $tid ended as '$THREAD_STATUS' (expected completed)"
    fi
    trun=$(api_get "/api/threads/$tid" | jq -r '.thread.run_ids[0] // empty')
    tbranch=$(api_get "/api/threads/$tid" | jq -r '.thread.branch // empty')
    ttitle=$(printf '%s\n' "$titles" | awk -F'\t' -v t="$tid" '$1 == t { print $2 }')
    case "$ttitle" in
      "$tag A") tfile=alpha-$SUFFIX.txt; tword=ALPHA-$SUFFIX ;;
      "$tag B") tfile=bravo-$SUFFIX.txt; tword=BRAVO-$SUFFIX ;;
      "$tag C") tfile=charlie-$SUFFIX.txt; tword=CHARLIE-$SUFFIX ;;
      *) fail "thread $tid has an unexpected title '$ttitle' (wanted '$tag A', '$tag B' or '$tag C')"; continue ;;
    esac
    assert_eq "thread '$ttitle': $tfile on its branch holds exactly the requested word" \
      "$(git -C "$REPO" show "$tbranch:$tfile" 2>/dev/null | tr -d ' \n\r')" "$tword"
    [ -n "$trun" ] || { fail "thread $tid has no run"; continue; }
    run_interval "$trun" >> "$WORK/three-task-intervals.txt"
  done
  assert_eq "still exactly three threads after the runs finished (no thread started later)" "$(three_titles "$tag" | grep -c .)" "3"

  say "5b. run intervals (event store: RunStarted .. first terminal event)"
  while IFS= read -r l; do [ -n "$l" ] && note "$l"; done < "$WORK/three-task-intervals.txt"
  nrun=$(grep -c -E '^[^ ]+ [0-9]+ [0-9]+ ' "$WORK/three-task-intervals.txt")
  assert_eq "start and finish times were read for all three runs" "$nrun" "3"
  intervals_render < "$WORK/three-task-intervals.txt" | while IFS= read -r l; do note "$l"; done
  pairs=$(intervals_overlap_pairs < "$WORK/three-task-intervals.txt")
  peak=$(intervals_peak < "$WORK/three-task-intervals.txt")
  note "overlapping pairs: $(printf '%s' "$pairs" | tr '\n' ';' | sed 's/;$//') ; peak simultaneous runs: $peak ; project cap: $cap"
  if [ -n "$pairs" ]; then
    pass "at least two of the three runs overlapped (start_i < finish_j and start_j < finish_i): $(printf '%s' "$pairs" | grep -c .) pair(s)"
  else
    fail "no two of the three runs overlapped: they ran serially (start_i < finish_j and start_j < finish_i never held)"
  fi
  [ "$peak" -le "$cap" ] && pass "the project cap was respected (peak $peak <= $cap simultaneous runs)" || fail "peak $peak simultaneous runs exceeded the project cap $cap"
  if [ "$cap" != 3 ]; then
    fm project update --max-concurrent-runs 3 "$PROJECT" >/dev/null 2>&1 || fail "could not restore max_concurrent_runs=3"
  fi
}

# ---------------------------------------------------------------- 6. notifications, usage

step_notifications_usage() {
  say "6. notifications and usage"
  n=$(wc -l < "$HOOK_CAPTURE" 2>/dev/null | tr -d ' ')
  [ "${n:-0}" -ge 1 ] && pass "notification sink received $n deliveries" || fail "notification sink received nothing"
  classes=$(jq -r '.body | (.event_class // .class // .kind // empty)' "$HOOK_CAPTURE" 2>/dev/null | sort | uniq -c | tr '\n' ';')
  note "delivery classes: ${classes:-none}"
  u=$(fm usage --project "$PROJECT" --format json 2>&1); urc=$?
  assert_eq "usage report exits 0" "$urc" "0"
  out "   usage: $(printf '%s' "$u" | tr '\n' ' ' | cut -c1-300)"
}

# ---------------------------------------------------------------- 7. review archive

step_review() {
  say "7. review archive and verdict"
  if [ "$E2E_REVIEW" != 1 ]; then unverified "review archive" "E2E_REVIEW=0"; return 0; fi
  dir="$REPO/.foreman/sessions/run/$T1_RUN"
  rn=0
  while [ ! -f "$dir/analysis.json" ] && [ "$rn" -lt 600 ]; do sleep 5; rn=$((rn + 5)); done
  for f in manifest.json request.md transcript.jsonl diff.patch changed-files.txt analysis.json analysis.md; do
    assert_true "archive file $f exists" test -s "$dir/$f"
  done
  assert_has "request.md carries the bead's request" "$(cat "$dir/request.md" 2>/dev/null)" "FOREMAN_LIBRARY_PATH"
  assert_has "diff.patch contains notes.txt" "$(cat "$dir/diff.patch" 2>/dev/null)" "notes.txt"
  verdict=$(jq -r '.verdict // empty' "$dir/analysis.json" 2>/dev/null)
  case "$verdict" in
    met|partially_met|not_met) pass "analysis verdict recorded: $verdict" ;;
    *)
      fail "analysis verdict '$verdict' (undetermined means the reviewer agent failed): error_code=$(jq -r '.error_code' "$dir/analysis.json" 2>/dev/null) summary=$(jq -r '.summary' "$dir/analysis.json" 2>/dev/null | head -c 300)"
      if [ -f "$dir/evaluator-transcript.jsonl" ]; then
        note "evaluator transcript (last 5 events):"
        tail -n 5 "$dir/evaluator-transcript.jsonl" | cut -c1-300 | while IFS= read -r l; do note "  $l"; done
      fi
      grep -E 'Review|review|evaluator' "$SERVER_LOG" | grep -E 'warning|error' | tail -n 5 | cut -c1-300 | while IFS= read -r l; do note "  $l"; done ;;
  esac
  out "   analysis.json: $(jq -c '{verdict, scores, error_code}' "$dir/analysis.json" 2>/dev/null)"
  # BeadSink posts after analysis.json is written: poll for the comment.
  cn=0; cm=""
  while [ "$cn" -lt 90 ]; do
    cm=$(cd "$REPO" && br comments list "$BEAD_ID" 2>/dev/null)
    case "$cm" in *erdict*) break ;; esac
    sleep 3; cn=$((cn + 3))
  done
  assert_has "the verdict was posted as a comment on the source bead" "$cm" "verdict"
}

# ---------------------------------------------------------------- main

setup_stack
if [ "${E2E_GH_ONLY:-0}" = 1 ]; then
  step_github
  summary
  exit $?
fi
if [ "${E2E_THREE_ONLY:-0}" = 1 ]; then
  step_project
  step_three_tasks
  summary
  exit $?
fi
step_project
step_memory_library
if step_bead_thread; then
  step_thread_control
  step_overview_coordinator
  step_three_tasks
  step_notifications_usage
  step_review
else
  note "skipping the dependent steps: the first thread failed"
fi
step_github
summary
exit $?
