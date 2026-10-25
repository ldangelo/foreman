#!/usr/bin/env bash
# scripts/e2e/failure_injection.sh
#
# Failure-injection acceptance for the Claude Projects flow (epic E16-S8-T2). Each scenario
# injects one real failure into a real throwaway Foreman server (private database/port/scratch
# repo; real pi agent on minimax) and asserts the TYPED failure cause and the recovery:
#
#   provider-down      coordinator provider unreachable -> typed error in the conversation, no
#                      thread created, recovery after the provider is restored, no duplicates;
#                      a thread whose model does not exist -> run failed with a typed reason
#   agent-crash        kill -9 of the agent process (by PID) mid-run -> run fails visibly,
#                      typed reason, worktree/branch not left claiming to run
#   coordinator-crash  kill the coordinator's project worker process mid-turn -> the next
#                      message is answered, exactly one set of actions exists
#   server-crash       kill -9 of the server AND its exec-port (agent orphaned to pid 1), then
#                      restart -> OrphanReaper terminates the orphan (#607), no "worktree
#                      already exists" failure, the run is resumed or fails visibly
#   port-closed        kill -9 of ONLY the agent's exec-port (server stays up) -> run fails
#                      `:port_closed` and the orphaned agent is reaped by the live failure path
#                      (foreman-zmhzw), not left running in the failed run's worktree
#   cancel-strays      `run cancel` and `thread stop` of a run whose agent is blocked in a `sleep 300`
#                      tool -> the agent AND the tool process (which runs in a session of its own)
#                      are gone: nothing is left running, re-parented to pid 1, in the run's worktree
#                      (foreman-zmhzw)
#   shutdown-strays    SIGTERM (graceful shutdown) of the server with such a run in flight -> the
#                      same: no agent and no tool process outlives the server (foreman-zmhzw)
#   br-down            br's WRITE verbs (comments, create) fail for the SERVER (a stub earlier on
#                      its PATH; reads still work or BeadsWatcher could not import) -> the thread
#                      still completes, the review verdict is still recorded, and the bead sink
#                      failure is visible in the recorded summary (bead_unresolved/bead_write_failed)
#   project-paused     `project pause` -> no new thread starts while paused (typed rejection),
#                      a thread already running at pause time still completes while paused
#                      (asserted), resume restores admissions
#
# Each scenario prints EXPECTED vs ACTUAL via PASS/FAIL lines; any FAIL makes the exit non-zero.
# Exit: 0 all passed, 1 environment problem, 2 setup failed, 3 one or more assertions failed.
#
#     devbox run -- bash scripts/e2e/failure_injection.sh [scenario ...]
#
# With no arguments every scenario runs. Same environment variables as
# claude_projects_flow.sh (E2E_WORK_DIR, E2E_DB_NAME, E2E_PORT, E2E_KEEP, ...). The review
# analyzer runs as usual (pi reviewer) and is not asserted here.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=fail
E2E_PORT=${E2E_PORT:-4830}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4930}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

SCENARIOS=${*:-"provider-down agent-crash coordinator-crash server-crash port-closed cancel-strays shutdown-strays project-paused br-down"}
for s in $SCENARIOS; do
  case "$s" in provider-down|agent-crash|coordinator-crash|server-crash|port-closed|cancel-strays|shutdown-strays|project-paused|br-down) ;; *) die "unknown scenario '$s'" 1 ;; esac
done

check_environment
install_traps

# ---------------------------------------------------------------- helpers

thread_count() { api_get "/api/projects/$PROJECT/threads" | jq '.threads | length'; }

# wait_run_status <run_id> <regex> <timeout> -> RUN_STATUS
wait_run_status() {
  wr_start=$(date +%s); RUN_STATUS=""
  while :; do
    RUN_STATUS=$(api_get "/api/runs/$1" | jq -r '.run.status // empty')
    if printf '%s' "$RUN_STATUS" | grep -Eq "^($2)$"; then return 0; fi
    [ "$(elapsed "$wr_start")" -lt "$3" ] || return 1
    sleep 2
  done
}

# bead_run <bead_id> <timeout> -> RUN (run id of the bead's task, empty after timeout)
bead_run() {
  thread_for_bead "$1" "$2"
  RUN=""
  [ -n "$THREAD" ] && RUN=${THREAD#run:}
}

# agent_pids <worktree-substring> <root pid>: descendants of root whose cwd is inside a worktree
agent_pids() {
  for ap in $(descendants "$2"); do
    if lsof -a -p "$ap" -d cwd -Fn 2>/dev/null | grep -q "^n.*$1"; then echo "$ap"; fi
  done
}

alive() { kill -0 "$1" 2>/dev/null; }

# wait_agent <run_id> <root pid> [timeout] -> AGENT_PIDS (processes under the server whose cwd is in the run's worktree)
wait_agent() {
  wa_n=0; AGENT_PIDS=""
  while [ -z "$AGENT_PIDS" ] && [ "$wa_n" -lt "${3:-120}" ]; do
    AGENT_PIDS=$(agent_pids "$1" "$2" | tr '\n' ' ')
    [ -n "$AGENT_PIDS" ] || sleep 2
    wa_n=$((wa_n + 2))
  done
}

failure_reason() { api_get "/api/runs/$1" | jq -c '.run.failure_reason // .run.error // null'; }

# wait_tool <agent pid> [timeout]: until the agent is blocked in its `sleep 300` tool (so it is idle and not
# writing to the pipe that dies with exec-port, which would kill it with the server)
wait_tool() {
  wt_n=0
  while [ "$wt_n" -lt "${2:-120}" ]; do
    for wd in $(descendants "$1"); do
      case "$(ps -o command= -p "$wd" 2>/dev/null)" in *"sleep 300"*) return 0 ;; esac
    done
    sleep 2; wt_n=$((wt_n + 2))
  done
  return 1
}

LONG="Run the shell command 'sleep 300' and wait for it to finish. Then create a file named done.txt containing the word DONE."

# run_strays <run_id>: every process on the host - whatever its parent, so also the ones re-parented to
# pid 1 - whose cwd is inside that run's worktree (HOME is redirected, so they live under
# $WORK/home/.foreman/worktrees/<project>/<task>/<run>)
run_strays() {
  lsof -d cwd -Fpn 2>/dev/null | awk -v r="$1" '/^p/ { pid = substr($0, 2) } /^n/ { p = substr($0, 2); if (index(p, "/.foreman/worktrees/") && index(p, r)) print pid }' | sort -u
}

# show_run_strays <label> <run_id>: the evidence, one `ps` row per process
show_run_strays() {
  note "$1:"
  for sp in $(run_strays "$2"); do note "  $(ps -o pid=,ppid=,pgid=,stat=,command= -p "$sp" 2>/dev/null | cut -c1-150)"; done
}

# no_run_strays <what> <run_id>: nothing may be left running in the run's worktree (waits for the
# agent's own exit and the sweep that follows it)
no_run_strays() {
  ns_n=0; ns_left=""
  while [ "$ns_n" -lt 60 ]; do
    ns_left=$(run_strays "$2" | tr '\n' ' ')
    [ -z "$ns_left" ] && break
    sleep 2; ns_n=$((ns_n + 2))
  done
  if [ -z "$ns_left" ]; then
    pass "$1: nothing is left running in the run's worktree"
  else
    fail "$1: still running in the run's worktree:$ns_left"
    show_run_strays "left behind" "$2"
    for sp in $ns_left; do kill -9 "$sp" 2>/dev/null; done
  fi
}

# ---------------------------------------------------------------- scenario: provider-down

scenario_provider_down() {
  say "scenario provider-down"
  note "EXPECTED: unreachable coordinator provider -> typed unhealthy notice, no thread; restore -> reply, still no thread; nonexistent model -> run failed with a typed reason, not an opaque one"
  base=$(thread_count)
  fm project update --coordinator-provider claude --coordinator-model claude-nonexistent-e2e "$PROJECT" >/dev/null 2>&1 \
    || fail "could not point the coordinator at claude"
  # The isolated HOME holds no claude credentials: the provider is genuinely unavailable.
  chat=$(fm project chat --timeout 3m -m "Start a thread that creates hello.txt." "$PROJECT" 2>&1); rc=$?
  note "ACTUAL chat exit=$rc: $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-300)"
  if [ "$rc" -ne 0 ]; then pass "chat against a down provider fails visibly (exit $rc, not a silent success)"; else fail "chat against a down provider exited 0"; fi
  hist=$(fm project chat --history 10 --format json "$PROJECT" 2>&1)
  note "conversation: $(printf '%s' "$hist" | tr '\n' ' ' | cut -c1-500)"
  assert_has "conversation records a typed unhealthy/error notice" "$hist" "unhealthy"
  assert_eq "no thread was created while the provider was down" "$(thread_count)" "$base"

  fm project update --coordinator-provider pi --coordinator-model "$E2E_MODEL" "$PROJECT" >/dev/null 2>&1 || fail "could not restore the coordinator provider"
  fm project chat --restart "$PROJECT" >"$WORK/restart.out" 2>&1 || fail "coordinator restart: $(head -c 200 "$WORK/restart.out")"
  chat=$(fm project chat --timeout 4m -m "Reply with the single word ACK. Do not start any thread." "$PROJECT" 2>&1); rc=$?
  assert_eq "after restore + restart the coordinator answers (exit)" "$rc" "0"
  assert_has "coordinator answered" "$chat" "ACK"
  # The message sent while the provider was down stays queued; it is served once after recovery
  # (exactly one thread for it, never zero and never two).
  sleep 30
  hello=$(api_get "/api/projects/$PROJECT/threads" | jq '[.threads[] | select((.title // "") | test("hello"; "i"))] | length')
  if [ "$hello" -le 1 ]; then pass "recovery served the queued request at most once ($hello thread(s) for hello.txt): no duplicates"; else fail "recovery created $hello threads for one request"; fi
  base=$(thread_count)

  new_bead "e2e-$SUFFIX bad model" "Create hello.txt." >/dev/null
  # the bad-model workflow serves type docs
  BEAD_ID=$(cd "$REPO" && br create "e2e-$SUFFIX bad model" -t docs -p 2 -l foreman-exec -d "Create hello.txt containing hi." --silent 2>/dev/null)
  (cd "$REPO" && br sync --flush-only >/dev/null 2>&1)
  bead_run "$BEAD_ID" 180
  if [ -z "$RUN" ]; then fail "no run for the bad-model bead"; return 0; fi
  if wait_run_status "$RUN" "failed|cancelled" 300; then pass "run with a nonexistent model ended '$RUN_STATUS'"; else fail "run with a nonexistent model ended '$RUN_STATUS' (expected failed)"; return 0; fi
  reason=$(failure_reason "$RUN")
  note "ACTUAL failure_reason: $reason"
  case "$reason" in
    *'"other"'*execution*|*other*execution*) fail "failure reason is the opaque {:other,:execution}: $reason" ;;
    null|'""') fail "run failed with no recorded reason" ;;
    *) pass "run failure carries a recorded reason: $(printf '%s' "$reason" | cut -c1-160)" ;;
  esac
}

# ---------------------------------------------------------------- scenario: agent-crash

scenario_agent_crash() {
  say "scenario agent-crash"
  note "EXPECTED: kill -9 of the agent mid-run -> run failed with a recorded reason, thread under Waiting on you, a failure notification delivered"
  new_bead "e2e-$SUFFIX agent crash" "$LONG"
  bead_run "$BEAD_ID" 180
  [ -n "$RUN" ] || { fail "no run appeared for the agent-crash bead"; return 0; }
  wait_agent "$RUN" "$SERVER_PID" 180
  if [ -z "$AGENT_PIDS" ]; then fail "no agent process found under the server for run $RUN"; return 0; fi
  note "agent process tree: $AGENT_PIDS"
  for p in $AGENT_PIDS; do kill -9 "$p" 2>/dev/null; done
  pass "kill -9 sent to the agent processes of run $RUN (pids $AGENT_PIDS)"
  if wait_run_status "$RUN" "failed|cancelled|completed" 180; then
    assert_eq "run after agent kill" "$RUN_STATUS" "failed"
  else
    fail "run still '$RUN_STATUS' 180s after its agent was killed"
  fi
  reason=$(failure_reason "$RUN")
  note "ACTUAL failure_reason: $reason"
  case "$reason" in null|'""') fail "agent kill left no recorded reason" ;; *) pass "agent kill recorded a reason: $(printf '%s' "$reason" | cut -c1-160)" ;; esac
  assert_eq "thread status after the kill" "$(api_get "/api/threads/run:$RUN" | jq -r '.thread.status')" "failed"
  note "Overview counts after the crash: $(overview_counts)"
  assert_eq "Overview shows the failed thread under Waiting on you" \
    "$(api_get "/api/projects/$PROJECT/overview" | jq -r --arg t "run:$RUN" '[.groups.waiting_on_you[]? | select(.thread_id == $t)] | length')" "1"
  fc=0
  while [ "$(hook_count '"failure"')" -lt 1 ] && [ "$fc" -lt 60 ]; do sleep 3; fc=$((fc + 3)); done
  if [ "$(hook_count 'failure')" -ge 1 ]; then pass "a failure notification reached the webhook sink"; else fail "no failure notification reached the webhook sink within 60s"; fi
}

# ---------------------------------------------------------------- scenario: coordinator-crash

scenario_coordinator_crash() {
  say "scenario coordinator-crash"
  note "EXPECTED: killing the coordinator project worker mid-turn does not wedge the project: the next message is answered and the requested thread exists exactly once"
  base=$(thread_count)
  title="e2e-$SUFFIX coordinator crash probe"
  (fm project chat --no-wait -m "Start exactly one thread titled '$title' whose task is: create the file probe.txt containing the word PROBE." "$PROJECT" >"$WORK/crash-chat.out" 2>&1)
  killed=$(rpc "case Registry.lookup(ForemanServer.Coordinator.Registry, \"$PROJECT\") do [{pid, _}] -> Process.exit(pid, :kill); IO.puts(\"KILLED \" <> inspect(pid)); [] -> IO.puts(\"NO-WORKER\") end" | tail -n 1)
  note "ACTUAL kill: $killed"
  case "$killed" in
    KILLED*) pass "coordinator project worker killed mid-turn ($killed)" ;;
    *) unverified "kill the coordinator worker mid-turn" "no worker was running 6s after the message ($killed): the turn had already finished or never started" ;;
  esac
  sleep 5
  chat=$(fm project chat --timeout 5m -m "Also reply with the single word ACK." "$PROJECT" 2>&1); rc=$?
  note "ACTUAL chat after the kill: exit=$rc $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-200)"
  assert_eq "coordinator answers after the crash (exit)" "$rc" "0"
  # the requested thread must exist (the turn is re-run after the crash) and exactly once
  cn=0; n=0
  while [ "$cn" -lt 150 ] && [ "$n" -lt 1 ]; do
    n=$(api_get "/api/projects/$PROJECT/threads" | jq --arg t "$title" '[.threads[] | select(.title | contains($t))] | length')
    [ "$n" -ge 1 ] || sleep 5
    cn=$((cn + 5))
  done
  sleep 20
  n=$(api_get "/api/projects/$PROJECT/threads" | jq --arg t "$title" '[.threads[] | select(.title | contains($t))] | length')
  assert_eq "the requested thread exists exactly once after the crash (0 = request lost, 2 = duplicate actions)" "$n" "1"
  note "thread count: $base -> $(thread_count)"
}

# ---------------------------------------------------------------- scenario: server-crash

scenario_server_crash() {
  say "scenario server-crash"
  note "EXPECTED: kill -9 of exec-port + server orphans the agent; after restart OrphanReaper reaps it and the run is not stuck on 'worktree already exists'"
  # Whether the agent survives as an orphan depends on a race between exec-port's death and the
  # agent's own pipe handling, so retry (up to 3 attempts) until the orphan exists: only then is
  # OrphanReaper exercised.
  orphans=""; attempt=0
  while [ -z "$orphans" ] && [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1 ]; then
      note "attempt $attempt: no orphan was produced by the previous crash"
      fm run cancel --id "$RUN" --reason "e2e retry" >/dev/null 2>&1
    fi
    new_bead "e2e-$SUFFIX server crash $attempt" "$LONG"
    bead_run "$BEAD_ID" 180
    [ -n "$RUN" ] || { fail "no run appeared for the server-crash bead"; return 0; }
    wait_agent "$RUN" "$SERVER_PID" 180
    if [ -z "$AGENT_PIDS" ]; then fail "no agent process found for run $RUN"; return 0; fi
    note "agent pids: $AGENT_PIDS"
    for ap in $AGENT_PIDS; do wait_tool "$ap" 120 && break; done
    # exec-port is the agent's parent. Killing it first orphans the agent (re-parented to pid 1); the
    # server dies right after, so it cannot record the lost port (what `pkill -9 -f <repo path>` or
    # an OOM kill does).
    ports=""
    for d in $(descendants "$SERVER_PID"); do
      case "$(ps -o comm= -p "$d")" in *exec-port) ports="$ports $d" ;; esac
    done
    note "exec-port pids:$ports"
    ptree() { for q in $(descendants "$SERVER_PID") $AGENT_PIDS; do ps -o pid=,ppid=,pgid=,stat=,command= -p "$q" 2>/dev/null | cut -c1-140; done | sort -u; }
    note "process tree before the crash:"; ptree | while IFS= read -r l; do note "  $l"; done
    old_server=$SERVER_PID
    # shellcheck disable=SC2086
    kill -9 $ports "$old_server" 2>/dev/null
    SERVER_PID=""
    sleep 2
    orphans=""
    for p in $AGENT_PIDS; do if alive "$p" && [ "$(ps -o ppid= -p "$p" | tr -d ' ')" = 1 ]; then orphans="$orphans $p"; fi; done
    if [ -n "$orphans" ]; then pass "agent orphaned to pid 1 after the crash (pids$orphans)"; fi
    start_server
  done
  # recovery: the run is resumed on boot or fails visibly; it must not be stuck
  sleep 20
  wait_run_status "$RUN" "completed|failed|cancelled|running|working|in_progress|pending" 60
  note "ACTUAL run status after restart: $RUN_STATUS; reason: $(failure_reason "$RUN")"
  if [ "$RUN_STATUS" = in_progress ]; then
    wait_agent "$RUN" "$SERVER_PID" 120
    if [ -n "$AGENT_PIDS" ]; then pass "run resumed after the crash: a fresh agent (pids $AGENT_PIDS) is running in its worktree"; else fail "run is in_progress but no agent runs for it 120s after the restart (stuck)"; fi
  fi
  assert_not_has "restart did not fail the run with 'worktree already exists'" "$(failure_reason "$RUN")" "already exists"
  if [ -n "$orphans" ]; then
    n=0; left=""
    while [ "$n" -lt 30 ]; do left=""; for p in $orphans; do alive "$p" && left="$left $p"; done; [ -z "$left" ] && break; sleep 2; n=$((n + 2)); done
    if [ -z "$left" ]; then pass "OrphanReaper terminated the orphaned agent(s)"; else fail "orphaned agent(s) still alive after restart:$left"; for p in $left; do kill -9 "$p" 2>/dev/null; done; fi
    assert_has "server log records the reap" "$(cat "$SERVER_LOG")" "OrphanReaper"
  else
    unverified "OrphanReaper on a real orphan" "the agent died with the server on this host, so no orphan existed to reap"
  fi
  # leave nothing running for the next scenario
  fm run cancel --id "$RUN" --reason "e2e cleanup" >/dev/null 2>&1
}

# ---------------------------------------------------------------- scenario: port-closed

scenario_port_closed() {
  say "scenario port-closed"
  note "EXPECTED: kill -9 of only the exec-port (server alive) fails the run and the orphaned agent is reaped by the live failure path (OrphanReaper in the server log); without that it lives on at ppid 1 in the failed run's worktree"
  new_bead "e2e-$SUFFIX port closed" "$LONG"
  bead_run "$BEAD_ID" 180
  [ -n "$RUN" ] || { fail "no run appeared for the port-closed bead"; return 0; }
  wait_agent "$RUN" "$SERVER_PID" 180
  if [ -z "$AGENT_PIDS" ]; then fail "no agent process found for run $RUN"; return 0; fi
  note "agent pids: $AGENT_PIDS"
  for ap in $AGENT_PIDS; do wait_tool "$ap" 120 && break; done
  ports=""
  for d in $(descendants "$SERVER_PID"); do
    case "$(ps -o comm= -p "$d")" in *exec-port) ports="$ports $d" ;; esac
  done
  note "exec-port pids:$ports"
  # shellcheck disable=SC2086
  kill -9 $ports 2>/dev/null
  # which agents outlived the exec-port: only those are orphans for the reaper to log
  sleep 2; orphans=""; for p in $AGENT_PIDS; do alive "$p" && orphans="$orphans $p"; done
  wait_run_status "$RUN" "failed|cancelled|completed" 120
  note "ACTUAL run status: $RUN_STATUS; reason: $(failure_reason "$RUN"); agents alive after the exec-port kill:${orphans:- none}"
  assert_has "the run failed because its exec-port closed" "$(failure_reason "$RUN")" "port_closed"
  n=0; left=""
  while [ "$n" -lt 30 ]; do left=""; for p in $AGENT_PIDS; do alive "$p" && left="$left $p"; done; [ -z "$left" ] && break; sleep 2; n=$((n + 2)); done
  if [ -z "$left" ]; then pass "no agent process of the failed run is left running"; else fail "agent(s) still alive after the run failed:$left"; for p in $left; do kill -9 "$p" 2>/dev/null; done; fi
  if [ -n "$orphans" ]; then
    assert_has "server log records the reap" "$(cat "$SERVER_LOG")" "OrphanReaper: terminating"
  else
    unverified "OrphanReaper on a real orphan" "the agent died with its exec-port on this host, so no orphan existed to reap (foreman-e01a1)"
  fi
}

# ---------------------------------------------------------------- scenario: cancel-strays

# start_busy_run <what> -> RUN, THREAD, AGENT_PIDS: a run whose agent is blocked in its `sleep 300` tool
start_busy_run() {
  new_bead "e2e-$SUFFIX $1" "$LONG"
  bead_run "$BEAD_ID" 180
  [ -n "$RUN" ] || { fail "no run appeared for the $1 bead"; return 1; }
  wait_agent "$RUN" "$SERVER_PID" 180
  if [ -z "$AGENT_PIDS" ]; then fail "no agent process found for run $RUN"; return 1; fi
  for ap in $AGENT_PIDS; do wait_tool "$ap" 120 && break; done
  show_run_strays "in the run's worktree before the $1" "$RUN"
}

scenario_cancel_strays() {
  say "scenario cancel-strays"
  note "EXPECTED: after run cancel and after thread stop the agent AND the tool process it started (sleep 300, in a session of its own) are gone; before foreman-zmhzw the tool process outlived the cancelled run, re-parented to pid 1, in its worktree"
  start_busy_run "run cancel" || return 0
  if fm run cancel --id "$RUN" --reason "e2e cancel" >"$WORK/cancel.out" 2>&1; then pass "run cancel accepted"; else fail "run cancel: $(cut -c1-200 "$WORK/cancel.out")"; fi
  wait_run_status "$RUN" "cancelled" 60 && pass "run cancelled" || fail "run not cancelled (status '$RUN_STATUS')"
  no_run_strays "after run cancel" "$RUN"
  start_busy_run "thread stop" || return 0
  if fm thread stop --reason "e2e stop" "$THREAD" >"$WORK/stop.out" 2>&1; then pass "thread stop accepted"; else fail "thread stop: $(cut -c1-200 "$WORK/stop.out")"; fi
  wait_run_status "$RUN" "cancelled" 60 && pass "thread stopped (run cancelled)" || fail "thread not stopped (run status '$RUN_STATUS')"
  no_run_strays "after thread stop" "$RUN"
}

# ---------------------------------------------------------------- scenario: shutdown-strays

scenario_shutdown_strays() {
  say "scenario shutdown-strays"
  note "EXPECTED: SIGTERM of the server with a run in flight leaves no agent and no tool process of that run running; before foreman-zmhzw the tool process outlived the server, re-parented to pid 1, in the run's worktree"
  start_busy_run "graceful shutdown" || return 0
  old_server=$SERVER_PID
  kill -TERM "$old_server"
  sn=0
  while alive "$old_server" && [ "$sn" -lt 90 ]; do sleep 1; sn=$((sn + 1)); done
  if alive "$old_server"; then
    fail "the server was still running ${sn}s after SIGTERM"
    kill -9 "$old_server" 2>/dev/null
  else
    pass "the server stopped ${sn}s after SIGTERM"
  fi
  SERVER_PID=""
  no_run_strays "after the graceful shutdown" "$RUN"
  assert_has "server log records the sweep at shutdown" "$(cat "$SERVER_LOG")" "process(es) of agents still running"
  # the interrupted run is resumed at boot: leave nothing running for the next scenario
  start_server
  fm run cancel --id "$RUN" --reason "e2e cleanup" >/dev/null 2>&1
  no_run_strays "after the resumed run was cancelled" "$RUN"
}

# ---------------------------------------------------------------- scenario: project-paused

scenario_project_paused() {
  say "scenario project-paused"
  note "EXPECTED: while paused no new thread starts (typed project_paused rejection), a running thread continues, resume restores admissions"
  # A thread that is already running when the project is paused must keep going (E1: pause gates
  # admission of NEW work only). Start one that is still busy at the moment of the pause.
  new_bead "e2e-$SUFFIX running before pause" "Run the shell command 'sleep 45' and wait for it. Then create a file named before-pause.txt containing the word RUNNING."
  bead_run "$BEAD_ID" 180
  RUN_BEFORE=$RUN
  THREAD_BEFORE=$THREAD
  if [ -z "$RUN_BEFORE" ]; then fail "no thread started for the before-pause bead"; return 0; fi
  wait_run_status "$RUN_BEFORE" "running|in_progress|working" 120 && pass "before-pause thread $RUN_BEFORE is running (status $RUN_STATUS)" || fail "before-pause thread never reached running (status '$RUN_STATUS')"
  fm project pause --reason "e2e pause" "$PROJECT" >"$WORK/pause.out" 2>&1 && pass "project pause accepted" || fail "project pause: $(cut -c1-200 "$WORK/pause.out")"
  assert_eq "project reads back paused" "$(api_get "/api/projects/$PROJECT" | jq -r '.project.status // .status // empty')" "paused"
  base=$(thread_count)
  new_bead "e2e-$SUFFIX while paused" "Create a file named after-pause.txt containing the word HELLO."
  sleep 25
  assert_eq "no thread started for the bead while paused" "$(thread_count)" "$base"
  chat=$(fm project chat --timeout 2m -m "Start a thread that creates x.txt." "$PROJECT" 2>&1)
  note "ACTUAL chat while paused: $(printf '%s' "$chat" | tr '\n' ' ' | cut -c1-300)"
  assert_eq "no thread started through the coordinator while paused" "$(thread_count)" "$base"
  # The paused project must not have stopped the already-running thread.
  if wait_run_status "$RUN_BEFORE" "completed|failed|cancelled|stopped" "$E2E_RUN_TIMEOUT"; then
    assert_eq "the thread running at pause time still completed while the project was paused" "$RUN_STATUS" "completed"
    pb=$(api_get "/api/projects/$PROJECT" | jq -r '.project.status // .status // empty')
    assert_eq "project was still paused when that thread completed" "$pb" "paused"
    pbranch=$(api_get "/api/threads/$THREAD_BEFORE" | jq -r '.thread.branch // empty')
    assert_content_exactly "the paused-project thread delivered its file (before-pause.txt)" "$(git -C "$REPO" show "$pbranch:before-pause.txt" 2>/dev/null)" "RUNNING"
  else
    fail "the thread running at pause time did not finish within ${E2E_RUN_TIMEOUT}s (status '$RUN_STATUS'): pause stopped it"
  fi
  fm project resume "$PROJECT" >"$WORK/resume.out" 2>&1 && pass "project resume accepted" || fail "project resume: $(cut -c1-200 "$WORK/resume.out")"
  thread_for_bead "$BEAD_ID" 180
  if [ -n "$THREAD" ]; then pass "after resume the held bead started thread $THREAD (not lost)"; else fail "after resume the bead never started a thread"; fi
}

# ---------------------------------------------------------------- scenario: br-down

scenario_br_down() {
  say "scenario br-down"
  note "EXPECTED: with br writes (comments/create) failing for the server the thread still completes and its review verdict is still recorded; the bead-sink failure is visible in the recorded summary; no comment lands on the bead"
  mkdir -p "$WORK/nobr"
  real_br=$(command -v br)
  printf '#!/bin/sh\ncase "$1" in comments|create) echo "br: simulated outage (e2e br-down)" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$real_br" > "$WORK/nobr/br"
  chmod +x "$WORK/nobr/br"
  stop_server
  E2E_PATH_PREFIX="$WORK/nobr" start_server
  new_bead "e2e-$SUFFIX br down" "Create a file named brdown.txt containing the word UP."
  thread_for_bead "$BEAD_ID" 180
  [ -n "$THREAD" ] || { fail "no thread appeared for the br-down bead"; return 0; }
  wait_run_status "${THREAD#run:}" "completed|failed" "$E2E_RUN_TIMEOUT"
  assert_eq "thread completed while br was down" "$RUN_STATUS" "completed"
  vn=0; verdict=""; summary=""
  while [ "$vn" -lt 600 ]; do
    rep=$(api_get "/api/threads/$THREAD" | jq -c '.thread.last_report // empty')
    verdict=$(printf '%s' "$rep" | jq -r '.verdict // empty' 2>/dev/null)
    [ -n "$verdict" ] && { summary=$(printf '%s' "$rep" | jq -r '.summary // empty'); break; }
    sleep 5; vn=$((vn + 5))
  done
  note "ACTUAL review report: verdict='$verdict' summary='$(printf '%s' "$summary" | head -c 300)'"
  if [ -n "$verdict" ]; then
    pass "review verdict recorded while br was down: $verdict"
  else
    fail "no review verdict was recorded within 600s while br was down"
    note "review-related server log lines (last 15):"
    grep -iE 'review|evaluator|analy[sz]' "$SERVER_LOG" | grep -vE 'GET |Sent 200|Processing with|Parameters|Pipelines' | tail -n 15 | cut -c1-260 | while IFS= read -r l; do note "  $l"; done
  fi
  assert_has "the bead-sink failure is visible in the recorded summary" "$summary" "bead sink failed"
  assert_not_has "no review comment landed on the bead" "$(cd "$REPO" && br comments list "$BEAD_ID" 2>/dev/null)" "erdict"
}

# quiesce: cancel every running thread so the next scenario starts with free capacity
quiesce() {
  for t in $(api_get "/api/projects/$PROJECT/overview" | jq -r '.groups.working[]?.thread_id'); do
    fm run cancel --id "${t#run:}" --reason "e2e quiesce" >/dev/null 2>&1
  done
  qn=0
  while [ "$qn" -lt 60 ]; do
    [ "$(api_get "/api/projects/$PROJECT/overview" | jq -r '.counts.working')" = 0 ] && break
    sleep 2; qn=$((qn + 2))
  done
}

# ---------------------------------------------------------------- main

setup_stack
register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
fm project update --coordinator-provider pi --coordinator-model "$E2E_MODEL" --max-concurrent-runs 3 "$PROJECT" >/dev/null 2>&1 || die "project update failed" 2
note "project $PROJECT registered; scenarios: $SCENARIOS"
for s in $SCENARIOS; do
  case "$s" in
    provider-down) scenario_provider_down ;;
    agent-crash) scenario_agent_crash ;;
    coordinator-crash) scenario_coordinator_crash ;;
    server-crash) scenario_server_crash ;;
    port-closed) scenario_port_closed ;;
    cancel-strays) scenario_cancel_strays ;;
    shutdown-strays) scenario_shutdown_strays ;;
    project-paused) scenario_project_paused ;;
    br-down) scenario_br_down ;;
  esac
done
summary
exit $?
