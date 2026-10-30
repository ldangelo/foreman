#!/usr/bin/env bash
# scripts/e2e/project_archive_flow.sh
#
# Live proof (foreman-5fqso) of what `foreman project delete` (soft delete = archive) does against a REAL
# throwaway Foreman server (private database/port/scratch repo; real pi agent on minimax for the workflow runs):
#
#   1. a workflow run in flight BLOCKS the archive: `project delete` is refused with HTTP 409
#      `project_has_active_runs` naming the RUN id, `--force` prints `project archive blocked by active runs: <id>`
#      to stderr. Once the run is cancelled and terminal the archive is accepted; `GET /api/projects` hides the
#      project, `?include_archived=true` shows it, `GET /api/projects/:id` still answers, new work (`run submit`)
#      is refused, `project reactivate` restores it and a run is accepted again. Nothing is purged: the project's
#      `.foreman` directory, memory, library and the earlier run are still there/readable, archived and reactivated.
#   2. a running JOBSITE does NOT block the archive (deliberate: a jobsite holds no run reservation; pinned by
#      test/foreman_server/jobsite/project_archive_test.exs and docs/decisions/project-delete.md). A jobsite whose
#      agent is a held `pi` shim (scripts/e2e/project_archive/pi-held.sh: blocks one marked prompt until a release
#      file exists, forwards every other pi call to the real pi) is started through `POST /api/jobsites`; the
#      archive is accepted, the jobsite keeps running and its agent process stays alive, a second
#      `POST /api/jobsites` is refused 422 `spec_project_unavailable` and the jobsite list still holds exactly
#      one, releasing the agent lets the jobsite complete, and after `project reactivate` a new jobsite starts.
#      The OBSERVED outcome is printed as "OBSERVED" lines (the evidence the bead asks for).
#
#     devbox run -- bash scripts/e2e/project_archive_flow.sh
#
# Requires (checked by check_environment): git jq curl psql go elixir mix python3 br pi on PATH, the Postgres of the
# other harnesses (E2E_PG_*, localhost:55432 postgres/postgres) and a pi with working minimax credentials (the
# workflow runs use the real pi; only the marked jobsite prompt is answered by the shim). No claude, no GitHub.
# Optional env (same as claude_projects/lib.sh): E2E_WORK_DIR, E2E_DB_NAME, E2E_PORT (default 4880), E2E_HOOK_PORT
# (4980), E2E_MODEL, E2E_RUN_TIMEOUT, E2E_KEEP=1 (leave the stack up), E2E_EVIDENCE=always.
# The review analyzer is switched off (E2E_REVIEW_ANALYSIS=0). Expected runtime: 5-9 minutes (boot 1-2 min, two held
# real-pi runs that are cancelled, then the jobsite part, which makes no model call).
#
# Results: PASS = observed as expected. FAIL = observed differently (exit 3). UNVERIFIED = a precondition did not
# hold, so nothing is claimed (foreman-azc2o: the first run's kickoff fails intermittently; a run that is not
# running when the delete is sent proves nothing about the refusal), never counted as a pass; it does not change
# the exit status. Exit: 0 no FAIL, 1 environment problem, 2 setup failed, 3 one or more assertions failed.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=parch
E2E_PORT=${E2E_PORT:-4880}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4980}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

# The held-pi shim directory lives outside $WORK (setup_stack wipes $WORK before it starts the server, and the server's
# PATH is fixed at that start), under the git-ignored <repo>/tmp, never /tmp. Its release/started files live in $WORK.
SHIM_DIR="$ROOT/tmp/e2e-parch-shim-$SUFFIX"
RELEASE="$WORK/jobsite-release"
STARTED="$WORK/jobsite-started"
HOLD_MARKER="JOBSITE-HOLD"
E2E_PATH_PREFIX="$SHIM_DIR"
E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0 FOREMAN_JOBSITES_ALLOW_REMOTE_START=true"

check_environment
install_traps

JOBSITE_IDS=""   # every jobsite this script started: cancelled on every exit path
OPEN_RUNS=""     # every workflow run this script started: cancelled on every exit path

# parch_exit: the EXIT trap. Releases/cancels what this script started, removes the shim, then hands over to the
# harness cleanup (evidence, server stop, stray sweep, work dir and database removal) with the original status.
parch_exit() {
  pe_rc=$?
  trap - EXIT
  if [ -n "$API" ]; then
    for pe_id in $JOBSITE_IDS; do
      curl -sS -o /dev/null --max-time 20 -X POST -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' \
        --data '{"reason":"e2e cleanup"}' "$API/api/jobsites/$pe_id/cancel" >/dev/null 2>&1
    done
    for pe_run in $OPEN_RUNS; do
      fm run cancel --id "$pe_run" --reason "e2e cleanup" >/dev/null 2>&1
    done
  fi
  { : > "$RELEASE"; } 2>/dev/null   # a held agent that outlived the cancel must not block forever
  if [ "$E2E_KEEP" != 1 ]; then rm -rf "$SHIM_DIR"; fi
  (exit "$pe_rc")
  cleanup
}
trap parch_exit EXIT

# ---------------------------------------------------------------- helpers

# api_post <path> <json body> -> HTTP status on stdout; the response body is left in $WORK/api-post.out
api_post() {
  curl -sS -o "$WORK/api-post.out" -w '%{http_code}' --max-time 120 -X POST \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' \
    --data "$2" "$API$1" 2>/dev/null
}

# wait_jobsite <jobsite id> <jq predicate> <timeout s> -> JOBSITE (the last projection read); 0 once the predicate held
wait_jobsite() {
  wj_start=$(date +%s); JOBSITE=""
  while :; do
    JOBSITE=$(api_get "/api/jobsites/$1")
    if [ -n "$JOBSITE" ] && printf '%s' "$JOBSITE" | jq -e "$2" >/dev/null 2>&1; then return 0; fi
    [ "$(elapsed "$wj_start")" -lt "$3" ] || return 1
    sleep 1
  done
}

jobsite_count() { api_get "/api/jobsites" | jq -r '.jobsites | length'; }

# project_listed <query string, e.g. ?include_archived=true>: 0 when $PROJECT is in GET /api/projects<query>
project_listed() {
  api_get "/api/projects$1" | jq -e --arg p "$PROJECT" 'any(.projects[]?; (.id // .project_id // .name) == $p)' >/dev/null 2>&1
}

# project_absent <query string>: 0 only when GET /api/projects<query> ANSWERED a project list that lacks $PROJECT
# (an unreachable API is never "hidden")
project_absent() {
  api_get "/api/projects$1" | jq -e --arg p "$PROJECT" '(.projects | type == "array") and (any(.projects[]?; (.id // .project_id // .name) == $p) | not)' >/dev/null 2>&1
}

# wait_listed <yes|no> <query string> <timeout s>: polls until $PROJECT is (yes) / is not (no) in GET /api/projects<query>
wait_listed() {
  wl_start=$(date +%s)
  while :; do
    if [ "$1" = yes ]; then project_listed "$2" && return 0; else project_absent "$2" && return 0; fi
    [ "$(elapsed "$wl_start")" -lt "$3" ] || return 1
    sleep 1
  done
}

# run_status <run id> -> RUN_STATUS
run_status() { RUN_STATUS=$(api_get "/api/runs/$1" | jq -r '.run.status // empty'); }

# run_running <run id>: 0 when the run is running right now (RUN_STATUS holds what was read)
run_running() {
  run_status "$1"
  printf '%s' "$RUN_STATUS" | grep -Eq '^(running|in_progress|working)$'
}

# wait_running <run id> <timeout s> -> RUN_STATUS; 0 running, 1 reached a terminal status first, 2 timed out
wait_running() {
  wn_start=$(date +%s)
  while :; do
    if run_running "$1"; then return 0; fi
    if printf '%s' "$RUN_STATUS" | grep -Eq '^(completed|failed|cancelled|stopped|deleted)$'; then return 1; fi
    [ "$(elapsed "$wn_start")" -lt "$2" ] || return 2
    sleep 2
  done
}

# wait_run_terminal <run id> <timeout s> -> RUN_STATUS; 0 once completed|failed|cancelled|stopped
wait_run_terminal() {
  wt_start=$(date +%s)
  while :; do
    run_status "$1"
    if printf '%s' "$RUN_STATUS" | grep -Eq '^(completed|failed|cancelled|stopped|deleted)$'; then return 0; fi
    [ "$(elapsed "$wt_start")" -lt "$2" ] || return 1
    sleep 2
  done
}

# await_run <task id> -> RUN (empty after 120 s without a run for that task)
await_run() {
  ar_n=0; RUN=""
  while [ -z "$RUN" ] && [ "$ar_n" -lt 120 ]; do
    RUN=$(api_get "/api/runs?project_id=$PROJECT" | jq -r --arg t "$1" '[.runs[]? | select(.task_id == $t)][0].run_id // empty')
    [ -n "$RUN" ] || { sleep 2; ar_n=$((ar_n + 2)); }
  done
}

LONG="Run the shell command 'sleep 300' and wait for it to finish. Then create a file named done.txt containing the word DONE."

# start_held_run <label> -> RUN: submits a run whose agent blocks in a `sleep 300` tool and waits until it is RUNNING.
# foreman-azc2o: the first kickoff fails intermittently, so a run that fails instead of running is retried once (the
# attempt is noted); returns 1 (RUN empty) when no attempt reached running, 2 when `run submit` itself was refused.
start_held_run() {
  sh_try=1; RUN=""
  while [ "$sh_try" -le 2 ]; do
    sh_task="parch-$SUFFIX-$1-$sh_try"
    if ! fm run submit --project-id "$PROJECT" --workflow edit --work-id "$sh_task" --prompt "$LONG" >"$WORK/submit-$1-$sh_try.out" 2>&1; then
      note "run submit ($1, attempt $sh_try) was refused: $(tr '\n' ' ' < "$WORK/submit-$1-$sh_try.out" | cut -c1-300)"
      RUN=""
      return 2
    fi
    await_run "$sh_task"
    if [ -z "$RUN" ]; then
      note "attempt $sh_try ($1): no run appeared for task $sh_task within 120s (foreman-azc2o)"
    else
      OPEN_RUNS="$OPEN_RUNS $RUN"
      wait_running "$RUN" 180
      sh_rc=$?
      if [ "$sh_rc" = 0 ]; then
        note "$1: run $RUN is running (attempt $sh_try)"
        return 0
      fi
      note "attempt $sh_try ($1): run $RUN did not reach running (status '$RUN_STATUS', rc $sh_rc): $(api_get "/api/runs/$RUN" | jq -c '.run.failure_reason // .run.error // null')"
      fm run cancel --id "$RUN" --reason "e2e: attempt $sh_try did not start" >/dev/null 2>&1
    fi
    sh_try=$((sh_try + 1))
  done
  RUN=""
  return 1
}

# cancel_run <run id> <what>: cancels and waits for a terminal status (bounded)
cancel_run() {
  if fm run cancel --id "$1" --reason "e2e archive: $2" >"$WORK/cancel.out" 2>&1; then
    pass "run cancel accepted ($2)"
  else
    fail "run cancel ($2): $(cut -c1-200 "$WORK/cancel.out")"
  fi
  if wait_run_terminal "$1" 90; then pass "run $1 is terminal after the cancel ($2): $RUN_STATUS"; else fail "run $1 not terminal 90s after the cancel ($2): '$RUN_STATUS'"; fi
}

# ---------------------------------------------------------------- item 1: workflow runs

MARKER_NAME="e2e-archive-marker-$SUFFIX.txt"
MEM_TOKEN="E2E-ARCHIVE-MEMORY-$SUFFIX"
LIB_NAME="e2e-archive-lib-$SUFFIX"
MEM_SEEDED=0
LIB_ID=""
FIRST_RUN=""
ARCHIVED_EARLY=0

# seed_artifacts: things the archive must NOT purge: a file in <repo>/.foreman, a memory topic, a library entry
seed_artifacts() {
  mkdir -p "$REPO/.foreman/sessions" && echo "keep me $SUFFIX" > "$REPO/.foreman/sessions/$MARKER_NAME"
  if [ -f "$REPO/.foreman/sessions/$MARKER_NAME" ]; then pass "seeded $REPO/.foreman/sessions/$MARKER_NAME"; else fail "cannot seed the .foreman marker file"; fi
  echo "$MEM_TOKEN: the archive must not purge this topic" > "$WORK/memory-body.md"
  if fm project memory write --name e2e-archive --description "e2e archive probe" --file "$WORK/memory-body.md" "$PROJECT" >"$WORK/memory-write.out" 2>&1 \
     && grep -rqF "$MEM_TOKEN" "$REPO/.foreman/memory" 2>/dev/null; then
    MEM_SEEDED=1
    pass "seeded memory topic e2e-archive (on disk under $REPO/.foreman/memory)"
  else
    unverified "memory survives the archive" "could not seed a memory topic: $(tr '\n' ' ' < "$WORK/memory-write.out" | cut -c1-200); on-disk layout of memory is an [INFERENCE] of the topic file under <repo>/.foreman/memory"
  fi
  mkdir -p "$WORK/library-src" && echo "$MEM_TOKEN library file" > "$WORK/library-src/note.txt"
  if fm project library add --name "$LIB_NAME" --format json "$PROJECT" "$WORK/library-src/note.txt" >"$WORK/library-add.out" 2>&1; then
    LIB_ID=$(fm project library list --format json "$PROJECT" 2>/dev/null | jq -r --arg n "$LIB_NAME" '[.entries[]? | select(.name == $n)][0].entry_id // empty')
  fi
  if [ -n "$LIB_ID" ]; then
    pass "seeded library entry $LIB_ID ($LIB_NAME)"
  else
    unverified "library survives the archive" "could not seed a library entry: $(tr '\n' ' ' < "$WORK/library-add.out" | cut -c1-200)"
  fi
}

# check_not_purged <when>: everything seeded, and the first run, are still there
check_not_purged() {
  np_when=$1
  assert_true "$np_when: <repo>/.foreman/sessions/$MARKER_NAME is still on disk" test -f "$REPO/.foreman/sessions/$MARKER_NAME"
  if [ "$MEM_SEEDED" = 1 ]; then
    assert_true "$np_when: the memory topic is still on disk" grep -rqF "$MEM_TOKEN" "$REPO/.foreman/memory"
    np_mem=$(fm project memory read --name e2e-archive "$PROJECT" 2>&1)
    assert_has "$np_when: the memory topic is still readable through the CLI" "$np_mem" "$MEM_TOKEN"
  fi
  if [ -n "$LIB_ID" ]; then
    np_lib=$(fm project library list --format json "$PROJECT" 2>&1 | jq -r '[.entries[]?.entry_id] | join(" ")' 2>/dev/null)
    assert_has "$np_when: the library entry $LIB_ID is still listed" "$np_lib" "$LIB_ID"
  fi
  if [ -n "$FIRST_RUN" ]; then
    np_run=$(api_get "/api/runs/$FIRST_RUN" | jq -r '"\(.run.status // "")/\(.run.project_id // "")"')
    assert_eq "$np_when: the earlier run $FIRST_RUN is still readable (status/project)" "${np_run#*/}" "$PROJECT"
    note "earlier run $FIRST_RUN status: ${np_run%%/*}"
    assert_true "$np_when: the earlier run is still in GET /api/runs?project_id=" \
      bash -c 'curl -sSf --max-time 60 -H "authorization: Bearer $1" "$2/api/runs?project_id=$3" | jq -e --arg r "$4" "any(.runs[]?; .run_id == \$r)"' _ "$E2E_API_TOKEN" "$API" "$PROJECT" "$FIRST_RUN"
  fi
}

# refusal_steps: the archive must be refused while $RUN is running. Returns 1 when the precondition did not hold
# (UNVERIFIED recorded). May leave ARCHIVED_EARLY=1 when the server (wrongly) accepted the archive.
refusal_steps() {
  say "item 1a: archive refused while run $RUN is in flight"
  note "EXPECTED: HTTP 409 project_has_active_runs naming run $RUN; --force prints 'project archive blocked by active runs: $RUN' on stderr; the project stays listed and the run keeps running"
  # foreman-azc2o: assert the precondition IMMEDIATELY before the step that depends on it
  if ! run_running "$RUN"; then
    unverified "archive refused while a run is in flight" "run $RUN was '$RUN_STATUS', not running, immediately before the delete (foreman-azc2o): the refusal cannot be shown"
    return 1
  fi
  pass "precondition: run $RUN is running immediately before the delete (status $RUN_STATUS)"
  fm project delete "$PROJECT" >"$WORK/delete-active.out" 2>&1
  rs_rc=$?
  if [ "$rs_rc" = 0 ]; then
    ARCHIVED_EARLY=1
    if run_running "$RUN"; then
      fail "project delete was ACCEPTED while run $RUN is still running: $(tr '\n' ' ' < "$WORK/delete-active.out" | cut -c1-300)"
    else
      unverified "archive refused while a run is in flight" "run $RUN left running ($RUN_STATUS) between the precondition check and the delete, which was then (legitimately) accepted"
    fi
    return 1
  fi
  rs_out=$(cat "$WORK/delete-active.out")
  note "ACTUAL project delete (exit $rs_rc): $(printf '%s' "$rs_out" | tr '\n' ' ' | cut -c1-300)"
  pass "project delete exits non-zero while a run is in flight (exit $rs_rc)"
  assert_has "project delete reports HTTP 409" "$rs_out" "HTTP 409"
  assert_has "project delete reports project_has_active_runs" "$rs_out" "project_has_active_runs"
  assert_has "project delete names the active run id $RUN" "$rs_out" "$RUN"
  fm project delete --force "$PROJECT" >"$WORK/delete-force.out" 2>"$WORK/delete-force.err"
  rs_rc=$?
  note "ACTUAL project delete --force (exit $rs_rc) stderr: $(tr '\n' ' ' < "$WORK/delete-force.err" | cut -c1-300)"
  if [ "$rs_rc" -ne 0 ]; then pass "project delete --force exits non-zero while a run is in flight (exit $rs_rc)"; else fail "project delete --force was accepted while run $RUN runs"; fi
  assert_has "--force prints the blocking run on stderr" "$(cat "$WORK/delete-force.err")" "project archive blocked by active runs: $RUN"
  if project_listed ""; then pass "the project is still listed after the refused deletes"; else fail "the project vanished from GET /api/projects after refused deletes"; fi
  if run_running "$RUN"; then pass "run $RUN is still running after the refused deletes"; else fail "run $RUN is '$RUN_STATUS' after the refused deletes: the refusal disturbed it"; fi
  return 0
}

# archive_until_hidden: `project delete` until accepted AND the project is hidden (the run's reservation is released
# asynchronously after its cancel, so early attempts may still be refused). Bounded at 90 s.
archive_until_hidden() {
  au_start=$(date +%s); au_key=""; au_out=""
  if project_absent ""; then
    note "project is already archived (the earlier delete was accepted)"
    return 0
  fi
  while :; do
    # shellcheck disable=SC2086
    au_out=$(fm project delete ${au_key:+--idempotency-key "$au_key"} "$PROJECT" 2>&1)
    au_rc=$?
    if [ "$au_rc" = 0 ] && wait_listed no "" 20; then
      pass "project delete accepted after the run ended (+$(elapsed "$au_start")s): $(printf '%s' "$au_out" | tr '\n' ' ' | cut -c1-120)"
      return 0
    fi
    # a refused attempt must not have been remembered as applied; if the CLI says it was replayed, apply with a new key
    case "$au_out" in *"no change:"*) au_key="parch-$SUFFIX-retry" ;; esac
    if [ "$(elapsed "$au_start")" -ge 90 ]; then
      fail "project not archived 90s after the run ended (last exit $au_rc): $(printf '%s' "$au_out" | tr '\n' ' ' | cut -c1-300)"
      return 1
    fi
    sleep 2
  done
}

phase_workflow() {
  say "item 1: project archive vs a workflow run in flight"
  seed_artifacts
  if project_listed ""; then pass "precondition: the project is listed in GET /api/projects"; else fail "project $PROJECT not found in GET /api/projects (jq id/project_id/name): $(api_get /api/projects | cut -c1-300)"; fi

  start_held_run first
  start_rc=$?
  if [ "$start_rc" != 0 ]; then
    unverified "archive refused while a run is in flight" "no run reached running after 2 attempts (foreman-azc2o?), submit exit $start_rc"
  else
    FIRST_RUN=$RUN
    if refusal_steps; then
      cancel_run "$FIRST_RUN" "end of the refusal checks"
    else
      cancel_run "$FIRST_RUN" "refusal checks did not hold"
    fi
  fi

  say "item 1b: archive accepted once the run ended"
  archive_until_hidden || return 0
  assert_true "GET /api/projects hides the archived project" project_absent ""
  if project_listed "?include_archived=true"; then pass "GET /api/projects?include_archived=true shows the archived project"; else fail "GET /api/projects?include_archived=true does not show the archived project"; fi
  assert_eq "GET /api/projects/:id still answers for the archived project (HTTP status)" "$(api_status "/api/projects/$PROJECT")" 200
  note "archived project projection: $(api_get "/api/projects/$PROJECT" | jq -c '.project // . | {status, archived, "archived?": .["archived?"]}' 2>/dev/null)"

  pw_task="parch-$SUFFIX-while-archived"
  fm run submit --project-id "$PROJECT" --workflow edit --work-id "$pw_task" --prompt "Create a file named x.txt containing the word X." >"$WORK/submit-archived.out" 2>&1
  pw_rc=$?
  pw_out=$(cat "$WORK/submit-archived.out")
  note "ACTUAL run submit while archived (exit $pw_rc): $(printf '%s' "$pw_out" | tr '\n' ' ' | cut -c1-300)"
  if [ "$pw_rc" -ne 0 ]; then pass "run submit is refused while the project is archived (exit $pw_rc)"; else fail "run submit was accepted for an archived project"; fi
  assert_has "the refusal is the typed project_archived error" "$pw_out" "project_archived"
  assert_eq "no run exists for the refused task" "$(api_get "/api/runs?project_id=$PROJECT" | jq -r --arg t "$pw_task" '[.runs[]? | select(.task_id == $t)] | length')" 0
  check_not_purged "while archived"

  say "item 1c: reactivate"
  fm project reactivate "$PROJECT" >"$WORK/reactivate.out" 2>&1 && pass "project reactivate accepted: $(tr '\n' ' ' < "$WORK/reactivate.out" | cut -c1-100)" || fail "project reactivate: $(cut -c1-200 "$WORK/reactivate.out")"
  if wait_listed yes "" 20; then pass "GET /api/projects lists the project again"; else fail "the reactivated project is still hidden from GET /api/projects"; fi
  start_held_run reactivated
  start_rc=$?
  if [ "$start_rc" = 0 ]; then
    pass "a run is accepted and running again after reactivation ($RUN)"
    cancel_run "$RUN" "end of the reactivation check"
  elif [ "$start_rc" = 2 ]; then
    fail "run submit refused after reactivation: $(tr '\n' ' ' < "$WORK/submit-reactivated-1.out" | cut -c1-300)"
  else
    unverified "a run is accepted again after reactivation" "the run was submitted but never reached running (foreman-azc2o?)"
  fi
  check_not_purged "after reactivate"
}

# ---------------------------------------------------------------- item 2: jobsite while archived

# held_jobsite_spec <branch suffix> -> the POST /api/jobsites body; the prompt carries the marker the pi shim holds on
held_jobsite_spec() {
  jq -n --arg project "$PROJECT" --arg model "$E2E_MODEL" --arg branch "jobsite/e2e-$SUFFIX-$1" \
    --arg prompt "$HOLD_MARKER e2e project archive probe ($1): reply with the single word ok and nothing else." \
    '{project_id: $project, prompt: $prompt, agent: {provider: "pi", model: $model}, strategy: {branch: $branch}, sandbox: "host", idle_timeout_seconds: 1800}'
}

# start_jobsite <branch suffix> -> JS_ID; 0 when POST /api/jobsites answered 202 with an id
start_jobsite() {
  JS_ID=""
  sj_code=$(api_post "/api/jobsites" "$(held_jobsite_spec "$1")")
  if [ "$sj_code" != 202 ]; then
    fail "POST /api/jobsites ($1): expected HTTP 202, got $sj_code: $(cut -c1-300 "$WORK/api-post.out")"
    return 1
  fi
  JS_ID=$(jq -r '.id // empty' "$WORK/api-post.out")
  if [ -z "$JS_ID" ]; then fail "POST /api/jobsites ($1) answered 202 without an id: $(cut -c1-200 "$WORK/api-post.out")"; return 1; fi
  JOBSITE_IDS="$JOBSITE_IDS $JS_ID"
  pass "jobsite $JS_ID started through POST /api/jobsites (HTTP 202, $1)"
}

# agent_alive: 0 while the held agent (pid recorded by the shim) is alive and still is the shim, not a reused pid
agent_alive() {
  [ -n "${SHIM_PID:-}" ] && kill -0 "$SHIM_PID" 2>/dev/null && case "$(ps -o command= -p "$SHIM_PID" 2>/dev/null)" in *"$SHIM_DIR"*) return 0 ;; esac
  return 1
}

phase_jobsite() {
  say "item 2: project archive vs a running jobsite"
  note "EXPECTED (deliberate, docs/decisions/project-delete.md): the archive is ACCEPTED (a jobsite holds no run reservation); the jobsite keeps running; a second jobsite is refused 422 spec_project_unavailable; releasing lets it complete; after reactivate a new jobsite starts"
  rm -f "$RELEASE" "$STARTED"
  if ! project_listed ""; then fail "the project is not active at the start of the jobsite part"; return 0; fi
  js_before=$(jobsite_count)
  start_jobsite held || return 0
  js_id=$JS_ID
  if ! wait_jobsite "$js_id" '.status == "running"' 120; then
    fail "jobsite $js_id is not running 120s after its start: $(printf '%s' "$JOBSITE" | jq -c '{status, last_error}' 2>/dev/null)"
    return 0
  fi
  # wait until the shim is actually holding the agent iteration open
  js_n=0
  while [ ! -s "$STARTED" ] && [ "$js_n" -lt 120 ]; do sleep 1; js_n=$((js_n + 1)); done
  SHIM_PID=$(cat "$STARTED" 2>/dev/null)
  # foreman-azc2o-style precondition, immediately before the archive: running, held, agent alive
  if [ -z "$SHIM_PID" ]; then
    unverified "archive while a jobsite runs" "the held pi shim never started for jobsite $js_id within 120s (the jobsite's agent did not resolve 'pi' to the shim [INFERENCE: PATH of the server is what finds it]); projection: $(printf '%s' "$JOBSITE" | jq -c '{status, last_error}' 2>/dev/null)"
    return 0
  fi
  if ! agent_alive || [ "$(api_get "/api/jobsites/$js_id" | jq -r '.status')" != running ]; then
    unverified "archive while a jobsite runs" "the jobsite or its held agent (pid $SHIM_PID) was not running immediately before the archive: $(api_get "/api/jobsites/$js_id" | jq -c '{status, last_error}')"
    return 0
  fi
  pass "precondition: jobsite $js_id is running and its agent (pid $SHIM_PID, held by the shim) is alive immediately before the archive"

  fm project delete --idempotency-key "parch-$SUFFIX-archive-jobsite" "$PROJECT" >"$WORK/delete-jobsite.out" 2>&1
  js_rc=$?
  js_out=$(tr '\n' ' ' < "$WORK/delete-jobsite.out" | cut -c1-300)
  if [ "$js_rc" = 0 ]; then
    pass "project delete is ACCEPTED while a jobsite runs (exit 0): $js_out"
  else
    fail "project delete was refused while a jobsite runs (exit $js_rc): $js_out"
    note "OBSERVED: archive REFUSED with a running jobsite: $js_out"
    return 0
  fi
  if wait_listed no "" 20; then pass "GET /api/projects hides the project archived under a running jobsite"; else fail "the project is still listed after the accepted archive"; fi

  # the jobsite keeps running: read it for 6 s (an observation window, not a synchronisation) and require it never leaves running
  js_ok=1
  for js_i in 1 2 3 4 5 6; do
    js_st=$(api_get "/api/jobsites/$js_id" | jq -r '.status')
    if [ "$js_st" != running ] || ! agent_alive; then js_ok=0; note "jobsite status '$js_st', agent alive: $(agent_alive && echo yes || echo no) (observation $js_i)"; break; fi
    sleep 1
  done
  if [ "$js_ok" = 1 ]; then pass "jobsite $js_id is still running and its agent (pid $SHIM_PID) still alive 6s after the archive"; else fail "the archive disturbed the running jobsite (see the observation above)"; fi

  # a second jobsite is refused, leaves nothing behind
  js_code=$(api_post "/api/jobsites" "$(held_jobsite_spec second)")
  js_body=$(cut -c1-300 "$WORK/api-post.out")
  assert_eq "second POST /api/jobsites while archived (HTTP status)" "$js_code" 422
  assert_eq "second POST /api/jobsites error code" "$(jq -r '.error // empty' "$WORK/api-post.out")" spec_project_unavailable
  assert_has "the refusal says the project is archived" "$js_body" "archived"
  assert_eq "GET /api/jobsites still lists exactly one more jobsite than before" "$(jobsite_count)" "$((js_before + 1))"

  note "OBSERVED: project delete was ACCEPTED (exit $js_rc) while jobsite $js_id was running; the project left GET /api/projects; jobsite status stayed '$(api_get "/api/jobsites/$js_id" | jq -r '.status')' with agent pid $SHIM_PID alive: $(agent_alive && echo yes || echo no); a second POST /api/jobsites answered HTTP $js_code $(jq -c '{error, message}' "$WORK/api-post.out" 2>/dev/null)"

  # releasing lets the jobsite finish inside the archived project
  : > "$RELEASE"
  if wait_jobsite "$js_id" '.status | test("^(completed|failed|cancelled)$")' 120; then
    assert_eq "the released jobsite finished inside the archived project" "$(printf '%s' "$JOBSITE" | jq -r '.status')" completed
    note "OBSERVED: after the release jobsite $js_id is '$(printf '%s' "$JOBSITE" | jq -r '.status')' $(printf '%s' "$JOBSITE" | jq -c '{last_error}' 2>/dev/null)"
  else
    fail "the released jobsite did not finish within 120s: $(printf '%s' "$JOBSITE" | jq -c '{status, last_error}' 2>/dev/null)"
  fi
  js_n=0
  while agent_alive && [ "$js_n" -lt 30 ]; do sleep 1; js_n=$((js_n + 1)); done
  if agent_alive; then fail "the held agent (pid $SHIM_PID) still runs 30s after the release"; else pass "the held agent exited after the release"; fi

  # reactivate; a jobsite can start again
  fm project reactivate --idempotency-key "parch-$SUFFIX-reactivate-jobsite" "$PROJECT" >"$WORK/reactivate-jobsite.out" 2>&1 \
    && pass "project reactivate accepted: $(tr '\n' ' ' < "$WORK/reactivate-jobsite.out" | cut -c1-100)" || fail "project reactivate: $(cut -c1-200 "$WORK/reactivate-jobsite.out")"
  if wait_listed yes "" 20; then pass "GET /api/projects lists the project again"; else fail "the reactivated project is still hidden"; fi
  # the release file is still there, so the shim lets this jobsite's agent answer at once
  if start_jobsite after-reactivate; then
    if wait_jobsite "$JS_ID" '.status | test("^(completed|failed|cancelled)$")' 120; then
      assert_eq "the jobsite started after reactivation completed" "$(printf '%s' "$JOBSITE" | jq -r '.status')" completed
    else
      fail "the jobsite started after reactivation did not finish within 120s: $(printf '%s' "$JOBSITE" | jq -c '{status, last_error}' 2>/dev/null)"
    fi
    note "OBSERVED: after reactivation a new jobsite was accepted (HTTP 202) and ended '$(printf '%s' "$JOBSITE" | jq -r '.status')'"
  fi
}

# ---------------------------------------------------------------- main

mkdir -p "$SHIM_DIR" || die "cannot create $SHIM_DIR" 1
sed -e "s|__SHIM_DIR__|$SHIM_DIR|" -e "s|__RELEASE_FILE__|$RELEASE|" -e "s|__STARTED_FILE__|$STARTED|" \
  "$HERE/project_archive/pi-held.sh" > "$SHIM_DIR/pi" && chmod +x "$SHIM_DIR/pi" || die "cannot install the held pi shim" 1
note "held pi shim: $SHIM_DIR/pi (marker '$HOLD_MARKER', release file $RELEASE)"

setup_stack
printf '.foreman/\n' >> "$REPO/.git/info/exclude"
register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
fm project update --max-concurrent-runs 3 "$PROJECT" >/dev/null 2>&1 || die "project update failed" 2
note "project $PROJECT registered"

# the shim must be what the server finds first, and must leave the server's own probes to the real pi
assert_eq "the server's PATH reaches the real pi through the shim: pi --version" "$(PATH="$SHIM_DIR:$PATH" pi --version >/dev/null 2>&1; echo $?)" 0

phase_workflow
phase_jobsite
summary
exit $?
