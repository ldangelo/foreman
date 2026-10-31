#!/usr/bin/env bash
# Live acceptance of the coordinator's operator-grade actions, setup proposal and usage (bead foreman-fas1b, C5/C10/C11).
#
#   COORD_PROVIDER=claude COORD_MODEL=haiku devbox run -- bash scripts/e2e/coordinator_live_actions.sh
#   COORD_PROVIDER=pi COORD_MODEL=minimax/MiniMax-M2.7-highspeed devbox run -- bash scripts/e2e/coordinator_live_actions.sh
#
# One throwaway server (own port, database, scratch repos; scripts/e2e/claude_projects/lib.sh), the coordinator on a REAL provider:
#   1. setup proposal: a project over a repository WITHOUT AGENTS.md; the first conversation message is the setup_proposal
#      (no model turn); "apply N" applies the AGENTS.md fix; `project recommend` no longer lists it; /setup posts a fresh proposal
#   2. add_repo: an operator chat turn adds a second checkout (executed, repo list shows added_by coordinator:<project>);
#      a machine turn (source mcp) that asks for the same adds nothing
#   2b. invented quote: an operator turn tells the model to alter the `quote` of its add_repo action, so the action the model emits
#      carries words that are NOT in the operator's message (the script writes no action itself; whether the quote really is
#      non-verbatim is judged here, from the recorded CoordinatorActionRecorded params, by a restatement of the policy's
#      normalisation). The action must be `rejected` ("exact words") and register nothing; an action with no quote is refused the
#      same way; the same request quoted verbatim is then executed (positive control). A model that quotes verbatim anyway is
#      recorded UNVERIFIED, never a pass.
#   3. schedule: an operator turn asks for a recurring task (executed, schedule list, auto_approve false when the project
#      proposes before start); a sub-300 s interval is refused and the refusal is visible in the conversation
#   4. usage: `usage --by role` lists role coordinator with the tokens the CoordinatorUsageRecorded events carry, the
#      total includes it, `--by thread` does not list it. With pi a transparent `pi` shim
#      (coordinator_live_actions/pi-capture.sh) keeps pi's own raw JSON stream of every coordinator turn and the events must equal
#      the sum pi itself reported there (input, output, cache read/write, total, cost).
# Prints PASS / FAIL / UNVERIFIED per assertion; exit 3 on any FAIL.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
COORD_PROVIDER=${COORD_PROVIDER:-claude}
COORD_MODEL=${COORD_MODEL:-haiku}
E2E_NAME=${E2E_NAME:-coordlive_$COORD_PROVIDER}
E2E_PORT=${E2E_PORT:-4830}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4930}
E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0"
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/claude_home.sh
. "$HERE/claude_projects/claude_home.sh"

check_environment
install_traps

TURN_TIMEOUT=${E2E_TURN_TIMEOUT:-5m}
REPO2="$WORK/repo2"
ORIGIN2="$WORK/origin2.git"
REPO3="$WORK/repo3"
ORIGIN3="$WORK/origin3.git"
REPO5="$WORK/repo5"
ORIGIN5="$WORK/origin5.git"
REPO6="$WORK/repo6"
ORIGIN6="$WORK/origin6.git"
REPO7="$WORK/repo7"
ORIGIN7="$WORK/origin7.git"
REPO8="$WORK/repo8"
ORIGIN8="$WORK/origin8.git"

provider_ready() {
  case "$COORD_PROVIDER" in
    claude)
      claude_private_home || return 1
      claude_ready ;;
    pi)
      if pi --list-models "${COORD_MODEL#*/}" 2>&1 | grep -v "No models matching" | grep -qi "${COORD_MODEL#*/}"; then return 0; fi
      CLAUDE_UNAVAILABLE="pi on this host lists no model matching '${COORD_MODEL#*/}' (pi --list-models)"; return 1 ;;
    *) CLAUDE_UNAVAILABLE="unknown COORD_PROVIDER '$COORD_PROVIDER'"; return 1 ;;
  esac
}

# chat <text> -> CHAT_OUT, CHAT_RC (waits for the coordinator to go idle with no pending message)
chat() {
  CHAT_OUT=$(fm project chat --timeout "$TURN_TIMEOUT" -m "$1" "$PROJECT" 2>&1); CHAT_RC=$?
  out "   chat> $1"
  out "   reply[$CHAT_RC]: $(printf '%s' "$CHAT_OUT" | tr '\n' ' ' | cut -c1-600)"
}
history_json() { fm project chat --history 100 --format json "$PROJECT" 2>&1; }
repo_list() { fm project repo list --format json "$PROJECT" 2>&1 || fm project repo list "$PROJECT" 2>&1; }
sched_list() { fm project schedule list --project-id "$PROJECT" --json 2>&1; }
usage_json() { api_get "/api/projects/$PROJECT/usage?group_by=$1"; }

mcp_post_message() { # <text>: foreman_project_message over /mcp (source is always "mcp": a machine turn)
  hdr="$WORK/mcp-init.headers"
  curl -sS -D "$hdr" -o "$WORK/mcp-init.out" --max-time 30 -X POST "$API/mcp" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -H 'accept: application/json' \
    -H 'mcp-protocol-version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"coord-live","version":"1"}}}' >/dev/null 2>&1
  sid=$(grep -i '^mcp-session-id:' "$hdr" | head -n 1 | sed 's/^[^:]*: *//' | tr -d '\r\n ')
  curl -sS -o /dev/null --max-time 30 -X POST "$API/mcp" -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' \
    -H 'accept: application/json' -H 'mcp-protocol-version: 2025-06-18' -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1
  body=$(jq -nc --arg p "$PROJECT" --arg t "$1" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"foreman_project_message",arguments:{project_id:$p,text:$t}}}')
  curl -sS --max-time 60 -X POST "$API/mcp" -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' \
    -H 'accept: application/json' -H 'mcp-protocol-version: 2025-06-18' -H "mcp-session-id: $sid" -d "$body" 2>&1 | head -c 600
}

# wait_idle: until the coordinator is idle with no pending message
wait_idle() {
  wi=$(date +%s)
  while :; do
    st=$(api_get "/api/projects/$PROJECT/coordinator/messages" | jq -r '"\(.status // "?") \(.pending_messages // 0)"' 2>/dev/null)
    [ "$st" = "idle 0" ] && return 0
    [ "$(elapsed "$wi")" -lt 300 ] || { note "coordinator not idle after 300 s: $st"; return 1; }
    sleep 3
  done
}

# norm / quote_in: the confirmation heuristic of Coordinator.Policy.quote_verified?/2 (lower case, runs of whitespace collapsed,
# trimmed, then a substring test), restated here on purpose so the harness judges the model's quote without asking the code under test.
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
quote_in() { # <operator message> <quote>
  qi_needle=$(norm "$2"); qi_hay=$(norm "$1")
  case "$qi_hay" in *"$qi_needle"*) return 0 ;; *) return 1 ;; esac
}

# dump_events: every event of the event store, decoded, into $WORK/events.jsonl (event_store_dump.exs runs on the server node)
dump_events() {
  de_code=$(cat "$ASSETS/event_store_dump.exs")
  elixir --name "e2eevd$$@127.0.0.1" --cookie "$COOKIE" --hidden --rpc-eval "$NODE" "$de_code" 2>&1 | grep '^EVIDENCE ' | cut -c10- > "$WORK/events.jsonl"
}

# add_repo_actions <directory name>: this project's recorded add_repo actions whose path names that directory, one JSON object each
add_repo_actions() {
  jq -c --arg p "$PROJECT" --arg d "$1" 'select(.type == "CoordinatorActionRecorded" and .data.project_id == $p and .data.kind == "add_repo" and ((.data.params.path // "") | contains($d))) | .data | {action_id, status, reason, path: .params.path, quote: .params.quote}' "$WORK/events.jsonl"
}

# install_pi_capture: puts the `pi` shim of coordinator_live_actions/pi-capture.sh first on the server's PATH and restarts the server,
# so every pi `--mode json` run of the coordinator leaves its raw event stream in $WORK/pi-capture.
install_pi_capture() {
  mkdir -p "$WORK/pi-shim" "$WORK/pi-capture"
  sed -e "s|__SHIM_DIR__|$WORK/pi-shim|" -e "s|__CAPTURE_DIR__|$WORK/pi-capture|" "$HERE/coordinator_live_actions/pi-capture.sh" > "$WORK/pi-shim/pi"
  chmod +x "$WORK/pi-shim/pi"
  E2E_PATH_PREFIX="$WORK/pi-shim"
  stop_server; start_server
  note "pi shim installed first on the server's PATH; raw pi streams are kept in $WORK/pi-capture"
}

# ---------------------------------------------------------------- setup

setup_stack
if provider_ready; then
  note "provider $COORD_PROVIDER/$COORD_MODEL is ready"
else
  unverified "coordinator on $COORD_PROVIDER/$COORD_MODEL" "$CLAUDE_UNAVAILABLE"
  summary; exit $?
fi
if [ "$COORD_PROVIDER" = claude ]; then
  # restart so the server's HOME has the private claude home built above
  stop_server; start_server
fi
if [ "$COORD_PROVIDER" = pi ]; then install_pi_capture; fi
make_repo "$REPO2" "$ORIGIN2" || die "cannot create $REPO2" 2
make_repo "$REPO3" "$ORIGIN3" || die "cannot create $REPO3" 2
make_repo "$REPO5" "$ORIGIN5" || die "cannot create $REPO5" 2
make_repo "$REPO6" "$ORIGIN6" || die "cannot create $REPO6" 2
make_repo "$REPO7" "$ORIGIN7" || die "cannot create $REPO7" 2
make_repo "$REPO8" "$ORIGIN8" || die "cannot create $REPO8" 2

# ---------------------------------------------------------------- 1. setup proposal (before any model turn)

say "1. setup proposal on a repository without AGENTS.md"
[ ! -e "$REPO/AGENTS.md" ] && pass "scratch repo has no AGENTS.md" || fail "AGENTS.md exists"
register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
sleep 8
H0=$(history_json); printf '%s\n' "$H0" > "$WORK/history-0.json"
first_kind=$(printf '%s' "$H0" | jq -r '[.. | objects | select(has("kind") and has("role"))][0] | "\(.role)/\(.kind)"' 2>/dev/null)
assert_eq "the FIRST conversation message is the setup proposal (posted without a model turn)" "$first_kind" "system/setup_proposal"
proposal=$(printf '%s' "$H0" | jq -r '[.. | objects | select(.kind? == "setup_proposal")][0].text // empty' 2>/dev/null)
out "   proposal: $(printf '%s' "$proposal" | tr '\n' '|' | cut -c1-700)"
usage0=$(usage_json role); assert_not_has "no coordinator usage before any model turn" "$usage0" '"role": "coordinator"'
rec_before=$(fm project recommend --format json "$PROJECT" 2>&1); printf '%s\n' "$rec_before" > "$WORK/recommend-before.json"
assert_has "project recommend lists the AGENTS.md item before the fix" "$rec_before" "AGENTS"
N=$(printf '%s' "$proposal" | grep -i 'agents' | head -n 1 | sed -n 's/^[^0-9]*\([0-9][0-9]*\)[.)].*/\1/p')
note "AGENTS.md item number in the proposal: ${N:-not found}"

fm project update --coordinator-provider "$COORD_PROVIDER" --coordinator-model "$COORD_MODEL" --thread-model "$COORD_MODEL" \
  --max-concurrent-runs 2 "$PROJECT" >"$WORK/project-update.out" 2>&1 \
  && pass "coordinator set to $COORD_PROVIDER/$COORD_MODEL" || fail "project update: $(cut -c1-200 "$WORK/project-update.out")"
if [ -n "$N" ]; then
  # AGENTS.md has a MANUAL fix (Recommendations.applicable?/1 is false), so the proposal must not offer "apply N" for it and the
  # model must say so instead of inventing a fix (the bead's "apply 1 applies the AGENTS.md fix" premise does not hold).
  assert_not_has "the proposal does not offer 'apply $N' for the manual AGENTS.md item" "$(printf '%s' "$proposal" | grep -i -A1 agents_md)" 'Reply "apply'
  chat "apply $N"
  wait_idle
  assert_not_has "no AGENTS.md was written by 'apply $N' (manual fix, nothing applied)" "$(ls "$REPO")" "AGENTS.md"
  assert_not_has "no recommendation was applied (no system change recorded)" "$(history_json | jq -r '[.. | objects | select(.kind? == "apply_recommendation") | .status] | join(",")' 2>/dev/null)" "executed"
fi

say "1b. setup proposal with a fix Foreman can apply: beads database present, task provider not beads (task_provider.wire_beads)"
REPO4="$WORK/repo4"; ORIGIN4="$WORK/origin4.git"
make_repo "$REPO4" "$ORIGIN4" || die "cannot create $REPO4" 2
(cd "$REPO4" && br init --prefix e2e >/dev/null 2>&1) || die "br init in $REPO4" 2
P2="e2e-cp2-$SUFFIX"
fm project create --id "$P2" --path "$REPO4" --task-provider github >"$WORK/project2-create.out" 2>&1 \
  && pass "second project registered over $REPO4 with a non-beads task provider" || { fail "project2 create: $(cut -c1-300 "$WORK/project2-create.out")"; }
sleep 8
PROJECT_SAVE=$PROJECT; PROJECT=$P2
H2=$(history_json); printf '%s\n' "$H2" > "$WORK/history-p2-0.json"
assert_eq "P2: the FIRST conversation message is the setup proposal" "$(printf '%s' "$H2" | jq -r '[.. | objects | select(has("kind") and has("role"))][0] | "\(.role)/\(.kind)"' 2>/dev/null)" "system/setup_proposal"
prop2=$(printf '%s' "$H2" | jq -r '[.. | objects | select(.kind? == "setup_proposal")][0].text // empty' 2>/dev/null)
out "   P2 proposal: $(printf '%s' "$prop2" | tr '\n' '|' | cut -c1-600)"
N2=$(printf '%s' "$prop2" | grep 'wire_beads' | head -n 1 | sed -n 's/^[^0-9]*\([0-9][0-9]*\)[.)].*/\1/p')
assert_has "P2 proposal offers apply for wire_beads" "$(printf '%s' "$prop2" | grep -i -A1 wire_beads)" "Reply \"apply $N2\""
assert_has "P2 recommend lists task_provider.wire_beads before" "$(fm project recommend --format json "$P2" 2>&1)" "task_provider.wire_beads"
fm project update --coordinator-provider "$COORD_PROVIDER" --coordinator-model "$COORD_MODEL" "$P2" >"$WORK/project2-update.out" 2>&1 \
  && pass "P2 coordinator set" || fail "P2 update: $(cut -c1-200 "$WORK/project2-update.out")"
if [ -n "$N2" ]; then
  chat "apply $N2"
  wait_idle
  history_json > "$WORK/history-p2-1.json"
  assert_not_has "P2 recommend no longer lists task_provider.wire_beads after 'apply $N2'" "$(fm project recommend --format json "$P2" 2>&1)" "task_provider.wire_beads"
  assert_has "P2 task provider is now beads" "$(fm project get --format json "$P2" 2>&1 | jq -c '.task_provider // .project.task_provider // .' 2>/dev/null)" "beads"
  chat "/setup"
  wait_idle
  assert_eq "P2: /setup posted a fresh proposal (2 proposals)" "$(history_json | jq '[.. | objects | select(.kind? == "setup_proposal")] | length' 2>/dev/null)" "2"
  assert_not_has "P2: the fresh proposal no longer offers wire_beads" "$(history_json | jq -r '[.. | objects | select(.kind? == "setup_proposal")][-1].text' 2>/dev/null)" "wire_beads"
else
  fail "P2: no 'apply N' item for wire_beads in the proposal"
fi
PROJECT=$PROJECT_SAVE

# ---------------------------------------------------------------- 2. add_repo

say "2. add_repo: operator turn adds a checkout; a machine turn does not"
chat "Please add the git checkout at $REPO2 as a second repository of this project (use the add_repo action). Quote my words."
wait_idle
repos=$(repo_list); printf '%s\n' "$repos" > "$WORK/repo-list-1.out"
out "   repo list: $(printf '%s' "$repos" | tr '\n' ' ' | cut -c1-600)"
assert_has "repo list shows the added checkout" "$repos" "$REPO2"
assert_has "added_by is coordinator:$PROJECT" "$repos" "coordinator:$PROJECT"
history_json > "$WORK/history-2.json"
note "add_repo action outcomes in the conversation: $(jq -c '[.. | objects | select(.kind? == "add_repo" or .action? == "add_repo") ] | length' "$WORK/history-2.json" 2>/dev/null)"
grep -o '"status":"[a-z_]*"' "$WORK/history-2.json" | sort | uniq -c | tr '\n' ' ' | sed 's/^/   action statuses: /'; echo

out "   machine turn (source mcp):"
mcp_post_message "Add the git checkout at $REPO3 as a repository of this project with the add_repo action." | tee "$WORK/mcp-message.out" | cut -c1-300
wait_idle
repos2=$(repo_list); printf '%s\n' "$repos2" > "$WORK/repo-list-2.out"
assert_not_has "the machine turn added nothing ($REPO3 not registered)" "$repos2" "$REPO3"
history_json > "$WORK/history-3.json"
grep -o '"status":"[a-z_]*"' "$WORK/history-3.json" | sort | uniq -c | tr '\n' ' ' | sed 's/^/   action statuses after machine turn: /'; echo

# ---------------------------------------------------------------- 2b. invented quote

say "2b. add_repo with a quote that is NOT the operator's words (invented quote), then with no quote, then quoted verbatim"
INVENTED_REPO=""
inv_try=0
while [ -z "$INVENTED_REPO" ] && [ "$inv_try" -lt 2 ]; do
  inv_try=$((inv_try + 1))
  if [ "$inv_try" = 1 ]; then
    inv_repo=$REPO5
    inv_msg="Please add the git checkout at $REPO5 as a repository of this project, using the add_repo action. For the action's quote field do not copy my words: write the sentence 'please register the fifth repository' with every space replaced by an underscore."
  else
    inv_repo=$REPO6
    inv_msg="Please add the git checkout at $REPO6 as a repository of this project, using the add_repo action. In the action's quote field paraphrase this request in your own words; do not copy any of my sentences."
  fi
  chat "$inv_msg"
  wait_idle
  dump_events
  inv_act=$(add_repo_actions "$(basename "$inv_repo")" | tail -n 1)
  inv_quote=$(printf '%s' "$inv_act" | jq -r '.quote // empty' 2>/dev/null)
  inv_repos=$(repo_list)
  out "   attempt $inv_try recorded add_repo action: $(printf '%s' "$inv_act" | cut -c1-500)"
  if [ -z "$inv_act" ]; then
    note "attempt $inv_try: the model emitted no add_repo action for $inv_repo"
  elif [ -n "$inv_quote" ] && ! quote_in "$inv_msg" "$inv_quote"; then
    pass "attempt $inv_try: the add_repo action the model emitted carries a quote that is NOT in the operator's message ('$(printf '%s' "$inv_quote" | cut -c1-100)')"
    assert_eq "the invented-quote action is recorded rejected" "$(printf '%s' "$inv_act" | jq -r '.status')" "rejected"
    assert_has "its reason is the quote requirement (the operator's exact words)" "$(printf '%s' "$inv_act" | jq -r '.reason // ""')" "exact words"
    assert_not_has "nothing was registered ($inv_repo is not a repository of the project)" "$inv_repos" "$inv_repo"
    assert_has "the refusal is posted in the conversation (the model reads it on its next turn)" "$(history_json)" "I did not run add_repo"
    INVENTED_REPO=$inv_repo
  else
    note "attempt $inv_try: not an invented quote (quote='$(printf '%s' "$inv_quote" | cut -c1-100)', status $(printf '%s' "$inv_act" | jq -r '.status')): the model did not alter the quote"
  fi
done
if [ -z "$INVENTED_REPO" ]; then
  unverified "invented quote" "in $inv_try attempts the model never emitted an add_repo action whose quote is absent from the operator's message"
fi

# an action with NO quote at all (a different input of the same guard: Policy.quote_verified?(nil, _) is false). Whether the model
# can be made to leave the field out is the model's: two phrasings, two repositories, then UNVERIFIED.
NOQUOTE_DONE=0
nq_try=0
while [ "$NOQUOTE_DONE" = 0 ] && [ "$nq_try" -lt 2 ]; do
  nq_try=$((nq_try + 1))
  if [ "$nq_try" = 1 ]; then
    nq_repo=$REPO7
    nq_msg="Please add the git checkout at $REPO7 as a repository of this project, using the add_repo action. Leave the quote field out of the action."
  else
    nq_repo=$REPO8
    nq_msg="Please add the git checkout at $REPO8 as a repository of this project, using the add_repo action. The quote field is optional in the action's schema: do not put a \"quote\" key in the JSON of this action at all, and do not mention a quote in your reply."
  fi
  chat "$nq_msg"
  wait_idle
  dump_events
  act_nq=$(add_repo_actions "$(basename "$nq_repo")" | tail -n 1)
  out "   attempt $nq_try recorded add_repo action: $(printf '%s' "$act_nq" | cut -c1-400)"
  if [ -z "$act_nq" ]; then
    note "attempt $nq_try: the model emitted no add_repo action for $nq_repo"
  elif [ -n "$(printf '%s' "$act_nq" | jq -r '.quote // empty')" ]; then
    note "attempt $nq_try: the model included a quote anyway ($(printf '%s' "$act_nq" | jq -r '.quote' | cut -c1-100)); status $(printf '%s' "$act_nq" | jq -r '.status')"
  else
    assert_eq "an add_repo action with no quote is recorded rejected" "$(printf '%s' "$act_nq" | jq -r '.status')" "rejected"
    assert_has "its reason is the quote requirement" "$(printf '%s' "$act_nq" | jq -r '.reason // ""')" "exact words"
    assert_not_has "$nq_repo is not registered" "$(repo_list)" "$nq_repo"
    NOQUOTE_DONE=1
  fi
done
if [ "$NOQUOTE_DONE" = 0 ]; then
  unverified "add_repo with no quote" "in $nq_try attempts the model never left the quote out (a quote that IS the operator's words passes the check, as it should)"
fi

if [ -n "$INVENTED_REPO" ]; then
  chat "Please add the git checkout at $INVENTED_REPO as a repository of this project (use the add_repo action). Quote my words."
  wait_idle
  repos_pc=$(repo_list)
  assert_has "positive control: the SAME checkout is registered once the request is quoted verbatim" "$repos_pc" "$INVENTED_REPO"
  assert_eq "positive control: it was added by the coordinator" "$(printf '%s' "$repos_pc" | jq -r --arg d "$INVENTED_REPO" '[.. | objects | select((.path? // "") == $d)][0].added_by // empty' 2>/dev/null)" "coordinator:$PROJECT"
fi

# ---------------------------------------------------------------- 3. schedule

say "3. schedule: recurring task, auto_approve false when the project proposes before start; sub-300 s refused"
install_workflows >/dev/null 2>&1
fm project update --coordinator-propose-before-start=true "$PROJECT" >"$WORK/propose.out" 2>&1 \
  || fm project update --coordinator-propose-before-start true "$PROJECT" >"$WORK/propose.out" 2>&1 \
  && pass "project proposes before start" || fail "could not set propose-before-start: $(cut -c1-200 "$WORK/propose.out")"
chat "Create a schedule that runs the workflow edit every 15 minutes with the prompt 'append a line to notes.txt'. Use the schedule action and quote my words."
wait_idle
sch=$(sched_list); printf '%s\n' "$sch" > "$WORK/schedule-list-1.json"
out "   schedule list: $(printf '%s' "$sch" | tr '\n' ' ' | cut -c1-600)"
assert_has "schedule list shows the 15 minute schedule" "$sch" "notes.txt"
assert_has "auto_approve is false" "$(printf '%s' "$sch" | jq -c '[.. | objects | select(has("auto_approve")) | .auto_approve]' 2>/dev/null)" "false"
chat "Now schedule the workflow edit every 1 minute with the prompt 'tick'. Use the schedule action and quote my words."
wait_idle
sch2=$(sched_list); printf '%s\n' "$sch2" > "$WORK/schedule-list-2.json"
assert_not_has "no 1 minute schedule exists (interval floor 300 s)" "$sch2" '"tick"'
history_json > "$WORK/history-4.json"
refusal=$(jq -r '[.. | objects | select(.role? != null) | .text? // empty] | map(select(test("interval|300|floor|too short|minimum|refus"; "i"))) | last // empty' "$WORK/history-4.json" 2>/dev/null)
out "   refusal text visible in the conversation: $(printf '%s' "$refusal" | cut -c1-400)"
[ -n "$refusal" ] && pass "a refusal reason is visible in the conversation" || fail "no refusal reason found in the conversation"

# ---------------------------------------------------------------- 4. usage

say "4. coordinator usage"
dump_events
jq -c --arg p "$PROJECT" 'select(.type == "CoordinatorUsageRecorded" and .data.project_id == $p) | .data | {turn_id, provider, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, cost_usd}' "$WORK/events.jsonl" > "$WORK/coordinator-usage-events.jsonl"
n_ev=$(grep -c . "$WORK/coordinator-usage-events.jsonl")
out "   CoordinatorUsageRecorded events: $n_ev"; cat "$WORK/coordinator-usage-events.jsonl" | cut -c1-300
[ "$n_ev" -gt 0 ] && pass "turns recorded usage ($n_ev events)" || fail "no CoordinatorUsageRecorded event"
ev_total=$(jq -s '[.[].total_tokens // 0] | add // 0' "$WORK/coordinator-usage-events.jsonl")
ev_in=$(jq -s '[.[].input_tokens // 0] | add // 0' "$WORK/coordinator-usage-events.jsonl")
ev_out=$(jq -s '[.[].output_tokens // 0] | add // 0' "$WORK/coordinator-usage-events.jsonl")
by_role=$(usage_json role); printf '%s\n' "$by_role" > "$WORK/usage-by-role.json"
by_thread=$(usage_json thread); printf '%s\n' "$by_thread" > "$WORK/usage-by-thread.json"
by_model=$(usage_json model); printf '%s\n' "$by_model" > "$WORK/usage-by-model.json"
out "   foreman usage --by role:"; fm usage --project "$PROJECT" --by role 2>&1 | sed 's/^/     /'
row_total=$(printf '%s' "$by_role" | jq '[.by_role[]? | select(.role == "coordinator") | .total_tokens // 0] | add // 0')
row_in=$(printf '%s' "$by_role" | jq '[.by_role[]? | select(.role == "coordinator") | .input_tokens // 0] | add // 0')
row_out=$(printf '%s' "$by_role" | jq '[.by_role[]? | select(.role == "coordinator") | .output_tokens // 0] | add // 0')
assert_eq "role coordinator total_tokens = sum of the events' total_tokens" "$row_total" "$ev_total"
assert_eq "role coordinator input_tokens = sum of the events" "$row_in" "$ev_in"
assert_eq "role coordinator output_tokens = sum of the events" "$row_out" "$ev_out"
tot=$(printf '%s' "$by_role" | jq '.totals.total_tokens // 0')
assert_eq "the project total includes the coordinator (total = coordinator row, no other roles ran)" "$tot" "$row_total"
assert_not_has "--by thread does not list the coordinator" "$by_thread" '"coordinator"'
cost_ev=$(jq -s '[.[] | .cost_usd] | map(select(. != null)) | length' "$WORK/coordinator-usage-events.jsonl")
cost_row=$(printf '%s' "$by_role" | jq -c '[.by_role[]? | select(.role == "coordinator") | .cost_usd][0]')
note "events with a reported cost: $cost_ev of $n_ev; role row cost_usd: $cost_row"
if [ "$cost_ev" = 0 ]; then assert_eq "cost is null (unknown), not 0, when the provider reported none" "$cost_row" "null"; else note "provider reported cost for $cost_ev turns; cost_usd in the row: $cost_row"; fi
if [ "$COORD_PROVIDER" = claude ]; then
  sf=$(claude_session_files | tr '\n' ' ')
  cs_out=0
  for f in $sf; do
    o=$(jq -s '[.[] | select(.type == "assistant") | .message.usage.output_tokens // 0] | add // 0' "$f" 2>/dev/null); cs_out=$((cs_out + ${o:-0}))
  done
  note "claude's own session files: $(echo $sf | wc -w | tr -d ' ') files, summed message.usage.output_tokens = $cs_out (events: $ev_out)"
fi
if [ "$COORD_PROVIDER" = pi ]; then
  # pi's own raw stream (the shim): the sum of what pi reported in every assistant message of every coordinator turn, all projects
  cap_runs=$(ls "$WORK"/pi-capture/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  cap_usage=$(cat "$WORK"/pi-capture/*.jsonl 2>/dev/null | jq -c 'select(.type == "message_end" and .message.role == "assistant") | .message.usage // empty' 2>/dev/null)
  if [ "${cap_runs:-0}" -gt 0 ]; then pass "the pi shim kept the raw stream of $cap_runs pi runs"; else fail "the pi shim captured no pi --mode json run (the comparison below would be vacuous)"; fi
  cap_msgs=$(printf '%s\n' "$cap_usage" | grep -c .)
  ev_all_n=$(jq -s '[.[] | select(.type == "CoordinatorUsageRecorded")] | length' "$WORK/events.jsonl")
  note "pi runs captured: $cap_runs; assistant messages with usage: $cap_msgs; CoordinatorUsageRecorded events (all projects): $ev_all_n"
  for pf in "$WORK"/pi-capture/*.jsonl; do
    jq -rs '[.[] | select(.type == "message_end" and .message.role == "assistant")] as $m | "assistant messages \($m | length), tool calls \([$m[].message.content[]? | select(.type == "toolCall")] | length), input \([$m[].message.usage.input // 0] | add // 0), output \([$m[].message.usage.output // 0] | add // 0), total \([$m[].message.usage.totalTokens // 0] | add // 0)"' "$pf" 2>/dev/null | sed "s|^|     pi run $(basename "$pf" .jsonl): |"
  done
  for pair in input:input_tokens output:output_tokens cacheRead:cache_read_tokens cacheWrite:cache_write_tokens totalTokens:total_tokens; do
    raw_f=${pair%%:*}; ev_f=${pair##*:}
    raw_sum=$(printf '%s\n' "$cap_usage" | jq -s "[.[] | .$raw_f // 0] | add // 0")
    ev_sum=$(jq -s "[.[] | select(.type == \"CoordinatorUsageRecorded\") | .data.$ev_f // 0] | add // 0" "$WORK/events.jsonl")
    assert_eq "pi's own stream: $raw_f summed over its assistant messages = the recorded $ev_f summed (all projects)" "$ev_sum" "$raw_sum"
  done
  raw_cost=$(printf '%s\n' "$cap_usage" | jq -s '[.[] | .cost.total // 0] | add // 0')
  ev_cost_all=$(jq -s '[.[] | select(.type == "CoordinatorUsageRecorded") | .data.cost_usd // 0] | add // 0' "$WORK/events.jsonl")
  note "pi cost.total summed: $raw_cost; recorded cost_usd summed: $ev_cost_all"
  assert_true "pi's cost.total summed = the recorded cost_usd summed (within 1e-9)" jq -ne --argjson a "$raw_cost" --argjson b "$ev_cost_all" '(($a - $b) | fabs) < 1e-9'
fi
summary
exit $?
