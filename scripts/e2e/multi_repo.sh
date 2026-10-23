#!/bin/sh
# scripts/e2e/multi_repo.sh
#
# Live end-to-end proof of TRUE multi-repository runs (E12-S12): one run, one worktree
# and one branch per repository, one PR per touched repository, a per-PR merge gate,
# partial completion with `run retry-pr`, and an unchanged single-repository path.
#
# Real: git, a real Foreman server (own port, own Postgres database), the Go CLI, and a
# real headless agent (E2E_PROVIDER, default `pi` + MiniMax). Stubbed: only GitHub,
# through scripts/e2e/multi_repo/fake-gh (a recording `gh`), and the remotes, which are
# local bare repositories. POSIX sh (dash-safe); no bashisms.
#
# Run it from a devbox shell (Elixir/OTP, jq, git, Postgres client on PATH), then:
#
#     devbox run -- sh scripts/e2e/multi_repo.sh
#
# Stages (E2E_STAGES, space separated, default "gate green gates failure legacy"):
#   gate     the run-start gate refuses a multi-repo run while closed
#   green    ONE task over repos a+b: two worktrees, edits in both (one through the sibling
#            absolute path), commits, two pushed branches, two PRs, archive, cleanup
#   gates    merge_approve for a alone does not allow merging b (per-repo gate)
#   failure  b's origin made read-only: run completes with errors, `run retry-pr` recovers
#   legacy   a single-repository project on the same server is unaffected
# `setup` and the closing `strays` check always run. `gates` needs `green` in the same run.
#
# Environment (all optional):
#   E2E_PROVIDER      agent backend (default pi). Only `pi` + MiniMax is verified here.
#   E2E_MODEL         qualified model (default minimax/MiniMax-M2.7-highspeed)
#   E2E_PI_ISOLATE    1 (default): pi runs with a private agent dir holding only the
#                     operator's auth.json/models.json (no user extensions or MCP servers)
#   E2E_WORK_DIR      scratch area for repos, origins, logs (default <repo>/tmp/e2e-multi-repo;
#                     must sit under the VFS allowlist root, so NOT /tmp)
#   E2E_DB_NAME       private database (default foreman_e2e_multi_repo), dropped at the end
#   E2E_PG_HOST/E2E_PG_PORT/E2E_PG_USER/E2E_PG_PASSWORD   admin connection
#                     (default localhost/55432/postgres/postgres: the dev Postgres)
#   E2E_PORT          first port to try for the server (default 4800, next free one is used)
#   E2E_API_TOKEN     bearer token of the private server
#   E2E_RUN_TIMEOUT   seconds a run may take to reach a terminal state (default 600)
#   E2E_POLL_SECS     poll interval for the run status (default 3)
#   E2E_TRANSCRIPT    file the transcript is also appended to
#   E2E_KEEP=1        keep the server, database and work dir (for post-mortems)
#   E2E_GITHUB=1      NOT supported: the harness never creates real GitHub repositories
#
# Exit status: 0 every assertion passed; 1 environment problem; 2 setup failed;
# 3 one or more assertions failed (each is named in the closing summary).

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ASSETS="$HERE/multi_repo"
SERVER_DIR="$ROOT/packages/foreman_server"
CLI_DIR="$ROOT/packages/foreman_cli"

E2E_PROVIDER=${E2E_PROVIDER:-pi}
E2E_MODEL=${E2E_MODEL:-minimax/MiniMax-M2.7-highspeed}
E2E_PI_ISOLATE=${E2E_PI_ISOLATE:-1}
E2E_GITHUB=${E2E_GITHUB:-0}
E2E_WORK_DIR=${E2E_WORK_DIR:-$ROOT/tmp/e2e-multi-repo}
E2E_DB_NAME=${E2E_DB_NAME:-foreman_e2e_multi_repo}
E2E_PG_HOST=${E2E_PG_HOST:-localhost}
E2E_PG_PORT=${E2E_PG_PORT:-55432}
E2E_PG_USER=${E2E_PG_USER:-postgres}
E2E_PG_PASSWORD=${E2E_PG_PASSWORD:-postgres}
E2E_PORT=${E2E_PORT:-4800}
E2E_API_TOKEN=${E2E_API_TOKEN:-e2e-multi-repo-token}
E2E_RUN_TIMEOUT=${E2E_RUN_TIMEOUT:-600}
E2E_POLL_SECS=${E2E_POLL_SECS:-3}
E2E_TRANSCRIPT=${E2E_TRANSCRIPT:-}
E2E_KEEP=${E2E_KEEP:-0}
E2E_STAGES=${E2E_STAGES:-"gate green gates failure legacy"}

PASSED=0
FAILED=0
FAILURES=""
STARTED_AT=$(date +%s)
SERVER_PID=""
DB_CREATED=0
SUFFIX="$$"
TAB=$(printf '\t')

# ---------------------------------------------------------------- output helpers

out() {
  printf '%s\n' "$*"
  if [ -n "$E2E_TRANSCRIPT" ]; then printf '%s\n' "$*" >> "$E2E_TRANSCRIPT"; fi
}
say() { out ""; out "== $* =="; }
note() { out "   $*"; }
pass() { out "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() {
  out "  FAIL  $*"
  FAILED=$((FAILED + 1))
  FAILURES="$FAILURES
  - $*"
}
die() { out "fatal: $1"; exit "${2:-2}"; }
elapsed() { echo $(($(date +%s) - $1)); }
yes_no() { if [ -n "$1" ]; then echo yes; else echo no; fi; }
count_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# assert_eq <what> <actual> <expected>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1: expected '$3', got '$2'"; fi
}
# assert_true <what> <command...>   (the command succeeding is the pass condition)
assert_true() {
  at_what=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$at_what"; else fail "$at_what"; fi
}
# assert_has <what> <haystack> <needle>
assert_has() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: '$3' not found in: $(printf '%s' "$2" | cut -c1-300)" ;; esac
}

# ---------------------------------------------------------------- environment

case "$E2E_STAGES" in *[!a-z\ ]*) die "E2E_STAGES may only name stages (gate green gates failure legacy)" 1 ;; esac
for stage in $E2E_STAGES; do
  case "$stage" in gate|green|gates|failure|legacy) ;; *) die "unknown stage '$stage'" 1 ;; esac
done
case "$E2E_DB_NAME" in *[!a-z0-9_]*|"") die "E2E_DB_NAME must match [a-z0-9_]+" 1 ;; esac
for tool in git jq curl psql go elixir mix; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required (run inside 'devbox run --' or a devbox shell)" 1
done
if [ "$E2E_GITHUB" = 1 ]; then
  out "fatal: E2E_GITHUB=1 is not supported. This harness never creates GitHub repositories;"
  out "       it proves the flow against local bare origins and the recording fake gh."
  exit 1
fi
[ -d "$SERVER_DIR" ] && [ -d "$CLI_DIR" ] || die "cannot find packages/ under $ROOT" 1
case "$E2E_WORK_DIR" in
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/*)
    die "E2E_WORK_DIR=$E2E_WORK_DIR is outside the VFS allowlist root; use a directory under the repo checkout" 1 ;;
esac

WORK=$E2E_WORK_DIR
PGPASSWORD=$E2E_PG_PASSWORD
export PGPASSWORD
DATABASE_URL="postgres://$E2E_PG_USER:$E2E_PG_PASSWORD@$E2E_PG_HOST:$E2E_PG_PORT/$E2E_DB_NAME"
COOKIE="e2e-mr-cookie-$SUFFIX"
NODE="e2emr${SUFFIX}@127.0.0.1"
PROJECT="e2e-mr-$SUFFIX"
LEGACY_PROJECT="e2e-legacy-$SUFFIX"
WORKFLOW="multi-repo-edit"
REPO_A="$WORK/repos/repo-a"
REPO_B="$WORK/repos/repo-b"
REPO_C="$WORK/repos/repo-c"
ORIGIN_A="$WORK/origins/repo-a.git"
ORIGIN_B="$WORK/origins/repo-b.git"
ORIGIN_C="$WORK/origins/repo-c.git"
GH_STATE="$WORK/gh"
CALLS="$GH_STATE/calls.log"
FOREMAN="$WORK/bin/foreman"
SERVER_LOG="$WORK/server.log"
WT_ROOT="$HOME/.foreman/worktrees"
API=""

psql_admin() {
  psql -X -q -v ON_ERROR_STOP=1 -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" -d postgres "$@"
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    n=0
    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
    kill -9 "$SERVER_PID" 2>/dev/null
  fi
  SERVER_PID=""
}

cleanup() {
  cl_rc=$?
  trap - EXIT INT TERM HUP
  if [ "$E2E_KEEP" = 1 ]; then
    out ""
    out "E2E_KEEP=1: server pid=$SERVER_PID node=$NODE work dir=$WORK database=$E2E_DB_NAME left in place"
    exit "$cl_rc"
  fi
  stop_server
  if [ -f "$WORK/.e2e-multi-repo" ]; then
    chmod -R u+rwx "$WORK" 2>/dev/null
    rm -rf "$WORK"
  fi
  for p in "$PROJECT" "$LEGACY_PROJECT"; do
    case "$p" in e2e-mr-?*|e2e-legacy-?*) rm -rf "${WT_ROOT:?}/$p" ;; esac
  done
  if [ "$DB_CREATED" = 1 ]; then
    psql_admin -c "DROP DATABASE IF EXISTS $E2E_DB_NAME WITH (FORCE)" >/dev/null 2>&1
  fi
  exit "$cl_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ---------------------------------------------------------------- building blocks

fm() { FOREMAN_API_URL="$API" FOREMAN_API_TOKEN="$E2E_API_TOKEN" "$FOREMAN" "$@"; }

# api_get <path>: the JSON body, or nothing at all when the server answers an HTTP error.
api_get() { curl -sS -f --max-time 60 -H "authorization: Bearer $E2E_API_TOKEN" "$API$1" 2>/dev/null; }

# api_post <json envelope> -> API_CODE, API_BODY
api_post() {
  API_CODE=$(curl -sS -o "$WORK/last.body" -w '%{http_code}' -X POST "$API/api/commands" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -d "$1")
  API_BODY=$(cat "$WORK/last.body")
}

# rpc <elixir expression>: evaluate it inside the harness server's node, print its stdout.
rpc() {
  elixir --name "e2ectl$$@127.0.0.1" --cookie "$COOKIE" --hidden --rpc-eval "$NODE" "$1" 2>&1
}
rpc_json() { rpc "$1" | grep '^[[{]' | tail -n 1; }

repo_of() { case "$1" in a) echo "$REPO_A" ;; b) echo "$REPO_B" ;; c) echo "$REPO_C" ;; esac; }
origin_of() { case "$1" in a) echo "$ORIGIN_A" ;; b) echo "$ORIGIN_B" ;; c) echo "$ORIGIN_C" ;; esac; }
origin_branch_sha() { git --git-dir="$(origin_of "$1")" rev-parse --verify -q "refs/heads/$2" 2>/dev/null; }
registered_worktrees() { git -C "$(repo_of "$1")" worktree list --porcelain | grep -c "^worktree .*$2"; }
gh_calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }

make_repo() { # <dir> <bare origin>
  git init -q --bare -b main "$2" || return 1
  git init -q -b main "$1" || return 1
  git -C "$1" config user.name "e2e"
  git -C "$1" config user.email "e2e@example.com"
  git -C "$1" config commit.gpgsign false
  printf '# %s\n' "$(basename "$1")" > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "initial commit" || return 1
  git -C "$1" remote add origin "$2"
  git -C "$1" push -q -u origin main
}

pick_port() {
  pp=$E2E_PORT
  while :; do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$pp/" 2>/dev/null
    [ $? -eq 7 ] && break
    pp=$((pp + 1))
    [ "$pp" -lt 4999 ] || die "no free port found from $E2E_PORT" 2
  done
  E2E_PORT=$pp
}

write_workflow() {
  mkdir -p "$WORK/workflows/prompts"
  cat > "$WORK/workflows/$WORKFLOW.yaml" <<YAML
name: $WORKFLOW
description: E2E harness workflow (E12-S12). One phase; the agent edits every repository of the run.
task_types: [task]
worktree:
  enabled: true
  branch: foreman/{task_id}/{run_id}
  path: workspace
  cleanup: on_success
phases:
  - name: edit
    prompt: $WORKFLOW.md
    provider: $E2E_PROVIDER
    models:
      default: $E2E_MODEL
    commit: true
YAML
  cp "$ASSETS/prompt.md" "$WORK/workflows/prompts/$WORKFLOW.md"
}

# task_json <task_id> <title> <prompt> <project> [repo_ids as a JSON array]
task_json() {
  jq -nc --arg t "$1" --arg ti "$2" --arg pr "$3" --arg p "$4" --arg wf "$WORKFLOW" --argjson ids "${5:-null}" \
    '{type: "task.create",
      payload: ({task_id: $t, project_id: $p, task_type: "task", workflow_type: $wf, title: $ti,
                 prompt: $pr, provider_tracked: false, auto_approve: true}
                + (if $ids == null then {} else {repo_ids: $ids} end))}'
}

# await_run <project> <task_id> -> RUN (empty after ~60s without a run)
await_run() {
  ar_n=0; RUN=""
  while [ -z "$RUN" ] && [ "$ar_n" -lt 60 ]; do
    RUN=$(api_get "/api/runs?project_id=$1" | jq -r --arg t "$2" '[.runs[]? | select(.task_id == $t)][0].run_id // empty')
    [ -n "$RUN" ] || sleep 1
    ar_n=$((ar_n + 1))
  done
}

# wait_for_run <run_id> -> RUN_STATUS, RUN_JSON (the last `foreman run get`); SAW_WT_A / SAW_WT_B
# record whether the run's worktrees were seen registered in repo a / repo b while it was going.
wait_for_run() {
  wr_run=$1; wr_start=$(date +%s); wr_last=""; SAW_WT_A=0; SAW_WT_B=0; RUN_JSON=""
  while :; do
    if RUN_JSON=$(fm run get "$wr_run" 2>"$WORK/run-get.err"); then
      RUN_STATUS=$(printf '%s' "$RUN_JSON" | jq -r '.run.status // empty')
    else
      RUN_STATUS="get-failed: $(tr '\n' ' ' < "$WORK/run-get.err" | cut -c1-160)"
    fi
    if [ "$RUN_STATUS" != "$wr_last" ]; then
      note "run $wr_run: ${RUN_STATUS:-<none>} (+$(elapsed "$wr_start")s)"
      wr_last=$RUN_STATUS
    fi
    if git -C "$REPO_A" worktree list --porcelain 2>/dev/null | grep -q "$wr_run"; then SAW_WT_A=1; fi
    if git -C "$REPO_B" worktree list --porcelain 2>/dev/null | grep -q "$wr_run"; then SAW_WT_B=1; fi
    case "$RUN_STATUS" in completed|failed|cancelled|blocked|stuck|deleted) return 0 ;; esac
    if [ "$(elapsed "$wr_start")" -ge "$E2E_RUN_TIMEOUT" ]; then RUN_STATUS="timeout"; return 1; fi
    sleep "$E2E_POLL_SECS"
  done
}

diagnose_run() { # <run_id>: what a post-mortem of a failed stage needs
  out "   --- run projection: $(api_get "/api/runs/$1" | jq -c '.run | {status, failure_reason, pr_url, pr_urls, repo_ids}' 2>/dev/null)"
  out "   --- server log (errors and warnings, last 25 lines):"
  grep -E '\[(error|warning)\]' "$SERVER_LOG" 2>/dev/null | tail -n 25 | cut -c1-300 | while IFS= read -r l; do out "   $l"; done
}

# ---------------------------------------------------------------- setup

setup() {
  say "setup: scratch repositories, fake gh, database, server"
  if [ -e "$WORK" ] && [ ! -f "$WORK/.e2e-multi-repo" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
    die "refusing to reuse non-empty $WORK: it lacks the .e2e-multi-repo marker of a previous harness run" 1
  fi
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
  mkdir -p "$WORK/repos" "$WORK/origins" "$WORK/bin" "$GH_STATE" || die "cannot create $WORK" 1
  : > "$WORK/.e2e-multi-repo"
  make_repo "$REPO_A" "$ORIGIN_A" || die "cannot create scratch repository a" 2
  make_repo "$REPO_B" "$ORIGIN_B" || die "cannot create scratch repository b" 2
  make_repo "$REPO_C" "$ORIGIN_C" || die "cannot create scratch repository c" 2
  note "repos: $REPO_A  $REPO_B  $REPO_C (each with a local bare origin under $WORK/origins)"

  cp "$ASSETS/fake-gh" "$WORK/bin/gh"
  chmod +x "$WORK/bin/gh"
  write_workflow
  note "workflow: $WORK/workflows/$WORKFLOW.yaml (provider=$E2E_PROVIDER model=$E2E_MODEL cleanup=on_success)"

  PI_AGENT_DIR=""
  if [ "$E2E_PROVIDER" = pi ] && [ "$E2E_PI_ISOLATE" = 1 ]; then
    src=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
    mkdir -p "$WORK/pi-agent"
    for f in auth.json models.json; do
      if [ -e "$src/$f" ]; then ln -sf "$src/$f" "$WORK/pi-agent/$f"; fi
    done
    PI_AGENT_DIR="$WORK/pi-agent"
    note "pi runs with a private agent dir ($PI_AGENT_DIR: the operator's auth.json/models.json only)"
  fi

  (cd "$CLI_DIR" && go build -o "$FOREMAN" ./cmd/foreman) || die "go build of the foreman CLI failed" 2
  note "CLI built: $FOREMAN"

  psql_admin -c "DROP DATABASE IF EXISTS $E2E_DB_NAME WITH (FORCE)" -c "CREATE DATABASE $E2E_DB_NAME" \
    || die "cannot create database $E2E_DB_NAME on $E2E_PG_HOST:$E2E_PG_PORT" 2
  DB_CREATED=1
  (cd "$SERVER_DIR" && MIX_ENV=dev DATABASE_URL="$DATABASE_URL" \
    mix do ecto.migrate --quiet + event_store.init) >"$WORK/db-setup.log" 2>&1 \
    || { tail -n 20 "$WORK/db-setup.log"; die "database setup failed (see $WORK/db-setup.log)" 2; }
  note "database $E2E_DB_NAME ready"

  pick_port
  API="http://127.0.0.1:$E2E_PORT"
  (
    cd "$SERVER_DIR" || exit 2
    exec env MIX_ENV=dev DATABASE_URL="$DATABASE_URL" SHELL=/bin/sh \
      PATH="$WORK/bin:$PATH" E2E_GH_STATE="$GH_STATE" E2E_PORT="$E2E_PORT" \
      E2E_WORKFLOW_ROOT="$WORK/workflows" FOREMAN_API_TOKEN="$E2E_API_TOKEN" \
      FOREMAN_START_BEADS_WATCHER=false ${PI_AGENT_DIR:+PI_CODING_AGENT_DIR="$PI_AGENT_DIR"} \
      elixir --name "$NODE" --cookie "$COOKIE" -S mix run --no-start --no-halt "$ASSETS/boot.exs"
  ) >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  note "server pid $SERVER_PID, node $NODE, $API (log: $SERVER_LOG)"

  sw=$(date +%s)
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $E2E_API_TOKEN" "$API/api/projects" 2>/dev/null)
    if [ "$code" = 200 ] && grep -q 'E2E-SERVER-READY' "$SERVER_LOG"; then break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { tail -n 30 "$SERVER_LOG"; die "server exited during boot" 2; }
    [ "$(elapsed "$sw")" -lt 240 ] || { tail -n 30 "$SERVER_LOG"; die "server not ready after 240s" 2; }
    sleep 1
  done
  note "server ready after $(elapsed "$sw")s: $(grep -m1 'E2E-SERVER-READY' "$SERVER_LOG" | cut -c1-200)"

  api_post "$(jq -nc --arg p "$PROJECT" --arg path "$REPO_A" \
    '{type: "project.register", payload: {project_id: $p, name: $p, path: $path, status: "active"}}')"
  [ "$API_CODE" = 201 ] || die "project.register $PROJECT: HTTP $API_CODE $API_BODY" 2
  note "project $PROJECT registered over $REPO_A (its primary repository has the id 'main')"
  fm project repo add --id b --path "$REPO_B" "$PROJECT" >/dev/null || die "foreman project repo add b failed" 2
  assert_eq "project repositories (primary first, then b)" \
    "$(api_get "/api/projects/$PROJECT/repositories" | jq -c '[.repositories[]? | {id, primary}]')" \
    '[{"id":"main","primary":true},{"id":"b","primary":false}]'
}

# ---------------------------------------------------------------- stage: gate

stage_gate() {
  say "gate: a multi-repo run is refused while the run-start gate is closed"
  note "gate closed on the live node: $(rpc_json 'E2EMultiRepoProbe.gate(false)')"
  gate_task="gate-task-$SUFFIX"
  api_post "$(task_json "$gate_task" "E2E gate probe" "Create VERSION files." "$PROJECT" '["b"]')"
  assert_eq "task.create with repo_ids is accepted at the boundary (the gate is a run-start gate)" "$API_CODE" "201"
  await_run "$PROJECT" "$gate_task"
  if [ -z "$RUN" ]; then
    fail "gate: no run was created for $gate_task"
  else
    gate_run=$RUN
    wait_for_run "$gate_run"
    assert_eq "gate closed: run status" "$RUN_STATUS" "failed"
    reason=$(api_get "/api/runs/$gate_run" | jq -r '.run.failure_reason // "" | tostring')
    assert_has "gate closed: the failure reason names the gate" "$reason" "multi_repo_runs_disabled"
    assert_eq "gate closed: no worktree was provisioned in a" "$(registered_worktrees a "$gate_run")" "0"
  fi
  note "gate reopened on the live node: $(rpc_json 'E2EMultiRepoProbe.gate(true)')"
}

# ---------------------------------------------------------------- stage: green

GREEN_VERSION="1.4.2"

stage_green() {
  say "green: ONE task over repositories a (primary) and b (repo_ids: [b])"
  GREEN_TASK="green-task-$SUFFIX"
  prompt="Create a file named VERSION in EVERY repository of this run. Each VERSION file must contain exactly the text $GREEN_VERSION followed by a single newline."
  t0=$(date +%s)
  api_post "$(task_json "$GREEN_TASK" "E2E: add VERSION $GREEN_VERSION to every repository" "$prompt" "$PROJECT" '["b"]')"
  assert_eq "task.create repo_ids [b] accepted" "$API_CODE" "201"
  await_run "$PROJECT" "$GREEN_TASK"
  GREEN_RUN=$RUN
  [ -n "$GREEN_RUN" ] || { fail "green: no run was created for task $GREEN_TASK"; return 0; }
  note "run id: $GREEN_RUN"
  wait_for_run "$GREEN_RUN"
  note "terminal status '$RUN_STATUS' after $(elapsed "$t0")s"
  GREEN_BRANCH="foreman/$GREEN_TASK/$GREEN_RUN"
  if [ "$RUN_STATUS" != completed ]; then
    fail "green: run reached '$RUN_STATUS', expected 'completed'"
    diagnose_run "$GREEN_RUN"
    return 0
  fi
  pass "green: run completed"
  out "   foreman run get: $(printf '%s' "$RUN_JSON" | jq -c '.run | {run_id, status, task_id, pr_url, pr_urls, usage}')"

  probe=$(rpc_json "E2EMultiRepoProbe.run(\"$GREEN_RUN\")")
  out "   probe: $(printf '%s' "$probe" | jq -c '{status, completed_with_errors, worktrees: [.worktrees[] | {operation_id, repo_id, status}], pr_associations: [.pr_associations[] | {repo_id, pr_url}]}')"

  # --- worktrees: two existed, in the layout S3 section 5 promises, and were handled per policy
  assert_eq "worktree projections for the run" "$(printf '%s' "$probe" | jq '.worktrees | length')" "2"
  assert_eq "primary worktree operation id is the legacy wt-<run>" \
    "$(printf '%s' "$probe" | jq -r '[.worktrees[] | select(.repo_id == null)][0].operation_id')" "wt-$GREEN_RUN"
  assert_eq "secondary worktree operation id is wt-<run>-b" \
    "$(printf '%s' "$probe" | jq -r '[.worktrees[] | select(.repo_id == "b")][0].operation_id')" "wt-$GREEN_RUN-b"
  pri=$(printf '%s' "$probe" | jq -r '[.worktrees[] | select(.repo_id == null)][0].worktree_path')
  sec=$(printf '%s' "$probe" | jq -r '[.worktrees[] | select(.repo_id == "b")][0].worktree_path')
  case "$pri" in */"$GREEN_RUN"/workspace) pass "primary worktree path ends in <run>/workspace" ;; *) fail "primary worktree path: $pri" ;; esac
  case "$sec" in */"$GREEN_RUN"/repos/b) pass "secondary worktree path ends in <run>/repos/b" ;; *) fail "secondary worktree path: $sec" ;; esac
  assert_eq "the worktree of a was registered in repo a while the run was live" "$SAW_WT_A" "1"
  assert_eq "the worktree of b was registered in repo b while the run was live" "$SAW_WT_B" "1"
  assert_eq "cleanup: on_success reclaimed both worktrees (projection status)" \
    "$(printf '%s' "$probe" | jq -r '[.worktrees[].status] | unique | join(",")')" "cleaned"
  assert_true "cleanup: primary worktree directory is gone" test ! -e "$pri"
  assert_true "cleanup: secondary worktree directory is gone" test ! -e "$sec"
  assert_eq "cleanup: repo a keeps no registered run worktree" "$(registered_worktrees a "$GREEN_RUN")" "0"
  assert_eq "cleanup: repo b keeps no registered run worktree" "$(registered_worktrees b "$GREEN_RUN")" "0"

  # --- commits on both run branches, including the edit made through the sibling path
  for id in a b; do
    sha=$(origin_branch_sha "$id" "$GREEN_BRANCH")
    if [ -n "$sha" ]; then pass "branch $GREEN_BRANCH pushed to the origin of repo $id ($sha)"; else fail "branch $GREEN_BRANCH missing on the origin of repo $id"; fi
    ahead=$(git --git-dir="$(origin_of "$id")" rev-list --count "main..$GREEN_BRANCH" 2>/dev/null || echo 0)
    assert_eq "repo $id: pushed branch carries commits ahead of main" "$([ "$ahead" -ge 1 ] && echo yes || echo no)" "yes"
    assert_eq "repo $id: VERSION committed on the run branch" \
      "$(git --git-dir="$(origin_of "$id")" show "$GREEN_BRANCH:VERSION" 2>/dev/null | tr -d ' \n\r')" "$GREEN_VERSION"
    note "repo $id head commit: $(git --git-dir="$(origin_of "$id")" log -1 --format='%h %s' "$GREEN_BRANCH" 2>/dev/null)"
  done

  # --- the edit of b was made by the agent through b's ABSOLUTE sibling path (pi has no add_dirs):
  # with an isolated pi agent dir its session file records every tool call it made.
  session=$(find "$WORK/pi-agent/sessions" -path "*$GREEN_RUN*" -name '*.jsonl' 2>/dev/null | head -n 1)
  if [ -n "$session" ]; then
    sibling_calls=$(jq -r 'select(.type == "message" and .message.role == "assistant") | .message.content[]? | select(.type == "toolCall") | (.arguments.command // .arguments.path // "") | split("\n")[] | select(contains("/repos/b/"))' "$session" 2>/dev/null)
    assert_eq "the agent wrote b's VERSION through the sibling path ($GREEN_RUN/repos/b/)" "$(yes_no "$sibling_calls")" "yes"
    note "agent tool call touching b: $(printf '%s' "$sibling_calls" | head -n 1 | cut -c1-260)"
  else
    note "agent session not captured (E2E_PI_ISOLATE=0 or provider != pi): sibling-path tool call not asserted"
  fi

  # --- PRs: two fake-gh creations, one association per repository
  assert_eq "fake gh: 'pr create' calls for this branch" "$(gh_calls "pr create .*--head $GREEN_BRANCH")" "2"
  assert_eq "fake gh: the PR of a was created from repo a's checkout" "$(gh_calls "repo-a${TAB}pr create .*--head $GREEN_BRANCH")" "1"
  assert_eq "fake gh: the PR of b was created from repo b's checkout" "$(gh_calls "repo-b${TAB}pr create .*--head $GREEN_BRANCH")" "1"
  assert_eq "pr_associations_for_run" "$(printf '%s' "$probe" | jq '.pr_associations | length')" "2"
  GREEN_URL_A=$(printf '%s' "$probe" | jq -r '[.pr_associations[] | select(.repo_id == null or .repo_id == "main")][0].pr_url')
  GREEN_URL_B=$(printf '%s' "$probe" | jq -r '[.pr_associations[] | select(.repo_id == "b")][0].pr_url')
  assert_has "the PR of a points at repo-a" "$GREEN_URL_A" "/e2e-owner/repo-a/pull/"
  assert_has "the PR of b points at repo-b" "$GREEN_URL_B" "/e2e-owner/repo-b/pull/"
  runjson=$(api_get "/api/runs/$GREEN_RUN")
  assert_eq "run.pr_url is the PRIMARY's PR (b never overwrites it)" "$(printf '%s' "$runjson" | jq -r '.run.pr_url')" "$GREEN_URL_A"
  assert_eq "run.pr_urls.b" "$(printf '%s' "$runjson" | jq -r '.run.pr_urls.b // empty')" "$GREEN_URL_B"
  assert_eq "GET /api/runs/:id/prs lists both PRs" "$(api_get "/api/runs/$GREEN_RUN/prs" | jq '[.prs[]] | length')" "2"
  body_a=$(cat "$GH_STATE/pr/$(printf '%s' "$GREEN_URL_A" | tr -c 'A-Za-z0-9._-' '_')/body" 2>/dev/null)
  body_b=$(cat "$GH_STATE/pr/$(printf '%s' "$GREEN_URL_B" | tr -c 'A-Za-z0-9._-' '_')/body" 2>/dev/null)
  assert_has "cross-link: the body of PR a names the run" "$body_a" "Part of multi-repo run $GREEN_RUN"
  assert_has "cross-link: the body of PR a lists the sibling PR of b" "$body_a" "e2e-owner/repo-b#"
  assert_has "cross-link: the body of PR b lists the sibling PR of a" "$body_b" "e2e-owner/repo-a#"
  assert_eq "merge gates after finalisation (a,b)" \
    "$(printf '%s' "$probe" | jq -r '[.repositories[].gate] | join(",")')" "pending,pending"

  # --- events: `repo_id` is ABSENT for the run's primary and present only for b
  events=$(rpc_json "E2EMultiRepoProbe.events(\"$GREEN_RUN\", \"$GREEN_TASK\")")
  assert_eq "event types that carry repo_id (the primary's events carry none)" \
    "$(printf '%s' "$events" | jq -c '[.[] | select(.keys | any(. == "repo_id")) | .type] | unique')" \
    '["PrAssociated","PrReady","PrUpdated","RunBaseBranchRecorded","WorktreeCleaned","WorktreeCreated"]'
  assert_eq "each of them carries repo_id exactly once (b's), never a's" \
    "$(printf '%s' "$events" | jq -c '[.[] | select(.keys | any(. == "repo_id")) | .type] | group_by(.) | map(length) | unique')" "[1]"
  assert_eq "WorktreeCreated events (one per repository)" \
    "$(printf '%s' "$events" | jq -c '[.[] | select(.type == "WorktreeCreated")] | length')" "2"
  assert_eq "no event stores a nil repo_id/repo_ids (absent really means absent)" \
    "$(printf '%s' "$events" | jq -c '[.[] | select(.nil_keys | any(. == "repo_id" or . == "repo_ids"))] | length')" "0"

  # --- archive: diff.patch (primary), diffs/b.patch, manifest.repositories[]
  arch="$REPO_A/.foreman/sessions/run/$GREEN_RUN"
  out "   archive: $(ls "$arch" 2>/dev/null | tr '\n' ' ') diffs/: $(ls "$arch/diffs" 2>/dev/null | tr '\n' ' ')"
  assert_true "archive has diff.patch (repo a)" test -s "$arch/diff.patch"
  assert_true "archive has diffs/b.patch" test -s "$arch/diffs/b.patch"
  assert_has "diffs/b.patch carries the VERSION change of b" "$(cat "$arch/diffs/b.patch" 2>/dev/null)" "+$GREEN_VERSION"
  manifest=$(cat "$arch/manifest.json" 2>/dev/null)
  assert_eq "manifest.repositories[] ids" "$(printf '%s' "$manifest" | jq -c '[.repositories[]?.id]')" '["main","b"]'
  assert_eq "manifest.repositories[] carry their PR urls" \
    "$(printf '%s' "$manifest" | jq -c '[.repositories[]?.pr_url]')" "[\"$GREEN_URL_A\",\"$GREEN_URL_B\"]"
  assert_eq "git status of repo b is clean (nothing written outside the run worktree)" "$(git -C "$REPO_B" status --short)" ""
  assert_eq "git status of repo a shows only the Foreman archive" "$(git -C "$REPO_A" status --short)" "?? .foreman/"
  assert_eq "fake gh: unsupported invocations so far" "$(count_lines "$GH_STATE/unsupported.log")" "0"
}

# ---------------------------------------------------------------- stage: gates

stage_gates() {
  say "gates: merge_approve for repo a alone must not allow merging repo b"
  if [ -z "${GREEN_RUN:-}" ] || [ -z "${GREEN_URL_B:-}" ]; then fail "gates: needs a completed green stage in the same harness run"; return 0; fi
  gate_of() { rpc_json "E2EMultiRepoProbe.run(\"$GREEN_RUN\")" | jq -r --arg id "$1" '[.repositories[] | select(.repo_id == $id)][0].gate // "none"'; }
  assert_eq "gate of a before any approval" "$(gate_of main)" "pending"
  assert_eq "gate of b before any approval" "$(gate_of b)" "pending"

  fm run approve-merge --id "$GREEN_RUN" --approver e2e --identity github:ldangelo --head-sha "$(origin_branch_sha a "$GREEN_BRANCH")" >"$WORK/approve-a.out" 2>&1
  assert_eq "merge_approve (repo a): exit status" "$?" "0"
  assert_eq "gate of a after approving a" "$(gate_of main)" "approved"
  assert_eq "gate of b after approving a only" "$(gate_of b)" "pending"

  fm run merge --id "$GREEN_RUN" --repo-id b >"$WORK/merge-b-early.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "run merge --repo-id b is REFUSED while only a is approved (exit $rc): $(tr '\n' ' ' < "$WORK/merge-b-early.out" | cut -c1-200)"
  else
    fail "run merge --repo-id b succeeded although only a was approved"
  fi
  assert_eq "fake gh: no 'pr merge' reached any PR yet" "$(gh_calls 'pr merge')" "0"

  fm run merge --id "$GREEN_RUN" >"$WORK/merge-a.out" 2>&1
  assert_eq "run merge (repo a, approved): exit status" "$?" "0"
  sha_a=$(origin_branch_sha a "$GREEN_BRANCH")
  assert_eq "fake gh: a merged once, pinned to its approved head" "$(gh_calls "pr merge $GREEN_URL_A --squash --match-head-commit $sha_a")" "1"
  assert_eq "fake gh: b not merged by a's merge" "$(gh_calls "pr merge $GREEN_URL_B")" "0"

  fm run approve-merge --id "$GREEN_RUN" --approver e2e --identity github:ldangelo --head-sha "$(origin_branch_sha b "$GREEN_BRANCH")" --repo-id b >"$WORK/approve-b.out" 2>&1
  assert_eq "merge_approve (repo b): exit status" "$?" "0"
  fm run merge --id "$GREEN_RUN" --repo-id b >"$WORK/merge-b.out" 2>&1
  assert_eq "run merge --repo-id b (approved): exit status" "$?" "0"
  sha_b=$(origin_branch_sha b "$GREEN_BRANCH")
  assert_eq "fake gh: b merged once, pinned to ITS head" "$(gh_calls "pr merge $GREEN_URL_B --squash --match-head-commit $sha_b")" "1"
}

# ---------------------------------------------------------------- stage: failure

FAIL_VERSION="1.4.3"

stage_failure() {
  say "failure: repo b's origin is read-only when the run finalises"
  fail_task="failure-task-$SUFFIX"
  prompt="Create a file named VERSION in EVERY repository of this run. Each VERSION file must contain exactly the text $FAIL_VERSION followed by a single newline."
  chmod -R a-w "$ORIGIN_B"
  note "chmod -R a-w $ORIGIN_B (a push to it will fail)"
  t0=$(date +%s)
  api_post "$(task_json "$fail_task" "E2E: add VERSION $FAIL_VERSION (b origin read-only)" "$prompt" "$PROJECT" '["b"]')"
  assert_eq "task.create repo_ids [b] accepted" "$API_CODE" "201"
  await_run "$PROJECT" "$fail_task"
  fail_run=$RUN
  [ -n "$fail_run" ] || { chmod -R u+rwx "$ORIGIN_B"; fail "failure: no run was created for task $fail_task"; return 0; }
  note "run id: $fail_run"
  wait_for_run "$fail_run"
  note "terminal status '$RUN_STATUS' after $(elapsed "$t0")s"
  fail_branch="foreman/$fail_task/$fail_run"
  if [ "$RUN_STATUS" != completed ]; then
    chmod -R u+rwx "$ORIGIN_B"
    fail "failure: run reached '$RUN_STATUS', expected 'completed' (a repo's PR failure must not fail the run)"
    diagnose_run "$fail_run"
    return 0
  fi
  pass "failure: the run completed although b's PR could not be created"
  out "   foreman run get: $(printf '%s' "$RUN_JSON" | jq -c '.run | {run_id, status, task_id, pr_url, pr_urls, usage}')"
  probe=$(rpc_json "E2EMultiRepoProbe.run(\"$fail_run\")")
  out "   probe: $(printf '%s' "$probe" | jq -c '{status, completed_with_errors, repositories: [.repositories[] | {repo_id, pr_state, gate, pr_url: .pr_association.pr_url, wt: .worktree.status, failure: (.pr_failure.reason | tostring | .[0:160])}]}')"
  assert_eq "completed_with_errors (the derived dashboard flag)" "$(printf '%s' "$probe" | jq -r '.completed_with_errors')" "true"
  assert_eq "repo b reads as create_failed" "$(printf '%s' "$probe" | jq -r '[.repositories[] | select(.repo_id == "b")][0].pr_state')" "create_failed"
  assert_has "repo a has its PR" "$(printf '%s' "$probe" | jq -r '[.repositories[] | select(.["primary?"] == true)][0].pr_association.pr_url')" "/e2e-owner/repo-a/pull/"
  assert_eq "the branch of a is on its origin" "$(yes_no "$(origin_branch_sha a "$fail_branch")")" "yes"
  assert_eq "the branch of b is NOT on its origin" "$(yes_no "$(origin_branch_sha b "$fail_branch")")" "no"
  assert_eq "fake gh: a PR was created for a only" "$(gh_calls "pr create .*--head $fail_branch")" "1"
  assert_eq "worktree of a reclaimed (cleanup: on_success)" "$(registered_worktrees a "$fail_run")" "0"
  b_wt=$(printf '%s' "$probe" | jq -r '[.worktrees[] | select(.repo_id == "b")][0].worktree_path')
  assert_true "worktree of b KEPT for the retry" test -d "$b_wt"
  assert_eq "worktree of b still registered in repo b" "$(registered_worktrees b "$fail_run")" "1"
  sha_a_before=$(origin_branch_sha a "$fail_branch")

  say "failure: the operator restores the permissions and runs 'run retry-pr --repo-id b'"
  chmod -R u+rwx "$ORIGIN_B"
  fm run retry-pr --id "$fail_run" --repo-id b >"$WORK/retry-b.out" 2>&1
  rc=$?
  out "   retry-pr: exit $rc: $(tr '\n' ' ' < "$WORK/retry-b.out" | cut -c1-240)"
  assert_eq "run retry-pr: exit status" "$rc" "0"
  assert_eq "the branch of b is now on its origin" "$(yes_no "$(origin_branch_sha b "$fail_branch")")" "yes"
  assert_eq "VERSION of b on the pushed branch" \
    "$(git --git-dir="$ORIGIN_B" show "$fail_branch:VERSION" 2>/dev/null | tr -d ' \n\r')" "$FAIL_VERSION"
  assert_eq "fake gh: the retry created the PR of b" "$(gh_calls "repo-b${TAB}pr create .*--head $fail_branch")" "1"
  assert_eq "fake gh: the retry left a alone (still one PR for a)" "$(gh_calls "repo-a${TAB}pr create .*--head $fail_branch")" "1"
  assert_eq "the pushed branch of a is untouched by b's retry" "$(origin_branch_sha a "$fail_branch")" "$sha_a_before"
  probe=$(rpc_json "E2EMultiRepoProbe.run(\"$fail_run\")")
  assert_eq "pr_associations_for_run after the retry" "$(printf '%s' "$probe" | jq '.pr_associations | length')" "2"
  assert_eq "completed_with_errors cleared by the retry" "$(printf '%s' "$probe" | jq -r '.completed_with_errors')" "false"
  assert_true "the worktree of b is reclaimed by the successful retry (on_success)" test ! -e "$b_wt"
  assert_true "archive diffs/b.patch exists for the partially failed run too" test -s "$REPO_A/.foreman/sessions/run/$fail_run/diffs/b.patch"
}

# ---------------------------------------------------------------- stage: legacy

LEGACY_VERSION="1.4.4"

stage_legacy() {
  say "legacy: a single-repository project (never given a second repo) on the same server"
  api_post "$(jq -nc --arg p "$LEGACY_PROJECT" --arg path "$REPO_C" \
    '{type: "project.register", payload: {project_id: $p, name: $p, path: $path, status: "active"}}')"
  [ "$API_CODE" = 201 ] || { fail "legacy: project.register: HTTP $API_CODE $API_BODY"; return 0; }
  legacy_task="legacy-task-$SUFFIX"
  prompt="Create a file named VERSION in EVERY repository of this run. Each VERSION file must contain exactly the text $LEGACY_VERSION followed by a single newline."
  t0=$(date +%s)
  fm run submit --project-id "$LEGACY_PROJECT" --workflow "$WORKFLOW" --prompt "$prompt" --work-id "$legacy_task" >"$WORK/legacy-submit.out" 2>&1
  assert_eq "foreman run submit (no repo flags): exit status" "$?" "0"
  await_run "$LEGACY_PROJECT" "$legacy_task"
  legacy_run=$RUN
  [ -n "$legacy_run" ] || { fail "legacy: no run was created"; return 0; }
  note "run id: $legacy_run"
  wait_for_run "$legacy_run"
  note "terminal status '$RUN_STATUS' after $(elapsed "$t0")s"
  if [ "$RUN_STATUS" != completed ]; then fail "legacy: run reached '$RUN_STATUS'"; diagnose_run "$legacy_run"; return 0; fi
  pass "legacy: the run completed"
  out "   foreman run get: $(printf '%s' "$RUN_JSON" | jq -c '.run | {run_id, status, task_id, pr_url, pr_urls, usage}')"
  legacy_branch="foreman/$legacy_task/$legacy_run"
  probe=$(rpc_json "E2EMultiRepoProbe.run(\"$legacy_run\")")
  out "   probe: $(printf '%s' "$probe" | jq -c '{status, completed_with_errors, worktrees: [.worktrees[] | {operation_id, repo_id, status}], repositories: [.repositories[] | {repo_id, pr_state}], pr_associations: [.pr_associations[] | {repo_id, pr_url}]}')"
  assert_eq "a single run worktree" "$(printf '%s' "$probe" | jq '.worktrees | length')" "1"
  assert_eq "its operation id is the legacy wt-<run>" "$(printf '%s' "$probe" | jq -r '.worktrees[0].operation_id')" "wt-$legacy_run"
  assert_eq "run_repositories has the one primary entry" "$(printf '%s' "$probe" | jq '.repositories | length')" "1"
  assert_eq "exactly one PR association" "$(printf '%s' "$probe" | jq '.pr_associations | length')" "1"
  assert_eq "fake gh: one 'pr create' for the legacy branch" "$(gh_calls "pr create .*--head $legacy_branch")" "1"
  assert_eq "fake gh: it was opened from repo c" "$(gh_calls "repo-c${TAB}pr create .*--head $legacy_branch")" "1"
  runjson=$(api_get "/api/runs/$legacy_run")
  assert_has "run.pr_url is set" "$(printf '%s' "$runjson" | jq -r '.run.pr_url')" "/e2e-owner/repo-c/pull/"
  assert_eq "the run projection has no repo_ids / pr_urls / repo_id keys" \
    "$(printf '%s' "$runjson" | jq -c '.run | [has("repo_ids"), has("pr_urls"), has("repo_id")]')" "[false,false,false]"
  assert_eq "the branch is on the origin of c" "$(yes_no "$(origin_branch_sha c "$legacy_branch")")" "yes"
  assert_eq "VERSION committed" "$(git --git-dir="$ORIGIN_C" show "$legacy_branch:VERSION" 2>/dev/null | tr -d ' \n\r')" "$LEGACY_VERSION"
  events=$(rpc_json "E2EMultiRepoProbe.events(\"$legacy_run\", \"$legacy_task\")")
  out "   events: $(printf '%s' "$events" | jq -r '[.[] | .type] | unique | join(",")')"
  assert_eq "events were read (run + task)" "$([ "$(printf '%s' "$events" | jq 'length')" -gt 5 ] && echo yes || echo no)" "yes"
  assert_eq "no event of the single-repo run carries repo_id / repo_ids" \
    "$(printf '%s' "$events" | jq -c '[.[] | select(.keys | any(. == "repo_id" or . == "repo_ids")) | .type]')" "[]"
  assert_eq "no per-repo failure event" "$(printf '%s' "$events" | jq -c '[.[] | select(.type | test("RunRepoPrFailed"))] | length')" "0"
  assert_eq "git status of repo c shows only the Foreman archive" "$(git -C "$REPO_C" status --short)" "?? .foreman/"
  larch="$REPO_C/.foreman/sessions/run/$legacy_run"
  out "   archive: $(ls "$larch" 2>/dev/null | tr '\n' ' ')"
  assert_true "the archive has diff.patch" test -s "$larch/diff.patch"
  assert_true "the archive has NO diffs/ directory" test ! -e "$larch/diffs"
  assert_eq "the manifest has NO repositories[] key" "$(jq 'has("repositories")' "$larch/manifest.json" 2>/dev/null)" "false"
}

# ---------------------------------------------------------------- closing checks

stage_strays() {
  say "strays: nothing left behind by the runs"
  for id in a b c; do
    assert_eq "repo $id: only its main checkout is a registered worktree" \
      "$(git -C "$(repo_of "$id")" worktree list --porcelain | grep -c '^worktree ')" "1"
  done
  for p in "$PROJECT" "$LEGACY_PROJECT"; do
    assert_eq "no run worktree directory left under ~/.foreman/worktrees/$p" \
      "$(find "$WT_ROOT/$p" -type d \( -name workspace -o -path '*/repos/*' \) 2>/dev/null | wc -l | tr -d ' ')" "0"
  done
  assert_eq "fake gh: unsupported invocations over the whole run" "$(count_lines "$GH_STATE/unsupported.log")" "0"
  say "evidence: fake gh calls"
  cut -f2- "$CALLS" 2>/dev/null | cut -c1-210 | while IFS= read -r l; do out "   gh@$l"; done
  say "evidence: scratch repositories"
  for id in a b c; do
    out "   repo-$id local branches: $(git -C "$(repo_of "$id")" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')"
    out "   repo-$id origin branches: $(git --git-dir="$(origin_of "$id")" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')"
  done
}

# ---------------------------------------------------------------- main

say "foreman multi-repo live e2e: provider=$E2E_PROVIDER model=$E2E_MODEL stages=[$E2E_STAGES]"
setup

for stage in $E2E_STAGES; do
  s0=$(date +%s)
  "stage_$stage"
  note "stage $stage took $(elapsed "$s0")s"
done
stage_strays

say "summary"
out "   $PASSED passed, $FAILED failed in $(elapsed "$STARTED_AT")s (provider=$E2E_PROVIDER, model=$E2E_MODEL)"
if [ "$FAILED" -gt 0 ]; then
  out "FAILED ASSERTIONS:$FAILURES"
  exit 3
fi
out "multi-repo e2e: PASSED"
exit 0
