#!/usr/bin/env bash
# scripts/e2e/redaction_value_live.sh
#
# Live proof (bead foreman-ngky4) that a project secret whose NAME gives nothing away is redacted BY VALUE on every
# durable surface, end to end, with a REAL pi agent and a real coordinator: it stores `DEPLOY_TARGET` (a unique
# 22-character value, random per run) and `DEPLOY_REGION` (a unique 7-character value: below the documented 8-character
# floor ProjectEnvironment.min_stored_secret_chars/0, so it is NOT redacted in persisted text), then
#
#   1 secrets    sets both through `foreman project secret set` (value on stdin, never argv);
#   2 memory     a pi agent obtains the value itself (`printenv DEPLOY_TARGET`: stored secrets are injected into the agent's
#                environment, and the value is in NO prompt, bead or task text) and calls the MCP tool
#                foreman_project_memory_write with it in the topic body AND description. Asserted from the agent's OWN
#                transcript that the tool input really carried the value; then the topic file, `memory read`, `memory list`,
#                the MEMORY.md index, the ProjectMemoryWritten event rows and the thread transcript show `[REDACTED]` only;
#   3 chat       an operator chat message carrying both values: the persisted conversation (CoordinatorMessageAppended
#                events and `project chat --history N --format json`) holds the marker only for the 22-character value (the
#                7-character one stays, per the floor). The clause "a coordinator reply containing the value" is printed
#                UNVERIFIED: forcing a reply to echo a value depends on model compliance (the coordinator only ever sees the
#                redacted message), so only what is checkable is asserted;
#   4 context    a thread started afterwards from a bead whose text does NOT contain the value: its archived
#                <repo>/.foreman/sessions/run/<run>/project-context.md and `foreman project context --format json` carry the
#                marker, not the value; then a hand edit appends the value to the topic file, `foreman project memory sync`
#                is run, and the file and `memory read` are redacted again;
#   5 byte search (BEFORE cleanup deletes the database and the work dir; exact commands and counts are printed): the
#                22-character value must have ZERO hits in the Postgres events table (position(convert_to(V,'UTF8') in
#                data|metadata)), a whole-database pg_dump, the server log(s) ($SERVER_LOG and
#                $WORK/home/.foreman/logs), the memory dir, the run archive dir, the runs dir, the webhook capture and every
#                other file under the work dir. EXCLUDED, because they legitimately hold it: the 0600 secret store
#                ($WORK/home/.foreman/secrets) and the agent's own session files ($WORK/pi-agent/sessions, $WORK/home/.pi).
#                The 7-character value must be FOUND in the secret store and in the unredacted persisted text (events table,
#                memory dir). Every location is reported and the script keeps going: a hit where the value must not be is a
#                FAIL printed with file and count. NOTE: a hit in the server log is a real finding (it was one until
#                foreman-mw5rz: free-text params reached the Phoenix debug log; `config :phoenix, :filter_parameters` now
#                hides them, see docs/user-guide.md "Secrets"); it is reported as it is, never hidden or special-cased.
#
# Provider: pi only (owner-approved scope; claude follows later). E2E_PROVIDER=claude exits 2 with a message.
#
# Run from a devbox shell:
#
#     devbox run -- bash scripts/e2e/redaction_value_live.sh
#
# Environment (all optional): E2E_PROVIDER (pi), E2E_AGENT_MODEL (default E2E_MODEL, minimax/MiniMax-M2.7-highspeed),
# E2E_AGENT_ATTEMPTS (default 2: the first run/thread kickoff intermittently fails, foreman-azc2o; the memory-writing bead is
# retried once with a fresh bead), E2E_WORK_DIR (default <repo>/tmp/e2e-redaction-value; never /tmp), E2E_DB_NAME (default
# foreman_e2e_redaction_value), E2E_PORT (4840), E2E_HOOK_PORT (4940), E2E_RUN_TIMEOUT, E2E_POLL_SECS, E2E_TRANSCRIPT,
# E2E_KEEP=1 (keep server, database and work dir; drop the database yourself afterwards), and the E2E_PG_* / E2E_API_TOKEN
# settings of scripts/e2e/claude_projects/lib.sh. Needs psql (and pg_dump for the whole-database sweep), pi, br, go, elixir.
# A review analysis never runs (E2E_REVIEW_ANALYSIS=0): no reviewer agent, no gap beads.
#
# Expected runtime: 6-10 minutes (server boot + restart, three pi runs/turns, byte search). Nothing else heavy should run:
# a load average of 40-70 broke pi server boots in other harnesses.
#
# Output / exit status: PASS (observed and as expected), FAIL (observed and wrong: exit 3), UNVERIFIED (could not be
# observed on this run: a run that failed to start (foreman-azc2o), a model that dropped the value from the tool call, ...
# never a pass, never a fail). 0 all asserted checks passed, 1 environment problem, 2 setup failed / unsupported provider,
# 3 an assertion failed.
#
# The CLI outputs this script keeps live in $WORK/out (excluded from the byte search). Because a leak would put the value
# into them, a failing run's evidence under tmp/e2e-evidence (copied by the shared harness) may then contain it too.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-rv}
E2E_WORK_DIR=${E2E_WORK_DIR:-$ROOT/tmp/e2e-redaction-value}
E2E_DB_NAME=${E2E_DB_NAME:-foreman_e2e_redaction_value}
E2E_PORT=${E2E_PORT:-4840}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4940}
E2E_PROVIDER=${E2E_PROVIDER:-pi}
E2E_AGENT_ATTEMPTS=${E2E_AGENT_ATTEMPTS:-2}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

case "$E2E_PROVIDER" in
  pi) E2E_AGENT_MODEL=${E2E_AGENT_MODEL:-$E2E_MODEL} ;;
  claude) die "E2E_PROVIDER=claude is not implemented: this harness covers the pi provider only (owner-approved scope, claude follows later); run it without E2E_PROVIDER or with E2E_PROVIDER=pi" 2 ;;
  *) die "E2E_PROVIDER must be pi (got '$E2E_PROVIDER'; claude is not implemented yet)" 1 ;;
esac
case "$E2E_AGENT_ATTEMPTS" in ''|*[!0-9]*|0) die "E2E_AGENT_ATTEMPTS must be a positive integer" 1 ;; esac

MARK='[REDACTED]'
MEM_TOPIC=deploy-notes
OUT="$WORK/out"
SECRET_DIR="$WORK/home/.foreman/secrets"
SERVER_FILE_LOGS="$WORK/home/.foreman/logs"
RUNS_DIR="$WORK/home/.foreman/runs"
MEMORY_DIR="$REPO/.foreman/memory"
ARCHIVE_DIR="$REPO/.foreman/sessions"
MEM_DELIVERED=0
MEM_RUN=""
MEM_THREAD=""

# The two values. 22 characters: `tgt-` + 18 random [a-z0-9] (no JSON/shell/regex-special characters, no word a name or
# pattern based redaction would key on). 7 characters: random [a-z0-9].
rand_alnum() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }
V22="tgt-$(rand_alnum 18)"
V7=$(rand_alnum 7)
[ "${#V22}" -eq 22 ] && [ "${#V7}" -eq 7 ] || die "could not generate the 22- and 7-character values" 2

check_environment
install_traps

# ---------------------------------------------------------------- helpers

# text_count <value> <text>: occurrences of the value in the text
text_count() { printf '%s' "$2" | grep -aoF -- "$1" | wc -l | tr -d ' '; }
# file_count <value> <file>: occurrences of the value in the file (0 when it does not exist)
file_count() { if [ -f "$2" ]; then grep -aoF -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; else echo 0; fi; }

# assert_clean <what> <value> <text>: the value does not occur in the text (the text is never echoed: it may hold the value)
assert_clean() {
  ac_n=$(text_count "$2" "$3")
  if [ "${ac_n:-0}" -eq 0 ]; then pass "$1: the value does not occur"; else fail "$1: the value occurs $ac_n time(s)"; fi
}
# assert_marked <what> <text>: the redaction marker occurs in the text
assert_marked() {
  case "$2" in *"$MARK"*) pass "$1: carries $MARK" ;; *) fail "$1: no $MARK marker (first 200 chars: $(printf '%s' "$2" | cut -c1-200))" ;; esac
}

# psql_db <database> <psql args...>: psql against ANY database of the harness's Postgres (lib.sh's psql_admin is hard-wired to `postgres`)
psql_db() {
  pd_db=$1; shift
  psql -X -q -At -v ON_ERROR_STOP=1 -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" -d "$pd_db" "$@"
}

# wait_run <run id> -> RUN_STATUS (the last `foreman run get`), RUN_JSON
wait_run() {
  wr_run=$1; wr_start=$(date +%s); wr_last=""; RUN_JSON=""
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
    case "$RUN_STATUS" in completed|failed|cancelled|blocked|stuck|deleted) return 0 ;; esac
    if [ "$(elapsed "$wr_start")" -ge "$E2E_RUN_TIMEOUT" ]; then RUN_STATUS="timeout"; return 1; fi
    sleep "$E2E_POLL_SECS"
  done
}

diagnose_run() { # <run id>
  out "   --- run projection: $(api_get "/api/runs/$1" | jq -c '.run | {status, failure_reason}' 2>/dev/null)"
  out "   --- server log (errors and warnings, last 15 lines):"
  grep -E '\[(error|warning)\]' "$SERVER_LOG" 2>/dev/null | tail -n 15 | cut -c1-300 | while IFS= read -r l; do out "   $l"; done
}

# run_for_thread <thread id> -> RUN (empty after ~120 s without a run)
run_for_thread() {
  rt_n=0; RUN=""
  while [ -z "$RUN" ] && [ "$rt_n" -lt 120 ]; do
    RUN=$(api_get "/api/threads/$1" | jq -r '.thread.run_ids[0] // empty' 2>/dev/null)
    [ -n "$RUN" ] || sleep 2
    rt_n=$((rt_n + 2))
  done
}

# agent_calls <run id> <tool name>: the tool calls the pi agent itself made (their arguments, one JSON object per line),
# from ITS OWN transcript (copied from multi_repo_agent.sh, pi branch; there it lives inside that script).
agent_calls() {
  for f in $(find "$WORK/pi-agent/sessions" -path "*$1*" -name '*.jsonl' 2>/dev/null); do
    jq -c --arg n "foreman_$2" '
      select(.type == "message" and .message.role == "assistant") | .message.content[]?
      | select(.type == "toolCall" and ((.name // "") | test($n))) | .arguments' "$f" 2>/dev/null
  done
}

# agent_results <run id> <tool name>: what each call of the tool RETURNED to the agent (its tool result text), in call order.
agent_results() {
  for f in $(find "$WORK/pi-agent/sessions" -path "*$1*" -name '*.jsonl' 2>/dev/null); do
    jq -rs --arg n "foreman_$2" '
      [.[] | select(.type == "message" and .message.role == "assistant") | .message.content[]?
        | select(.type == "toolCall" and ((.name // "") | test($n))) | .id] as $ids
      | [.[] | select(.type == "message" and .message.role == "toolResult") | .message] as $results
      | $ids[] as $id
      | ($results[] | select(.toolCallId == $id) | [.content[]? | select(.type == "text") | .text] | join("") | gsub("\n"; " "))' "$f" 2>/dev/null
  done
}

# events_dump <file>: every event of the event store, decoded, one JSON object per line (event_store_dump.exs, run on the server node)
events_dump() {
  rpc "$(cat "$ASSETS/event_store_dump.exs")" | grep '^EVIDENCE ' | cut -c10- > "$1"
  [ -s "$1" ]
}

# ---------------------------------------------------------------- setup

write_workflows() {
  mkdir -p "$WORK/workflows/prompts"
  # `task_types` must be unique across the catalog (the harness's `edit` workflow owns task/bug/chore/feature).
  {
    printf 'name: rv-memory-call\ndescription: E2E workflow of scripts/e2e/redaction_value_live.sh\ntask_types: [rv-memory-call]\n'
    # The agent only calls an MCP tool and edits nothing, so the phase declares `commit: false`. The manifest validator then
    # REQUIRES `worktree.cleanup: never` (with `cleanup: on_success` a commit:false phase with no later committing phase is
    # INVALID and the workflow is not loaded, so every bead stays :unmapped: that is what a first attempt at this script hit).
    # With `commit: true` instead, Workflow.CheckoutGuard fails the run because Foreman's own .foreman/ writes (memory
    # .gitignore, the run archive) appear in the main checkout (a foreman bead is filed from that finding).
    printf 'worktree:\n  enabled: true\n  branch: foreman/{task_id}/{run_id}\n  path: workspace\n  cleanup: never\nphases:\n'
    printf '  - name: call\n    prompt: rv-memory-call-call.md\n    provider: pi\n    models:\n      default: %s\n    commit: false\n' "$E2E_AGENT_MODEL"
  } > "$WORK/workflows/rv-memory-call.yaml"
  cat > "$WORK/workflows/prompts/rv-memory-call-call.md" <<'MD'
{{workflow_name}} :: {{phase_name}}

## Task

{{input.prompt}}

## Rules

- Use only the shell for the one `printenv` command and the MCP tool of the `foreman` MCP server that the Task names.
- Do not edit any file and do not run git.
- Reply with exactly: done
MD
}

agent_access() {
  mcp_url="$API/mcp"
  (cd "$WORK" && PI_CODING_AGENT_DIR="$WORK/pi-agent" pi mcp add foreman --url "$mcp_url" \
    --header "Authorization=Bearer $E2E_API_TOKEN" --exposure direct >"$WORK/pi-mcp-add.log" 2>&1) \
    || { tail -n 5 "$WORK/pi-mcp-add.log"; die "pi mcp add failed" 2; }
  note "pi agent dir $WORK/pi-agent has the MCP server foreman -> $mcp_url (exposure direct)"
}

# check_mcp_endpoint: foreman-cnn1l (see multi_repo_agent.sh): /mcp answered HTTP 500 on a harness-booted server.
check_mcp_endpoint() {
  mcp_code=$(curl -sS -o "$WORK/mcp-initialize.body" -w '%{http_code}' --max-time 30 -X POST "$API/mcp" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -H 'accept: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"redaction-value-e2e","version":"1"}}}')
  assert_eq "/mcp answers initialize with HTTP 200 on this harness-booted server" "$mcp_code" "200"
  assert_eq "/mcp initialize names the Foreman MCP server" "$(jq -r '.result.serverInfo.name // empty' "$WORK/mcp-initialize.body" 2>/dev/null)" "foreman-mcp"
  if [ "$mcp_code" != 200 ]; then
    out "   $(head -c 400 "$WORK/mcp-initialize.body" | tr '\n' ' ')"
    summary
    exit $?
  fi
}

setup_all() {
  # No review analysis: it would start a second agent per terminal run (and may file gap beads).
  E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0"
  setup_stack
  mkdir -p "$OUT"
  write_workflows
  agent_access
  note "restarting the server so it loads the workflow rv-memory-call"
  stop_server
  start_server
  register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
  fm project update --coordinator-provider pi --coordinator-model "$E2E_AGENT_MODEL" --thread-model "$E2E_AGENT_MODEL" \
    "$PROJECT" >"$WORK/project-update.out" 2>&1 || { cat "$WORK/project-update.out"; die "project update failed" 2; }
  note "project $PROJECT over $REPO (task provider beads); coordinator and threads on pi $E2E_AGENT_MODEL"
  check_mcp_endpoint
}

# ---------------------------------------------------------------- 1. secrets

step_secrets() {
  say "1. secrets: DEPLOY_TARGET (22 chars) and DEPLOY_REGION (7 chars) through 'project secret set' (stdin)"
  note "22-char value: $V22   7-char value: $V7   (random per run; names look nothing like secrets)"
  assert_eq "DEPLOY_TARGET value length" "${#V22}" "22"
  assert_eq "DEPLOY_REGION value length (below the 8-character floor)" "${#V7}" "7"
  if printf '%s' "$V22" | fm project secret set "$PROJECT" DEPLOY_TARGET >"$OUT/secret-set-22.out" 2>&1; then
    pass "project secret set DEPLOY_TARGET (value on stdin): $(head -c 120 "$OUT/secret-set-22.out" | tr '\n' ' ')"
  else
    fail "project secret set DEPLOY_TARGET: $(head -c 300 "$OUT/secret-set-22.out" | tr '\n' ' ')"
  fi
  if printf '%s' "$V7" | fm project secret set "$PROJECT" DEPLOY_REGION >"$OUT/secret-set-7.out" 2>&1; then
    pass "project secret set DEPLOY_REGION (value on stdin): $(head -c 120 "$OUT/secret-set-7.out" | tr '\n' ' ')"
  else
    fail "project secret set DEPLOY_REGION: $(head -c 300 "$OUT/secret-set-7.out" | tr '\n' ' ')"
  fi
  sl=$(fm project secret list --format json "$PROJECT" 2>&1)
  assert_has "secret list names DEPLOY_TARGET" "$sl" "DEPLOY_TARGET"
  assert_has "secret list names DEPLOY_REGION" "$sl" "DEPLOY_REGION"
  assert_clean "secret list (names and versions only)" "$V22" "$sl"
  assert_clean "secret list (names and versions only), 7-char value" "$V7" "$sl"
}

# ---------------------------------------------------------------- 2. an agent writes the value into project memory

# The bead text carries NO value: the agent reads it from its own environment. (archive.ex redacts the server's env
# secrets only, so a value in a prompt/bead/task text would reach request.md and TaskCreated and fail the byte search
# for the wrong reason.)
mem_bead_text() {
  printf '%s' "Step 1: run the shell command \`printenv DEPLOY_TARGET\` and note its exact output; that output is the deploy target. \
Step 2: call the MCP tool \`foreman_project_memory_write\` of the \`foreman\` MCP server exactly once with these arguments: \
project_id \"$PROJECT\", name \"$MEM_TOPIC\", description the one line \"Deploy target: \" followed by the exact printenv output, and \
content at least six full sentences of ordinary prose (more than 600 characters) about how releases of this scratch project are \
shipped and checked, mentioning the deploy target (the exact printenv output, copied verbatim, without quotes, masking or any change) \
in two different sentences. Do not shorten, mask or alter the deploy target anywhere. Do not call any other tool. Reply with exactly: done"
}

# mem_attempt: one bead -> thread -> run; sets MEM_THREAD, MEM_RUN, MEM_WHY (why it did not deliver); returns 0 when a
# foreman_project_memory_write call that carried the value was observed in the agent's own transcript.
mem_attempt() {
  MEM_WHY=""
  new_bead "e2e-$SUFFIX memory note" "$(mem_bead_text)" rv-memory-call
  [ -n "${BEAD_ID:-}" ] || { MEM_WHY="br create returned no bead id"; return 1; }
  note "bead $BEAD_ID (type rv-memory-call, no value in its text)"
  thread_for_bead "$BEAD_ID" 180
  if [ -z "$THREAD" ]; then MEM_WHY="no thread appeared for bead $BEAD_ID within 180s (BeadsWatcher did not import it)"; return 1; fi
  MEM_THREAD=$THREAD
  run_for_thread "$MEM_THREAD"
  MEM_RUN=$RUN
  if [ -z "$MEM_RUN" ]; then MEM_WHY="thread $MEM_THREAD has no run after 120s"; return 1; fi
  note "thread $MEM_THREAD run $MEM_RUN"
  t0=$(date +%s)
  wait_run "$MEM_RUN"
  note "terminal status '$RUN_STATUS' after $(elapsed "$t0")s"
  # precondition (foreman-azc2o) immediately before the transcript reads: the run must really have completed
  if [ "$RUN_STATUS" != completed ]; then
    MEM_WHY="run $MEM_RUN ended '$RUN_STATUS', not completed (foreman-azc2o kickoff failure?)"
    diagnose_run "$MEM_RUN"
    return 1
  fi
  MEM_CALLS=$(agent_calls "$MEM_RUN" project_memory_write)
  MEM_VCALLS=$(printf '%s\n' "$MEM_CALLS" | jq -c --arg v "$V22" 'select((.content // "" | tostring) | contains($v))' 2>/dev/null)
  if [ -z "$MEM_VCALLS" ]; then
    MEM_WHY="run $MEM_RUN completed but none of its $(printf '%s\n' "$MEM_CALLS" | grep -c .) foreman_project_memory_write call(s) carried the value in content (model dropped or masked it)"
    return 1
  fi
  return 0
}

step_agent_memory() {
  say "2. a real pi agent writes the value into project memory (MCP foreman_project_memory_write); every durable form is redacted"
  ma=1; MEM_DELIVERED=0; last_why=""
  while [ "$ma" -le "$E2E_AGENT_ATTEMPTS" ]; do
    note "attempt $ma of $E2E_AGENT_ATTEMPTS"
    if mem_attempt; then MEM_DELIVERED=1; break; fi
    last_why=$MEM_WHY
    note "attempt $ma: $MEM_WHY"
    ma=$((ma + 1))
  done
  if [ "$MEM_DELIVERED" != 1 ]; then
    unverified "agent-written memory redaction (topic file, memory read/list, MEMORY.md, ProjectMemoryWritten, thread transcript)" "no run delivered the value in a foreman_project_memory_write call after $E2E_AGENT_ATTEMPTS attempt(s): $last_why"
    return 0
  fi

  pass "the agent's own transcript shows foreman_project_memory_write called with the 22-char value in content (run $MEM_RUN)"
  last_call=$(printf '%s\n' "$MEM_VCALLS" | tail -n 1)
  assert_eq "the call targeted this project and topic" "$(printf '%s' "$last_call" | jq -r '[.project_id, .name] | join(" ")')" "$PROJECT $MEM_TOPIC"
  exp_body=$(printf '%s' "$last_call" | jq -r --arg v "$V22" '(.content | tostring | split($v) | length) - 1')
  exp_desc=$(printf '%s' "$last_call" | jq -r --arg v "$V22" '((.description // "") | tostring | split($v) | length) - 1')
  note "the tool input carried the value $exp_body time(s) in content and $exp_desc time(s) in description; content is $(printf '%s' "$last_call" | jq -r '.content | tostring | length') chars"
  [ "$exp_desc" -ge 1 ] || unverified "the value in the memory DESCRIPTION (index hook)" "the model left the value out of the description argument; only the body path is exercised"

  result=$(agent_results "$MEM_RUN" project_memory_write | tail -n 1)
  red=$(printf '%s' "$result" | jq -r '.redactions // empty' 2>/dev/null)
  out "   tool result the agent got: $(printf '%s' "$result" | cut -c1-240)"
  if [ -z "$red" ]; then
    unverified "the tool result's redactions count" "the last foreman_project_memory_write result is not the JSON write result (rejected or unreadable): the on-disk checks below still decide"
  elif [ "$red" -ge $((exp_body + exp_desc)) ] && [ $((exp_body + exp_desc)) -ge 1 ]; then
    pass "the tool result reports redactions=$red (>= the $((exp_body + exp_desc)) occurrence(s) the agent sent)"
  else
    fail "the tool result reports redactions=$red, the agent sent $((exp_body + exp_desc)) occurrence(s)"
  fi

  tf="$MEMORY_DIR/$MEM_TOPIC.md"
  raw=$(cat "$tf" 2>/dev/null)
  [ -n "$raw" ] || fail "topic file $tf missing or empty"
  assert_clean "topic file $MEM_TOPIC.md on disk" "$V22" "$raw"
  assert_marked "topic file $MEM_TOPIC.md on disk" "$raw"
  mread=$(fm project memory read --name "$MEM_TOPIC" "$PROJECT" 2>&1)
  assert_clean "foreman project memory read" "$V22" "$mread"
  assert_marked "foreman project memory read" "$mread"
  mlist=$(fm project memory list --format json "$PROJECT" 2>&1)
  assert_has "foreman project memory list names the topic" "$mlist" "$MEM_TOPIC"
  assert_clean "foreman project memory list" "$V22" "$mlist"
  idx=$(cat "$MEMORY_DIR/MEMORY.md" 2>/dev/null)
  assert_has "MEMORY.md index lists the topic" "$idx" "$MEM_TOPIC"
  assert_clean "MEMORY.md index" "$V22" "$idx"
  if [ "$exp_desc" -ge 1 ]; then assert_marked "MEMORY.md index (the description hook)" "$idx"; fi

  if events_dump "$OUT/events-after-memory.jsonl"; then
    rows=$(jq -c --arg n "$MEM_TOPIC" 'select(.type == "ProjectMemoryWritten" and .data.name == $n)' "$OUT/events-after-memory.jsonl")
    assert_true "ProjectMemoryWritten event row(s) exist for $MEM_TOPIC ($(printf '%s\n' "$rows" | grep -c .))" test -n "$rows"
    assert_clean "ProjectMemoryWritten row(s) (decoded data and metadata)" "$V22" "$rows"
    if [ "$exp_desc" -ge 1 ]; then assert_marked "ProjectMemoryWritten row description" "$(printf '%s\n' "$rows" | jq -r '.data.description // empty')"; fi
  else
    fail "the event store dump (event_store_dump.exs through rpc) printed no events"
  fi

  # the thread transcript an operator sees carries what the agent's tools printed (`printenv DEPLOY_TARGET`)
  tr_json=$(api_get "/api/threads/$MEM_THREAD/transcript" 2>/dev/null)
  if [ -n "$tr_json" ]; then
    assert_clean "thread transcript API of the agent's thread" "$V22" "$tr_json"
  else
    unverified "thread transcript API of the agent's thread" "GET /api/threads/$MEM_THREAD/transcript returned nothing"
  fi
}

# ---------------------------------------------------------------- 3. operator chat

step_chat() {
  say "3. operator chat message carrying both values: the persisted conversation holds the marker only (22 chars) / the floor value (7 chars)"
  msg="For the record: the deploy target for this project is $V22 and the deploy region code is $V7. Reply with the single word ACK. Do not start any thread."
  note "message sent through stdin (never argv): the project's coordinator (pi) answers; its reply is not asserted to contain the value"
  chat_out=$(printf '%s\n' "$msg" | fm project chat --timeout 4m --format json "$PROJECT" 2>"$OUT/chat.err"); chat_rc=$?
  printf '%s' "$chat_out" > "$OUT/chat-reply.json"
  note "chat exit=$chat_rc, reply: $(printf '%s' "$chat_out" | jq -r '[.[]? | .text] | join(" ")' 2>/dev/null | cut -c1-160)"
  [ "$chat_rc" -eq 0 ] || note "chat exited $chat_rc ($(head -c 200 "$OUT/chat.err" | tr '\n' ' ')); the conversation is read back regardless"

  hist=$(fm project chat --history 30 --format json "$PROJECT" 2>&1)
  printf '%s' "$hist" > "$OUT/chat-history.json"
  opmsg=$(printf '%s' "$hist" | jq -r '[.[]? | select(.role == "operator") | .text] | join("\n")' 2>/dev/null)
  if [ -n "$opmsg" ]; then pass "chat --history N --format json lists the operator message"; else fail "chat --history lists no operator message"; fi
  assert_clean "chat --history (the whole persisted conversation)" "$V22" "$hist"
  assert_marked "chat --history operator message" "$opmsg"
  assert_has "chat --history operator message: the 7-char value stays (documented 8-character floor)" "$opmsg" "$V7"

  if events_dump "$OUT/events-after-chat.jsonl"; then
    conv=$(jq -c 'select(.type == "CoordinatorMessageAppended")' "$OUT/events-after-chat.jsonl")
    optext=$(printf '%s\n' "$conv" | jq -r 'select(.data.role == "operator") | .data.text')
    if [ -n "$optext" ]; then pass "CoordinatorMessageAppended event of the operator message exists"; else fail "no operator CoordinatorMessageAppended event"; fi
    assert_clean "CoordinatorMessageAppended events (every role, decoded data and metadata)" "$V22" "$conv"
    assert_marked "operator CoordinatorMessageAppended event" "$optext"
    assert_has "operator CoordinatorMessageAppended event: the 7-char value stays (floor)" "$optext" "$V7"
  else
    fail "the event store dump (event_store_dump.exs through rpc) printed no events"
  fi
  assert_clean "the coordinator's reply as printed by 'project chat'" "$V22" "$chat_out"
  unverified "a coordinator reply that contains the value (conversation redaction of the REPLY)" \
    "not forced: the operator message is redacted before the event, so the coordinator never sees the value and a reply echoing it depends on model compliance; only the persisted conversation and the reply it did give are asserted"
}

# ---------------------------------------------------------------- 4. a later thread; the hand edit

step_thread_context() {
  say "4. a thread started afterwards sees the redacted standing context; hand edit + 'memory sync'"
  # The coordinator is a real model: it answers step 3's chat and may rewrite the memory topic before this thread
  # starts (observed 2026-10-31: a ProjectMemoryWritten v2 by author coordinator:<project> with a clean description and
  # 0 redactions). Then MEMORY.md has no marker left and the standing context has nothing to redact, so the marker
  # checks below only discriminate when the index still carries one; otherwise they are UNVERIFIED, never a false FAIL.
  CTX_MARK_EXPECTED=0
  case "$(cat "$MEMORY_DIR/MEMORY.md" 2>/dev/null)" in *"$MARK"*) CTX_MARK_EXPECTED=1 ;; esac
  new_bead "e2e-$SUFFIX hello" "Create a file named hello.txt in the current directory containing the single word hello."
  [ -n "${BEAD_ID:-}" ] || die "br create returned no bead id" 2
  thread_for_bead "$BEAD_ID" 180
  if [ -z "$THREAD" ]; then
    fail "no thread appeared for bead $BEAD_ID within 180s (BeadsWatcher did not import it)"
  else
    pass "thread $THREAD started afterwards from bead $BEAD_ID (text without the value)"
    run_for_thread "$THREAD"
    CTX_RUN=$RUN
    if [ -z "$CTX_RUN" ]; then
      unverified "project-context.md of the later thread" "thread $THREAD has no run after 120s"
    else
      note "run $CTX_RUN"
      wait_run "$CTX_RUN"
      pf="$ARCHIVE_DIR/run/$CTX_RUN/project-context.md"
      cn=0
      while [ ! -f "$pf" ] && [ "$cn" -lt 60 ]; do sleep 2; cn=$((cn + 2)); done
      if [ -f "$pf" ]; then
        pass "archive file $pf exists (run ended '$RUN_STATUS')"
        ctxmd=$(cat "$pf")
        assert_clean "project-context.md of the later run" "$V22" "$ctxmd"
        if [ "$MEM_DELIVERED" = 1 ]; then
          if [ "$CTX_MARK_EXPECTED" = 1 ]; then
            assert_marked "project-context.md of the later run (standing memory index)" "$ctxmd"
          else
            unverified "marker in project-context.md" "the MEMORY.md index no longer carried $MARK when this thread started: the coordinator rewrote the topic after step 2 (a later ProjectMemoryWritten by another author), so the context has no value-bearing text to redact; absence of the value is still asserted above"
          fi
          assert_has "project-context.md lists the memory topic" "$ctxmd" "$MEM_TOPIC"
        else
          unverified "marker in project-context.md" "no agent-written memory exists (step 2 UNVERIFIED), so there is no value-bearing memory text for the context to redact; absence of the value is still asserted above"
        fi
      elif [ "$RUN_STATUS" = completed ]; then
        fail "run $CTX_RUN completed but $pf was not archived within 60s"
      else
        unverified "project-context.md of the later thread" "run $CTX_RUN ended '$RUN_STATUS' and archived no project-context.md (foreman-azc2o kickoff failure?)"
        diagnose_run "$CTX_RUN"
      fi
    fi
  fi
  pcj=$(fm project context --format json "$PROJECT" 2>&1)
  printf '%s' "$pcj" > "$OUT/project-context.json"
  stext=$(printf '%s' "$pcj" | jq -r '.system_text // empty' 2>/dev/null)
  if [ -n "$stext" ]; then pass "foreman project context --format json returns the standing context"; else fail "foreman project context --format json has no system_text: $(printf '%s' "$pcj" | cut -c1-200)"; fi
  assert_clean "foreman project context --format json" "$V22" "$pcj"
  if [ "$MEM_DELIVERED" = 1 ] && [ "$CTX_MARK_EXPECTED" = 1 ]; then assert_marked "foreman project context system_text" "$stext"; fi

  # hand edit: the value lands in a memory topic file by hand, redaction happens at 'memory sync'
  mkdir -p "$MEMORY_DIR"
  tf="$MEMORY_DIR/$MEM_TOPIC.md"
  [ -f "$tf" ] || note "no agent-written topic exists: the hand edit creates $MEM_TOPIC.md (an untracked topic file for sync to record)"
  before=$(file_count "$MARK" "$tf")
  printf '\nHand-edited note: the deploy target is %s and the region code is %s. Releases follow the usual checklist and are verified by the on-call engineer afterwards.\n' "$V22" "$V7" >> "$tf"
  # precondition immediately before the step that depends on it: the value really is in the file now
  pre=$(file_count "$V22" "$tf")
  if [ "${pre:-0}" -ge 1 ]; then
    pass "hand edit landed: $tf holds the 22-char value $pre time(s) before 'memory sync'"
    if fm project memory sync "$PROJECT" >"$OUT/memory-sync.out" 2>&1; then
      pass "foreman project memory sync: $(tr '\n' ' ' < "$OUT/memory-sync.out" | cut -c1-160)"
    else
      fail "foreman project memory sync: $(tr '\n' ' ' < "$OUT/memory-sync.out" | cut -c1-300)"
    fi
    after=$(cat "$tf" 2>/dev/null)
    assert_clean "topic file after sync" "$V22" "$after"
    assert_marked "topic file after sync" "$after"
    mread2=$(fm project memory read --name "$MEM_TOPIC" "$PROJECT" 2>&1)
    assert_clean "memory read after sync" "$V22" "$mread2"
    assert_marked "memory read after sync" "$mread2"
    assert_has "topic file after sync: the 7-char value stays (documented 8-character floor)" "$after" "$V7"
    assert_clean "MEMORY.md after sync" "$V22" "$(cat "$MEMORY_DIR/MEMORY.md" 2>/dev/null)"
    note "redaction markers in the topic file: $before before the hand edit, $(file_count "$MARK" "$tf") after sync"
  else
    unverified "hand edit + memory sync redaction" "the value did not land in $tf (grep count $pre)"
  fi
}

# ---------------------------------------------------------------- 5. byte search

HIT_TOTAL=0
HIT_LINES=""

# count_stream <value>: NUL-separated file names on stdin -> HIT_TOTAL (occurrences), HIT_LINES (file: count)
count_stream() {
  cs_v=$1; HIT_TOTAL=0; HIT_LINES=""
  while IFS= read -r -d '' cs_f; do
    cs_n=$(grep -aoF -- "$cs_v" "$cs_f" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${cs_n:-0}" -gt 0 ]; then
      HIT_TOTAL=$((HIT_TOTAL + cs_n))
      HIT_LINES="$HIT_LINES
       $cs_f: $cs_n"
    fi
  done
}

# report_loc <tag> <value> <expect: clean|present|info> <label> <command shown>: uses HIT_TOTAL/HIT_LINES of the last count
report_loc() {
  rl_tag=$1; rl_e=$3; rl_l=$4
  out "   cmd: $5"
  out "   => $rl_l: $HIT_TOTAL occurrence(s)${HIT_LINES:+ in:$HIT_LINES}"
  case "$rl_e" in
    clean)
      if [ "$HIT_TOTAL" -eq 0 ]; then pass "$rl_tag in $rl_l: 0 hits (must be clean)"
      else fail "$rl_tag LEAKED into $rl_l: $HIT_TOTAL hit(s):$HIT_LINES"; fi ;;
    present)
      if [ "$HIT_TOTAL" -ge 1 ]; then pass "$rl_tag found in $rl_l: $HIT_TOTAL hit(s) (expected: it is stored/persisted there as documented)"
      else fail "$rl_tag NOT found in $rl_l (expected it to be there)"; fi ;;
    *) note "$rl_tag in $rl_l: $HIT_TOTAL hit(s) (informational)" ;;
  esac
}

# check_loc <tag> <value> <expect> <label> <path...>
check_loc() {
  ck_tag=$1; ck_v=$2; ck_e=$3; ck_l=$4; shift 4
  count_stream "$ck_v" < <(for ck_p in "$@"; do [ -e "$ck_p" ] && find "$ck_p" -type f -print0; done)
  ck_cmd="find $* -type f | xargs grep -aoF -- '$ck_v' | wc -l"
  for ck_p in "$@"; do [ -e "$ck_p" ] || ck_cmd="$ck_cmd   (absent: $ck_p)"; done
  report_loc "$ck_tag" "$ck_v" "$ck_e" "$ck_l" "$ck_cmd"
}

# check_other <tag> <value> <expect>: every file of the work dir not covered by the named locations and not a legitimate holder
check_other() {
  co_tag=$1; co_v=$2; co_e=$3
  count_stream "$co_v" < <(find "$WORK" \( -path "$SECRET_DIR" -o -path "$WORK/pi-agent/sessions" -o -path "$WORK/home/.pi" -o -path "$OUT" \
      -o -path "$SERVER_FILE_LOGS" -o -path "$RUNS_DIR" -o -path "$MEMORY_DIR" -o -path "$ARCHIVE_DIR" \
      -o -path "$WORK/home/Library/Caches/jido_harness" \) -prune \
      -o -type f ! -path "$SERVER_LOG" ! -path "$HOOK_CAPTURE" -print0)
  report_loc "$co_tag" "$co_v" "$co_e" "every other file under $WORK" \
    "find $WORK (pruned: secret store, pi session dirs, jido_harness cache (INFO line above), harness out/, the locations above) -type f | xargs grep -aoF -- '$co_v' | wc -l"
}

DB_DATA_TYPE=""
# check_db_events <tag> <value> <expect>: the events table, bytes of data and metadata
check_db_events() {
  ce_tag=$1; ce_v=$2; ce_e=$3
  if [ -z "$DB_DATA_TYPE" ]; then
    DB_DATA_TYPE=$(psql_db "$E2E_DB_NAME" -c "select data_type from information_schema.columns where table_name = 'events' and column_name = 'data'" 2>"$OUT/psql.err")
  fi
  if [ -z "$DB_DATA_TYPE" ]; then
    unverified "$ce_tag in the Postgres events table" "no events.data column found in $E2E_DB_NAME ($(head -c 200 "$OUT/psql.err" | tr '\n' ' ')); the whole-database sweep below does not depend on table names"
    return 0
  fi
  if [ "$DB_DATA_TYPE" = bytea ]; then
    ce_sql="select count(*) from events where position(convert_to(:'v', 'UTF8') in data) > 0 or position(convert_to(:'v', 'UTF8') in metadata) > 0;"
  else
    ce_sql="select count(*) from events where data::text like '%' || :'v' || '%' or metadata::text like '%' || :'v' || '%';"
  fi
  ce_n=$(printf '%s\n' "$ce_sql" | psql_db "$E2E_DB_NAME" -v "v=$ce_v" 2>"$OUT/psql.err")
  if [ -z "$ce_n" ]; then
    unverified "$ce_tag in the Postgres events table" "query failed: $(head -c 200 "$OUT/psql.err" | tr '\n' ' ')"
    return 0
  fi
  HIT_TOTAL=$ce_n; HIT_LINES=""
  if [ "$ce_n" -gt 0 ]; then
    ce_by=$(printf '%s\n' "select e.event_type || ' @ ' || s.stream_uuid || ' x' || count(*) from events e join stream_events se on se.event_id = e.event_id join streams s on s.stream_id = se.stream_id where s.stream_uuid <> '\$all' and (position(convert_to(:'v', 'UTF8') in e.data) > 0 or position(convert_to(:'v', 'UTF8') in e.metadata) > 0) group by 1 order by count(*) desc limit 20;" \
      | psql_db "$E2E_DB_NAME" -v "v=$ce_v" 2>/dev/null)
    HIT_LINES=""
    while IFS= read -r ce_l; do
      [ -n "$ce_l" ] && HIT_LINES="$HIT_LINES
       event rows (type @ stream xcount): $ce_l"
    done <<EOF
$ce_by
EOF
  fi
  report_loc "$ce_tag" "$ce_v" "$ce_e" "Postgres events table ($E2E_DB_NAME, column type $DB_DATA_TYPE; counts ROWS)" \
    "psql -h $E2E_PG_HOST -p $E2E_PG_PORT -U $E2E_PG_USER -d $E2E_DB_NAME -At -v v='$ce_v' <<< \"$ce_sql\""
}

# check_db_dump <tag> <value> <expect>: every table of the database (plain-text pg_dump, bytea as \x hex too)
check_db_dump() {
  cd_tag=$1; cd_v=$2; cd_e=$3
  if ! command -v pg_dump >/dev/null 2>&1; then
    unverified "$cd_tag in a whole-database dump" "pg_dump is not on PATH"
    return 0
  fi
  cd_hex=$(printf '%s' "$cd_v" | od -An -tx1 | tr -d ' \n')
  if ! pg_dump -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" --data-only "$E2E_DB_NAME" > "$OUT/db.sql" 2>"$OUT/pg_dump.err"; then
    unverified "$cd_tag in a whole-database dump" "pg_dump failed: $(head -c 200 "$OUT/pg_dump.err" | tr '\n' ' ')"
    rm -f "$OUT/db.sql"
    return 0
  fi
  HIT_TOTAL=$(grep -aoF -e "$cd_v" -e "$cd_hex" "$OUT/db.sql" | wc -l | tr -d ' ')
  HIT_LINES=""
  if [ "$HIT_TOTAL" -gt 0 ]; then
    HIT_LINES=$(LC_ALL=C awk -v v="$cd_v" -v h="$cd_hex" '/^COPY /{t=$2} index($0, v) || index($0, h) {n[t]++} END {for (k in n) printf "\n       %s: %d line(s)", k, n[k]}' "$OUT/db.sql")
  fi
  rm -f "$OUT/db.sql"
  report_loc "$cd_tag" "$cd_v" "$cd_e" "whole database $E2E_DB_NAME (every table; plain text and hex)" \
    "pg_dump -h $E2E_PG_HOST -p $E2E_PG_PORT -U $E2E_PG_USER --data-only $E2E_DB_NAME | grep -aoF -e '$cd_v' -e '$cd_hex' | wc -l"
}

step_byte_search() {
  say "5. byte search, before cleanup removes the database and the work dir"
  note "excluded because they legitimately hold the value: the 0600 secret store ($SECRET_DIR) and the agent's own session files ($WORK/pi-agent/sessions, $WORK/home/.pi)"
  note "counts are occurrences per file (grep -aoF | wc -l); the events table counts rows"
  # The jido_harness cache holds the AGENT'S OWN event stream (proc_*/run_*/00000000.jsonl). The agent was given the value by
  # design (stored secrets are injected into its env), so the stream legitimately contains it, like the pi session files. It
  # is reported as INFO with counts, not PASS/FAIL; whether that cache should be redacted is a product question (bead).
  jc_dir="$WORK/home/Library/Caches/jido_harness"
  if [ -d "$jc_dir" ]; then
    jc_n=$(grep -raoF -- "$V22" "$jc_dir" 2>/dev/null | wc -l | tr -d ' ')
    jc_f=$(grep -rlaF -- "$V22" "$jc_dir" 2>/dev/null | wc -l | tr -d ' ')
    note "INFO (not PASS/FAIL): the jido_harness cache ($jc_dir) holds the agent's own event stream: the 22-char value occurs $jc_n time(s) in $jc_f file(s); cmd: grep -rlaF -- <V22> $jc_dir"
  else
    note "INFO: no jido_harness cache directory at $jc_dir"
  fi
  t22="22-char value"
  t7="7-char value"

  say "5a. 22-char value ($V22): must be found ONLY in the secret store"
  check_loc "$t22" "$V22" present "the secret store (0600)" "$SECRET_DIR"
  check_db_events "$t22" "$V22" clean
  check_db_dump "$t22" "$V22" clean
  check_loc "$t22" "$V22" clean "server stdout/stderr log (\$SERVER_LOG)" "$SERVER_LOG"
  check_loc "$t22" "$V22" clean "server file log(s) (\$WORK/home/.foreman/logs/foreman-server.log)" "$SERVER_FILE_LOGS"
  check_loc "$t22" "$V22" clean "project memory dir (<repo>/.foreman/memory)" "$MEMORY_DIR"
  check_loc "$t22" "$V22" clean "run archive dir (<repo>/.foreman/sessions)" "$ARCHIVE_DIR"
  check_loc "$t22" "$V22" clean "runs dir (\$WORK/home/.foreman/runs)" "$RUNS_DIR"
  check_loc "$t22" "$V22" clean "webhook capture (\$HOOK_CAPTURE)" "$HOOK_CAPTURE"
  check_other "$t22" "$V22" clean

  say "5b. 7-char value ($V7): below the 8-character floor, so it is found where it is stored and in unredacted persisted text"
  check_loc "$t7" "$V7" present "the secret store (0600)" "$SECRET_DIR"
  check_db_events "$t7" "$V7" present
  check_db_dump "$t7" "$V7" info
  check_loc "$t7" "$V7" present "project memory dir (hand edit kept it: not redacted at sync)" "$MEMORY_DIR"
  check_loc "$t7" "$V7" info "server stdout/stderr log (\$SERVER_LOG)" "$SERVER_LOG"
  check_loc "$t7" "$V7" info "server file log(s) (\$WORK/home/.foreman/logs)" "$SERVER_FILE_LOGS"
  check_loc "$t7" "$V7" info "run archive dir (<repo>/.foreman/sessions)" "$ARCHIVE_DIR"
  check_loc "$t7" "$V7" info "runs dir (\$WORK/home/.foreman/runs)" "$RUNS_DIR"
  check_loc "$t7" "$V7" info "webhook capture (\$HOOK_CAPTURE)" "$HOOK_CAPTURE"
  check_other "$t7" "$V7" info
}

# ---------------------------------------------------------------- main

say "foreman redaction-by-value live e2e: provider=$E2E_PROVIDER model=$E2E_AGENT_MODEL"
setup_all
step_secrets
step_agent_memory
step_chat
step_thread_context
step_byte_search
summary
exit $?
