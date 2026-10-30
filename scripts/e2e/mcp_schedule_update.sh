#!/usr/bin/env bash
# scripts/e2e/mcp_schedule_update.sh
#
# Live check of the MCP tool `foreman_schedule_update` (bead foreman-7c191, part 1) against a real, throwaway
# Foreman server: the real HTTP /mcp endpoint (plain JSON-RPC over curl, exactly what test/foreman_server/mcp/
# http_boot_test.exs and multi_repo_agent.sh check_mcp_endpoint do), the real Go CLI and the real projection.
# No model, no claude, no pi agent turn: nothing is ever run. The schedule is `--every 1h` (the minimum is 5m), so the
# ticker never fires it. (Part 2 of the bead, the question.answer browser boundary, is not in this script.)
#
# What it proves, in order (each lettered section prints its own PASS/FAIL lines):
#   (a) tools/list advertises foreman_schedule_update.
#   (b) it is a WRITE tool: with allow_workflow_writes switched off at runtime (Application.put_env on the live node)
#       tools/list drops EXACTLY ForemanServer.MCP.Policy.write_tools() (read from the node, not hard-coded) and
#       foreman_schedule_update with it; a tools/call of update and one of foreman_schedule_create answer
#       identically (whatever that answer is: it is printed) and change nothing; writes back on, the tool returns.
#   (c) a CLI-created schedule is updated through MCP: name, prompt, every, cron, and several fields at once. Each
#       result has exactly the keys project_id, schedule_id, status ("updated"); `foreman project schedule list
#       --json` shows each change and the fields that were not named keep their values.
#   (d) update with only project_id + schedule_id is refused with the typed code of the Schedule aggregate,
#       `missing_or_invalid` (tools.ex "no pre-validation": NOT INVALID_PARAMS), and changes nothing; a missing
#       schedule_id and an unknown argument are INVALID_PARAMS.
#   (e) after `foreman project schedule delete` the update is refused `schedule_deleted`; an unknown schedule id is
#       refused `schedule_not_found`.
# JSON-RPC `error.code` is an integer for protocol errors but the tool errors carry the typed code as a STRING
# (Dispatch.wrap puts it in error.code as is). The checks accept the typed code in error.code OR anywhere else in the
# error object (message, data) and print the raw error body whenever one does not match.
#
# Run (devbox shell, like the other live harnesses):   devbox run -- bash scripts/e2e/mcp_schedule_update.sh
# Needs: git jq curl psql go elixir mix python3 br pi on PATH (lib.sh check_environment; pi/br are only checked for
#   existence), Postgres on E2E_PG_HOST:E2E_PG_PORT (default localhost:55432, postgres/postgres).
# Environment (all optional): E2E_PORT (default 4890), E2E_HOOK_PORT (4990), E2E_WORK_DIR (default
#   <repo>/tmp/e2e-claude-projects-mcpsched, never /tmp), E2E_DB_NAME, E2E_API_TOKEN, E2E_SCHEDULE_SETTLE_SECS (how
#   long a read model may lag an accepted command, default 20), E2E_KEEP=1 (keep stack for a post-mortem),
#   E2E_EVIDENCE=always|0. A failing run keeps its evidence in tmp/e2e-evidence/mcpsched-*/ (work-files/ has every
#   MCP request/response as mcp-<n>.out, mcp-requests.log, the tools lists as tools-*.txt).
# Expected runtime: ~2-4 min warm (one server boot, go build, DB migrate, ~40 curl/CLI calls); a cold mix compile
#   can add several minutes (the harness waits up to 300 s for the server).
# Exit: 0 all passed, 1 environment problem, 2 setup failed, 3 one or more assertions FAILED.
#   PASS        the observed behaviour is what the code documents.
#   FAIL        it is not (the raw MCP body / CLI output is printed with it).
#   UNVERIFIED  a precondition did not hold (foreman-azc2o: e.g. writes not on, schedule not active, the node's
#               write-tool list unreadable), so the step was not run; never a pass.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-mcpsched}
E2E_PORT=${E2E_PORT:-4890}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4990}
# No review analysis: nothing runs here, and a reviewer agent must never start.
E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0"
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

check_environment
install_traps

MCP_PROTOCOL="2025-06-18"
MCP_SESSION=""
MCP_N=0
MCP_CODE=""
MCP_BODY=""
SETTLE_SECS=${E2E_SCHEDULE_SETTLE_SECS:-20}
SID=""

# ---------------------------------------------------------------- MCP over plain JSON-RPC

# mcp_rpc <method> <params json> [label]: one JSON-RPC request on the open session -> MCP_CODE (HTTP status), MCP_BODY (file)
mcp_rpc() {
  MCP_N=$((MCP_N + 1))
  MCP_BODY="$WORK/mcp-$MCP_N.out"
  m_req=$(jq -nc --argjson id "$MCP_N" --arg m "$1" --argjson p "$2" '{jsonrpc: "2.0", id: $id, method: $m, params: $p}')
  MCP_CODE=$(curl -sS -o "$MCP_BODY" -w '%{http_code}' --max-time 60 -X POST "$API/mcp" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -H 'accept: application/json' \
    -H "mcp-protocol-version: $MCP_PROTOCOL" -H "mcp-session-id: $MCP_SESSION" -d "$m_req" 2>"$WORK/mcp-$MCP_N.curlerr.log")
  [ -n "$MCP_CODE" ] || MCP_CODE=000
  [ -f "$MCP_BODY" ] || : > "$MCP_BODY"
  printf '#%s %s HTTP %s %s %s\n' "$MCP_N" "${3:-$1}" "$MCP_CODE" "$1" "$(printf '%s' "$2" | cut -c1-200)" >> "$WORK/mcp-requests.log"
}

# mcp_open: initialize + notifications/initialized -> MCP_SESSION. Returns 1 (after FAIL lines) when the endpoint is not usable.
mcp_open() {
  m_hdr="$WORK/mcp-initialize.headers.log"
  m_body="$WORK/mcp-initialize.out"
  m_code=$(curl -sS -D "$m_hdr" -o "$m_body" -w '%{http_code}' --max-time 30 -X POST "$API/mcp" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -H 'accept: application/json' \
    -H "mcp-protocol-version: $MCP_PROTOCOL" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$MCP_PROTOCOL\",\"capabilities\":{},\"clientInfo\":{\"name\":\"mcp-schedule-update-e2e\",\"version\":\"1\"}}}" 2>"$WORK/mcp-initialize.curlerr.log")
  assert_eq "/mcp initialize answers HTTP 200" "$m_code" "200"
  assert_eq "/mcp initialize names the Foreman MCP server" "$(jq -r '.result.serverInfo.name // empty' "$m_body" 2>/dev/null)" "foreman-mcp"
  MCP_SESSION=$(grep -i '^mcp-session-id:' "$m_hdr" 2>/dev/null | head -n 1 | sed 's/^[^:]*: *//' | tr -d '\r\n ')
  if [ "$m_code" != 200 ] || [ -z "$MCP_SESSION" ]; then
    fail "no usable MCP session (HTTP $m_code, mcp-session-id '${MCP_SESSION}'): $(head -c 400 "$m_body" | tr '\n' ' ')"
    return 1
  fi
  m_note=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$API/mcp" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -H 'accept: application/json' \
    -H "mcp-protocol-version: $MCP_PROTOCOL" -H "mcp-session-id: $MCP_SESSION" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null)
  assert_eq "notifications/initialized is accepted (HTTP 202)" "$m_note" "202"
  note "MCP session $MCP_SESSION"
}

# mcp_tool_names <label>: the advertised tool names (all pages), sorted, into $WORK/tools-<label>.txt. Returns 1 on a bad answer.
mcp_tool_names() {
  : > "$WORK/tools-$1.txt"
  m_cursor=""; m_pages=0
  while :; do
    if [ -n "$m_cursor" ]; then m_params=$(jq -nc --arg c "$m_cursor" '{cursor: $c}'); else m_params='{}'; fi
    mcp_rpc tools/list "$m_params" "tools/list ($1)"
    if [ "$MCP_CODE" != 200 ] || ! jq -e '.result.tools | arrays' "$MCP_BODY" >/dev/null 2>&1; then
      note "tools/list ($1): HTTP $MCP_CODE: $(head -c 400 "$MCP_BODY" | tr '\n' ' ')"
      return 1
    fi
    jq -r '.result.tools[].name' "$MCP_BODY" >> "$WORK/tools-$1.txt"
    m_cursor=$(jq -r '.result.nextCursor // empty' "$MCP_BODY")
    m_pages=$((m_pages + 1))
    { [ -n "$m_cursor" ] && [ "$m_pages" -lt 20 ]; } || break
  done
  sort -u -o "$WORK/tools-$1.txt" "$WORK/tools-$1.txt"
}

# mcp_call <tool> <arguments json> [label] -> MCP_CODE, MCP_BODY
mcp_call() {
  mcp_rpc tools/call "$(jq -nc --arg n "$1" --argjson a "$2" '{name: $n, arguments: $a}')" "${3:-$1}"
}

# mcp_has_code <body file> <typed code>: 0 when the error (a JSON-RPC `error`, or a result with isError true) carries the
# code in error.code, in error.data.code, or anywhere in its message/data strings.
mcp_has_code() {
  jq -e --arg c "$2" '
    (.error // (if .result.isError == true then .result else null end)) as $e
    | $e != null and (
        (($e.code | tostring) == $c)
        or ((($e.data | objects | .code) // "" | tostring) == $c)
        or ([$e | .. | strings | select(contains($c))] | length > 0))' "$1" >/dev/null 2>&1
}

# mcp_error_text <body file>: the error object compactly (for evidence)
mcp_error_text() {
  jq -c '.error // (if .result.isError == true then .result else null end) // {"no_error_in_body": .}' "$1" 2>/dev/null || head -c 400 "$1"
}

# assert_mcp_code <what> <typed code> <body file> [HTTP status of that call]
assert_mcp_code() {
  if mcp_has_code "$3" "$2"; then
    pass "$1: refused with $2 (JSON-RPC error.code=$(jq -c '.error.code // "(result.isError)"' "$3" 2>/dev/null))"
  else
    fail "$1: expected typed code $2, raw error: $(mcp_error_text "$3" | cut -c1-700) (HTTP ${4:-$MCP_CODE})"
  fi
}

# assert_mcp_not_code <what> <typed code> <body file>
assert_mcp_not_code() {
  if mcp_has_code "$3" "$2"; then
    fail "$1: unexpectedly carries $2, raw error: $(mcp_error_text "$3" | cut -c1-700)"
  else
    pass "$1: does not carry $2"
  fi
}

# assert_listed / assert_not_listed <what> <tools list label> <tool name>: exact name match in $WORK/tools-<label>.txt
assert_listed() {
  if grep -qx -- "$3" "$WORK/tools-$2.txt" 2>/dev/null; then pass "$1"; else fail "$1: '$3' is not in $WORK/tools-$2.txt"; fi
}
assert_not_listed() {
  if grep -qx -- "$3" "$WORK/tools-$2.txt" 2>/dev/null; then fail "$1: '$3' is in $WORK/tools-$2.txt"; else pass "$1"; fi
}

# assert_update_ok <what> <body file> <schedule id>: success with exactly the three documented keys
assert_update_ok() {
  if jq -e '(.result | objects) and (.result.isError != true) and (.error == null)' "$2" >/dev/null 2>&1; then
    au_res=$(jq -c '.result.content[0].text | fromjson' "$2" 2>/dev/null)
    assert_eq "$1: result keys" "$(printf '%s' "$au_res" | jq -c 'keys' 2>/dev/null)" '["project_id","schedule_id","status"]'
    assert_eq "$1: result project_id" "$(printf '%s' "$au_res" | jq -r '.project_id // empty' 2>/dev/null)" "$PROJECT"
    assert_eq "$1: result schedule_id" "$(printf '%s' "$au_res" | jq -r '.schedule_id // empty' 2>/dev/null)" "$3"
    assert_eq "$1: result status" "$(printf '%s' "$au_res" | jq -r '.status // empty' 2>/dev/null)" "updated"
  else
    fail "$1: not a successful tools/call (HTTP $MCP_CODE), raw: $(head -c 700 "$2" | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------- schedule + runtime-policy helpers

schedule_json() { fm project schedule list --project-id "$PROJECT" --json 2>/dev/null; }
sched_row() { schedule_json | jq -c --arg id "$1" '[.schedules[]? | select(.schedule_id == $id)][0] // empty' 2>/dev/null; }
sched_count() { schedule_json | jq '[.schedules[]?] | length' 2>/dev/null; }

# assert_sched <what> <schedule id> <jq filter over the row> <expected>: the CLI listing shows the value (bounded poll: the read
# model may trail an accepted command by a moment)
assert_sched() {
  as_end=$(($(date +%s) + SETTLE_SECS)); as_got=""; as_row=""
  while :; do
    as_row=$(sched_row "$2")
    as_got=$(printf '%s' "${as_row:-null}" | jq -r "$3" 2>/dev/null)
    [ "$as_got" = "$4" ] && break
    [ "$(date +%s)" -lt "$as_end" ] || break
    sleep 1
  done
  if [ "$as_got" = "$4" ]; then pass "list --json: $1 (= $4)"; else fail "list --json: $1: expected '$4', got '$as_got'; row: $(printf '%s' "$as_row" | cut -c1-500)"; fi
}

# sched_stable <row json>: the row without the fields computed at read time
sched_stable() { printf '%s' "$1" | jq -S -c 'del(.next_fire_at)' 2>/dev/null; }

# writes_now: the live node's allow_workflow_writes as the harness node sees it (true | false | nil), empty when unreadable
writes_now() {
  rpc 'IO.puts("WRITES-NOW " <> inspect(Keyword.get(Application.get_env(:foreman_server, :mcp, []), :allow_workflow_writes)))' \
    | sed -n 's/^WRITES-NOW //p' | tail -n 1
}

# set_writes <true|false>: the runtime toggle. Dispatch.components/0 and Policy.authorized?/1 read the env on every request
# (mcp.ex __components__), so the next tools/list and tools/call see it without a restart.
set_writes() {
  rpc "Application.put_env(:foreman_server, :mcp, Keyword.put(Application.get_env(:foreman_server, :mcp, []), :allow_workflow_writes, $1)); IO.puts(\"WRITES-SET \" <> inspect(Keyword.get(Application.get_env(:foreman_server, :mcp), :allow_workflow_writes)))" \
    | sed -n 's/^WRITES-SET //p' | tail -n 1
}

# need_writes_on <step>: precondition immediately before a step that needs the write gate open (foreman-azc2o). 0 holds;
# otherwise UNVERIFIED and 1.
need_writes_on() {
  nw=$(writes_now)
  if [ "$nw" = true ]; then return 0; fi
  unverified "$1" "precondition not met: allow_workflow_writes is '${nw:-unreadable}' on the node, not true"
  return 1
}

# need_schedule_active <step> <sid>: the schedule the step updates exists and is active, right now
need_schedule_active() {
  na=$(sched_row "$2" | jq -r '.status // empty' 2>/dev/null)
  if [ "$na" = active ]; then return 0; fi
  unverified "$1" "precondition not met: schedule '$2' is '${na:-absent}' in the CLI listing, not active"
  return 1
}

# update_step <what> <arguments json>: writes on + schedule active (UNVERIFIED and return 1 when not), then the tools/call
update_step() {
  need_writes_on "$1" || return 1
  need_schedule_active "$1" "$SID" || return 1
  mcp_call foreman_schedule_update "$2" "update: $1"
  note "update $1 -> HTTP $MCP_CODE $(head -c 300 "$MCP_BODY" | tr '\n' ' ')"
}

# ---------------------------------------------------------------- the stack

say "setup: scratch repo, database, server (MCP on, workflow writes on by dev config), project"
setup_stack
register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
note "project $PROJECT registered; MCP endpoint $API/mcp; review analysis off (E2E_EXTRA_ENV=$E2E_EXTRA_ENV)"

# ---------------------------------------------------------------- schedule created by the CLI

say "CLI: create the schedule the MCP tool will update (--every 1h: never fires)"
S_NAME="e2e-mcp-orig-$SUFFIX"
S_PROMPT="ORIGINAL-PROMPT-$SUFFIX"
if s_out=$(fm project schedule create --project-id "$PROJECT" --name "$S_NAME" --every 1h --workflow edit \
    --idempotency-key "e2e-mcp-sched-$SUFFIX" --prompt "$S_PROMPT" 2>"$WORK/sched-create.err.log"); then
  SID=$(printf '%s' "$s_out" | sed -n 's/^created schedule \([^ ]*\) in project .*$/\1/p')
  assert_eq "CLI says created" "$s_out" "created schedule $SID in project $PROJECT"
else
  fail "schedule create rejected (the workflow 'edit' must be installed): $(cat "$WORK/sched-create.err.log") $s_out"
fi
if [ -z "$SID" ]; then
  unverified "every MCP check" "no schedule could be created through the CLI, so there is nothing to update"
  summary
  exit $?
fi
assert_sched "created schedule is active" "$SID" '.status // empty' "active"
assert_sched "created schedule name" "$SID" '.name // empty' "$S_NAME"
assert_sched "created schedule prompt" "$SID" '.prompt // empty' "$S_PROMPT"
assert_sched "created schedule spec every" "$SID" '.spec.every // empty' "1h"
assert_sched "created schedule workflow" "$SID" '.workflow // empty' "edit"
note "schedule row: $(sched_row "$SID")"

# ---------------------------------------------------------------- MCP session

say "MCP: initialize the session"
if ! mcp_open; then
  unverified "every MCP check" "the /mcp endpoint gave no session"
  summary
  exit $?
fi

# ---------------------------------------------------------------- (a) advertised

say "(a) tools/list advertises foreman_schedule_update"
if mcp_tool_names writes-on; then
  m_on=$(cat "$WORK/tools-writes-on.txt")
  note "$(printf '%s\n' "$m_on" | wc -l | tr -d ' ') tools advertised with writes on"
  assert_listed "tools/list (writes on) lists foreman_schedule_update" writes-on foreman_schedule_update
  for t in foreman_schedule_list foreman_schedule_create foreman_schedule_pause foreman_schedule_resume foreman_schedule_delete; do
    assert_listed "tools/list (writes on) lists $t" writes-on "$t"
  done
  # the schema the tool advertises: required ids, additionalProperties false
  mcp_rpc tools/list '{}' "tools/list (schema of update)"
  assert_eq "update's advertised required arguments" "$(jq -c '[.result.tools[]? | select(.name == "foreman_schedule_update") | .inputSchema.required[]?] | sort' "$MCP_BODY" 2>/dev/null)" '["project_id","schedule_id"]'
else
  fail "tools/list failed with writes on"
  unverified "(b) (c) (d) (e)" "tools/list did not answer"
  summary
  exit $?
fi

# ---------------------------------------------------------------- (b) write tool

say "(b) foreman_schedule_update is a write tool: writes off drops it, and a call behaves like foreman_schedule_create"
b_ok=1
b_start=$(writes_now)
if [ "$b_start" != true ]; then
  unverified "(b) writes-off checks" "precondition not met: allow_workflow_writes is '${b_start:-unreadable}' on the node before the toggle (dev config should have it true)"
  b_ok=0
fi
WT_FILE="$WORK/write-tools.txt"
rpc 'ForemanServer.MCP.Policy.write_tools() |> Enum.each(&IO.puts("WT " <> &1))' | sed -n 's/^WT //p' | sort -u > "$WT_FILE"
if [ ! -s "$WT_FILE" ]; then
  unverified "(b) the dropped set is exactly Policy.write_tools()" "could not read ForemanServer.MCP.Policy.write_tools() from the node"
  b_ok=0
fi
if [ "$b_ok" = 1 ]; then
  b_count_before=$(sched_count)
  b_row_before=$(sched_stable "$(sched_row "$SID")")
  b_set=$(set_writes false)
  if [ "$b_set" != false ]; then
    fail "toggling allow_workflow_writes off did not take effect (node says '${b_set:-no answer}')"
    set_writes true >/dev/null
    b_ok=0
  fi
fi
if [ "$b_ok" = 1 ]; then
  # precondition immediately before the dependent step: the node really has writes off now
  if [ "$(writes_now)" != false ]; then
    unverified "(b) writes-off tools/list and calls" "precondition not met: writes are not off on the node right after the toggle"
    set_writes true >/dev/null
    b_ok=0
  fi
fi
if [ "$b_ok" = 1 ]; then
  if mcp_tool_names writes-off; then
    comm -23 "$WORK/tools-writes-on.txt" "$WORK/tools-writes-off.txt" > "$WORK/tools-dropped.txt"
    comm -12 "$WORK/tools-writes-on.txt" "$WT_FILE" > "$WORK/tools-expected-dropped.txt"
    comm -13 "$WORK/tools-writes-on.txt" "$WORK/tools-writes-off.txt" > "$WORK/tools-added.txt"
    note "$(wc -l < "$WORK/tools-dropped.txt" | tr -d ' ') tools dropped by switching writes off; Policy.write_tools() has $(wc -l < "$WT_FILE" | tr -d ' ')"
    assert_eq "writes off: tools/list drops exactly the advertised write tools" "$(tr '\n' ' ' < "$WORK/tools-dropped.txt")" "$(tr '\n' ' ' < "$WORK/tools-expected-dropped.txt")"
    assert_eq "writes off: no tool appears that was not advertised before" "$(tr '\n' ' ' < "$WORK/tools-added.txt")" ""
    assert_not_listed "writes off: foreman_schedule_update is not advertised" writes-off foreman_schedule_update
    assert_listed "writes off: foreman_schedule_list (a read tool) is still advertised" writes-off foreman_schedule_list
    for t in foreman_schedule_create foreman_schedule_pause foreman_schedule_resume foreman_schedule_delete; do
      assert_not_listed "writes off: $t is not advertised either" writes-off "$t"
    done
  else
    fail "tools/list failed with writes off"
  fi

  # the call of a write tool while writes are off: update and create must answer alike. Expected [INFERENCE from the code, not
  # asserted]: the tool is not in Dispatch.components/0, so Anubis answers invalid_params "Tool not found: <tool>"
  # (handlers/tools.ex); a stale tools list would instead reach Dispatch.call -> POLICY_REFUSED. Either way both must match.
  mcp_call foreman_schedule_update "$(jq -nc --arg p "$PROJECT" --arg s "$SID" --arg n "WRITES-OFF-$SUFFIX" '{project_id: $p, schedule_id: $s, name: $n}')" "writes-off update"
  b_upd_body=$MCP_BODY; b_upd_code=$MCP_CODE
  mcp_call foreman_schedule_create "$(jq -nc --arg p "$PROJECT" --arg n "WRITES-OFF-CREATE-$SUFFIX" --arg pr "never created" '{project_id: $p, name: $n, prompt: $pr, workflow: "edit", every: "1h"}')" "writes-off create"
  b_cre_body=$MCP_BODY; b_cre_code=$MCP_CODE
  note "writes off, update -> HTTP $b_upd_code: $(mcp_error_text "$b_upd_body" | cut -c1-400)"
  note "writes off, create -> HTTP $b_cre_code: $(mcp_error_text "$b_cre_body" | cut -c1-400)"
  b_norm_upd=$(jq -S -c '(.error // (if .result.isError == true then .result else null end)) // {"no_error_in_body": .}' "$b_upd_body" 2>/dev/null | sed 's/foreman_schedule_update/<TOOL>/g')
  b_norm_cre=$(jq -S -c '(.error // (if .result.isError == true then .result else null end)) // {"no_error_in_body": .}' "$b_cre_body" 2>/dev/null | sed 's/foreman_schedule_create/<TOOL>/g')
  if [ -z "$b_norm_upd" ] || [ -z "$b_norm_cre" ]; then fail "writes off: an answer is not JSON-RPC JSON (update: '$(head -c 200 "$b_upd_body")', create: '$(head -c 200 "$b_cre_body")')"; fi
  assert_eq "writes off: update and create answer with the same HTTP status" "$b_upd_code" "$b_cre_code"
  assert_not_has "writes off: update is refused, not executed" "$b_norm_upd" "no_error_in_body"
  assert_not_has "writes off: create is refused, not executed" "$b_norm_cre" "no_error_in_body"
  assert_eq "writes off: update's error is exactly create's error (tool name aside)" "$b_norm_upd" "$b_norm_cre"
  assert_eq "writes off: the schedule is untouched (CLI listing)" "$(sched_stable "$(sched_row "$SID")")" "$b_row_before"
  assert_eq "writes off: no schedule was created or removed" "$(sched_count)" "$b_count_before"

  b_back=$(set_writes true)
  assert_eq "writes restored on the node" "$b_back" "true"
  if mcp_tool_names writes-restored; then
    assert_eq "writes back on: tools/list is the original list again" "$(tr '\n' ' ' < "$WORK/tools-writes-restored.txt")" "$(tr '\n' ' ' < "$WORK/tools-writes-on.txt")"
  else
    fail "tools/list failed after restoring writes"
  fi
fi

# ---------------------------------------------------------------- (c) updates

say "(c) update name, prompt, every, cron of the CLI-created schedule over MCP"
row0=$(sched_row "$SID")
note "before: $row0"
NEW_NAME="e2e-mcp-renamed-$SUFFIX"
NEW_PROMPT="UPDATED-PROMPT-$SUFFIX"

if update_step "(c) name" "$(jq -nc --arg p "$PROJECT" --arg s "$SID" --arg n "$NEW_NAME" '{project_id: $p, schedule_id: $s, name: $n}')"; then
  assert_update_ok "update name" "$MCP_BODY" "$SID"
  assert_sched "name changed" "$SID" '.name // empty' "$NEW_NAME"
  assert_sched "prompt untouched by a name update" "$SID" '.prompt // empty' "$S_PROMPT"
  assert_sched "spec untouched by a name update" "$SID" '.spec.every // empty' "1h"
  assert_sched "workflow untouched by a name update" "$SID" '.workflow // empty' "edit"
fi

if update_step "(c) prompt" "$(jq -nc --arg p "$PROJECT" --arg s "$SID" --arg t "$NEW_PROMPT" '{project_id: $p, schedule_id: $s, prompt: $t}')"; then
  assert_update_ok "update prompt" "$MCP_BODY" "$SID"
  assert_sched "prompt changed" "$SID" '.prompt // empty' "$NEW_PROMPT"
  assert_sched "name kept by a prompt update" "$SID" '.name // empty' "$NEW_NAME"
fi

if update_step "(c) every" "$(jq -nc --arg p "$PROJECT" --arg s "$SID" '{project_id: $p, schedule_id: $s, every: "2h"}')"; then
  assert_update_ok "update every" "$MCP_BODY" "$SID"
  assert_sched "spec every changed" "$SID" '.spec.every // empty' "2h"
  assert_sched "spec has no cron after every" "$SID" '.spec.cron // "absent"' "absent"
  assert_sched "prompt kept by a spec update" "$SID" '.prompt // empty' "$NEW_PROMPT"
  assert_sched "schedule still active after a spec update" "$SID" '.status // empty' "active"
fi

if update_step "(c) cron" "$(jq -nc --arg p "$PROJECT" --arg s "$SID" '{project_id: $p, schedule_id: $s, cron: "0 9 * * 1-5"}')"; then
  assert_update_ok "update cron" "$MCP_BODY" "$SID"
  assert_sched "spec cron changed" "$SID" '.spec.cron // empty' "0 9 * * 1-5"
  assert_sched "spec has no every after cron (the spec is replaced whole)" "$SID" '.spec.every // "absent"' "absent"
  assert_sched "name kept by a cron update" "$SID" '.name // empty' "$NEW_NAME"
fi

ALL_NAME="e2e-mcp-all-$SUFFIX"
ALL_PROMPT="ALL-AT-ONCE-PROMPT-$SUFFIX"
if update_step "(c) name + prompt + every in one call" "$(jq -nc --arg p "$PROJECT" --arg s "$SID" --arg n "$ALL_NAME" --arg t "$ALL_PROMPT" '{project_id: $p, schedule_id: $s, name: $n, prompt: $t, every: "3h"}')"; then
  assert_update_ok "update name+prompt+every" "$MCP_BODY" "$SID"
  assert_sched "name changed (one call)" "$SID" '.name // empty' "$ALL_NAME"
  assert_sched "prompt changed (one call)" "$SID" '.prompt // empty' "$ALL_PROMPT"
  assert_sched "spec every changed (one call)" "$SID" '.spec.every // empty' "3h"
  assert_sched "spec has no cron after every (one call)" "$SID" '.spec.cron // "absent"' "absent"
  assert_sched "workflow still edit" "$SID" '.workflow // empty' "edit"
fi

# ---------------------------------------------------------------- (d) argument refusals

say "(d) no change fields -> the aggregate's typed missing_or_invalid; bad arguments -> INVALID_PARAMS"
if need_writes_on "(d) refusals" && need_schedule_active "(d) refusals" "$SID"; then
  d_before=$(sched_stable "$(sched_row "$SID")")

  mcp_call foreman_schedule_update "$(jq -nc --arg p "$PROJECT" --arg s "$SID" '{project_id: $p, schedule_id: $s}')" "update with no fields"
  note "no fields -> HTTP $MCP_CODE: $(mcp_error_text "$MCP_BODY" | cut -c1-400)"
  assert_mcp_code "update with only project_id and schedule_id" "missing_or_invalid" "$MCP_BODY" "$MCP_CODE"
  # tools.ex does no pre-validation: this is the Schedule aggregate's refusal, not an argument error
  assert_mcp_not_code "update with only project_id and schedule_id" "INVALID_PARAMS" "$MCP_BODY"
  assert_eq "no-field update changed nothing" "$(sched_stable "$(sched_row "$SID")")" "$d_before"

  mcp_call foreman_schedule_update "$(jq -nc --arg p "$PROJECT" --arg n "no-schedule-id" '{project_id: $p, name: $n}')" "update without schedule_id"
  note "no schedule_id -> HTTP $MCP_CODE: $(mcp_error_text "$MCP_BODY" | cut -c1-400)"
  assert_mcp_code "update without schedule_id" "INVALID_PARAMS" "$MCP_BODY" "$MCP_CODE"
  assert_has "update without schedule_id names the missing argument" "$(mcp_error_text "$MCP_BODY")" "schedule_id"

  mcp_call foreman_schedule_update "$(jq -nc --arg p "$PROJECT" --arg s "$SID" '{project_id: $p, schedule_id: $s, bogus_argument: "x"}')" "update with an unknown argument"
  note "unknown argument -> HTTP $MCP_CODE: $(mcp_error_text "$MCP_BODY" | cut -c1-400)"
  assert_mcp_code "update with an unknown argument" "INVALID_PARAMS" "$MCP_BODY" "$MCP_CODE"
  assert_has "update with an unknown argument names it" "$(mcp_error_text "$MCP_BODY")" "bogus_argument"
  assert_eq "argument refusals changed nothing" "$(sched_stable "$(sched_row "$SID")")" "$d_before"
fi

# ---------------------------------------------------------------- (e) deleted / unknown

say "(e) after a CLI delete: schedule_deleted; unknown schedule: schedule_not_found"
if need_schedule_active "(e) delete via the CLI" "$SID"; then
  if e_out=$(fm project schedule delete --project-id "$PROJECT" --id "$SID" 2>"$WORK/sched-delete.err.log"); then
    assert_eq "CLI delete output" "$e_out" "deleted schedule $SID in project $PROJECT"
  else
    fail "schedule delete rejected: $(cat "$WORK/sched-delete.err.log") $e_out"
  fi
  assert_sched "deleted schedule is gone from the listing" "$SID" '.status // "absent"' "absent"

  if need_writes_on "(e) update of a deleted schedule"; then
    mcp_call foreman_schedule_update "$(jq -nc --arg p "$PROJECT" --arg s "$SID" '{project_id: $p, schedule_id: $s, name: "after-delete"}')" "update of a deleted schedule"
    note "deleted -> HTTP $MCP_CODE: $(mcp_error_text "$MCP_BODY" | cut -c1-400)"
    assert_mcp_code "update of a CLI-deleted schedule" "schedule_deleted" "$MCP_BODY" "$MCP_CODE"
    assert_eq "the deleted schedule did not come back" "$(sched_row "$SID")" ""
  fi
fi

if need_writes_on "(e) update of an unknown schedule"; then
  UNKNOWN_SID="sch-unknown-$SUFFIX"
  mcp_call foreman_schedule_update "$(jq -nc --arg p "$PROJECT" --arg s "$UNKNOWN_SID" '{project_id: $p, schedule_id: $s, name: "x"}')" "update of an unknown schedule"
  note "unknown -> HTTP $MCP_CODE: $(mcp_error_text "$MCP_BODY" | cut -c1-400)"
  assert_mcp_code "update of an unknown schedule" "schedule_not_found" "$MCP_BODY" "$MCP_CODE"
  assert_eq "no schedule was created by the unknown update" "$(sched_count)" "0"
fi

summary
exit $?
