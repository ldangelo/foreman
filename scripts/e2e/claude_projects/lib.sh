#!/usr/bin/env bash
# Shared harness for scripts/e2e/claude_projects_flow.sh and scripts/e2e/failure_injection.sh.
# Sourced, never executed. Provides: assertions (PASS/FAIL/UNVERIFIED with evidence), a private
# throwaway stack (Postgres database, scratch git repo + local bare origin + br database, real
# Foreman server, notification sink) and CLI/API helpers.
#
# Real: Foreman server (MIX_ENV=dev, own port, own database), the Go CLI, git, br and a real
# `pi` agent on minimax/MiniMax-M2.7-highspeed. Not used: GitHub (nothing is pushed anywhere
# but the scratch repo's local bare origin), real notification endpoints (a local HTTP sink).
#
# Cleanup only touches what this harness created: its own PIDs, its own database, its own
# work directory (marker-protected). Nothing is killed by name.

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
