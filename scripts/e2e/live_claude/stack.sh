#!/usr/bin/env bash
# scripts/e2e/live_claude/stack.sh
#
# A PRIVATE, long-lived Foreman stack for live Claude acceptance (threads, coordinator,
# reviewer, session resume, in-flight tool approvals), driven step by step from a shell:
#
#     devbox run -- bash scripts/e2e/live_claude/stack.sh up        # scratch repo + DB + server + project
#     devbox run -- bash scripts/e2e/live_claude/stack.sh restart   # stop (TERM) and start the server on the same DB
#     devbox run -- bash scripts/e2e/live_claude/stack.sh crash     # kill -9 the server, start it again
#     devbox run -- bash scripts/e2e/live_claude/stack.sh stop      # stop the server only
#     devbox run -- bash scripts/e2e/live_claude/stack.sh start     # start it again
#     bash scripts/e2e/live_claude/stack.sh env                     # print the shell exports (source it)
#     devbox run -- bash scripts/e2e/live_claude/stack.sh down      # tear everything down
#
# It reuses scripts/e2e/claude_projects/lib.sh (scratch repo + local bare origin + its own `br`
# database, private Postgres database, Go CLI, notification sink, process helpers) and differs
# from claude_projects_flow.sh in three ways: the agents are REAL claude (workflows in
# ./workflows: claudeedit = auto_approve, claudeprompt = approval_mode prompt), the redirected
# HOME carries the claude auth symlinks (~/.claude, ~/.claude.json, ~/Library/Keychains), and the
# server is spawned detached so it survives between calls (state in $WORK/stack.env).
#
# Environment (all optional): E2E_WORK_DIR (default <worktree>-scratch/work; never /tmp),
# E2E_NAME (default liveclaude: names the private database foreman_e2e_claude_projects_<name>),
# E2E_PORT, E2E_REVIEW_PROVIDER (claude) / E2E_REVIEW_MODEL (haiku), E2E_APPROVAL_TIMEOUT_MS,
# E2E_INFLIGHT_PROGRESS_MS, E2E_SWEEP_INTERVAL_MS (approvals tuning, read by boot.exs),
# E2E_EXTRA_ENV ("K=V K2=V2" added to the server's environment, e.g. FOREMAN_CLAUDE_CLI=...).
#
# Only PIDs and paths this script created are ever touched; nothing is matched by name.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
E2E_NAME=${E2E_NAME:-liveclaude}
E2E_WORK_DIR=${E2E_WORK_DIR:-$(dirname "$ROOT")/$(basename "$ROOT")-scratch/work}
E2E_MODEL=${E2E_MODEL:-haiku}
E2E_PORT=${E2E_PORT:-47811}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-47911}
# shellcheck source=../claude_projects/lib.sh
. "$ROOT/scripts/e2e/claude_projects/lib.sh"

STATE="$WORK/stack.env"
if [ -f "$STATE" ]; then . "$STATE"; fi
LIVE_ASSETS="$HERE"
E2E_REVIEW_PROVIDER=${E2E_REVIEW_PROVIDER:-claude}
E2E_REVIEW_MODEL=${E2E_REVIEW_MODEL:-haiku}

save_state() {
  cat > "$STATE" <<EOF
SUFFIX='$SUFFIX'
PROJECT='$PROJECT'
COOKIE='$COOKIE'
NODE='$NODE'
E2E_PORT='$E2E_PORT'
E2E_HOOK_PORT='$E2E_HOOK_PORT'
API='$API'
SERVER_PID='$SERVER_PID'
SERVER_LOG='$SERVER_LOG'
HOOK_PID='$HOOK_PID'
DB_CREATED='$DB_CREATED'
EOF
}

# The claude auth of this host, made reachable from the redirected HOME.
link_claude_auth() {
  mkdir -p "$WORK/home/Library"
  for rel in .claude .claude.json Library/Keychains; do
    if [ -e "$REAL_HOME/$rel" ] && [ ! -e "$WORK/home/$rel" ]; then ln -s "$REAL_HOME/$rel" "$WORK/home/$rel"; fi
  done
}

# claude_env: the environment a claude process of this stack runs in (no inherited Claude Code session vars).
claude_probe() {
  env -u CLAUDECODE -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u MY_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY \
    HOME="$WORK/home" TMPDIR="$WORK/tmp" claude "$@"
}

spawn_server() {
  mkdir -p "$WORK/logs"
  SERVER_LOG="$WORK/logs/server-$(date -u +%H%M%S).log"
  : > "$SERVER_LOG"
  # shellcheck disable=SC2086  # E2E_EXTRA_ENV is a deliberate word list of K=V pairs
  SERVER_PID=$(python3 "$HERE/spawn.py" "$SERVER_LOG" "$WORK/server.pid" "$SERVER_DIR" \
    env -u CLAUDECODE -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u MY_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY \
    MIX_ENV=dev DATABASE_URL="$DATABASE_URL" SHELL=/bin/sh \
    HOME="$WORK/home" MIX_HOME="${MIX_HOME:-$REAL_HOME/.mix}" HEX_HOME="${HEX_HOME:-$REAL_HOME/.hex}" \
    TMPDIR="$WORK/tmp" PATH="$PATH" PI_CODING_AGENT_DIR="$WORK/pi-agent" \
    E2E_PORT="$E2E_PORT" E2E_WORKFLOW_ROOT="$WORK/workflows" \
    ${E2E_APPROVAL_TIMEOUT_MS:+E2E_APPROVAL_TIMEOUT_MS=$E2E_APPROVAL_TIMEOUT_MS} \
    ${E2E_INFLIGHT_PROGRESS_MS:+E2E_INFLIGHT_PROGRESS_MS=$E2E_INFLIGHT_PROGRESS_MS} \
    ${E2E_SWEEP_INTERVAL_MS:+E2E_SWEEP_INTERVAL_MS=$E2E_SWEEP_INTERVAL_MS} \
    FOREMAN_VFS_ALLOWED_ROOT="$WORK" FOREMAN_API_TOKEN="$E2E_API_TOKEN" \
    FOREMAN_START_BEADS_WATCHER=true FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true FOREMAN_JOBSITES_ALLOW_REMOTE_START=true \
    FOREMAN_NOTIFY_WEBHOOK_URL="http://127.0.0.1:$E2E_HOOK_PORT/hook" \
    FOREMAN_REVIEW_PROVIDER="$E2E_REVIEW_PROVIDER" FOREMAN_REVIEW_MODEL="$E2E_REVIEW_MODEL" \
    ${E2E_EXTRA_ENV:-} \
    elixir --name "$NODE" --cookie "$COOKIE" -S mix run --no-start --no-halt "$LIVE_ASSETS/boot.exs")
  save_state
  sw=$(date +%s)
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $E2E_API_TOKEN" "$API/api/projects" 2>/dev/null)
    if [ "$code" = 200 ] && grep -q 'E2E-SERVER-READY' "$SERVER_LOG"; then break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { tail -n 30 "$SERVER_LOG"; die "server exited during boot" 2; }
    [ "$(elapsed "$sw")" -lt 300 ] || { tail -n 30 "$SERVER_LOG"; die "server not ready after 300s" 2; }
    sleep 1
  done
  note "server pid $SERVER_PID, node $NODE, $API ready after $(elapsed "$sw")s, log $SERVER_LOG"
  grep -m1 'E2E-SERVER-READY' "$SERVER_LOG" | sed 's/^/   /'
}

cmd_up() {
  check_environment
  if [ -e "$WORK" ] && [ ! -f "$WORK/.e2e-claude-projects" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
    die "refusing to reuse non-empty $WORK without the .e2e-claude-projects marker" 1
  fi
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/pi-agent" "$WORK/logs" "$WORK/tmp" || die "cannot create $WORK" 1
  : > "$WORK/.e2e-claude-projects"
  SUFFIX="lc$$"
  PROJECT="lc"
  COOKIE="lc-cookie-$SUFFIX"
  NODE="lc${SUFFIX}@127.0.0.1"
  SERVER_PID=""; SERVER_LOG=""; HOOK_PID=""; DB_CREATED=0
  say "setup: scratch repo, br database, claude auth, workflows, CLI, database, sink"
  make_repo "$REPO" "$ORIGIN" || die "cannot create the scratch repository" 2
  (cd "$REPO" && br init --prefix lc >/dev/null 2>&1) || die "br init failed in $REPO" 2
  printf '.beads/\n.foreman/\n' >> "$REPO/.git/info/exclude"
  note "scratch repo $REPO (bare origin $ORIGIN, br database $REPO/.beads)"
  link_claude_auth
  mkdir -p "$WORK/workflows/prompts"
  cp "$LIVE_ASSETS"/workflows/*.yaml "$WORK/workflows/"
  cp "$LIVE_ASSETS"/workflows/prompts/*.md "$WORK/workflows/prompts/"
  note "workflows: $(ls "$WORK/workflows" | tr '\n' ' ')"
  (cd "$CLI_DIR" && go build -o "$FOREMAN" ./cmd/foreman) || die "go build of the foreman CLI failed" 2
  note "CLI built: $FOREMAN"
  psql_admin -c "DROP DATABASE IF EXISTS $E2E_DB_NAME WITH (FORCE)" -c "CREATE DATABASE $E2E_DB_NAME" \
    || die "cannot create database $E2E_DB_NAME" 2
  DB_CREATED=1
  save_state
  (cd "$SERVER_DIR" && MIX_ENV=dev DATABASE_URL="$DATABASE_URL" SHELL=/bin/sh \
    mix do ecto.migrate --quiet + event_store.init) >"$WORK/db-setup.log" 2>&1 \
    || { tail -n 20 "$WORK/db-setup.log"; die "database setup failed (see $WORK/db-setup.log)" 2; }
  note "database $E2E_DB_NAME ready"
  E2E_PORT=$(pick_port "$E2E_PORT")
  E2E_HOOK_PORT=$(pick_port "$E2E_HOOK_PORT")
  API="http://127.0.0.1:$E2E_PORT"
  HOOK_PID=$(python3 "$HERE/spawn.py" "$WORK/webhook.log" "$WORK/hook.pid" "$WORK" \
    python3 "$ASSETS/webhook_listener.py" "$E2E_HOOK_PORT" "$HOOK_CAPTURE")
  note "notification sink pid $HOOK_PID on 127.0.0.1:$E2E_HOOK_PORT"
  save_state
  say "claude through the redirected HOME"
  claude_probe -p "Reply with the single word ok" --model haiku 2>&1 | head -3 | sed 's/^/   claude: /'
  spawn_server
  register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
  fm project update --coordinator-provider claude --coordinator-model haiku --max-concurrent-runs 3 \
    --notification-preference every_turn "$PROJECT" >"$WORK/project-update.out" 2>&1 \
    || { cat "$WORK/project-update.out"; die "project update failed" 2; }
  note "project $PROJECT registered; coordinator = claude/haiku"
  fm project get --format json "$PROJECT" 2>/dev/null | jq -c '.project | {id: .project_id, path, coordinator_provider: .config.coordinator_provider, coordinator_model: .config.coordinator_model, max_concurrent_runs: .config.max_concurrent_runs}' | sed 's/^/   /'
  save_state
}

# server_tree: the pids of the server and its descendants (agents run under it)
server_tree() { { echo "$SERVER_PID"; descendants "$SERVER_PID"; } | sort -un; }

cmd_stop() {
  [ -n "$SERVER_PID" ] || { note "no server recorded"; return 0; }
  say "stop server $SERVER_PID (TERM, then KILL)"
  stop_server
  save_state
}

cmd_crash() {
  [ -n "$SERVER_PID" ] || { note "no server recorded"; return 0; }
  say "crash server $SERVER_PID (kill -9 the whole tree)"
  tree=$(server_tree)
  for p in $tree; do kill -9 "$p" 2>/dev/null; done
  SERVER_PID=""
  save_state
}

cmd_start() {
  say "start server"
  spawn_server
}

cmd_down() {
  say "down: server, sink, strays, work dir, database"
  stop_server
  stop_pid "$HOOK_PID"
  sweep_strays
  if [ -f "$WORK/.e2e-claude-projects" ]; then
    chmod -R u+rwx "$WORK" 2>/dev/null
    rm -rf "$WORK"
  fi
  psql_admin -c "DROP DATABASE IF EXISTS $E2E_DB_NAME WITH (FORCE)" >/dev/null 2>&1 && note "database $E2E_DB_NAME dropped"
}

cmd_env() {
  cat <<EOF
export LC_WORK='$WORK' LC_REPO='$REPO' LC_API='$API' LC_TOKEN='$E2E_API_TOKEN' LC_PROJECT='$PROJECT'
export LC_NODE='$NODE' LC_COOKIE='$COOKIE' LC_PORT='$E2E_PORT' LC_DB='$E2E_DB_NAME' LC_FOREMAN='$FOREMAN'
export LC_SERVER_PID='$SERVER_PID' LC_SERVER_LOG='$SERVER_LOG' LC_HOME='$WORK/home'
EOF
}

cmd_status() {
  out "work=$WORK db=$E2E_DB_NAME api=$API node=$NODE project=$PROJECT"
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then out "server pid $SERVER_PID alive, tree: $(server_tree | tr '\n' ' ')"; else out "server not running"; fi
  out "log: $SERVER_LOG"
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  stop) cmd_stop ;;
  start) cmd_start ;;
  restart) cmd_stop; cmd_start ;;
  crash) cmd_crash; cmd_start ;;
  env) cmd_env ;;
  status) cmd_status ;;
  *) echo "usage: stack.sh up|down|stop|start|restart|crash|env|status" >&2; exit 1 ;;
esac
