#!/usr/bin/env bash
# Shared harness for scripts/e2e/claude_projects_flow.sh and scripts/e2e/failure_injection.sh.
# Sourced, never executed. Provides: assertions (PASS/FAIL/UNVERIFIED with evidence), a private
# throwaway stack (Postgres database, scratch git repo + local bare origin + br database, real
# Foreman server, notification sink), CLI/API helpers and, when a run fails, the evidence of why (evidence_keep).
#
# Real: Foreman server (MIX_ENV=dev, own port, own database), the Go CLI, git, br and a real
# `pi` agent on minimax/MiniMax-M2.7-highspeed. Not used: GitHub (nothing is pushed anywhere
# but the scratch repo's local bare origin), real notification endpoints (a local HTTP sink).
#
# Cleanup only touches what this harness created: its own PIDs, its own database, its own
# work directory (marker-protected). Nothing is killed by name. It removes the work directory and
# drops the database, so a run that failed first keeps its evidence outside them (evidence_keep).

set -u

E2E_NAME=${E2E_NAME:-cp}
E2E_MODEL=${E2E_MODEL:-minimax/MiniMax-M2.7-highspeed}
E2E_WORK_DIR=${E2E_WORK_DIR:-$ROOT/tmp/e2e-claude-projects-$E2E_NAME}
E2E_DB_NAME=${E2E_DB_NAME:-foreman_e2e_claude_projects_$E2E_NAME}
E2E_PG_HOST=${E2E_PG_HOST:-localhost}
E2E_PG_PORT=${E2E_PG_PORT:-55432}
E2E_PG_USER=${E2E_PG_USER:-postgres}
E2E_PG_PASSWORD=${E2E_PG_PASSWORD:-postgres}
E2E_PORT=${E2E_PORT:-4810}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4910}
E2E_API_TOKEN=${E2E_API_TOKEN:-e2e-claude-projects-token}
E2E_RUN_TIMEOUT=${E2E_RUN_TIMEOUT:-600}
E2E_POLL_SECS=${E2E_POLL_SECS:-3}
E2E_REVIEW=${E2E_REVIEW:-1}
E2E_TRANSCRIPT=${E2E_TRANSCRIPT:-}
E2E_KEEP=${E2E_KEEP:-0}
E2E_GITHUB=${E2E_GITHUB:-0}
# Failure evidence (foreman-azc2o): a non-zero exit or a failed assertion makes cleanup() keep what a post-mortem needs
# under $E2E_EVIDENCE_DIR/<name>-<UTC start time>-<pid>/ before it tears the stack down. E2E_EVIDENCE=0 switches it off,
# E2E_EVIDENCE=always keeps it for a passing run too (to compare a failing run with a passing one).
E2E_EVIDENCE_DIR=${E2E_EVIDENCE_DIR:-$ROOT/tmp/e2e-evidence}
E2E_EVIDENCE=${E2E_EVIDENCE:-1}

SERVER_DIR="$ROOT/packages/foreman_server"
CLI_DIR="$ROOT/packages/foreman_cli"
ASSETS="$ROOT/scripts/e2e/claude_projects"
# shellcheck source=../exact_content.sh
. "$ROOT/scripts/e2e/exact_content.sh"

PASSED=0
FAILED=0
UNVERIFIED=0
FAILURES=""
UNVERIFIED_LIST=""
STARTED_AT=$(date +%s)
SERVER_PID=""
HOOK_PID=""
DB_CREATED=0
SUFFIX="$$"
REAL_HOME=$HOME

WORK=$E2E_WORK_DIR
REPO="$WORK/repo"
ORIGIN="$WORK/origin.git"
FOREMAN="$WORK/bin/foreman"
SERVER_LOG="$WORK/server.log"
HOOK_CAPTURE="$WORK/webhook-capture.jsonl"
PROJECT="e2e-cp-$SUFFIX"
COOKIE="e2e-cp-cookie-$SUFFIX"
NODE="e2ecp${SUFFIX}@127.0.0.1"
API=""
EVIDENCE_RUN_DIR="$E2E_EVIDENCE_DIR/$E2E_NAME-$(date -u +%Y%m%dT%H%M%SZ)-$SUFFIX"

PGPASSWORD=$E2E_PG_PASSWORD
export PGPASSWORD
DATABASE_URL="postgres://$E2E_PG_USER:$E2E_PG_PASSWORD@$E2E_PG_HOST:$E2E_PG_PORT/$E2E_DB_NAME"

# ---------------------------------------------------------------- output

out() {
  printf '%s\n' "$*"
  if [ -n "$E2E_TRANSCRIPT" ]; then printf '%s\n' "$*" >> "$E2E_TRANSCRIPT"; fi
}
say() { out ""; out "== $* =="; }
note() { out "   $*"; }
pass() { out "  PASS        $*"; PASSED=$((PASSED + 1)); }
fail() {
  out "  FAIL        $*"
  FAILED=$((FAILED + 1))
  FAILURES="$FAILURES
  - $*"
}
# unverified <what> <why>: a scenario the harness cannot exercise on this host. Counted, never a pass.
unverified() {
  out "  UNVERIFIED  $1 -- $2"
  UNVERIFIED=$((UNVERIFIED + 1))
  UNVERIFIED_LIST="$UNVERIFIED_LIST
  - $1 ($2)"
}
die() { out "fatal: $1"; exit "${2:-2}"; }
elapsed() { echo $(($(date +%s) - $1)); }

assert_eq() { # <what> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1: expected '$3', got '$2'"; fi
}
assert_true() { # <what> <command...>
  at_what=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$at_what"; else fail "$at_what"; fi
}
assert_has() { # <what> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: '$3' not found in: $(printf '%s' "$2" | cut -c1-300)" ;; esac
}
assert_not_has() { # <what> <haystack> <needle>
  case "$2" in *"$3"*) fail "$1: '$3' unexpectedly present in: $(printf '%s' "$2" | cut -c1-300)" ;; *) pass "$1" ;; esac
}

summary() {
  say "summary"
  out "   passed=$PASSED failed=$FAILED unverified=$UNVERIFIED wall=$(elapsed "$STARTED_AT")s"
  if [ "$UNVERIFIED" -gt 0 ]; then out "   UNVERIFIED:$UNVERIFIED_LIST"; fi
  if [ "$FAILED" -gt 0 ]; then
    out "   FAILED:$FAILURES"
    return 3
  fi
  return 0
}

# ---------------------------------------------------------------- environment

psql_admin() {
  psql -X -q -v ON_ERROR_STOP=1 -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" -d postgres "$@"
}

check_environment() {
  case "$E2E_DB_NAME" in *[!a-z0-9_]*|"") die "E2E_DB_NAME must match [a-z0-9_]+" 1 ;; esac
  for tool in git jq curl psql go elixir mix python3 br pi; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required (run inside 'devbox run --'; pi and br must be on PATH)" 1
  done
  if [ "$E2E_GITHUB" = 1 ]; then
    die "E2E_GITHUB=1 is not supported: this harness never creates GitHub repositories (local bare origin only)" 1
  fi
  case "$WORK" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/*) die "E2E_WORK_DIR=$WORK is in a volatile location; use a directory under the checkout" 1 ;;
  esac
  [ -d "$SERVER_DIR" ] && [ -d "$CLI_DIR" ] || die "cannot find packages/ under $ROOT" 1
}

# ---------------------------------------------------------------- stack lifecycle

stop_pid() { # <pid>: TERM, wait, then KILL. Only ever called with PIDs this harness started.
  sp=$1
  if [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null; then
    kill "$sp" 2>/dev/null
    n=0
    while kill -0 "$sp" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
    kill -9 "$sp" 2>/dev/null
  fi
}

# descendants <pid>: all descendant pids of a pid this harness started
descendants() {
  ps -A -o pid=,ppid= | awk -v root="$1" '
    { parent[$1] = $2; pids[n++] = $1 }
    END {
      mark[root] = 1; changed = 1
      while (changed) { changed = 0
        for (i = 0; i < n; i++) { p = pids[i]; if (!(p in mark) && (parent[p] in mark)) { mark[p] = 1; changed = 1 } } }
      for (p in mark) if (p != root) print p
    }'
}

# stop_server: stops the server this harness started, then kills whatever of ITS process tree
# outlived it (agent tool processes such as a `sleep` run by the agent are in their own process
# groups and are re-parented to pid 1 when the server goes away).
stop_server() {
  ss_tree=""
  if [ -n "$SERVER_PID" ]; then ss_tree=$(descendants "$SERVER_PID"); fi
  stop_pid "$SERVER_PID"
  SERVER_PID=""
  for q in $ss_tree; do kill -9 "$q" 2>/dev/null; done
}

# sweep_strays: kill processes whose working directory is inside THIS harness's work dir (agent
# tool children that outlived their agent). Scoped by directory, never by command name.
sweep_strays() {
  case "$WORK" in ""|/) return 0 ;; esac
  lsof -d cwd -Fpn 2>/dev/null | awk -v w="$WORK/" '/^p/ { pid = substr($0, 2) } /^n/ { if (index(substr($0, 2), w) == 1) print pid }' | sort -u \
    | while read -r sp; do
        [ "$sp" = "$$" ] && continue
        out "   sweep: killing stray process $sp (cwd inside $WORK): $(ps -o command= -p "$sp" 2>/dev/null | cut -c1-80)"
        kill -9 "$sp" 2>/dev/null
      done
}

cleanup() {
  cl_rc=$?
  trap - EXIT INT TERM HUP
  if [ "$E2E_KEEP" = 1 ]; then
    out ""
    out "E2E_KEEP=1: server pid=$SERVER_PID node=$NODE hook pid=$HOOK_PID work dir=$WORK database=$E2E_DB_NAME left in place"
    exit "$cl_rc"
  fi
  if type github_cleanup >/dev/null 2>&1; then github_cleanup; fi
  if [ "$cl_rc" -ne 0 ] || [ "$FAILED" -gt 0 ] || [ "$E2E_EVIDENCE" = always ]; then
    # a subshell: whatever goes wrong while keeping the evidence must never skip the teardown below
    ( evidence_keep "$cl_rc" ) || out "   evidence: keeping it failed (status $?); the teardown goes on"
  fi
  stop_server
  stop_pid "$HOOK_PID"
  sweep_strays
  if [ -f "$WORK/.e2e-claude-projects" ]; then
    chmod -R u+rwx "$WORK" 2>/dev/null
    rm -rf "$WORK"
  fi
  if [ "$DB_CREATED" = 1 ]; then
    psql_admin -c "DROP DATABASE IF EXISTS $E2E_DB_NAME WITH (FORCE)" >/dev/null 2>&1
  fi
  exit "$cl_rc"
}

install_traps() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
}

# ---------------------------------------------------------------- failure evidence (foreman-azc2o)
#
# The first thread of claude_projects_flow.sh ended `failed` once in three runs and its cause was gone with the stack: cleanup()
# removes the work directory and drops the database. evidence_keep runs from cleanup() WHILE THE SERVER IS STILL UP, when the
# harness exits non-zero or an assertion failed (always, with E2E_EVIDENCE=always), and writes to $EVIDENCE_RUN_DIR (outside
# $WORK; <repo>/tmp is git-ignored):
#
#   summary.txt      exit status, the failed assertions, every run that did not complete with its failure_reason, the
#                    failure events of the event store, the server log's errors and warnings, and what could not be kept
#   server.log, notifications.jsonl, transcript.txt (E2E_TRANSCRIPT), work-files/ (the CLI outputs the steps left)
#   api/             what the API answered: project, threads, Overview, runs, queue and, per thread, its projection,
#                    transcript and task (api/index.txt: every request with its HTTP status)
#   events.jsonl     every event of the event store, decoded (event_store_dump.exs): run, worktree, phase and worker
#                    stdout/stderr streams; `jq -c 'select(.stream | contains("<run id>"))' events.jsonl` is one run's
#   run-artifacts/   the run's prompt and phase output files; agent-sessions/ the pi agent's own session files
#   worktrees.txt    git state of the scratch repository and the run worktrees that were kept (worktrees/ their files)
#   repo-beads/      the scratch br database; repo.bundle every ref of the scratch repository (a completed thread's
#                    committed branch lives there, its worktree may be gone: `git clone repo.bundle`); processes.txt the
#                    server's process tree
#   environment.txt  the host at that moment (load, disk, memory), the other harness stacks alive, the connections to the
#                    database and what `pi --list-models <model>`, the kickoff preflight's own question, answers then
#   database.dump    pg_dump -Fc of the database (pg_restore it into any Postgres)
#
# Every part is best effort and none is silent: what could not be kept is printed and written into summary.txt.

# ev_line <text>: one line into summary.txt and onto the harness output
ev_line() {
  printf '%s\n' "$1" >> "$EVIDENCE_RUN_DIR/summary.txt"
  note "$1"
}

# ev_get <path> <file>: GET one API path into <file> whatever its status; every request and its status go to api/index.txt.
# Returns 1 when the server did not answer at all (000), so the caller does not ask again per thread.
ev_get() {
  eg_code=$(curl -sS -o "$2" -w '%{http_code}' --max-time 20 -H "authorization: Bearer $E2E_API_TOKEN" "$API$1" 2>"$2.err")
  printf '%s GET %s\n' "$eg_code" "$1" >> "$EVIDENCE_RUN_DIR/api/index.txt"
  [ -s "$2.err" ] || rm -f "$2.err"
  [ "$eg_code" != 000 ]
}

# ev_copy <what> <source> <dest in the evidence dir>: copies a file or directory, says so when it cannot
ev_copy() {
  if [ ! -e "$2" ]; then ev_line "$1: not kept, $2 does not exist"; return 1; fi
  if cp -R "$2" "$EVIDENCE_RUN_DIR/$3" 2>"$EVIDENCE_RUN_DIR/$3.err"; then rm -f "$EVIDENCE_RUN_DIR/$3.err"; else ev_line "$1: copy of $2 failed: $(head -c 200 "$EVIDENCE_RUN_DIR/$3.err")"; return 1; fi
}

# evidence_keep <harness exit status>
evidence_keep() {
  [ "$E2E_EVIDENCE" = 0 ] && return 0
  ek_rc=$1; ek=$EVIDENCE_RUN_DIR
  mkdir -p "$ek/api" || { out "evidence: cannot create $ek, the evidence of this run is lost"; return 1; }
  say "evidence: exit status $ek_rc, $FAILED failed assertion(s), kept in $ek"
  ek_alive=no
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then ek_alive=yes; fi
  ek_bound=""
  if command -v timeout >/dev/null 2>&1; then ek_bound="timeout 120"; fi
  {
    echo "harness $E2E_NAME, exit status $ek_rc: passed=$PASSED failed=$FAILED unverified=$UNVERIFIED wall=$(elapsed "$STARTED_AT")s"
    echo "kept $(date -u +%Y-%m-%dT%H:%M:%SZ) (server.log times are local, UTC$(date +%z)); host load $(uptime | sed 's/.*load averages*: //')"
    echo "repository $ROOT at $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'); model $E2E_MODEL; pi $(pi --version 2>&1 | head -n 1); br $(br --version 2>&1 | head -n 1)"
    echo "project $PROJECT; database $E2E_DB_NAME on $E2E_PG_HOST:$E2E_PG_PORT; server $API node $NODE pid ${SERVER_PID:-none}, running at the time: $ek_alive"
    echo "FAILED assertions:${FAILURES:- none}"
    if [ -n "$UNVERIFIED_LIST" ]; then echo "UNVERIFIED:$UNVERIFIED_LIST"; fi
  } > "$ek/summary.txt"

  # the server's own words: log, notifications, the CLI outputs the steps left in the work dir
  ev_copy "server.log" "$SERVER_LOG" server.log
  if [ -f "$HOOK_CAPTURE" ]; then ev_copy "notifications.jsonl" "$HOOK_CAPTURE" notifications.jsonl; fi
  if [ -n "$E2E_TRANSCRIPT" ] && [ -f "$E2E_TRANSCRIPT" ]; then ev_copy "transcript.txt" "$E2E_TRANSCRIPT" transcript.txt; fi
  mkdir -p "$ek/work-files"
  for ek_f in "$WORK"/*.out "$WORK"/*.log "$WORK"/*.txt "$WORK"/*.jsonl "$WORK"/*.md; do
    [ -f "$ek_f" ] || continue
    case "$ek_f" in "$SERVER_LOG"|"$HOOK_CAPTURE") continue ;; esac
    cp "$ek_f" "$ek/work-files/" 2>/dev/null || ev_line "work-files: could not copy $ek_f"
  done

  # the API's view while the server is up
  if [ "$ek_alive" = yes ] && ev_get "/api/projects/$PROJECT/threads" "$ek/api/threads.json"; then
    ev_get "/api/projects/$PROJECT" "$ek/api/project.json"
    ev_get "/api/projects/$PROJECT/overview?include_resolved=true" "$ek/api/overview.json"
    ev_get "/api/runs?project_id=$PROJECT&limit=500" "$ek/api/runs.json"
    ev_get "/api/queue" "$ek/api/queue.json"
    for ek_t in $(jq -r '.threads[]?.id // empty' "$ek/api/threads.json" 2>/dev/null | head -n 40); do
      ek_n=$(printf '%s' "$ek_t" | tr -c 'A-Za-z0-9._-' '_')
      ev_get "/api/threads/$ek_t" "$ek/api/thread-$ek_n.json"
      ev_get "/api/threads/$ek_t/transcript" "$ek/api/transcript-$ek_n.json"
      ek_task=$(jq -r '.thread.task_id // empty' "$ek/api/thread-$ek_n.json" 2>/dev/null)
      if [ -n "$ek_task" ]; then ev_get "/api/tasks/$ek_task" "$ek/api/task-$(printf '%s' "$ek_task" | tr -c 'A-Za-z0-9._-' '_').json"; fi
    done
    ev_line "api: $(grep -c . "$ek/api/index.txt") requests kept in api/ (api/index.txt lists them with their HTTP status)"
    jq -r '.runs[]? | select(.status != "completed") | "run NOT completed: \(.run_id) status=\(.status) task=\(.task_id // "-") failure_reason=\((.failure_reason // "none") | tostring | .[0:800])"' \
      "$ek/api/runs.json" 2>/dev/null | while IFS= read -r ek_l; do ev_line "$ek_l"; done
  else
    ev_line "api: not kept: the server is not running or did not answer (see server.log; database.dump, when it was kept, has the events)"
  fi

  # every event of the event store (the failure reasons, the worktree and the workers' stdout/stderr)
  if [ "$ek_alive" = yes ]; then
    ek_code=$(cat "$ASSETS/event_store_dump.exs")
    $ek_bound elixir --name "e2eevd$$@127.0.0.1" --cookie "$COOKIE" --hidden --rpc-eval "$NODE" "$ek_code" > "$ek/events.rpc.out" 2>&1
    ek_n=$(grep -c '^EVIDENCE ' "$ek/events.rpc.out")
    if [ "${ek_n:-0}" -gt 0 ]; then
      grep '^EVIDENCE ' "$ek/events.rpc.out" | cut -c10- > "$ek/events.jsonl" && rm -f "$ek/events.rpc.out"
      ev_line "events.jsonl: $ek_n events"
      jq -c 'select(.type | test("(Failed|Crashed|Blocked|FlaggedStuck|Unresponsive|Cancelled)$")) | {at, stream, type, data}' "$ek/events.jsonl" 2>/dev/null \
        | head -n 12 | cut -c1-1200 | while IFS= read -r ek_l; do ev_line "failure event: $ek_l"; done
    else
      ev_line "events.jsonl: not kept, the event store dump printed no event (see events.rpc.out)"
    fi
  else
    ev_line "events.jsonl: not kept, the server is not running (database.dump, when it was kept, has them)"
  fi

  # what the agent did, on disk: its prompt and output, its own session files, the worktree it worked in
  if [ -d "$WORK/home/.foreman/runs" ]; then ev_copy "run-artifacts" "$WORK/home/.foreman/runs" run-artifacts; fi
  if [ -d "$WORK/pi-agent/sessions" ]; then ev_copy "agent-sessions" "$WORK/pi-agent/sessions" agent-sessions; fi
  if [ -d "$WORK/home/.foreman/worktrees" ]; then ev_copy "worktrees" "$WORK/home/.foreman/worktrees" worktrees; fi
  if [ -d "$REPO/.beads" ]; then ev_copy "repo-beads" "$REPO/.beads" repo-beads; fi
  if [ -d "$REPO/.git" ]; then
    {
      echo "== git worktree list"; git -C "$REPO" worktree list 2>&1
      echo; echo "== branches"; git -C "$REPO" for-each-ref --format='%(refname:short) %(objectname:short) %(subject)' refs/heads 2>&1
      git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10) }' | while IFS= read -r ek_w; do
        [ "$ek_w" = "$REPO" ] && continue
        echo; echo "== $ek_w"
        git -C "$ek_w" status --short --branch 2>&1 | head -n 20
        git -C "$ek_w" log --format='%h %s' -n 5 2>&1
        git -C "$ek_w" diff --stat HEAD 2>&1 | tail -n 10
      done
    } > "$ek/worktrees.txt" 2>&1
  fi
  # the scratch repository itself: a completed thread's committed branch contents live here, and its worktree may be gone
  # already (worktrees.txt lists the live ones only). One bundle of every ref, bounded (E2E_EVIDENCE_REPO_MAX_KB of .git,
  # default 200 MB): a repository over the bound or a bundle git refuses is said so in summary.txt, never silently skipped
  if [ -d "$REPO/.git" ]; then
    ek_kb=$(du -sk "$REPO/.git" 2>/dev/null | cut -f1)
    if [ "${ek_kb:-0}" -gt "${E2E_EVIDENCE_REPO_MAX_KB:-204800}" ]; then
      ev_line "repo.bundle: not kept, $REPO/.git is ${ek_kb} KB (limit ${E2E_EVIDENCE_REPO_MAX_KB:-204800} KB, E2E_EVIDENCE_REPO_MAX_KB)"
    elif git -C "$REPO" bundle create "$ek/repo.bundle" --all >"$ek/repo.bundle.out" 2>&1; then
      rm -f "$ek/repo.bundle.out"
      ev_line "repo.bundle: every ref of the scratch repository, $(wc -c < "$ek/repo.bundle" | tr -d ' ') bytes (git clone repo.bundle <dir>)"
    else
      ev_line "repo.bundle: git bundle failed: $(head -c 200 "$ek/repo.bundle.out" | tr '\n' ' ')"
    fi
  fi
  if [ "$ek_alive" = yes ]; then
    {
      echo "pid ppid elapsed stat command (the server and its descendants)"
      for ek_p in $SERVER_PID $(descendants "$SERVER_PID"); do ps -o pid=,ppid=,etime=,stat=,command= -p "$ek_p" 2>/dev/null | cut -c1-240; done
    } > "$ek/processes.txt"
  fi

  # last resort and complete record: the database itself
  if [ "$DB_CREATED" = 1 ]; then
    if $ek_bound pg_dump -Fc -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" -d "$E2E_DB_NAME" -f "$ek/database.dump" 2>"$ek/database.dump.err"; then
      rm -f "$ek/database.dump.err"
      ev_line "database.dump: pg_dump -Fc of $E2E_DB_NAME, $(wc -c < "$ek/database.dump" | tr -d ' ') bytes"
    else
      ev_line "database.dump: pg_dump failed: $(head -c 200 "$ek/database.dump.err")"
    fi
  fi

  # the host at that moment: load, disk, memory, the other harness stacks alive (a BEAM node named e2e* that is not this one,
  # which would share the machine and possibly the database name), the connections to this database, and what the kickoff
  # preflight's own question (`pi --list-models <model>`) answers now, asked the way the server asks it
  {
    echo "== uptime"; uptime
    echo "== disk of the work dir"; df -h "$WORK" 2>&1 | tail -n 2
    echo "== memory"; if command -v vm_stat >/dev/null 2>&1; then vm_stat | head -n 6; else free -m 2>&1 | head -n 3; fi
    echo "== other harness stacks alive (BEAM nodes named e2e*, not $NODE)"
    ps -A -o pid=,etime=,command= | grep 'beam\.smp' | grep -- ' -name e2e' | grep -v -- " -name $NODE " | sed -E 's/^( *[0-9]+ +[0-9:-]+ ).* (-name [^ ]+) .*/\1\2/'
    echo "== connections to $E2E_DB_NAME by state"
    psql_admin -Atc "select coalesce(state, '-'), count(*) from pg_stat_activity where datname = '$E2E_DB_NAME' group by 1" 2>&1
    if [ -d "$WORK/pi-agent" ]; then
      echo "== pi --list-models $E2E_MODEL (HOME=$WORK/home PI_CODING_AGENT_DIR=$WORK/pi-agent, as the server runs it)"
      ek_t=$(date +%s)
      env HOME="$WORK/home" PI_CODING_AGENT_DIR="$WORK/pi-agent" PATH="${E2E_PATH_PREFIX:+$E2E_PATH_PREFIX:}$PATH" $ek_bound pi --list-models "$E2E_MODEL" 2>&1 | head -n 20 | cut -c1-200
      echo "exit status ${PIPESTATUS[0]} after $(elapsed "$ek_t")s"
    fi
  } > "$ek/environment.txt" 2>&1

  # the server log's own errors and warnings last, so the runs that did not complete and their failure events come first.
  # The scratch origin is a local bare repository, so AutoPR's `gh pr create` fails on EVERY run that finishes: those
  # lines are counted, not listed (grep server.log for them); every other error and warning is listed
  if [ -f "$SERVER_LOG" ]; then
    ek_noise='none of the git remotes configured for this repository point to a known GitHub host'
    ek_all=$(grep -E '\[(error|warning|critical|alert|emergency)\]' "$SERVER_LOG")
    ek_n=$(printf '%s\n' "$ek_all" | grep -cE "$ek_noise")
    printf '%s\n' "$ek_all" | grep -vE "$ek_noise" | grep . | tail -n 25 | cut -c1-320 | while IFS= read -r ek_l; do ev_line "server.log: $ek_l"; done
    if [ "$ek_n" -gt 0 ]; then ev_line "server.log: $ek_n more error line(s) are AutoPR's 'gh pr create' failing for want of a GitHub remote (the scratch origin is a local bare repository): expected, not listed"; fi
  fi
  out "   evidence kept: $ek (start with summary.txt)"
}

pick_port() { # <first port> -> prints a free port at or above it
  pp=$1
  while :; do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$pp/" 2>/dev/null
    [ $? -eq 7 ] && break
    pp=$((pp + 1))
    [ "$pp" -lt 64000 ] || die "no free port found from $1" 2
  done
  echo "$pp"
}

fm() { FOREMAN_API_URL="$API" FOREMAN_API_TOKEN="$E2E_API_TOKEN" HOME="$REAL_HOME" "$FOREMAN" "$@"; }
api_get() { curl -sS -f --max-time 60 -H "authorization: Bearer $E2E_API_TOKEN" "$API$1" 2>/dev/null; }
# api_status <path>: HTTP status of a GET
api_status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -H "authorization: Bearer $E2E_API_TOKEN" "$API$1" 2>/dev/null; }
rpc() { elixir --name "e2ectl$$@127.0.0.1" --cookie "$COOKIE" --hidden --rpc-eval "$NODE" "$1" 2>&1; }

make_repo() { # <dir> <bare origin>
  git init -q --bare -b main "$2" || return 1
  git init -q -b main "$1" || return 1
  git -C "$1" config user.name "e2e"
  git -C "$1" config user.email "e2e@example.com"
  git -C "$1" config commit.gpgsign false
  printf '# scratch project\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "initial commit" || return 1
  git -C "$1" remote add origin "$2"
  git -C "$1" push -q -u origin main
}

install_workflows() {
  mkdir -p "$WORK/workflows/prompts"
  sed "s|__E2E_MODEL__|$E2E_MODEL|" "$ASSETS/workflows/edit.yaml" > "$WORK/workflows/edit.yaml"
  cp "$ASSETS/workflows/broken-model.yaml" "$WORK/workflows/broken-model.yaml"
  cp "$ASSETS/workflows/prompts/edit.md" "$WORK/workflows/prompts/edit.md"
}

# ---------------------------------------------------------------- real claude (opt-in per scenario)
#
# The server runs with HOME=$WORK/home, so a real `claude` it spawns only finds the operator's login
# through the symlinks below (the same three scripts/e2e/live_claude/stack.sh makes). The harness never
# touches the real HOME otherwise. claude scenarios call claude_ready first: a host without a logged-in
# claude records UNVERIFIED instead of failing.

# claude_env <command...>: runs the command the way the server's claude processes run: through the
# redirected HOME and without the Claude Code session variables that make a nested claude refuse or
# switch to API-key billing.
claude_env() {
  env -u CLAUDECODE -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u MY_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY \
    HOME="$WORK/home" "$@"
}

link_claude_auth() {
  mkdir -p "$WORK/home/Library"
  for rel in .claude .claude.json Library/Keychains; do
    if [ -e "$REAL_HOME/$rel" ] && [ ! -e "$WORK/home/$rel" ]; then ln -s "$REAL_HOME/$rel" "$WORK/home/$rel"; fi
  done
}

# claude_ready: 0 when a real `claude` answers through the redirected HOME (installed AND logged in),
# else 1 with the reason in CLAUDE_UNAVAILABLE.
claude_ready() {
  CLAUDE_UNAVAILABLE=""
  if ! command -v claude >/dev/null 2>&1; then CLAUDE_UNAVAILABLE="no claude binary on PATH"; return 1; fi
  link_claude_auth
  cr_out=$(claude_env claude -p "Reply with the single word ok" --model haiku </dev/null 2>&1 | head -c 300)
  case "$cr_out" in
    *[Oo]k*) return 0 ;;
    *) CLAUDE_UNAVAILABLE="claude did not answer through the redirected HOME: $(printf '%s' "$cr_out" | tr '\n' ' ' | cut -c1-160)"; return 1 ;;
  esac
}

# install_claude_workflow: adds the real-claude workflow `claudeedit` to the scratch workflow root. It is not
# part of install_workflows: it takes a server (re)start to be seen, and a catalog that always offered it to
# the pi coordinator could pick it for a task. Its task type (claude-e2e) matches nothing else.
install_claude_workflow() {
  cp "$ASSETS/workflows/claudeedit.yaml" "$WORK/workflows/claudeedit.yaml"
}

# start_server: (re)starts the Foreman server on $E2E_PORT against the existing database.
start_server() {
  : > "$SERVER_LOG"
  (
    cd "$SERVER_DIR" || exit 2
    exec env -u CLAUDECODE -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u MY_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY \
      MIX_ENV=dev DATABASE_URL="$DATABASE_URL" SHELL=/bin/sh \
      HOME="$WORK/home" MIX_HOME="${MIX_HOME:-$REAL_HOME/.mix}" HEX_HOME="${HEX_HOME:-$REAL_HOME/.hex}" \
      PATH="${E2E_PATH_PREFIX:+$E2E_PATH_PREFIX:}$PATH" PI_CODING_AGENT_DIR="$WORK/pi-agent" \
      E2E_PORT="$E2E_PORT" E2E_WORKFLOW_ROOT="$WORK/workflows" \
      FOREMAN_VFS_ALLOWED_ROOT="$WORK" FOREMAN_API_TOKEN="$E2E_API_TOKEN" \
      FOREMAN_START_BEADS_WATCHER=true FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true \
      FOREMAN_NOTIFY_WEBHOOK_URL="http://127.0.0.1:$E2E_HOOK_PORT/hook" \
      FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP=true FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS=true \
      ${E2E_REVIEW_ENV:-FOREMAN_REVIEW_PROVIDER=pi} FOREMAN_REVIEW_MODEL="$E2E_MODEL" \
      ${E2E_EXTRA_ENV:-} \
      elixir --name "$NODE" --cookie "$COOKIE" -S mix run --no-start --no-halt "$ASSETS/boot.exs"
  ) >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  sw=$(date +%s)
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $E2E_API_TOKEN" "$API/api/projects" 2>/dev/null)
    if [ "$code" = 200 ] && grep -q 'E2E-SERVER-READY' "$SERVER_LOG"; then break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { tail -n 30 "$SERVER_LOG"; die "server exited during boot" 2; }
    [ "$(elapsed "$sw")" -lt 300 ] || { tail -n 30 "$SERVER_LOG"; die "server not ready after 300s" 2; }
    sleep 1
  done
  note "server pid $SERVER_PID, node $NODE, $API ready after $(elapsed "$sw")s"
}

# setup_stack: scratch repo + bare origin + br database, workflows, CLI, database, notification
# sink, server. Leaves the project unregistered.
setup_stack() {
  say "setup: scratch repo, br database, database, notification sink, server"
  if [ -e "$WORK" ] && [ ! -f "$WORK/.e2e-claude-projects" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
    die "refusing to reuse non-empty $WORK: it lacks the .e2e-claude-projects marker of a previous harness run" 1
  fi
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/pi-agent" || die "cannot create $WORK" 1
  : > "$WORK/.e2e-claude-projects"
  make_repo "$REPO" "$ORIGIN" || die "cannot create the scratch repository" 2
  (cd "$REPO" && br init --prefix e2e >/dev/null 2>&1) || die "br init failed in $REPO" 2
  printf '.beads/\n' >> "$REPO/.git/info/exclude"
  note "scratch repo $REPO (local bare origin $ORIGIN, br database $REPO/.beads)"

  # pi: the operator's auth/models only, no user extensions or MCP servers.
  src=${PI_CODING_AGENT_DIR:-$REAL_HOME/.pi/agent}
  for f in auth.json models.json; do
    if [ -e "$src/$f" ]; then ln -sf "$src/$f" "$WORK/pi-agent/$f"; fi
  done
  install_workflows
  note "workflows: $WORK/workflows (edit: pi $E2E_MODEL)"

  (cd "$CLI_DIR" && go build -o "$FOREMAN" ./cmd/foreman) || die "go build of the foreman CLI failed" 2
  note "CLI built: $FOREMAN"

  psql_admin -c "DROP DATABASE IF EXISTS $E2E_DB_NAME WITH (FORCE)" -c "CREATE DATABASE $E2E_DB_NAME" \
    || die "cannot create database $E2E_DB_NAME on $E2E_PG_HOST:$E2E_PG_PORT" 2
  DB_CREATED=1
  (cd "$SERVER_DIR" && MIX_ENV=dev DATABASE_URL="$DATABASE_URL" SHELL=/bin/sh \
    mix do ecto.migrate --quiet + event_store.init) >"$WORK/db-setup.log" 2>&1 \
    || { tail -n 20 "$WORK/db-setup.log"; die "database setup failed (see $WORK/db-setup.log)" 2; }
  note "database $E2E_DB_NAME ready"

  E2E_PORT=$(pick_port "$E2E_PORT")
  E2E_HOOK_PORT=$(pick_port "$E2E_HOOK_PORT")
  API="http://127.0.0.1:$E2E_PORT"
  python3 "$ASSETS/webhook_listener.py" "$E2E_HOOK_PORT" "$HOOK_CAPTURE" >"$WORK/webhook.log" 2>&1 &
  HOOK_PID=$!
  note "notification sink pid $HOOK_PID on 127.0.0.1:$E2E_HOOK_PORT -> $HOOK_CAPTURE"
  start_server
}

# ---------------------------------------------------------------- domain helpers

register_project() { # registers $PROJECT over the scratch repo with the br provider
  fm project create --id "$PROJECT" --path "$REPO" --task-provider beads \
    --task-provider-database-path "$REPO/.beads/beads.db" >"$WORK/project-create.out" 2>&1
}

# new_bead <title> <description> [issue type, default task] -> BEAD_ID (labelled foreman-exec so BeadsWatcher dispatches it).
# The issue type picks the workflow: `task` is the pi `edit` workflow, `claude-e2e` the real-claude `claudeedit` one.
new_bead() {
  BEAD_ID=$(cd "$REPO" && br create "$1" -t "${3:-task}" -p 2 -l foreman-exec -d "$2" --silent 2>/dev/null)
  (cd "$REPO" && br sync --flush-only >/dev/null 2>&1)
}

# thread_for_bead <bead_id> [timeout s] -> THREAD (the id of the thread whose task is that bead)
thread_for_bead() {
  tb_n=0; THREAD=""
  while [ -z "$THREAD" ] && [ "$tb_n" -lt "${2:-120}" ]; do
    THREAD=$(api_get "/api/projects/$PROJECT/threads" | jq -r --arg b "$1" '[.threads[]? | select((.task_id // "") | endswith($b))][0].id // empty' 2>/dev/null)
    [ -n "$THREAD" ] || sleep 2
    tb_n=$((tb_n + 2))
  done
}

hook_count() { # <event class>
  if [ -f "$HOOK_CAPTURE" ]; then grep -c -- "$1" "$HOOK_CAPTURE" 2>/dev/null || true; else echo 0; fi
}

# overview_counts: one-line Overview group counts (the evidence at each stage of a thread's life)
overview_counts() { api_get "/api/projects/$PROJECT/overview" | jq -c '.counts'; }
